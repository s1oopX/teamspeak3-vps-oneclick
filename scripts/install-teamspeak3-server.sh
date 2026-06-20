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
  printf '[ts3-docker-install] 错误: %s\n' "$*" >&2
  exit 1
}

is_interactive() {
  [ -t 0 ] && [ -t 1 ]
}

print_welcome() {
  cat <<'EOF_WELCOME'

TeamSpeak 3 Server 一键部署
开源维护者: @s1oopX (https://github.com/s1oopX)
项目地址: https://github.com/s1oopX/teamspeak3-vps-oneclick

本脚本将在部署机上生成 Docker Compose 配置、启动 TeamSpeak 3 Server，并默认只开放客户端必需端口。

EOF_WELCOME
}

prompt_server_password_choice() {
  if [ -n "$TS3_SERVER_PASSWORD" ]; then
    log "已通过 TS3_SERVER_PASSWORD 提供服务器密码，服务启动后将自动写入。"
    return
  fi

  if ! is_interactive; then
    log "当前不是交互式终端，且未提供 TS3_SERVER_PASSWORD；服务器将保持无密码连接。"
    return
  fi

  local choice password confirm
  cat <<'EOF_PASSWORD'
请选择服务器连接密码设置方式:
  1) 设置自定义密码
  2) 不设置密码
EOF_PASSWORD

  while true; do
    read -r -p "请选择 [1/2] (默认 2): " choice
    choice="${choice:-2}"
    case "$choice" in
      1)
        while true; do
          read -r -s -p "请输入服务器连接密码: " password
          printf '\n'
          if [ -z "$password" ]; then
            printf '密码不能为空；如果不需要密码，请返回选择 2。\n'
            continue
          fi
          read -r -s -p "请再次输入服务器连接密码: " confirm
          printf '\n'
          if [ "$password" != "$confirm" ]; then
            printf '两次输入不一致，请重新输入。\n'
            continue
          fi
          TS3_SERVER_PASSWORD="$password"
          log "服务器密码已确认，稍后将通过部署机本地 ServerQuery 写入；不会保存到 .env。"
          return
        done
        ;;
      2)
        log "本次不设置服务器密码，TeamSpeak 客户端连接时密码留空。"
        return
        ;;
      *)
        printf '请输入 1 或 2。\n'
        ;;
    esac
  done
}

run_stage() {
  local number="$1"
  local title="$2"
  shift 2

  cat <<EOF_STAGE

[${number}/8] ${title}
EOF_STAGE

  log "开始：${title}"
  "$@"
  log "完成：${title}"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "请使用 root 权限运行，例如：sudo bash install-teamspeak3-server.sh"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少必要命令：$1"
}

redact_sensitive_logs() {
  sed -E \
    -e 's/(loginname= "serveradmin", password= ")[^"]*(")/\1[REDACTED]\2/Ig' \
    -e 's/(password[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/(token[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/(privilege key[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig'
}

check_platform() {
  [ -r /etc/os-release ] || fail "未找到 /etc/os-release，无法识别系统。"
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}:${ID_LIKE:-}" in
    *ubuntu*|*debian*) ;;
    *) log "提醒：${PRETTY_NAME:-未知系统} 不是主要验证平台，将继续尝试部署。" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) TS3_IMAGE_PLATFORM="linux/amd64" ;;
    aarch64|arm64) TS3_IMAGE_PLATFORM="linux/arm64" ;;
    *) fail "暂不支持当前 CPU 架构：$(uname -m)" ;;
  esac

  log "已识别 Docker 镜像平台: ${TS3_IMAGE_PLATFORM}"
}

