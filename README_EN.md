# TeamSpeak 3 Server VPS One-Click Deployment

[中文](README.md)

![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![TeamSpeak](https://img.shields.io/badge/TeamSpeak_3-Server-2580C3)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-12-A81D33?logo=debian&logoColor=white)
![License](https://img.shields.io/github/license/s1oopX/teamspeak3-vps-oneclick)

A one-click TeamSpeak 3 Server deployment script for Linux VPS instances, maintained by open-source maintainer [@s1oopX](https://github.com/s1oopX). The project uses Docker Compose, exposes only client-required ports by default, and keeps the ServerQuery management interface limited to the deployment host's loopback interface.

## Features

- Generates configuration, selects an available image, starts the container, and applies basic firewall rules with one command.
- Lets you choose a custom server password or no password at the beginning of installation.
- Falls back to an alternate image source when Docker Hub is unreachable.
- Offers to display the first admin one-time token after deployment.
- Supports safe re-runs for configuration refreshes or deployment file regeneration.

## Tech Stack

`Bash` · `Docker Engine` · `Docker Compose` · `TeamSpeak 3 Server` · `ufw` · `Ubuntu/Debian`

## Requirements

- Ubuntu 22.04/24.04 or Debian 12.
- `linux/amd64` VPS recommended.
- Docker Engine and Docker Compose plugin installed.
- `sudo` access and permission to manage cloud security group rules.

## Quick Start

Run inside your VPS SSH terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/install-teamspeak3-server.sh -o install-teamspeak3-server.sh
sudo bash install-teamspeak3-server.sh
```

If the printed public address is inaccurate, specify the address shown to clients:

```bash
sudo PUBLIC_IP='your-vps-public-ip' bash install-teamspeak3-server.sh
```

## Client Connection

```text
Address: public IP printed by the installer
Port: 9987
Password: the password set during installation, or empty if none was set
```

The admin one-time token grants the initial server administrator permission. Fetch it when prompted at the end of deployment, store it safely, and use it in the TeamSpeak client through `Permissions -> Use Token`.

## Ports and Security

| Protocol | Port | Purpose |
| --- | --- | --- |
| UDP | 9987 | Voice connection |
| TCP | 30033 | File transfer |

Do not expose `10011/tcp` publicly by default. It is the ServerQuery management interface and only listens on the deployment host's local address `127.0.0.1`.

## Common Commands

```bash
cd /opt/teamspeak3-docker
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml ps
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml logs --tail=120 teamspeak
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml restart
```

Deployment check:

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/checks/check-teamspeak3-server.sh -o check-teamspeak3-server.sh
sudo bash check-teamspeak3-server.sh
```

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/uninstall-teamspeak3-server.sh -o uninstall-teamspeak3-server.sh
sudo bash uninstall-teamspeak3-server.sh
```

See [.env.example](.env.example) for additional configuration options.

## License

This project is released under the repository [LICENSE](LICENSE).
