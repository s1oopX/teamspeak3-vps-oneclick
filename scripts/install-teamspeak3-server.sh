#!/usr/bin/env bash
set -Eeuo pipefail

TS3_IMAGE_DEFAULT="${TS3_IMAGE_DEFAULT:-teamspeak:3.13.8}"
TS3_IMAGE="${TS3_IMAGE:-}"
TS3_IMAGE_FALLBACKS="${TS3_IMAGE_FALLBACKS:-docker.m.daocloud.io/library/teamspeak:3.13.8}"
TS3_PROJECT_DIR="${TS3_PROJECT_DIR:-/opt/teamspeak3-docker}"
TS3_DATA_DIR="${TS3_DATA_DIR:-${TS3_PROJECT_DIR}/data}"
TS3_CONTAINER_NAME="${TS3_CONTAINER_NAME:-teamspeak3}"
TS3_COMPOSE_PROJECT="${TS3_COMPOSE_PROJECT:-teamspeak3}"
TS3_VOICE_PORT="${TS3_VOICE_PORT:-9987}"
TS3_QUERY_PORT="${TS3_QUERY_PORT:-10011}"
TS3_QUERY_BIND="${TS3_QUERY_BIND:-127.0.0.1}"
TS3_FILE_PORT="${TS3_FILE_PORT:-30033}"
TS3_CONTAINER_UID="${TS3_CONTAINER_UID:-9987}"
TS3_CONTAINER_GID="${TS3_CONTAINER_GID:-9987}"
PUBLIC_IP="${PUBLIC_IP:-}"
TS3_SERVER_PASSWORD="${TS3_SERVER_PASSWORD:-}"
TS3_IMAGE_PLATFORM=""

log() {
  printf '[ts3-docker-install] %s\n' "$*"
}

fail() {
  printf '[ts3-docker-install] ERROR: %s\n' "$*" >&2
  exit 1
}

is_interactive() {
  [ -t 0 ] && [ -t 1 ]
}

print_welcome() {
  cat <<'EOF_WELCOME'

TeamSpeak 3 Server 一键部署
开源维护者: @s1oopX
GitHub: https://github.com/s1oopX
项目地址: https://github.com/s1oopX/teamspeak3-vps-oneclick

本脚本将帮助你在 VPS 上部署 TeamSpeak 3 Server，并尽量只暴露客户端必需端口。

EOF_WELCOME
}

prompt_server_password_choice() {
  if [ -n "$TS3_SERVER_PASSWORD" ]; then
    log "已检测到 TS3_SERVER_PASSWORD，容器启动后会自动设置服务器密码"
    return
  fi

  if ! is_interactive; then
    log "当前不是交互式终端；未提供 TS3_SERVER_PASSWORD 时服务器密码将保持为空"
    return
  fi

  local choice password confirm
  cat <<'EOF_PASSWORD'
请选择服务器密码设置方式:
  1) 自定义服务器密码
  2) 不设置密码
EOF_PASSWORD

  while true; do
    read -r -p "请输入选项 [1/2] (默认 2): " choice
    choice="${choice:-2}"
    case "$choice" in
      1)
        while true; do
          read -r -s -p "请输入服务器密码: " password
          printf '\n'
          if [ -z "$password" ]; then
            printf '密码不能为空；如果不需要密码，请返回选择 2。\n'
            continue
          fi
          read -r -s -p "请再次输入服务器密码: " confirm
          printf '\n'
          if [ "$password" != "$confirm" ]; then
            printf '两次输入不一致，请重新输入。\n'
            continue
          fi
          TS3_SERVER_PASSWORD="$password"
          log "服务器密码已确认；稍后会通过本地 ServerQuery 写入，不会保存到 .env"
          return
        done
        ;;
      2)
        log "本次不设置服务器密码；TeamSpeak 客户端连接时密码留空"
        return
        ;;
      *)
        printf '请输入 1 或 2。\n'
        ;;
    esac
  done
}