check_docker() {
  require_command docker
  docker compose version >/dev/null 2>&1 || fail "缺少 Docker Compose 插件：docker compose"

  if ! docker info >/dev/null 2>&1; then
    fail "Docker 已安装但当前不可用，请检查 docker.service，或确认脚本已通过 sudo/root 执行。"
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
    fail "容器名 ${TS3_CONTAINER_NAME} 已被其他 Docker 容器占用，请先移除或重命名后再安装。"
  fi

  log "检测到现有 ${TS3_COMPOSE_PROJECT} 部署，将按重复执行/更新流程处理。"
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
    log "使用 TS3_IMAGE 指定的镜像: ${TS3_IMAGE}"
    if ! image_manifest_ok "$TS3_IMAGE"; then
      fail "指定镜像不可访问，或不支持 ${TS3_IMAGE_PLATFORM}: ${TS3_IMAGE}"
    fi
    return
  fi

  local candidate
  for candidate in "$TS3_IMAGE_DEFAULT" $TS3_IMAGE_FALLBACKS; do
    log "检测镜像可用性及平台支持 (${TS3_IMAGE_PLATFORM}): ${candidate}"
    if image_manifest_ok "$candidate"; then
      TS3_IMAGE="$candidate"
      log "已选择镜像: ${TS3_IMAGE}"
      return
    fi
    log "当前镜像不可用或不支持 ${TS3_IMAGE_PLATFORM}，继续尝试下一个镜像。"
  done

  fail "没有找到适用于 ${TS3_IMAGE_PLATFORM} 的可访问 TeamSpeak 镜像。请通过 TS3_IMAGE 指定兼容镜像。"
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
      *) fail "不支持的端口检查协议：$proto" ;;
    esac

    if ss -H -l -n "$ss_proto" "sport = :${port}" 2>/dev/null | grep -q .; then
      if docker ps --filter "name=^/${TS3_CONTAINER_NAME}$" --format '{{.Names}}' | grep -Fxq "$TS3_CONTAINER_NAME" &&
        docker port "$TS3_CONTAINER_NAME" "${container_port}/${proto}" 2>/dev/null | awk -F: '{print $NF}' | grep -Fxq "$port"; then
        log "端口 ${port}/${proto} 已由 ${TS3_CONTAINER_NAME} 使用，允许重复执行。"
        return
      fi
      fail "端口 ${port}/${proto} 已被占用，请释放端口后再运行。"
    fi
  fi
}

write_project_files() {
  log "准备部署目录: ${TS3_PROJECT_DIR}"
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
    log "未检测到 ufw，跳过部署机防火墙配置。"
    return
  fi

  if ufw status | grep -qi '^Status: active'; then
    log "配置部署机 ufw 防火墙规则。"
    ufw allow "${TS3_VOICE_PORT}/udp" comment 'TeamSpeak voice' >/dev/null
    ufw allow "${TS3_FILE_PORT}/tcp" comment 'TeamSpeak file transfer' >/dev/null
    case "$TS3_QUERY_BIND" in
      0.0.0.0|"::") ufw allow "${TS3_QUERY_PORT}/tcp" comment 'TeamSpeak ServerQuery' >/dev/null ;;
      *)
        log "ServerQuery 仅监听 ${TS3_QUERY_BIND}，不会公网放行 ${TS3_QUERY_PORT}/tcp。"
        ufw --force delete allow "${TS3_QUERY_PORT}/tcp" >/dev/null 2>&1 || true
        ;;
    esac
  else
    log "ufw 已安装但未启用，跳过部署机防火墙配置。"
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
  local ip_service
  if [ -n "$PUBLIC_IP" ]; then
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    for ip_service in \
      https://api.ipify.org \
      https://ifconfig.me/ip \
      https://icanhazip.com; do
      PUBLIC_IP="$(curl -fsS --connect-timeout 5 --max-time 10 "$ip_service" 2>/dev/null | tr -d '\r\n[:space:]' || true)"
      if [ -n "$PUBLIC_IP" ] && [ "${PUBLIC_IP#*:}" = "$PUBLIC_IP" ] && ! is_private_ipv4 "$PUBLIC_IP"; then
        return
      fi
      PUBLIC_IP=""
    done
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
稍后可在部署机上获取管理员一次性 Token:
  $(admin_token_command)

建议尽快获取并妥善保存；它用于首次授予服务器管理员权限。
EOF_TOKEN_COMMAND
}

