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

section "system"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"
fi
printf 'Arch: %s\n' "$(uname -m)"
printf 'User: %s\n' "$(whoami)"

section "docker"
if has docker; then
  docker --version || true
  docker compose version || true
  docker info --format 'ServerVersion={{.ServerVersion}} StorageDriver={{.Driver}} CgroupDriver={{.CgroupDriver}}' || true
else
  printf 'docker not found\n'
fi

section "project files"
for path in \
  "$TS3_PROJECT_DIR" \
  "$TS3_PROJECT_DIR/.env" \
  "$TS3_PROJECT_DIR/compose.yaml" \
  "$TS3_DATA_DIR"; do
  if [ -e "$path" ]; then
    printf 'OK      %s\n' "$path"
  else
    printf 'MISSING %s\n' "$path"
  fi
done

section "compose ps"
if has docker && [ -d "$TS3_PROJECT_DIR" ]; then
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    ps || true
fi

section "container"
if has docker; then
  docker ps -a --filter "name=^/${TS3_CONTAINER_NAME}$" --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' || true
fi

section "listening ports"
if has ss; then
  ss -tulpen | grep -E "(:${TS3_VOICE_PORT}|:${TS3_QUERY_PORT}|:${TS3_FILE_PORT})\\b" || true
else
  printf 'ss not found\n'
fi

section "ufw"
if has ufw; then
  ufw status verbose || true
else
  printf 'ufw not installed\n'
fi

section "cloud security group reminder"
cat <<EOF_REMINDER
Make sure your VPS provider security group allows:
  ${TS3_VOICE_PORT}/udp  Voice, required by TeamSpeak official port table
  ${TS3_FILE_PORT}/tcp  Filetransfer, required by TeamSpeak official port table
  ${TS3_QUERY_PORT}/tcp  ServerQuery raw, optional; public only when TS3_QUERY_BIND=0.0.0.0 and restricted to trusted source IPs
EOF_REMINDER

section "local TeamSpeak client connection"
detect_public_ip
if [ "$TS3_VOICE_PORT" = "9987" ]; then
  printf 'Server address:  %s\n' "${PUBLIC_IP:-<your-vps-public-ip>}"
else
  printf 'Server address:  %s:%s\n' "${PUBLIC_IP:-<your-vps-public-ip>}" "$TS3_VOICE_PORT"
fi
printf 'Voice port:      %s/udp\n' "$TS3_VOICE_PORT"
if [ -n "$TS3_SERVER_PASSWORD" ]; then
  printf 'Server password: provided by current TS3_SERVER_PASSWORD environment\n'
else
  printf 'Server password: blank by default; use the password you set during install if TS3_SERVER_PASSWORD was used\n'
fi
printf 'Privilege key:   check admin token hint below, then use it in the TeamSpeak client after first login\n'

section "recent logs"
if container_exists; then
  docker logs --tail=120 "$TS3_CONTAINER_NAME" 2>&1 | redact_sensitive_logs || true
else
  printf 'container not found: %s\n' "$TS3_CONTAINER_NAME"
fi

section "admin token hint"
if container_exists; then
  docker logs "$TS3_CONTAINER_NAME" 2>&1 | grep -Ei 'token|privilege' | grep -Eiv 'serveradmin|password' | tail -30 || true
else
  printf 'container not found: %s\n' "$TS3_CONTAINER_NAME"
fi