confirm_stage() {
  local title="$1"
  local description="$2"
  local choice

  cat <<EOF_STAGE

${title}
${description}
EOF_STAGE

  if ! is_interactive; then
    log "当前不是交互式终端；自动继续执行此阶段"
    return
  fi

  while true; do
    read -r -p "按 Enter 继续，输入 q 退出安装: " choice
    case "${choice:-}" in
      "")
        return
        ;;
      q|Q)
        fail "用户已取消安装"
        ;;
      *)
        printf '请按 Enter 继续，或输入 q 退出。\n'
        ;;
    esac
  done
}

run_stage() {
  local number="$1"
  local title="$2"
  local description="$3"
  shift 3

  confirm_stage "第 ${number}/8 步：${title}" "$description"
  log "开始：${title}"
  "$@"
  log "完成：${title}"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "run this script as root, for example: sudo bash install-teamspeak3-server.sh"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

redact_sensitive_logs() {
  sed -E \
    -e 's/(loginname= "serveradmin", password= ")[^"]*(")/\1[REDACTED]\2/Ig' \
    -e 's/(password[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/(token[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/(privilege key[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig'
}

check_platform() {
  [ -r /etc/os-release ] || fail "missing /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}:${ID_LIKE:-}" in
    *ubuntu*|*debian*) ;;
    *) log "warning: ${PRETTY_NAME:-unknown OS} is not the primary tested platform" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) TS3_IMAGE_PLATFORM="linux/amd64" ;;
    aarch64|arm64) TS3_IMAGE_PLATFORM="linux/arm64" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac

  log "detected Docker image platform: ${TS3_IMAGE_PLATFORM}"
}

check_docker() {
  require_command docker
  docker compose version >/dev/null 2>&1 || fail "missing Docker Compose plugin: docker compose"

  if ! docker info >/dev/null 2>&1; then
    fail "docker is installed but not usable. Check docker.service or run this script with sudo."
  fi
}

check_existing_container_name() {
  local existing_id existing_project
  existing_id="$(docker ps -aq --filter "name=^/${TS3_CONTAINER_NAME}$" | head -1 || true)"
  if [ -z "$existing_id" ]; then
    return
  fi

  existing_project="$(docker inspect -f '{{with index .Config.Labels "com.docker.compose.project"}}{{.}}{{end}}' "$existing_id" 2>/dev/null || true)"
  if [ "$existing_project" != "$TS3_COMPOSE_PROJECT" ]; then
    fail "container name ${TS3_CONTAINER_NAME} is already used by a non-matching Docker container. Remove or rename it before installing."
  fi

  log "found existing container from compose project ${TS3_COMPOSE_PROJECT}; treating this as an update/re-run"
}

image_manifest_ok() {
  local image="$1"
  local manifest
  if command -v timeout >/dev/null 2>&1; then
    manifest="$(timeout 35 docker manifest inspect --verbose "$image" 2>/dev/null)" || return 1
  else
    manifest="$(docker manifest inspect --verbose "$image" 2>/dev/null)" || return 1
  fi

  image_manifest_supports_platform "$manifest"
}

image_manifest_supports_platform() {
  local manifest="$1"
  local platform_os="${TS3_IMAGE_PLATFORM%%/*}"
  local platform_arch="${TS3_IMAGE_PLATFORM#*/}"

  if ! printf '%s\n' "$manifest" | grep -q '"platform"'; then
    return 0
  fi

  printf '%s\n' "$manifest" | awk -v os="$platform_os" -v arch="$platform_arch" '
    /"platform"[[:space:]]*:/ {
      in_platform = 1
      found_os = 0
      found_arch = 0
      next
    }
    in_platform && /}/ {
      if (found_os && found_arch) {
        supported = 1
      }
      in_platform = 0
    }
    in_platform && $0 ~ "\"os\"[[:space:]]*:[[:space:]]*\"" os "\"" {
      found_os = 1
    }
    in_platform && $0 ~ "\"architecture\"[[:space:]]*:[[:space:]]*\"" arch "\"" {
      found_arch = 1
    }
    END {
      exit (supported ? 0 : 1)
    }
  '
}

