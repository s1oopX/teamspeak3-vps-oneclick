#!/usr/bin/env bash
set -Eeuo pipefail

TS3_PROJECT_DIR="${TS3_PROJECT_DIR:-/opt/teamspeak3-docker}"
TS3_COMPOSE_PROJECT="${TS3_COMPOSE_PROJECT:-teamspeak3}"
TS3_REMOVE_DATA="${TS3_REMOVE_DATA:-false}"

fail() {
  printf '[ts3-docker-uninstall] 错误: %s\n' "$*" >&2
  exit 1
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  fail "请使用 root 权限运行，例如：sudo bash uninstall-teamspeak3-server.sh"
fi

safe_project_dir() {
  local target
  target="$(readlink -m "$TS3_PROJECT_DIR")"

  case "$target" in
    ""|"/"|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/opt"|"/proc"|"/root"|"/run"|"/sbin"|"/srv"|"/sys"|"/tmp"|"/usr"|"/var")
      fail "拒绝删除高风险目录：${target}"
      ;;
  esac

  if [ ! -f "${target}/compose.yaml" ] || [ ! -f "${target}/.env" ]; then
    fail "拒绝删除 ${target}：未同时找到 compose.yaml 和 .env。"
  fi

  printf '%s\n' "$target"
}

if ! command -v docker >/dev/null 2>&1; then
  fail "未检测到 docker。"
fi

if [ -f "${TS3_PROJECT_DIR}/compose.yaml" ]; then
  docker compose \
    --project-name "$TS3_COMPOSE_PROJECT" \
    --env-file "${TS3_PROJECT_DIR}/.env" \
    -f "${TS3_PROJECT_DIR}/compose.yaml" \
    down
else
  printf '[ts3-docker-uninstall] 未找到 Compose 文件：%s\n' "${TS3_PROJECT_DIR}/compose.yaml"
fi

if [ "$TS3_REMOVE_DATA" = "true" ]; then
  remove_target="$(safe_project_dir)"
  printf '[ts3-docker-uninstall] 删除项目目录和持久化数据：%s\n' "$remove_target"
  rm -rf -- "$remove_target"
else
  printf '[ts3-docker-uninstall] 已停止服务，数据保留在：%s\n' "$TS3_PROJECT_DIR"
  printf '[ts3-docker-uninstall] 如需同时删除数据，请使用 TS3_REMOVE_DATA=true 重新运行卸载脚本。\n'
fi
