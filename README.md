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
  miners.env              # miner binaries and download sources
  profiles.env            # pools, credentials, and compatibility rules
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
GitHub-managed miner installation also requires `curl`, `jq`, and `tar`.

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
configs/miners.env
configs/profiles.env
```

`miners.env` owns download sources, executable paths, and working directories.
`profiles.env` owns pool endpoints, wallets, passwords, default miners, and the
allowed pool/miner combinations. `miner.env` is generated runtime state and
stores each command argument separately so spaces and punctuation are preserved.

Default expected binary:

```bash
~/programs/pearl_miners/lpminer/lpminer
```

Install Pearl miners on the client machine:

```bash
sudo ./scripts/install_pearl_miners.sh
```

The installer supports `lpminer`, `alpha-miner`, WildRig Multi, Pearl Fortune,
PeakMiner, SRBMiner-Multi, and `tw-pearl-miner`. It installs local binaries
under `~/programs/pearl_miners/` by default:

```text
~/programs/pearl_miners/lpminer/lpminer
~/programs/pearl_miners/alpha_miner/alpha-miner
~/programs/pearl_miners/wildrig/wildrig-multi
~/programs/pearl_miners/pearlfortune/miner-cuda13
~/programs/pearl_miners/peakminer/peakminer
~/programs/pearl_miners/srbminer/SRBMiner-MULTI
~/programs/pearl_miners/tw-pearl-miner/pearl-gpu-miner
```

Install one miner or update GitHub-managed miners explicitly:

```bash
sudo ./scripts/install_pearl_miners.sh tw-pearl-miner
sudo ./scripts/install_pearl_miners.sh --update wildrig tw-pearl-miner
sudo ./scripts/install_pearl_miners.sh --all --update
sudo ./scripts/install_pearl_miners.sh --replace-config --all
```

Without `--update`, an existing executable is left unchanged. With `--update`,
GitHub miners query the latest stable Release, select exactly one configured
Linux asset, verify its published SHA-256 digest when available, and update only
when the release tag or asset changed. `lpminer` and `alpha-miner` remain pinned
to their fixed URLs even when `--update` is supplied.

The installer preserves existing `miners.env`, `profiles.env`, and `miner.env`
files by default. Pass `--replace-config` to replace all three with the current
repository templates. This resets pool, wallet, miner-selection, and other local
configuration values; `PEARL_MINERS_DIR` is still adjusted to the selected
installation directory.

`tw-pearl-miner` defaults to its Linux CUDA 12 archive (`*.c12.tar.gz`) and
never matches Windows, B300, HiveOS, or MMPOS assets. Systems with an NVIDIA
driver suitable for CUDA 13 can change `TW_PEARL_MINER_ASSET_REGEX` as described
in `configs/miners.env`. Its command builder follows the options documented by
[egg5233/tw-pearl-miner](https://github.com/egg5233/tw-pearl-miner): `--pool`,
`--wallet`, `--worker`, AlphaPool `--password`, and `--pf` when PearlFortune is
reached through the local GOST address.

Switch the active pool and miner with explicit options:

```bash
sudo ./scripts/switch_profile.sh --pool luckypool --miner lpminer
sudo ./scripts/switch_profile.sh --pool luckypool --miner tw-pearl-miner
sudo ./scripts/switch_profile.sh --pool pearlhash --miner wildrig
sudo ./scripts/switch_profile.sh --pool kryptex --miner srbminer
```

`--miner` may be omitted to use `<POOL>_DEFAULT_MINER`. Append literal runtime
arguments with a repeatable option, for example `--miner-arg=--no-tui` or
`--miner-arg=--gpus --miner-arg=0,1`.

The `pearlhash` profile uses WildRig Multi from
https://github.com/andru-kun/wildrig-multi. The project documents this command
shape:

```bash
./wildrig-multi \
  --algo pearl \
  --url stratum+tcp://pool.pearlhash.xyz:9000 \
  --user <address> \
  --pass x \
  --worker <worker>
```

In this project the miner still connects to the local GOST tunnel:

```bash
${PEARL_MINERS_DIR}/wildrig/wildrig-multi \
  --algo pearl \
  --url stratum+tcp://127.0.0.1:3333 \
  --user prl1p22pq5hnskyrpysvtx8yqayq8vurrrfu0jzmyeqtjxs7r75k8jvuqpqspma \
  --pass x \
  --worker rtx3090
```

The resulting path is:

```text
wildrig-multi -> 127.0.0.1:3333 -> gost-client.service -> pool.pearlhash.xyz:9000
```

The `pearlfortune` pool follows the CUDA command shape from
https://github.com/pearlfortune/pearl-miner. The installer selects the stable
Linux `pearlfortune-vX.Y.Z.tar.gz` Release asset and uses `miner-cuda13`:

```bash
./miner-cuda13 \
  --proxy global.pearlfortune.org:8888 \
  --address {prl-address} \
  --worker $(hostname) \
  -gpu
