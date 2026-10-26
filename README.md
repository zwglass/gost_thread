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
gost-thread               # management CLI
CLI.md                    # CLI usage
systemd/
  gost-server.service
  gost-client.service
  pearl-miner.service
logs/
```

## CLI

CLI usage: [CLI.md](CLI.md)

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
`profiles.env` owns pool endpoints, default miners, allowed pool/miner combinations,
and independent Bash argument arrays for each combination. `miner.env` is generated runtime state and
stores each command argument separately so spaces and punctuation are preserved.

Default expected binary:

```bash
~/programs/pearl_miners/lpminer/lpminer
```

Installation and update commands are documented in [CLI.md](CLI.md).

The installer supports `lpminer`, `alpha-miner`, WildRig Multi, Pearl Fortune,
PeakMiner, SRBMiner-Multi, Krig Miner, and OneZeroMiner. On a fresh
installation it derives an absolute directory from the project location and
installs local binaries under `<project-directory>/miners/` by default:

```text
<project-directory>/miners/lpminer/lpminer
<project-directory>/miners/alpha_miner/alpha-miner
<project-directory>/miners/wildrig/wildrig-multi
<project-directory>/miners/pearlfortune/miner-cuda13
<project-directory>/miners/peakminer/peakminer
<project-directory>/miners/srbminer/SRBMiner-MULTI
<project-directory>/miners/onezerominer/onezerominer
<project-directory>/miners/krig-miner/krig-miner
```

Without `--update`, an existing executable is left unchanged. With `--update`,
GitHub miners query the latest stable Release, select exactly one configured
Linux asset, verify its published SHA-256 digest when available, and update only
when the release tag or asset changed. `lpminer` and `alpha-miner` remain pinned
to their fixed URLs even when `--update` is supplied.

Set an absolute `PEARL_MINERS_DIR` only when you intentionally want a different
location; it remains supported for existing deployments and custom layouts.

The installer preserves existing configuration files by default. Pass
`--replace-config` to replace `miners.env` and `profiles.env` with the current
repository templates. This resets pool, wallet, and miner installation settings;
`PEARL_MINERS_DIR` is still adjusted to the selected installation directory.
The runtime-generated `miner.env` is left untouched. When `--replace-config` is
used, it is neither created nor overwritten from the static template.

Profile switching commands and options are documented in [CLI.md](CLI.md).

Configure each command in `profiles.env` using `<POOL>_<MINER>_ARGS`, with
uppercase identifiers and hyphens replaced by underscores:

```bash
ALPHAPOOL_ALPHA_MINER_ARGS=(
  --pool 'stratum+tcp://{LOCAL_ADDRESS}'
  --address "${WALLET_ADDRESS}"
  --worker "${WORKER_NAME}"
  --password 'x;d=262144;mdl=your-mdl-address'
)
```

Each array element is one literal argument. Shell variables expand when the
configuration is sourced. `{LOCAL_ADDRESS}`, `{TARGET_HOST}`, and `{TARGET_PORT}`
are replaced after miner-specific endpoint overrides; extra `--miner-arg` values
are appended literally. The executable and working directory stay in `miners.env`.
Krig's TLS endpoint and network redirect handling still apply.

Existing installed profiles without an array use the legacy argument builder and
pool wallet/password fields. Add arrays to `/etc/gost-thread/profiles.env` to
migrate while preserving your settings. `--replace-config` installs the new
repository template and resets your pool and wallet settings. Arrays must be
nonempty indexed Bash arrays; plain command strings are rejected.

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

The `pearlhash` pool also supports OneZeroMiner with `--algo pearlhash`,
a separate `--wallet` and `--worker`, and `--pass x`. It connects through the
same local GOST tunnel to `pool.pearlhash.xyz:9000`.

For an existing installation, merge `PEARLHASH_SUPPORTED_MINERS` and
`PEARLHASH_ONEZEROMINER_ARGS` from `configs/profiles.env` into
`/etc/gost-thread/profiles.env`, along with the OneZeroMiner entries in
`miners.env` if they have not already been added.

The `pearlfortune` pool follows the CUDA command shape from
https://github.com/pearlfortune/pearl-miner. The installer selects the stable
Linux `pearlfortune-vX.Y.Z.tar.gz` Release asset (including the optional `fix` suffix) and uses `miner-cuda13`:

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

The `kryptex` profile uses SRBMiner-Multi by default, and also supports
[Krig Miner](https://github.com/kryptex/krig-miner). Krig Miner requires a
TLS-only pool connection, so its selection uses Kryptex's TLS endpoint while
the other miners continue to use the existing non-SSL endpoint.

[OneZeroMiner](https://github.com/OneZeroMiner/onezerominer) is also supported
with `--algo pearlhash`. The installer selects `onezerominer-linux-X.Y.Z.tar.gz`
from the latest stable GitHub Release. Its pool connection uses the existing
local GOST tunnel and the configured `<wallet>.<worker>` username.

For existing installations, add the OneZeroMiner entries from `configs/miners.env`
and `configs/profiles.env` to the corresponding files in `/etc/gost-thread/`.
Alternatively, `--replace-config onezerominer` refreshes both files from the
repository templates; save custom wallets, workers, paths, and pool settings
before using it and reapply them before starting the miner.

KRig validates the official pool address. Its host-level redirect routes the
official TLS connection through the local GOST listener using an iptables
OUTPUT DNAT rule, not an `/etc/hosts` override. DNS must continue resolving
`prl.kryptex.network` to its public address. Redirect commands are documented
in [CLI.md](CLI.md).
[SRBMiner-Multi](https://github.com/doktor83/SRBMiner-Multi) is the default;
Kryptex lists Pearl as the
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

Pools are defined in `configs/profiles.env`; miner installation properties are
defined independently in `configs/miners.env`. `switch_profile.sh` validates the
declared pool/miner combination and expands its configured argument array. All supported combinations run through `pearl-miner.service`.

For profiles that use GOST, `start_pearl_miners.sh` checks `gost-client.service` and
the local pool endpoint before starting the miner. If the client tunnel is
inactive or the local pool port is not reachable, it runs `stop_client.sh` and
`start_client.sh` once, then verifies the tunnel again.

Service status, process diagnostics, and log commands are documented in
[CLI.md](CLI.md).

## Install

### One-Line GitHub Install

Use the GitHub installer from `zwglass/gost_thread`.
Installation commands and options are documented in [CLI.md](CLI.md).

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

### Local Install

Local installation commands are documented in [CLI.md](CLI.md).

This copies config files to:

```text
/etc/gost-thread/
```

And service files to:

```text
/etc/systemd/system/
```

## Nvidia GPU Power Limit

```bash
sudo nvidia-smi -pl 250

nvidia-smi -q -d POWER

nvidia-smi -q -d POWER | grep -i "Power Limit"
```

## Nvidia GPU Set Lock Memory Frequency

```
# 查看支持的频率
nvidia-smi -q -d SUPPORTED_CLOCKS

# 查看当前功耗、显存频率
nvidia-smi --query-gpu=index,name,power.draw,clocks.mem,clocks.gr --format=csv

# 驱动支持显存频率锁定
sudo nvidia-smi -i 0 -lmc 810

# 恢复默认设置
sudo nvidia-smi -i 0 -rmc
```

## Direct Mode

Commands and requirements for running without systemd are documented in
[CLI.md](CLI.md).
