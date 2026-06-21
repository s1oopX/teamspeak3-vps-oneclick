# TeamSpeak 3 Server VPS 一键部署

[English](README_EN.md)

![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![TeamSpeak](https://img.shields.io/badge/TeamSpeak_3-Server-2580C3)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-12-A81D33?logo=debian&logoColor=white)
![License](https://img.shields.io/github/license/s1oopX/teamspeak3-vps-oneclick)

面向 Linux VPS 的 TeamSpeak 3 Server 一键部署脚本，由开源维护者 [@s1oopX](https://github.com/s1oopX) 维护。项目基于 Docker Compose，默认仅开放客户端必需端口，并将 ServerQuery 管理接口限制为仅部署机本地访问。

* [LIUNX DO](https://linux.do/)——新的理想型社区

## 功能特性

- 一条命令完成配置生成、镜像选择、容器启动与基础防火墙规则。
- 安装开始可选择自定义服务器密码，或保持无密码连接。
- Docker Hub 不可达时自动尝试备用镜像源。
- 部署完成后可选择获取首次管理员一次性 Token。
- 支持重复执行，用于更新配置或重新生成部署文件。

## 技术栈

`Bash` · `Docker Engine` · `Docker Compose` · `TeamSpeak 3 Server` · `ufw` · `Ubuntu/Debian`

## 适用环境

- Ubuntu 22.04/24.04 或 Debian 12。
- 推荐 `linux/amd64` VPS。
- 已安装 Docker Engine 与 Docker Compose 插件。
- 具备 `sudo` 权限，并可配置云厂商安全组。

## 快速部署

在 VPS 的 SSH 终端中执行：

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/install-teamspeak3-server.sh -o install-teamspeak3-server.sh
sudo bash install-teamspeak3-server.sh
```

## 客户端连接

```text
地址: VPS 公网 IP
端口: 9987
密码: 安装时设置的密码；未设置则留空
```

管理员一次性 Token 是首次获取服务器管理员权限的凭据。建议在部署完成时按脚本提示获取并妥善保存，然后在 TeamSpeak 客户端中通过 `Permissions -> Use Token` 使用。

## 端口安全

| 协议 | 端口 | 用途 |
| --- | --- | --- |
| UDP | 9987 | 语音连接 |
| TCP | 30033 | 文件传输 |

默认不要公网开放 `10011/tcp`。它是 ServerQuery 管理接口，默认仅监听部署机本地地址 `127.0.0.1`。

## 常用命令

```bash
cd /opt/teamspeak3-docker
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml ps
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml logs --tail=120 teamspeak
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml restart
```

部署检查：

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/checks/check-teamspeak3-server.sh -o check-teamspeak3-server.sh
sudo bash check-teamspeak3-server.sh
```

卸载：

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/uninstall-teamspeak3-server.sh -o uninstall-teamspeak3-server.sh
sudo bash uninstall-teamspeak3-server.sh
```

更多配置项见 [.env.example](.env.example)。

## 许可证

本项目基于 [LICENSE](LICENSE) 发布。
