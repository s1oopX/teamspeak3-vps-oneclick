# TeamSpeak 3 Server One-Click Deploy

[中文](README.md)

Docker Compose one-click deployment for a self-hosted TeamSpeak 3 Server on a Linux VPS.

Open-source maintainer: [@s1oopX](https://github.com/s1oopX).

## Validation Environment

This project has been validated on a domestic-region Linux VPS provided by a cloud vendor, with public IPv4 access and root/sudo privileges.

Because domestic-region VPS instances may experience unstable access to Docker Hub, GitHub Raw, and other overseas resources, the installer probes the official TeamSpeak image `teamspeak:3.13.8` first and then falls back to the configured mirror when needed. Actual connectivity still depends on the cloud security group, the server firewall, and the client network.

## Requirements

- Ubuntu 22.04/24.04 or Debian 12.
- CPU architecture: the default official image is currently `linux/amd64`; the installer validates that the selected image supports the current platform. ARM VPS instances need a compatible image via `TS3_IMAGE`.
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

At startup, the installer shows the GitHub link for [@s1oopX](https://github.com/s1oopX) and identifies the project as maintained by its open-source maintainer. It then asks you to choose:

```text
1) Set a custom server password
2) Do not set a password
```

During installation, each stage shows the current step, what it is handling, and when it completes; there are no extra confirmations in the middle.

For long-lived production installs, prefer replacing `main` in the URL with a fixed release tag once one is available, and inspect the downloaded script before running it.

To skip the interactive menu, you can still pass the server password directly inside the VPS SSH session:

```bash
sudo TS3_SERVER_PASSWORD='change-me' bash install-teamspeak3-server.sh
```

The password is applied through local ServerQuery after the container starts. It is not written into the generated `.env` file.

After deployment, the installer prints a summary with connection details and maintenance commands, then asks whether to fetch the first admin one-time token:

```text
1) Fetch
2) Not now
```

Choosing `1` prints the token from the container logs and explains why it matters and where to use it in the TeamSpeak client. Choosing `2` prints the later retrieval command and recommends saving the token safely.

## Check

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/checks/check-teamspeak3-server.sh -o check-teamspeak3-server.sh
sudo bash check-teamspeak3-server.sh
```

The check script cannot tell from the generated `.env` whether `TS3_SERVER_PASSWORD` was set during install. If it was, keep using that password in the client.

## Client Connection

TeamSpeak client fields:

```text
Server Address: <your-vps-public-ip>
Port: 9987
Password: empty unless TS3_SERVER_PASSWORD was set
Nickname: choose your own
```

If you choose not to fetch it at the end of deployment, you can later check the first admin token with:

```bash
sudo docker logs teamspeak3 2>&1 | grep -Ei 'token|privilege' | grep -Eiv 'serveradmin|password'
```

Use the token in the client:

```text
Permissions -> Use Token
```

## Cloud Security Group

For normal TeamSpeak client usage, open only these inbound rules in your cloud provider console:

| Protocol | Port | Purpose | Required |
| --- | --- | --- | --- |
| UDP | 9987 | Voice | Yes |
| TCP | 30033 | File transfer | Yes |

`10011/tcp` is the ServerQuery management interface, not a normal client connection port. By default, this project binds ServerQuery to `127.0.0.1:10011`, so you do not need to expose `10011/tcp` publicly in the cloud security group.

Only expose ServerQuery when you really need remote ServerQuery tools, bots, or automation scripts. Install or reconfigure with:

```bash
sudo TS3_QUERY_BIND=0.0.0.0 bash install-teamspeak3-server.sh
```

Then allow `10011/tcp` only from trusted source IPs in your cloud security group. Do not open it to `0.0.0.0/0`.

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
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/uninstall-teamspeak3-server.sh -o uninstall-teamspeak3-server.sh
sudo bash uninstall-teamspeak3-server.sh
```

Uninstall and remove persistent data:

```bash
curl -fsSL https://raw.githubusercontent.com/s1oopX/teamspeak3-vps-oneclick/main/scripts/uninstall-teamspeak3-server.sh -o uninstall-teamspeak3-server.sh
sudo TS3_REMOVE_DATA=true bash uninstall-teamspeak3-server.sh
```

## Configuration

Common environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `TS3_IMAGE_DEFAULT` | `teamspeak:3.13.8` | Preferred official image |
| `TS3_IMAGE_FALLBACKS` | `docker.m.daocloud.io/library/teamspeak:3.13.8` | Fallback images for networks where Docker Hub is unreachable |
| `TS3_IMAGE` | empty | Force a specific image; ARM VPS instances can use it to provide a compatible image |
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
