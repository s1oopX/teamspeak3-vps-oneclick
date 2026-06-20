# TeamSpeak 3 Server One-Click Deploy

[中文](README.md)

Docker Compose one-click deployment for a self-hosted TeamSpeak 3 Server on a Linux VPS.

## Validation Environment

This project has been validated on a domestic-region Linux VPS provided by a cloud vendor, with public IPv4 access and root/sudo privileges.

Because domestic-region VPS instances may experience unstable access to Docker Hub, GitHub Raw, and other overseas resources, the installer probes the official TeamSpeak image `teamspeak:3.13.8` first and then falls back to the configured mirror when needed. Actual connectivity still depends on the cloud security group, the server firewall, and the client network.

## Requirements

- Ubuntu 22.04/24.04 or Debian 12.
- Root access or sudo.
- Docker Engine.
- Docker Compose plugin (`docker compose`).

## Quick Start

Run the install commands **inside your VPS SSH session**, not on your local computer.

From your local computer, SSH into your VPS first:

```bash
ssh <user>@<your-vps-public-ip>
```

If your VPS uses a private key:

```bash
ssh -i /path/to/private-key <user>@<your-vps-public-ip>
```

After you are inside the VPS terminal, run:

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/install-teamspeak3-server.sh -o install-teamspeak3-server.sh
sudo bash install-teamspeak3-server.sh
```

To set a server password during install, still run this inside the VPS SSH session:

```bash
sudo TS3_SERVER_PASSWORD='change-me' bash install-teamspeak3-server.sh
```

The password is applied through local ServerQuery after the container starts. It is not written into the generated `.env` file.

## Check

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/checks/check-teamspeak3-server.sh -o check-teamspeak3-server.sh
sudo bash check-teamspeak3-server.sh
```

## Client Connection

TeamSpeak client fields:

```text
Server Address: <your-vps-public-ip>
Port: 9987
Password: empty unless TS3_SERVER_PASSWORD was set
Nickname: choose your own
```

First admin token:

```bash
sudo docker logs teamspeak3 2>&1 | grep -Ei 'token|privilege|serveradmin|password'
```

Use the token in the client:

```text
Permissions -> Use Token
```

## Cloud Security Group

Open these inbound rules in your cloud provider console:

| Protocol | Port | Purpose | Required |
| --- | --- | --- | --- |
| UDP | 9987 | Voice | Yes |
| TCP | 30033 | File transfer | Yes |
| TCP | 10011 | ServerQuery raw | Optional |

By default, this project binds ServerQuery to `127.0.0.1:10011`, so `10011/tcp` does not need to be opened publicly for normal client usage.

To expose ServerQuery publicly, install with:

```bash
sudo TS3_QUERY_BIND=0.0.0.0 bash install-teamspeak3-server.sh
```

Then open `10011/tcp` only to trusted source IPs.

## Maintenance

```bash
cd /opt/teamspeak3-docker
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml ps
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml logs --tail=120 teamspeak
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml restart
sudo docker compose --project-name teamspeak3 --env-file .env -f compose.yaml down
```

Re-run install safely:

```bash
sudo bash install-teamspeak3-server.sh
```

Uninstall, keeping persistent data:

```bash
sudo bash scripts/uninstall-teamspeak3-server.sh
```

Uninstall and remove persistent data:

```bash
sudo TS3_REMOVE_DATA=true bash scripts/uninstall-teamspeak3-server.sh
```

## Configuration

Common environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `TS3_IMAGE_DEFAULT` | `teamspeak:3.13.8` | Preferred official image |
| `TS3_IMAGE_FALLBACKS` | `docker.m.daocloud.io/library/teamspeak:3.13.8` | Fallback images for networks where Docker Hub is unreachable |
| `TS3_IMAGE` | empty | Force a specific image |
| `TS3_PROJECT_DIR` | `/opt/teamspeak3-docker` | Compose project directory |
| `TS3_DATA_DIR` | `/opt/teamspeak3-docker/data` | Persistent data directory |
| `TS3_COMPOSE_PROJECT` | `teamspeak3` | Compose project name |
| `TS3_CONTAINER_NAME` | `teamspeak3` | Container name |
| `TS3_VOICE_PORT` | `9987` | Voice UDP host port |
| `TS3_FILE_PORT` | `30033` | Filetransfer TCP host port |
| `TS3_QUERY_PORT` | `10011` | ServerQuery TCP host port |
| `TS3_QUERY_BIND` | `127.0.0.1` | ServerQuery host bind address |
| `TS3_SERVER_PASSWORD` | empty | Optional server password |
| `PUBLIC_IP` | auto-detect | Printed client connection address |

## Troubleshooting

If the client says it cannot connect:

- Confirm the server address and port are correct.
- Confirm cloud security group allows `9987/udp`.
- Confirm local firewall allows `9987/udp`.
- Run the check script.
- Disable local proxy/TUN/VPN temporarily. TeamSpeak voice uses UDP, and some proxy/TUN setups do not forward it correctly.

TCP checks for `30033` or `10011` can pass while `9987/udp` is still blocked.