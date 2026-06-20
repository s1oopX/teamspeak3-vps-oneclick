#!/usr/bin/env bash
set -Eeuo pipefail

TS3_PROJECT_DIR="${TS3_PROJECT_DIR:-/opt/teamspeak3-docker}"
TS3_COMPOSE_PROJECT="${TS3_COMPOSE_PROJECT:-teamspeak3}"
TS3_REMOVE_DATA="${TS3_REMOVE_DATA:-false}"

fail() {
  printf '[ts3-docker-uninstall] ERROR: %s\n' "$*" >&2
  exit 1
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  fail "run this script as root, for example: sudo bash scripts/uninstall-teamspeak3-server.sh"
fi

safe_project_dir() {
  local target
  target="$(readlink -m "$TS3_PROJECT_DIR")"

  case "$target" in
    ""|"/"|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/srv"|"/sys"|"/tmp"|"/usr"|"/var")
      fail "refusing to remove unsafe project directory: ${target}"
      ;;
  esac

  if [ ! -f "${target}/compose.yaml" ] || [ ! -f "${target}/.env" ]; then
    fail "refusing to remove ${target}: compose.yaml and .env were not both found"
  fi

  printf '%s\n' "$target"
}

if ! command -v docker >/dev/null 2>&1; then
  fail "docker not found"
fi

if [ -f "${TS3_PROJECT_DIR}/compose.yaml" ]; then
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    down
else
  printf '[ts3-docker-uninstall] compose file not found: %s\n' "${TS3_PROJECT_DIR}/compose.yaml"
fi

if [ "$TS3_REMOVE_DATA" = "true" ]; then
  remove_target="$(safe_project_dir)"
  printf '[ts3-docker-uninstall] removing project directory and persistent data: %s\n' "$remove_target"
  rm -rf -- "$remove_target"
else
  printf '[ts3-docker-uninstall] data kept at: %s\n' "$TS3_PROJECT_DIR"
  printf '[ts3-docker-uninstall] rerun with TS3_REMOVE_DATA=true to remove persistent data.\n'
fi
