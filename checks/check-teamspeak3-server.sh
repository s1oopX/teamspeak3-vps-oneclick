#!/usr/bin/env bash
set -Eeuo pipefail

TS3_PROJECT_DIR="${TS3_PROJECT_DIR:-/opt/teamspeak3-docker}"
TS3_DATA_DIR="${TS3_DATA_DIR:-${TS3_PROJECT_DIR}/data}"
TS3_CONTAINER_NAME="${TS3_CONTAINER_NAME:-teamspeak3}"
TS3_COMPOSE_PROJECT="${TS3_COMPOSE_PROJECT:-teamspeak3}"
TS3_VOICE_PORT="${TS3_VOICE_PORT:-9987}"
TS3_QUERY_PORT="${TS3_QUERY_PORT:-10011}"
TS3_QUERY_BIND="${TS3_QUERY_BIND:-127.0.0.1}"
TS3_FILE_PORT="${TS3_FILE_PORT:-30033}"
PUBLIC_IP="${PUBLIC_IP:-}"
TS3_SERVER_PASSWORD="${TS3_SERVER_PASSWORD:-}"

section() {
  printf '\n== %s ==\n' "$*"
}

has() {
  command -v "$1" >/dev/null 2>&1
}

redact_sensitive_logs() {
  sed -E \
    -e 's/(loginname= "serveradmin", password= ")[^"]*(")/\1[REDACTED]\2/Ig' \
    -e 's/(password[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/(token[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/(privilege key[=:]?[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig'
}

container_exists() {
  has docker && docker ps -a --filter "name=^/${TS3_CONTAINER_NAME}$" --format '{{.Names}}' | grep -Fxq "$TS3_CONTAINER_NAME"
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

  if has curl; then
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

section "系统信息"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '系统: %s\n' "${PRETTY_NAME:-未知}"
fi
printf '架构: %s\n' "$(uname -m)"
printf '用户: %s\n' "$(whoami)"

section "Docker"
if has docker; then
  docker --version || true
  docker compose version || true
  docker info --format 'ServerVersion={{.ServerVersion}} StorageDriver={{.Driver}} CgroupDriver={{.CgroupDriver}}' || true
else
  printf '未检测到 docker\n'
fi

section "项目文件"
for path in \
  "$TS3_PROJECT_DIR" \
  "$TS3_PROJECT_DIR/.env" \
  "$TS3_PROJECT_DIR/compose.yaml" \
  "$TS3_DATA_DIR"; do
  if [ -e "$path" ]; then
    printf '存在  %s\n' "$path"
  else
    printf '缺失  %s\n' "$path"
  fi
done

section "Compose 状态"
if has docker && [ -d "$TS3_PROJECT_DIR" ]; then
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    ps || true
fi

section "容器"
if has docker; then
  docker ps -a --filter "name=^/${TS3_CONTAINER_NAME}$" --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' || true
fi

section "监听端口"
if has ss; then
  ss -tulpen | grep -E "(:${TS3_VOICE_PORT}|:${TS3_QUERY_PORT}|:${TS3_FILE_PORT})\\b" || true
else
  printf '未检测到 ss，跳过端口监听检查。\n'
fi

section "ufw 防火墙"
if has ufw; then
  ufw status verbose || true
else
  printf '未检测到 ufw。\n'
fi

section "云安全组提醒"
cat <<EOF_REMINDER
请确认云厂商安全组已放行:
  ${TS3_VOICE_PORT}/udp  语音连接，TeamSpeak 客户端必需
  ${TS3_FILE_PORT}/tcp  文件传输，建议放行
  ${TS3_QUERY_PORT}/tcp  ServerQuery 管理接口，默认不要公网放行
EOF_REMINDER

section "客户端连接信息"
detect_public_ip
if [ "$TS3_VOICE_PORT" = "9987" ]; then
  printf '地址: %s\n' "${PUBLIC_IP:-<your-vps-public-ip>}"
else
  printf '地址: %s:%s\n' "${PUBLIC_IP:-<your-vps-public-ip>}" "$TS3_VOICE_PORT"
fi
printf '端口: %s (UDP)\n' "$TS3_VOICE_PORT"
if [ -n "$TS3_SERVER_PASSWORD" ]; then
  printf '密码: 当前环境已提供 TS3_SERVER_PASSWORD\n'
else
  printf '密码: 默认留空；如果安装时设置过密码，请使用当时的密码\n'
fi
printf '管理员 Token: 如需首次授予管理员权限，请查看下方 Token 线索。\n'

section "最近日志"
if container_exists; then
  docker logs --tail=120 "$TS3_CONTAINER_NAME" 2>&1 | redact_sensitive_logs || true
else
  printf '未找到容器：%s\n' "$TS3_CONTAINER_NAME"
fi

section "管理员 Token 线索"
if container_exists; then
  docker logs "$TS3_CONTAINER_NAME" 2>&1 | grep -Ei 'token|privilege' | grep -Eiv 'serveradmin|password' | tail -30 || true
else
  printf '未找到容器：%s\n' "$TS3_CONTAINER_NAME"
fi
