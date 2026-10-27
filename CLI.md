# GOST Thread CLI 使用说明

命令在项目根目录执行。一键安装后的默认目录是 `/opt/gost_thread`。

| 大类 | 使用场景 | 配置位置 |
| --- | --- | --- |
| 开发 | 修改项目源码、原始配置、本地调试 | 项目 `configs/` |
| 部署 | 安装、运行、维护已部署服务 | `/etc/gost-thread`、systemd |

## 一、开发

开发命令直接操作项目原始配置，默认不需要 `sudo`。

### 1. Profiles 查看

```bash
./gost-thread profiles list
./gost-thread profiles list --verbose
./gost-thread profiles show luckypool
```

`show` 显示地址、矿工、参数数组和矿工专用地址；密码只显示是否设置。

### 2. Profiles 新增、修改、删除

新增：

```bash
./gost-thread profiles add newpool \
  --target-host pool.example.com \
  --target-port 3333 \
  --miner srbminer \
  --supported-miners "srbminer peakminer"
```

| 参数 | 说明 |
| --- | --- |
| `--target-host HOST` | 必填，矿池主机 |
| `--target-port PORT` | 必填，端口范围 `1-65535` |
| `--miner NAME` | 必填，默认矿工 |
| `--supported-miners "NAME..."` | 可选，必须包含默认矿工 |
| `--wallet VALUE` | 可选，覆盖全局钱包 |
| `--password VALUE` | 可选，覆盖全局密码 |
| `--arg VALUE` | 可选，添加 shell 风格参数表达式，可重复 |

新增时会为所有支持的矿工自动生成默认参数数组，例如
`PEARLFORTUNE_PEARLFORTUNE_ARGS`。显式传入 `--arg` 时，只覆盖默认矿工的
参数数组。  (比如: --arg '--proxy {LOCAL_ADDRESS}' --arg '--address "wallet with spaces"' --arg '--worker "rig-01"' --arg '-gpu')

修改：

```bash
./gost-thread profiles update newpool \
  --target-host new-pool.example.com \
  --target-port 4444

./gost-thread profiles update newpool --clear-password
```

只修改传入字段，支持 `--clear-wallet` 和 `--clear-password`。

删除：

```bash
./gost-thread profiles remove newpool --miner peakminer
```

该命令只删除一个 `pool/miner` 组合，并清理对应参数和专用地址。若删除的是
默认矿工，会自动选择剩余矿工作为默认值；删除最后一个矿工时才移除整个 pool。

需要直接删除整个 pool 时：

```bash
./gost-thread profiles remove-profile newpool
```

### 3. 矿工参数与专用地址

```bash
./gost-thread profiles set-args newpool \
  --miner peakminer \
  --arg=--url \
  --arg='{LOCAL_ADDRESS}'

./gost-thread profiles clear-args newpool --miner peakminer

./gost-thread profiles set-endpoint kryptex \
  --miner krig-miner \
  --target-host prl.kryptex.network \
  --target-port 8048

./gost-thread profiles clear-endpoint kryptex --miner krig-miner
```

`--arg` 支持引号和反斜杠：空格分隔参数，引号用于保留空格。例如：

```bash
--arg '--proxy {LOCAL_ADDRESS}'
--arg '--address "wallet with spaces"'
--arg '--worker "rig-01"'
```

也可以使用 `--arg "--proxy \'{LOCAL_ADDRESS}\'"` 这类转义形式。解析器不会
执行变量替换、命令替换或其他 shell 命令。`{LOCAL_ADDRESS}`、
`{TARGET_HOST}`、`{TARGET_PORT}` 会在运行时替换。

每个 `--arg` 表达式写为一行。一行中的多个 shell 参数仍分别作为独立的
Bash 数组元素，例如：

```bash
PEARLFORTUNE_PEARLFORTUNE_ARGS=(
  --proxy '{LOCAL_ADDRESS}'
  --address 'wallet with spaces'
  --worker 'rig-01'
  -gpu
)
```

### 4. 校验配置

```bash
./gost-thread profiles validate
./gost-thread profiles validate newpool
```

校验地址、端口、矿工兼容性、`miners.env` 注册信息和参数数组。

### 5. 应用开发配置

```bash
./gost-thread profiles use newpool
./gost-thread profiles use newpool --miner peakminer
```

该命令更新项目 `configs/client.env` 和 `configs/miner.env`，默认不重启服务。
可重复使用 `--miner-arg VALUE` 添加运行时参数。

### 6. 本地调试

前台运行 GOST 客户端和矿工：

```bash
./scripts/run_pearl_miners_direct.sh \
  --pool luckypool \
  --miner lpminer
```

使用独立配置：

```bash
GOST_THREAD_CONFIG_DIR="$PWD/direct-config" \
  ./scripts/run_pearl_miners_direct.sh \
  --pool luckypool \
  --miner lpminer
```

需要 Bash 4.3+ 和 `timeout`。按 `Ctrl-C` 停止本次进程，不自动重启，也不支持
KRig 主机级重定向。

运行项目测试：

```bash
bash tests/test_scripts.sh
python3 tests/test_direct_runner.py
```

### 7. 开发配置路径

默认使用项目 `configs/`。可单独覆盖：

```bash
GOST_THREAD_PROFILES_FILE="$PWD/test-config/profiles.env" \
  ./gost-thread profiles list

GOST_THREAD_MINERS_FILE="$PWD/test-config/miners.env" \
  ./gost-thread profiles validate
```

### 8. 命令别名

