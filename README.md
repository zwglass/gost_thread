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
  miner.env               # active miner runtime config
  profiles.env            # miner and pool profiles
scripts/
  install_gost.sh         # install config and systemd services
  install_pearl_miners.sh # install Pearl miner binaries and systemd services
  start_server.sh
  start_client.sh
  start_pearl_miners.sh
  stop_server.sh
  stop_client.sh
  stop_pearl_miners.sh
  status.sh
  uninstall.sh
systemd/
  gost-server.service
  gost-client.service
  pearl-miner.service
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

## Pearl Miner

The `pearl-miner.service` unit runs the active local miner behind the local
client tunnel. The miner binary and arguments come from `miner.env`.

```bash
./lpminer \
  --algo pearl \
  --pool stratum+tcp://127.0.0.1:3333 \
  --wallet prl1p22pq5hnskyrpysvtx8yqayq8vurrrfu0jzmyeqtjxs7r75k8jvuqpqspma \
  --worker rtx3090
```

Configuration:

```bash
configs/miner.env
configs/profiles.env
```

Default expected binary:

```bash
~/programs/pearl_miners/lpminer/lpminer
```

Install Pearl miners on the client machine:

```bash
sudo env LPMINER_DOWNLOAD_URL=YOUR_LPMINER_DOWNLOAD_URL \
  AKOYA_POOL_WALLET=YOUR_PEARL_ADDRESS \
  ./scripts/install_pearl_miners.sh
```

The installer checks `lpminer`, `alpha-miner`, and `akoya-miner`. It installs
local binaries under `~/programs/pearl_miners/` by default:

```text
~/programs/pearl_miners/lpminer/lpminer
~/programs/pearl_miners/alpha_miner/alpha-miner
```

Akoya is installed by the official installer and keeps its official path and
service layout. `LPMINER_DOWNLOAD_URL` is required when `lpminer` is not already
installed because this repository does not ship a stable lpminer download URL.
`ALPHA_MINER_DOWNLOAD_URL` defaults to
`https://pearl.alphapool.tech/downloads/alpha-miner`.

The installer stops and disables miner services after installation. Start the
wanted profile with `start_pearl_miners.sh`; it enables the selected service,
disables the other miner service, and systemd `Conflicts=` prevents both miners
from staying active after boot.

Switch the active pool and miner profile:

```bash
sudo ./scripts/switch_profile.sh luckypool
sudo ./scripts/switch_profile.sh alphapool
sudo ./scripts/switch_profile.sh akoya
```

Akoya uses its own `akoya-miner.service`, but this project can still route it
through GOST. You can install Akoya through `install_pearl_miners.sh`, or install
it manually first and then start it through this project's profile wrapper:

```bash
curl -sSL https://get.akoyapool.com/install.sh | sudo bash
./scripts/start_pearl_miners.sh akoya
```

The `akoya` profile sets the GOST client target to
`pool-v2.akoyapool.com:443` and updates `/etc/akoya-miner/akoya-miner.env` so
Akoya connects to the local tunnel:

```env
AKOYA_POOL_HOST=127.0.0.1
AKOYA_POOL_PORT=3333
AKOYA_POOL_TLS=1
```

The resulting path is:

```text
akoya-miner.service -> 127.0.0.1:3333 -> gost-client.service -> pool-v2.akoyapool.com:443
```

The same profile argument can be passed when starting services:

```bash
./scripts/start_client.sh luckypool
./scripts/start_pearl_miners.sh alphapool
./scripts/start_pearl_miners.sh akoya
```

Profiles are defined in `configs/profiles.env`. Each profile controls the GOST
target pool endpoint, miner binary path, miner working directory, local miner
pool, and full miner argument string. Profiles with `MINER_SERVICE`, such as
`akoya`, are treated as independent miner services and are not run through
`pearl-miner.service`, but they can still use the same GOST client tunnel.

Only one miner service is kept running. Starting `luckypool` or `alphapool`
stops `akoya-miner.service`; starting `akoya` stops `pearl-miner.service`.
`./scripts/stop_pearl_miners.sh` stops and disables both services.

For profiles that use GOST, `start_pearl_miners.sh` checks `gost-client.service` and
the local pool endpoint before starting the miner. If the client tunnel is
inactive or the local pool port is not reachable, it runs `stop_client.sh` and
`start_client.sh` once, then verifies the tunnel again.

View Pearl miner runtime output:

```bash
sudo journalctl -u pearl-miner -f
```

View recent Pearl miner logs:

```bash
sudo journalctl -u pearl-miner -n 100 --no-pager
```

View full Pearl miner service status and command:

```bash
systemctl status pearl-miner --no-pager -l
```

View current lpminer process and installed config:

```bash
ps -fp $(pidof lpminer)
sudo cat /etc/gost-thread/miner.env
sudo cat /etc/gost-thread/profiles.env
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

`GOST_TARGET_HOST` and `GOST_TARGET_PORT` initialize the default `luckypool`
profile during one-line client installs. Additional profiles can be edited in
`/etc/gost-thread/profiles.env`.

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
./scripts/start_client.sh luckypool
./scripts/start_client.sh alphapool
./scripts/stop_client.sh
```

Pearl Miners:

```bash
./scripts/start_pearl_miners.sh
./scripts/start_pearl_miners.sh luckypool
./scripts/start_pearl_miners.sh alphapool
./scripts/stop_pearl_miners.sh
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

sudo systemctl start pearl-miner
sudo systemctl stop pearl-miner
sudo systemctl status pearl-miner
```

## Logs

Use journalctl:

```bash
sudo journalctl -u gost-server -f
sudo journalctl -u gost-client -f
sudo journalctl -u pearl-miner -f
```

Recent Pearl miner logs:

```bash
sudo journalctl -u pearl-miner -n 100 --no-pager
```

## Uninstall

```bash
sudo ./scripts/uninstall.sh
```

## Nvidia GPU Power Limit

```bash
sudo nvidia-smi -pl 250

nvidia-smi -q -d POWER

nvidia-smi -q -d POWER | grep -i "Power Limit"
```