select_image() {
  if [ -n "$TS3_IMAGE" ]; then
    log "using image from TS3_IMAGE: ${TS3_IMAGE}"
    if ! image_manifest_ok "$TS3_IMAGE"; then
      fail "configured image is not reachable or does not support ${TS3_IMAGE_PLATFORM}: ${TS3_IMAGE}"
    fi
    return
  fi

  local candidate
  for candidate in "$TS3_IMAGE_DEFAULT" $TS3_IMAGE_FALLBACKS; do
    log "checking image reachability and platform support (${TS3_IMAGE_PLATFORM}): ${candidate}"
    if image_manifest_ok "$candidate"; then
      TS3_IMAGE="$candidate"
      log "selected image: ${TS3_IMAGE}"
      return
    fi
    log "image not reachable from this server or does not support ${TS3_IMAGE_PLATFORM}: ${candidate}"
  done

  fail "no reachable TeamSpeak image found for ${TS3_IMAGE_PLATFORM}. Set TS3_IMAGE to a reachable, compatible TeamSpeak image."
}

check_port_free() {
  local port="$1"
  local proto="$2"
  local container_port="$3"
  local ss_proto

  if command -v ss >/dev/null 2>&1; then
    case "$proto" in
      udp) ss_proto="-u" ;;
      tcp) ss_proto="-t" ;;
      *) fail "unsupported protocol for port check: $proto" ;;
    esac

    if ss -H -l -n "$ss_proto" "sport = :${port}" 2>/dev/null | grep -q .; then
      if docker ps --filter "name=^/${TS3_CONTAINER_NAME}$" --format '{{.Names}}' | grep -Fxq "$TS3_CONTAINER_NAME" &&
        docker port "$TS3_CONTAINER_NAME" "${container_port}/${proto}" 2>/dev/null | awk -F: '{print $NF}' | grep -Fxq "$port"; then
        log "port ${port}/${proto} is already used by ${TS3_CONTAINER_NAME}; allowing re-run"
        return
      fi
      fail "port ${port}/${proto} appears to be in use"
    fi
  fi
}

write_project_files() {
  log "creating project directory: ${TS3_PROJECT_DIR}"
  mkdir -p "$TS3_PROJECT_DIR" "$TS3_DATA_DIR"
  chown "${TS3_CONTAINER_UID}:${TS3_CONTAINER_GID}" "$TS3_DATA_DIR"
  chmod 775 "$TS3_DATA_DIR"

  cat > "${TS3_PROJECT_DIR}/.env" <<EOF_ENV
TS3_IMAGE=${TS3_IMAGE}
TS3_COMPOSE_PROJECT=${TS3_COMPOSE_PROJECT}
TS3_CONTAINER_NAME=${TS3_CONTAINER_NAME}
TS3_VOICE_PORT=${TS3_VOICE_PORT}
TS3_QUERY_PORT=${TS3_QUERY_PORT}
TS3_QUERY_BIND=${TS3_QUERY_BIND}
TS3_FILE_PORT=${TS3_FILE_PORT}
TS3_DATA_DIR=${TS3_DATA_DIR}
EOF_ENV

  cat > "${TS3_PROJECT_DIR}/compose.yaml" <<'EOF_COMPOSE'
services:
  teamspeak:
    image: ${TS3_IMAGE:-teamspeak:3.13.8}
    container_name: ${TS3_CONTAINER_NAME:-teamspeak3}
    restart: unless-stopped
    environment:
      TS3SERVER_LICENSE: accept
    ports:
      - "${TS3_VOICE_PORT:-9987}:9987/udp"
      - "${TS3_QUERY_BIND:-127.0.0.1}:${TS3_QUERY_PORT:-10011}:10011/tcp"
      - "${TS3_FILE_PORT:-30033}:30033/tcp"
    volumes:
      - "${TS3_DATA_DIR:-./data}:/var/ts3server/"
EOF_COMPOSE
}

