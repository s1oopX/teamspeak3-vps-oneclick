# TeamSpeak 3 Server 一键部署

[English](README_EN.md)

这是一个基于 Docker Compose 的 TeamSpeak 3 Server 一键部署项目，目标是在 Linux VPS 上快速、稳定地搭建自建 TeamSpeak 服务器。

开源维护者：[@s1oopX](https://github.com/s1oopX)。

## 环境说明

本项目的实际部署验证环境为：某云厂商国内地域 VPS，系统为 Linux，具备公网 IPv4 和 root/sudo 权限。

由于国内地域 VPS 访问 Docker Hub、GitHub Raw 等境外资源时可能存在网络波动，安装脚本会先检测官方 TeamSpeak 镜像 `teamspeak:3.13.8` 的可达性；如不可达，再尝试配置的备用镜像。端口连通性仍以云厂商安全组、本机防火墙和客户端本地网络为准。

## 环境要求

- Ubuntu 22.04/24.04 或 Debian 12。
- CPU 架构：默认官方镜像当前为 `linux/amd64`；安装脚本会校验所选镜像是否支持当前平台。ARM VPS 需要通过 `TS3_IMAGE` 指定兼容镜像。
- root 权限，或可使用 sudo。
- Docker Engine。
- Docker Compose 插件，也就是 `docker compose`。

## 快速开始

下面的安装命令必须在你的 **VPS SSH 会话里运行**，不是在本地电脑运行。

先从你的本地电脑 SSH 进入 VPS：

```bash
ssh <user>@<your-vps-public-ip>
```

如果你的 VPS 使用私钥登录：

```bash
ssh -i /path/to/private-key <user>@<your-vps-public-ip>
```

进入 VPS 终端后，运行：

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/install-teamspeak3-server.sh -o install-teamspeak3-server.sh
sudo bash install-teamspeak3-server.sh
```

安装脚本开始时会显示 [@s1oopX](https://github.com/s1oopX) 的 GitHub 链接，并说明本项目由开源维护者维护。随后会让你选择：

```text
1) 自定义服务器密码
2) 不设置密码
```

安装过程中，每一个阶段都会简短显示当前步骤和完成状态；中途不会要求再次确认。

用于长期生产环境时，建议在项目发布版本后把 URL 里的 `main` 替换为固定 tag，并在执行前先查看下载的脚本内容。

如果你想跳过交互菜单，也可以在 VPS SSH 会话里直接传入服务器密码：

```bash
sudo TS3_SERVER_PASSWORD='change-me' bash install-teamspeak3-server.sh
```

服务器密码会在容器启动后通过本地 ServerQuery 写入，不会保存到生成的 `.env` 文件里。

部署完成后，脚本会输出连接信息和维护命令，并询问是否立即获取管理员一次性 Token：

```text
1) 获取
2) 暂时不
```

选择 `1` 会自动从容器日志里显示管理员一次性 Token，并提示它的重要性和在 TeamSpeak 客户端里的使用位置。选择 `2` 会显示稍后获取命令，并建议你妥善保存。

## 检查部署状态

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/checks/check-teamspeak3-server.sh -o check-teamspeak3-server.sh
sudo bash check-teamspeak3-server.sh
```

检查脚本无法从生成的 `.env` 判断安装时是否设置过 `TS3_SERVER_PASSWORD`；如果设置过，客户端连接时继续使用当时设置的密码。

## TeamSpeak 客户端连接

TeamSpeak 客户端里填写：

```text
Server Address: <your-vps-public-ip>
Port: 9987
Password: 如果安装时没有设置 TS3_SERVER_PASSWORD，这里留空
Nickname: 自己填写
```

如果部署完成时选择了暂时不获取，之后可用下面的命令查看首次管理员 token：

```bash
sudo docker logs teamspeak3 2>&1 | grep -Ei 'token|privilege' | grep -Eiv 'serveradmin|password'
```

进入服务器后，在 TeamSpeak 客户端中使用：

```text
Permissions -> Use Token
```

## 云服务器安全组

正常使用 TeamSpeak 客户端时，只需要在云厂商控制台放行以下入站规则：

| 协议 | 端口 | 用途 | 是否必需 |
| --- | --- | --- | --- |
| UDP | 9987 | 语音连接 | 是 |
| TCP | 30033 | 文件传输 | 是 |

`10011/tcp` 是 ServerQuery 管理接口，不是普通客户端连接所需端口。默认情况下，本项目会把 ServerQuery 绑定到 `127.0.0.1:10011`，因此不需要在云厂商安全组里公网放行 `10011/tcp`。

只有在你确实需要远程 ServerQuery 管理工具、机器人或自动化脚本连接时，才考虑公网开放 ServerQuery。安装或重新配置时使用：

```bash
sudo TS3_QUERY_BIND=0.0.0.0 bash install-teamspeak3-server.sh
```

随后在云厂商安全组里只对可信来源 IP 放行 `10011/tcp`，不要对 `0.0.0.0/0` 全网开放。

## 维护命令

```bash
cd /opt/teamspeak3-docker
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml ps
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml logs --tail=120 teamspeak
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml restart
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml down
```

安全重复运行安装脚本：

```bash
sudo bash install-teamspeak3-server.sh
```

卸载但保留持久化数据：

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/uninstall-teamspeak3-server.sh -o uninstall-teamspeak3-server.sh
sudo bash uninstall-teamspeak3-server.sh
```

卸载并删除持久化数据：

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/uninstall-teamspeak3-server.sh -o uninstall-teamspeak3-server.sh
sudo TS3_REMOVE_DATA=true bash uninstall-teamspeak3-server.sh
```

## 配置项

常用环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TS3_IMAGE_DEFAULT` | `teamspeak:3.13.8` | 优先使用的官方镜像 |
| `TS3_IMAGE_FALLBACKS` | `docker.m.daocloud.io/library/teamspeak:3.13.8` | Docker Hub 不可达时使用的备用镜像 |
| `TS3_IMAGE` | 空 | 强制指定镜像；ARM VPS 可用它指定兼容镜像 |
| `TS3_PROJECT_DIR` | `/opt/teamspeak3-docker` | Compose 项目目录 |
| `TS3_DATA_DIR` | `/opt/teamspeak3-docker/data` | 持久化数据目录 |
| `TS3_COMPOSE_PROJECT` | `teamspeak3` | Compose 项目名 |
| `TS3_CONTAINER_NAME` | `teamspeak3` | 容器名 |
| `TS3_VOICE_PORT` | `9987` | 语音 UDP 主机端口 |
| `TS3_FILE_PORT` | `30033` | 文件传输 TCP 主机端口 |
| `TS3_QUERY_PORT` | `10011` | ServerQuery TCP 主机端口 |
| `TS3_QUERY_BIND` | `127.0.0.1` | ServerQuery 监听地址 |
| `TS3_SERVER_PASSWORD` | 空 | 可选服务器密码 |
| `PUBLIC_IP` | 自动检测 | 输出给客户端连接使用的地址 |

## 故障排查

如果 TeamSpeak 客户端无法连接：

- 确认服务器地址和端口填写正确。
- 确认云服务器安全组已经放行 `9987/udp`。
- 确认 VPS 本机防火墙允许 `9987/udp`。
- 运行检查脚本。
- 临时关闭本地代理、TUN 或 VPN。TeamSpeak 语音使用 UDP，部分代理/TUN 配置不会正确转发 UDP。

`30033/tcp` 或 `10011/tcp` 检查通过，不代表 `9987/udp` 一定可用。