```

In this project the miner still connects to the local GOST tunnel:

```bash
${PEARL_MINERS_DIR}/pearlfortune/miner-cuda13 \
  --proxy 127.0.0.1:3333 \
  --address prl1p22pq5hnskyrpysvtx8yqayq8vurrrfu0jzmyeqtjxs7r75k8jvuqpqspma \
  --worker rtx3090 \
  -gpu
```

The resulting path is:

```text
miner-cuda13 -> 127.0.0.1:3333 -> gost-client.service -> global.pearlfortune.org:8888
```

The `herominers` profile uses PeakMiner from
https://github.com/peakminer/peakminer. PeakMiner documents Pearl support over
Stratum V1, Linux support with a bundled CUDA 12 runtime, and this command shape
for HeroMiners:

```bash
peakminer \
  --url de.pearl.herominers.com:1200 \
  --user <wallet>.<worker>
```

This project resolves PeakMiner's latest stable Linux tar archive through the
GitHub Releases API.

In this project the miner still connects to the local GOST tunnel:

```bash
${PEARL_MINERS_DIR}/peakminer/peakminer \
  --url 127.0.0.1:3333 \
  --user prl1p22pq5hnskyrpysvtx8yqayq8vurrrfu0jzmyeqtjxs7r75k8jvuqpqspma.rtx3090
```

The resulting path is:

```text
peakminer -> 127.0.0.1:3333 -> gost-client.service -> de.pearl.herominers.com:1200
```

The `kryptex` profile uses SRBMiner-Multi from
https://github.com/doktor83/SRBMiner-Multi. Kryptex lists Pearl as the
`PearlHash` algorithm and the Global non-SSL endpoint as:

```text
prl.kryptex.network:7048
```

SRBMiner-Multi documents this general command shape:

```bash
./SRBMiner-MULTI \
  --algorithm <algorithm> \
  --pool <pool-host:port> \
  --wallet <wallet>
```

In this project the miner still connects to the local GOST tunnel:

```bash
${PEARL_MINERS_DIR}/srbminer/SRBMiner-MULTI \
  --algorithm pearlhash \
  --pool 127.0.0.1:3333 \
  --wallet prl1p22pq5hnskyrpysvtx8yqayq8vurrrfu0jzmyeqtjxs7r75k8jvuqpqspma.rtx3090 \
  --password x
```

The resulting path is:

```text
SRBMiner-MULTI -> 127.0.0.1:3333 -> gost-client.service -> prl.kryptex.network:7048
```

The same explicit selection can be passed when starting services:

```bash
./scripts/start_client.sh --pool luckypool --miner lpminer
./scripts/start_pearl_miners.sh --pool alphapool --miner alpha-miner
./scripts/start_pearl_miners.sh --pool pearlhash --miner wildrig
./scripts/start_pearl_miners.sh --pool pearlfortune --miner tw-pearl-miner
./scripts/start_pearl_miners.sh --pool herominers --miner peakminer
./scripts/start_pearl_miners.sh --pool kryptex --miner srbminer
```

Pools are defined in `configs/profiles.env`; miner installation properties are
defined independently in `configs/miners.env`. `switch_profile.sh` validates the
declared pool/miner combination and constructs the correct argv for that miner
type. All supported combinations run through `pearl-miner.service`.

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

View current miner process and installed config:

```bash
ps -fp $(pidof lpminer)
ps -fp $(pidof alpha-miner)
ps -fp $(pidof wildrig-multi)
ps -fp $(pidof miner)
ps -fp $(pidof peakminer)
ps -fp $(pidof SRBMiner-MULTI)
ps -fp $(pidof pearl-gpu-miner)
sudo cat /etc/gost-thread/miner.env
sudo cat /etc/gost-thread/miners.env
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
./scripts/start_client.sh --pool luckypool --miner lpminer
./scripts/start_client.sh --pool pearlhash --miner wildrig
./scripts/stop_client.sh
```

Pearl Miners:

```bash
./scripts/start_pearl_miners.sh
./scripts/start_pearl_miners.sh --pool luckypool --miner lpminer
./scripts/start_pearl_miners.sh --pool alphapool --miner tw-pearl-miner
./scripts/start_pearl_miners.sh --pool pearlhash --miner wildrig
./scripts/start_pearl_miners.sh --pool pearlfortune --miner pearlfortune
./scripts/start_pearl_miners.sh --pool herominers --miner peakminer
./scripts/start_pearl_miners.sh --pool kryptex --miner srbminer
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
sudo journalctl -u pearl-miner -n 50 --no-pager
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