print_admin_token_now() {
  local token_lines
  token_lines="$(get_admin_token_lines)"

  if [ -n "$token_lines" ]; then
    cat <<'EOF_TOKEN_NOTICE'

管理员一次性 Token:

EOF_TOKEN_NOTICE
    printf '%s\n' "$token_lines"
    cat <<'EOF_TOKEN_IMPORTANT'

使用位置:
  连接服务器后，在 TeamSpeak 客户端的 Permissions -> Use Privilege Key / Use Token 中使用。

重要提醒:
  该 Token 用于首次授予服务器管理员权限，请妥善保存，不要公开分享；使用后通常会失效。

EOF_TOKEN_IMPORTANT
  else
    cat <<EOF_TOKEN
暂未检测到管理员 Token 日志。请等待 10-30 秒后在部署机上运行:
  $(admin_token_command)
EOF_TOKEN
  fi
}

prompt_admin_token_choice() {
  cat <<'EOF_TOKEN_CHOICE'
是否现在获取管理员一次性 Token?
  1) 获取并显示
  2) 暂时不获取
EOF_TOKEN_CHOICE

  if ! is_interactive; then
    log "当前不是交互式终端，跳过管理员 Token 显示。"
    print_admin_token_command
    return
  fi

  local choice
  while true; do
    read -r -p "请选择 [1/2] (默认 2): " choice
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
  log "拉取镜像: ${TS3_IMAGE}。首次部署可能需要几分钟。"
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    pull

  log "启动 TeamSpeak 容器。"
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
    fail "容器 ${TS3_CONTAINER_NAME} 启动后未保持运行，请根据上方日志排查。"
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
    fail "已设置 TS3_SERVER_PASSWORD，但未能从容器日志中找到 ServerQuery 管理员密码。"
  fi

  log "通过部署机本地 ServerQuery 写入 TeamSpeak 服务器密码。"
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
                raise RuntimeError(f"ServerQuery 登录失败: {result.strip()}")
            result = send(sock, "use sid=1")
            if "error id=0" not in result:
                raise RuntimeError(f"ServerQuery 选择虚拟服务器失败: {result.strip()}")
            result = send(sock, f"serveredit virtualserver_password={escape(server_password)}")
            if "error id=0" not in result:
                raise RuntimeError(f"ServerQuery 写入服务器配置失败: {result.strip()}")
            send(sock, "quit")
            print("TeamSpeak 服务器密码已设置")
            sys.exit(0)
    except Exception as exc:
        last_error = exc
        time.sleep(2)

print(f"设置 TeamSpeak 服务器密码失败: {last_error}", file=sys.stderr)
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
    server_password_status="未设置，客户端连接时留空"
  fi

  cat <<EOF_NEXT

部署完成

TeamSpeak 客户端连接信息:
  地址: ${client_address}
  端口: ${TS3_VOICE_PORT} (UDP)
  密码: ${server_password_status}

部署信息:
  项目目录: ${TS3_PROJECT_DIR}
  状态检查: sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file ${TS3_PROJECT_DIR}/.env -f ${TS3_PROJECT_DIR}/compose.yaml ps

云安全组提醒:
  请放行 ${TS3_VOICE_PORT}/udp 和 ${TS3_FILE_PORT}/tcp。
  默认不要公网放行 ${TS3_QUERY_PORT}/tcp；该端口是 ServerQuery 管理接口。

EOF_NEXT

  prompt_admin_token_choice
}

main() {
  print_welcome
  require_root
  prompt_server_password_choice

  run_stage 1 "检查系统平台" check_platform
  run_stage 2 "检查 Docker" check_docker
  run_stage 3 "检查现有容器" check_existing_container_name
  run_stage 4 "选择镜像" select_image
  run_stage 5 "检查端口" check_required_ports
  run_stage 6 "写入配置" write_project_files
  run_stage 7 "配置防火墙" configure_ufw
  run_stage 8 "启动服务" start_and_verify_service

  set_server_password_if_requested
  print_next_steps
}

main "$@"