configure_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    log "ufw not installed; skip local firewall rules"
    return
  fi

  if ufw status | grep -qi '^Status: active'; then
    log "configuring ufw rules"
    ufw allow "${TS3_VOICE_PORT}/udp" comment 'TeamSpeak voice'
    ufw allow "${TS3_FILE_PORT}/tcp" comment 'TeamSpeak file transfer'
    case "$TS3_QUERY_BIND" in
      0.0.0.0|"::") ufw allow "${TS3_QUERY_PORT}/tcp" comment 'TeamSpeak ServerQuery' ;;
      *)
        log "ServerQuery is bound to ${TS3_QUERY_BIND}; ensure no public ufw rule remains for ${TS3_QUERY_PORT}/tcp"
        ufw --force delete allow "${TS3_QUERY_PORT}/tcp" >/dev/null 2>&1 || true
        ;;
    esac
  else
    log "ufw installed but inactive; skip local firewall rules"
  fi
}

is_private_ipv4() {
  local ip="$1"
  case "$ip" in
    10.*|127.*|169.254.*|192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_public_ip() {
  if [ -n "$PUBLIC_IP" ]; then
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    PUBLIC_IP="$(curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  fi

  if [ -z "$PUBLIC_IP" ]; then
    local candidate
    for candidate in $(hostname -I 2>/dev/null || true); do
      if [ "${candidate#*:}" = "$candidate" ] && ! is_private_ipv4 "$candidate"; then
        PUBLIC_IP="$candidate"
        break
      fi
    done
  fi
}

admin_token_command() {
  printf 'sudo docker logs %s 2>&1 | grep -Ei '\''token|privilege'\'' | grep -Eiv '\''serveradmin|password'\''' "$TS3_CONTAINER_NAME"
}

get_admin_token_lines() {
  docker logs "$TS3_CONTAINER_NAME" 2>&1 | grep -Ei 'token|privilege' | grep -Eiv 'serveradmin|password' | tail -30 || true
}

print_admin_token_command() {
  cat <<EOF_TOKEN_COMMAND
稍后可在 VPS 上运行以下命令获取管理员一次性 Token:
  $(admin_token_command)

建议复制并妥善保存第一次管理员 Token。它用于首次进入服务器后获得管理员权限，通常只会在首次初始化日志中出现。
EOF_TOKEN_COMMAND
}

print_admin_token_now() {
  local token_lines
  token_lines="$(get_admin_token_lines)"

  if [ -n "$token_lines" ]; then
    cat <<'EOF_TOKEN_NOTICE'

管理员一次性 Token 已找到:

EOF_TOKEN_NOTICE
    printf '%s\n' "$token_lines"
    cat <<'EOF_TOKEN_IMPORTANT'

重要提示:
  - 这个 Token 用于首次进入服务器后获得服务器管理员权限。
  - 请不要公开分享它；使用后它会失效。
  - 在 TeamSpeak 客户端连接服务器后，进入 Permissions -> Use Privilege Key / Use Token 使用。

EOF_TOKEN_IMPORTANT
  else
    cat <<EOF_TOKEN
暂时没有检测到管理员 Token 日志。请等待 10-30 秒后在 VPS 上运行:
  $(admin_token_command)
EOF_TOKEN
  fi
}

prompt_admin_token_choice() {
  cat <<'EOF_TOKEN_CHOICE'
是否现在获取管理员一次性 Token?
  1) 获取
  2) 暂时不
EOF_TOKEN_CHOICE

  if ! is_interactive; then
    log "当前不是交互式终端；不会自动显示管理员 Token"
    print_admin_token_command
    return
  fi

  local choice
  while true; do
    read -r -p "请输入选项 [1/2] (默认 2): " choice
    choice="${choice:-2}"
    case "$choice" in
      1)
        print_admin_token_now
        return
        ;;
      2)
        print_admin_token_command
        return
        ;;
      *)
        printf '请输入 1 或 2。\n'
        ;;
    esac
  done
}

