# GOST Thread

GOST Thread is a small service wrapper for a GO Simple Tunnel relay server and client tunnel.

The process is managed by systemd, so it can:

- start in one command
- restart automatically after an unexpected exit
- start after reboot when enabled
- stop cleanly with systemctl or the helper scripts

## Layout

```text
configs/
  server.env              # server listen config
  client.env              # client forward config
scripts/
  install_gost.sh         # install config and systemd services
  start_server.sh
  start_client.sh
  stop_server.sh
  stop_client.sh
  status.sh
  uninstall.sh
systemd/
  gost-server.service
  gost-client.service
logs/
```

## Requirements

Install `gost` first and make sure the path matches `GOST_BIN` in the env files.

Default path:

```bash
/usr/local/bin/gost
```

Check it:

```bash
which gost
gost -V
```

## Server

The server service runs:

```bash
gost -L=relay+tls://gostuser:CHANGE_ME_PASSWORD@0.0.0.0:8443
```

Configuration:

```bash
configs/server.env
```

## Client

The client service runs:

```bash
gost \
  -L=tcp://127.0.0.1:3333/pearl-ca1.luckypool.io:3360 \
  -F=relay+tls://gostuser:CHANGE_ME_PASSWORD@YOUR_SERVER_IP_OR_DOMAIN:8443
```

Configuration:

```bash
configs/client.env
```

## Install

### One-Line GitHub Install

Use the GitHub installer from `zwglass/gost_thread`.

Server machine:

```bash
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh | sudo bash -s -- server
```

Client machine:

```bash
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh | sudo bash -s -- client
```

Client machine without interactive prompts:

```bash
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh | sudo env \
  GOST_SERVER_HOST=YOUR_SERVER_IP_OR_DOMAIN \
  GOST_AUTH_USER=gostuser \
  GOST_AUTH_PASSWORD=CHANGE_ME_PASSWORD \
  bash -s -- client
```

Interactive mode:

```bash
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh | sudo bash
```

The installer will:

- install `gost` first if it is missing
- create the project at `/opt/gost_thread`
- ask for the GOST username and password
- ask for the server IP or domain when installing the client
- copy config files to `/etc/gost-thread/`
- copy systemd services to `/etc/systemd/system/`
- enable the selected service
- start the selected service

Use the same GOST username and password on the server and client.
The username and password may contain only letters, numbers, dot, underscore, and hyphen.

Environment variables supported by the installer:

```text
GOST_SERVER_HOST      # required for client or both
GOST_AUTH_USER        # default: gostuser
GOST_AUTH_PASSWORD    # required
GOST_SERVER_PORT      # default: 8443
GOST_LOCAL_PORT       # default: 3333
GOST_TARGET_HOST      # default: pearl-ca1.luckypool.io
GOST_TARGET_PORT      # default: 3360
```

You can override the repository URL:

```bash
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh | sudo env GOST_THREAD_REPO=https://github.com/zwglass/gost_thread bash -s -- client
```

### Local Install

Run from a local clone on the target machine:

```bash
sudo ./scripts/install_gost.sh
```

Install only one role:

```bash
sudo ./scripts/install_gost.sh --role server
sudo ./scripts/install_gost.sh --role client
```

This copies config files to:

```text
/etc/gost-thread/
```

And service files to:

```text
/etc/systemd/system/
```

## Start And Stop

Server:

```bash
./scripts/start_server.sh
./scripts/stop_server.sh
```

Client:

```bash
./scripts/start_client.sh
./scripts/stop_client.sh
```

Status:

```bash
./scripts/status.sh
```

Direct systemd commands:

```bash
sudo systemctl start gost-server
sudo systemctl stop gost-server
sudo systemctl status gost-server

sudo systemctl start gost-client
sudo systemctl stop gost-client
sudo systemctl status gost-client
```

## Logs

Use journalctl:

```bash
sudo journalctl -u gost-server -f
sudo journalctl -u gost-client -f
```

## Uninstall

```bash
sudo ./scripts/uninstall.sh
```