| 命令 | 别名 |
| --- | --- |
| `profiles` | `profile` |
| `list` | `view` |
| `show` | `view <profile>` |
| `add` | `create` |
| `use` | `switch`、`apply` |
| `remove` | `delete`、`rm` |
| `remove-profile` | `delete-profile`、`remove-pool` |
| `set-args` | `set-miner-args` |
| `clear-args` | `unset-args` |
| `set-endpoint` | `set-miner-endpoint` |
| `clear-endpoint` | `unset-endpoint` |

## 二、部署

部署命令面向已安装配置、systemd 服务和 `/etc/gost-thread`，通常需要 `sudo`。

### 1. 安装

一键安装：

```bash
# 服务端
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh |
  sudo bash -s -- server

# 客户端
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh |
  sudo bash -s -- client

# 服务端和客户端
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh |
  sudo bash -s -- both
```

客户端非交互安装：

```bash
curl -fsSL https://github.com/zwglass/gost_thread/raw/master/install.sh |
  sudo env \
    GOST_SERVER_HOST=YOUR_SERVER \
    GOST_AUTH_USER=gostuser \
    GOST_AUTH_PASSWORD=CHANGE_ME_PASSWORD \
    bash -s -- client
```

本地安装：

```bash
sudo ./scripts/install_gost.sh
sudo ./scripts/install_gost.sh --role server
sudo ./scripts/install_gost.sh --role client
sudo ./scripts/install_gost.sh --no-systemd --role client
```

`--role` 可选 `server`、`client`、`both`。

### 2. 矿工安装与更新

```bash
sudo ./scripts/install_pearl_miners.sh
sudo ./scripts/install_pearl_miners.sh onezerominer
sudo ./scripts/install_pearl_miners.sh --update wildrig onezerominer
sudo ./scripts/install_pearl_miners.sh --all --update
sudo ./scripts/install_pearl_miners.sh --replace-config --all
sudo ./scripts/install_pearl_miners.sh --no-systemd onezerominer

# 走代理安装
sudo --preserve-env=http_proxy,https_proxy,all_proxy,no_proxy,HTTP_PROXY,HTTPS_PROXY,ALL_PROXY,NO_PROXY ./scripts/install_pearl_miners.sh --all --update
```

| 参数 | 说明 |
| --- | --- |
| `MINER...` | 安装指定矿工；省略时安装全部已配置矿工 |
| `--all` | 安装全部矿工 |
| `--update` | 更新 GitHub Release 管理的矿工 |
| `--replace-config` | 替换 `miners.env` 和 `profiles.env` |
| `--no-systemd` | 不安装 systemd 服务 |

`--replace-config` 会覆盖钱包、矿池和路径配置，执行前请备份。

### 3. 部署后 Profile 管理

命令语法与开发类相同，通过环境变量指定部署配置：

```bash
sudo env GOST_THREAD_CONFIG_DIR=/etc/gost-thread \
  /opt/gost_thread/gost-thread profiles list

sudo env GOST_THREAD_CONFIG_DIR=/etc/gost-thread \
  /opt/gost_thread/gost-thread profiles validate

sudo env GOST_THREAD_CONFIG_DIR=/etc/gost-thread \
  /opt/gost_thread/gost-thread profiles use newpool --miner srbminer
```

也可以直接调用切换脚本：

```bash
sudo ./scripts/switch_profile.sh --pool luckypool --miner lpminer
sudo ./scripts/switch_profile.sh \
  --pool alphapool \
  --miner alpha-miner \
  --miner-arg=--no-tui
```

- `--pool`：必填，矿池名称。
- `--miner`：可选，默认使用 `<POOL>_DEFAULT_MINER`。
- `--miner-arg`：可选，可重复，参数原样传给矿工。

### 4. 服务启停

```bash
# GOST 服务端
./scripts/start_server.sh
./scripts/stop_server.sh

# GOST 客户端
./scripts/start_client.sh
./scripts/stop_client.sh

# 矿工
./scripts/start_pearl_miners.sh
./scripts/stop_pearl_miners.sh

# 状态
./scripts/status.sh
```

启动时切换 profile：

```bash
./scripts/start_client.sh --pool luckypool --miner lpminer
./scripts/start_pearl_miners.sh --pool kryptex --miner srbminer
```

`stop_pearl_miners.sh` 会停止并禁用矿工服务。

### 5. KRig 重定向

```bash
sudo ./scripts/krig_gost_redirect.sh enable
sudo ./scripts/krig_gost_redirect.sh status
sudo ./scripts/krig_gost_redirect.sh disable
```

KRig 使用 `iptables` OUTPUT DNAT 转发官方 TLS 地址，不要用 `/etc/hosts`
替换官方域名。

### 6. 诊断与日志

```bash
sudo journalctl -u gost-server -f
sudo journalctl -u gost-client -f
sudo journalctl -u pearl-miner -f
sudo journalctl -u pearl-miner -n 100 --no-pager
```

### 7. 卸载

```bash
sudo ./scripts/uninstall.sh
```

该命令停止并删除项目 systemd 服务以及 `/etc/gost-thread` 下的配置。

### 8. 部署环境变量

| 变量 | 用途 |
| --- | --- |
| `GOST_THREAD_CONFIG_DIR` | 指定部署配置目录 |
| `GOST_THREAD_PROFILES_FILE` | 覆盖 profiles 文件 |
| `GOST_THREAD_MINERS_FILE` | 覆盖 miners 文件 |
| `GOST_THREAD_USE_SUDO=0` | 客户端和矿工启停脚本不调用 `sudo` |
| `GOST_THREAD_SYSTEMCTL` | 覆盖 `systemctl` 命令路径 |