start_compose() {
  log "正在拉取镜像: ${TS3_IMAGE}；首次部署可能需要几分钟"
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    pull

  log "正在启动 TeamSpeak 容器"
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    up -d

  sleep 8
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    ps
}

verify_container_running() {
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$TS3_CONTAINER_NAME" 2>/dev/null || true)"
  if [ "$running" != "true" ]; then
    docker logs --tail=120 "$TS3_CONTAINER_NAME" 2>&1 | redact_sensitive_logs || true
    fail "container ${TS3_CONTAINER_NAME} is not running after startup"
  fi
}

check_required_ports() {
  check_port_free "$TS3_VOICE_PORT" udp 9987
  check_port_free "$TS3_QUERY_PORT" tcp 10011
  check_port_free "$TS3_FILE_PORT" tcp 30033
}

start_and_verify_service() {
  start_compose
  verify_container_running
}

set_server_password_if_requested() {
  if [ -z "$TS3_SERVER_PASSWORD" ]; then
    return
  fi

  require_command python3

  local query_password
  query_password="$(docker logs "$TS3_CONTAINER_NAME" 2>&1 | sed -n 's/.*loginname= "serveradmin", password= "\([^"]*\)".*/\1/p' | tail -1 || true)"
  if [ -z "$query_password" ]; then
    fail "TS3_SERVER_PASSWORD was set, but the ServerQuery admin password was not found in container logs"
  fi

  log "正在通过本地 ServerQuery 设置 TeamSpeak 服务器密码"
  TS3_QUERY_PORT_VALUE="$TS3_QUERY_PORT" \
  TS3_QUERY_PASSWORD="$query_password" \
  TS3_SERVER_PASSWORD_VALUE="$TS3_SERVER_PASSWORD" \
  python3 - <<'PY'
import os
import socket
import sys
import time

query_port = int(os.environ["TS3_QUERY_PORT_VALUE"])
query_password = os.environ["TS3_QUERY_PASSWORD"]
server_password = os.environ["TS3_SERVER_PASSWORD_VALUE"]

_ESCAPE = {
    "\\": "\\\\",
    "/": "\\/",
    " ": "\\s",
    "|": "\\p",
    "\a": "\\a",
    "\b": "\\b",
    "\f": "\\f",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
    "\v": "\\v",
}

def escape(value: str) -> str:
    return "".join(_ESCAPE.get(ch, ch) for ch in value)

def recv_until_error(sock: socket.socket) -> str:
    data = b""
    sock.settimeout(8)
    while b"error id=" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data.decode("utf-8", errors="replace")

def send(sock: socket.socket, command: str) -> str:
    sock.sendall((command + "\n").encode("utf-8"))
    return recv_until_error(sock)

last_error = None
for _ in range(12):
    try:
        with socket.create_connection(("127.0.0.1", query_port), timeout=5) as sock:
            sock.settimeout(5)
            sock.recv(4096)
            result = send(sock, f"login serveradmin {escape(query_password)}")
            if "error id=0" not in result:
                raise RuntimeError(f"ServerQuery login failed: {result.strip()}")
            result = send(sock, "use sid=1")
            if "error id=0" not in result:
                raise RuntimeError(f"ServerQuery use sid=1 failed: {result.strip()}")
            result = send(sock, f"serveredit virtualserver_password={escape(server_password)}")
            if "error id=0" not in result:
                raise RuntimeError(f"ServerQuery serveredit failed: {result.strip()}")
            send(sock, "quit")
            print("TeamSpeak server password set")
            sys.exit(0)
    except Exception as exc:
        last_error = exc
        time.sleep(2)

print(f"failed to set server password: {last_error}", file=sys.stderr)
sys.exit(1)
PY
}

print_next_steps() {
  detect_public_ip

  local client_address
  local server_password_status
  if [ "$TS3_VOICE_PORT" = "9987" ]; then
    client_address="${PUBLIC_IP}"
  else
    client_address="${PUBLIC_IP}:${TS3_VOICE_PORT}"
  fi

  if [ -z "$client_address" ] || [ "$client_address" = ":${TS3_VOICE_PORT}" ]; then
    if [ "$TS3_VOICE_PORT" = "9987" ]; then
      client_address="<your-vps-public-ip>"
    else
      client_address="<your-vps-public-ip>:${TS3_VOICE_PORT}"
    fi
  fi

  if [ -n "$TS3_SERVER_PASSWORD" ]; then
    server_password_status="已设置"
  else
    server_password_status="未设置；客户端连接时留空"
  fi

  cat <<EOF_NEXT

部署完成总结

所选镜像:
  ${TS3_IMAGE}

项目目录:
  ${TS3_PROJECT_DIR}

持久化数据目录:
  ${TS3_DATA_DIR}

容器名称:
  ${TS3_CONTAINER_NAME}

TeamSpeak 客户端连接信息:
  Server nickname: 可自定义，例如 My TeamSpeak VPS
  Server address:  ${client_address}
  Voice port:      ${TS3_VOICE_PORT}/udp
  Server password: ${server_password_status}
  Your nickname:   可自定义

首次进入服务器后:
  使用管理员一次性 Token / Privilege Key 获取服务器管理员权限。

常用维护命令:
  cd ${TS3_PROJECT_DIR}
  sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file .env -f compose.yaml ps
  sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file .env -f compose.yaml logs --tail=120 teamspeak
  sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file .env -f compose.yaml restart
  sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file .env -f compose.yaml down

云服务器安全组建议:
  ${TS3_VOICE_PORT}/udp  语音连接，必需
  ${TS3_FILE_PORT}/tcp  文件传输，建议放行
  ${TS3_QUERY_PORT}/tcp  ServerQuery，可选；只有 TS3_QUERY_BIND=0.0.0.0 且限制可信来源 IP 时才公网放行

EOF_NEXT

  prompt_admin_token_choice
}

main() {
  print_welcome
  require_root
  prompt_server_password_choice

  run_stage 1 "检查 VPS 系统和平台" \
    "将读取系统版本和 CPU 架构，并确认所选 TeamSpeak 镜像平台是否匹配当前 VPS。" \
    check_platform

  run_stage 2 "检查 Docker Engine 和 Docker Compose" \
    "将确认 docker 命令可用、Docker Compose 插件存在，并检查当前用户是否可以访问 Docker 服务。" \
    check_docker

  run_stage 3 "检查现有 TeamSpeak 容器" \
    "将检查是否已有同名容器；如果属于同一 Compose 项目，会按安全重跑处理，否则会停止安装并提示你先处理冲突。" \
    check_existing_container_name

  run_stage 4 "选择可访问的 TeamSpeak 镜像" \
    "将先检测官方镜像，再检测备用镜像，并选择当前 VPS 可访问且平台兼容的镜像。" \
    select_image

  run_stage 5 "检查必需端口是否空闲" \
    "将检查语音、文件传输和本地 ServerQuery 端口是否已被其他服务占用。" \
    check_required_ports

  run_stage 6 "写入 Docker Compose 项目文件" \
    "将创建项目目录、持久化数据目录、.env 和 compose.yaml；服务器密码不会写入 .env。" \
    write_project_files

  run_stage 7 "检查并配置本机防火墙规则" \
    "如果 ufw 已启用，将放行 TeamSpeak 客户端必需端口，并保持 ServerQuery 默认不公网暴露。" \
    configure_ufw

  run_stage 8 "启动并验证 TeamSpeak 服务" \
    "将拉取镜像、启动容器，并确认 TeamSpeak 容器处于运行状态。" \
    start_and_verify_service

  set_server_password_if_requested
  print_next_steps
}

main "$@"
