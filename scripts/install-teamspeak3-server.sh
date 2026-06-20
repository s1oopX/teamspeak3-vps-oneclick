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

print_token_hint() {
  local token_lines
  token_lines="$(docker logs "$TS3_CONTAINER_NAME" 2>&1 | grep -Ei 'token|privilege' | grep -Eiv 'serveradmin|password' | tail -30 || true)"

  if [ -n "$token_lines" ]; then
    printf '%s\n' "$token_lines"
  else
    cat <<EOF_TOKEN
No token line was detected yet. Try again after 10-30 seconds:
  sudo docker logs ${TS3_CONTAINER_NAME} 2>&1 | grep -Ei 'token|privilege' | grep -Eiv 'serveradmin|password'
EOF_TOKEN
  fi
}

start_compose() {
  log "pulling image: ${TS3_IMAGE}"
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    pull

  log "starting container"
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

  log "setting TeamSpeak server password from TS3_SERVER_PASSWORD"
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
    server_password_status="set from TS3_SERVER_PASSWORD"
  else
    server_password_status="blank by default; this script does not set a server password"
  fi

  cat <<EOF_NEXT

TeamSpeak 3 Server Docker deployment finished.

Selected image:
  ${TS3_IMAGE}

Project directory:
  ${TS3_PROJECT_DIR}

Persistent data directory:
  ${TS3_DATA_DIR}

Container:
  ${TS3_CONTAINER_NAME}

Local TeamSpeak client connection:
  Server nickname: choose any name, for example My TeamSpeak VPS
  Server address:  ${client_address}
  Voice port:      ${TS3_VOICE_PORT}/udp
  Server password: ${server_password_status}
  Your nickname:   choose any nickname in the client

After first login:
  Use the privilege key from the container logs to become server admin.

Useful commands:
  cd ${TS3_PROJECT_DIR}
  sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file .env -f compose.yaml ps
  sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file .env -f compose.yaml logs --tail=120 teamspeak
  sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file .env -f compose.yaml restart
  sudo docker compose --project-name ${TS3_COMPOSE_PROJECT} --env-file .env -f compose.yaml down

Ports to open in your cloud security group:
  ${TS3_VOICE_PORT}/udp  Voice, required by TeamSpeak official port table
  ${TS3_FILE_PORT}/tcp  Filetransfer, required by TeamSpeak official port table
  ${TS3_QUERY_PORT}/tcp  ServerQuery raw, optional; public only when TS3_QUERY_BIND=0.0.0.0 and restricted to trusted source IPs

First admin token:
  sudo docker logs ${TS3_CONTAINER_NAME} 2>&1 | grep -Ei 'token|privilege' | grep -Eiv 'serveradmin|password'

EOF_NEXT

  printf 'Detected first-admin related log lines:\n'
  print_token_hint
}

main() {
  require_root
  check_platform
  check_docker
  check_existing_container_name
  select_image
  check_port_free "$TS3_VOICE_PORT" udp 9987
  check_port_free "$TS3_QUERY_PORT" tcp 10011
  check_port_free "$TS3_FILE_PORT" tcp 30033
  write_project_files
  configure_ufw
  start_compose
  verify_container_running
  set_server_password_if_requested
  print_next_steps
}

main "$@"
