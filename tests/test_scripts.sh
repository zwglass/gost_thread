#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "${expected}" != "${actual}" ]]; then
    fail "${label}: expected [${expected}], got [${actual}]"
  fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_release_json() {
  local output_file="$1"
  local tag="$2"
  local asset_name="$3"
  local asset_url="$4"
  local digest="$5"

  jq -n \
    --arg tag "${tag}" \
    --arg name "${asset_name}" \
    --arg url "${asset_url}" \
    --arg digest "sha256:${digest}" \
    '{tag_name:$tag, assets:[{name:$name, browser_download_url:$url, digest:$digest}]}' \
    >"${output_file}"
}

test_switch_profile_and_runner() {
  local config_dir="${TEST_ROOT}/switch-config"
  local recovery_config_dir="${TEST_ROOT}/krig-recovery-config"
  local fake_miner="${TEST_ROOT}/fake-miner"
  local output
  local selection
  local pool
  local miner
  local client_config

  mkdir -p "${config_dir}"
  cp "${ROOT_DIR}/configs/profiles.env" "${ROOT_DIR}/configs/miners.env" "${ROOT_DIR}/configs/client.env" "${config_dir}/"

  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" \
    --pool alphapool --miner alpha-miner --miner-arg=--no-tui >/dev/null

  client_config="$(<"${config_dir}/client.env")"
  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" \
    --pool alphapool --miner alpha-miner --miner-arg=--no-tui >/dev/null
  assert_equals "${client_config}" "$(<"${config_dir}/client.env")" \
    "client config after repeated profile switch"

  # shellcheck source=/dev/null
  . "${config_dir}/miner.env"
  assert_equals "alphapool" "${ACTIVE_POOL}" "active pool"
  assert_equals "alpha-miner" "${ACTIVE_MINER}" "active miner"
  assert_equals "x;d=262144;mdl=mdl1pgsyjwlla6vaqfp428s2ltf78zhh3kkklx8rmvehxpa6dph8kghrskygxsh" "${MINER_ARG_7}" "quoted password argument"
  assert_equals "--no-tui" "${MINER_ARG_8}" "extra argument"

  if GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool pearlhash --miner alpha-miner >/dev/null 2>&1; then
    fail "unsupported pool/miner combination was accepted"
  fi

  for selection in \
    "luckypool lpminer" \
    "alphapool alpha-miner" \
    "pearlhash wildrig" \
    "pearlhash onezerominer" \
    "pearlfortune pearlfortune" \
    "herominers peakminer" \
    "kryptex onezerominer" \
    "kryptex srbminer" \
    "kryptex peakminer" \
    "kryptex krig-miner"; do
    read -r pool miner <<<"${selection}"
    GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
      "${ROOT_DIR}/scripts/switch_profile.sh" --pool "${pool}" --miner "${miner}" >/dev/null
  done

  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool pearlhash --miner onezerominer >/dev/null
  . "${config_dir}/miner.env"
  . "${config_dir}/profiles.env"
  . "${config_dir}/client.env"
  assert_equals pearlhash "${MINER_ARG_1}" "PearlHash OneZeroMiner algorithm"
  assert_equals stratum+tcp://127.0.0.1:3333 "${MINER_ARG_3}" "PearlHash OneZeroMiner local pool"
  assert_equals "${WALLET_ADDRESS}" "${MINER_ARG_5}" "PearlHash OneZeroMiner wallet"
  assert_equals --worker "${MINER_ARG_6}" "PearlHash OneZeroMiner worker option"
  assert_equals "${WORKER_NAME}" "${MINER_ARG_7}" "PearlHash OneZeroMiner worker"
  assert_equals "tcp://127.0.0.1:3333/pool.pearlhash.xyz:9000" "${LOCAL_FORWARD}" "PearlHash OneZeroMiner GOST forward"

  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool kryptex --miner onezerominer >/dev/null
  . "${config_dir}/miner.env"
  . "${config_dir}/profiles.env"
  . "${config_dir}/client.env"
  assert_equals pearlhash "${MINER_ARG_1}" "OneZeroMiner algorithm"
  assert_equals stratum+tcp://127.0.0.1:3333 "${MINER_ARG_3}" "OneZeroMiner local pool"
  assert_equals "${WALLET_ADDRESS}.${WORKER_NAME}" "${MINER_ARG_5}" "OneZeroMiner username"
  assert_equals "tcp://127.0.0.1:3333/prl-eu.kryptex.network:7048" "${LOCAL_FORWARD}" "OneZeroMiner GOST forward"

  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool kryptex --miner krig-miner >/dev/null
  # shellcheck source=/dev/null
  . "${config_dir}/miner.env"
  # shellcheck source=/dev/null
  . "${config_dir}/profiles.env"
  assert_equals "stratum+ssl://prl.kryptex.network:8048" "${MINER_ARG_1}" "Krig Miner TLS URL"
  assert_equals "${WALLET_ADDRESS}/rtx3090" "${MINER_ARG_3}" "Krig Miner wallet and worker"
  # shellcheck source=/dev/null
  . "${config_dir}/client.env"
  assert_equals "tcp://127.0.0.1:8048/prl.kryptex.network:8048" "${LOCAL_FORWARD}" "Krig Miner local GOST forward"

  mkdir -p "${recovery_config_dir}"
  cp "${ROOT_DIR}/configs/profiles.env" "${ROOT_DIR}/configs/miners.env" "${ROOT_DIR}/configs/client.env" "${recovery_config_dir}/"
  sed '/^KRYPTEX_KRIG_MINER_TARGET_\(HOST\|PORT\)=/d' "${recovery_config_dir}/profiles.env" >"${recovery_config_dir}/profiles.env.tmp"
  mv "${recovery_config_dir}/profiles.env.tmp" "${recovery_config_dir}/profiles.env"
  GOST_THREAD_CONFIG_DIR="${recovery_config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool kryptex --miner krig-miner >/dev/null
  grep -q '^KRYPTEX_KRIG_MINER_TARGET_HOST=prl.kryptex.network$' "${recovery_config_dir}/profiles.env" || \
    fail "missing KRig target host was not restored"
  grep -q '^KRYPTEX_KRIG_MINER_TARGET_PORT=8048$' "${recovery_config_dir}/profiles.env" || \
    fail "missing KRig target port was not restored"

  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" \
    --pool alphapool --miner alpha-miner --miner-arg=--no-tui >/dev/null
  # shellcheck source=/dev/null
  . "${config_dir}/miner.env"

  printf '%s\n' '#!/usr/bin/env bash' 'printf "<%s>\\n" "$@"' >"${fake_miner}"
  chmod +x "${fake_miner}"
  MINER_BIN="${fake_miner}"
  MINER_WORKDIR="${TEST_ROOT}"
  export MINER_BIN MINER_WORKDIR MINER_LD_LIBRARY_PATH MINER_ARG_COUNT
  for ((i = 0; i < MINER_ARG_COUNT; i++)); do
    key="MINER_ARG_${i}"
    export "${key}"
  done
  output="$("${ROOT_DIR}/scripts/run_pearl_miner.sh")"
  [[ "${output}" == *'<x;d=262144;mdl=mdl1pgsyjwlla6vaqfp428s2ltf78zhh3kkklx8rmvehxpa6dph8kghrskygxsh>'* ]] || \
    fail "runner did not preserve password as one argument"

  # A configured command replaces the builder and preserves literal shell text.
  cat >>"${config_dir}/profiles.env" <<'EOF'
ALPHAPOOL_ALPHA_MINER_ARGS=(
  --custom 'space ; $(must-not-run)'
  --endpoint '{LOCAL_ADDRESS}/{TARGET_HOST}:{TARGET_PORT}'
  ''
)
EOF
  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool alphapool --miner alpha-miner \
    '--miner-arg={LOCAL_ADDRESS}' >/dev/null
  . "${config_dir}/miner.env"
  assert_equals 'space ; $(must-not-run)' "${MINER_ARG_1}" "literal custom argument"
  assert_equals '127.0.0.1:3333/eu1.alphapool.tech:5566' "${MINER_ARG_3}" "runtime placeholders"
  assert_equals '' "${MINER_ARG_4}" "empty argument"
  assert_equals '{LOCAL_ADDRESS}' "${MINER_ARG_5}" "literal extra argument"
  assert_equals 6 "${MINER_ARG_COUNT}" "configured command replaces defaults"

  printf '\nALPHAPOOL_ALPHA_MINER_ARGS=()\n' >>"${config_dir}/profiles.env"
  if GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool alphapool --miner alpha-miner >/dev/null 2>&1; then
    fail "empty argument array was accepted"
  fi
  printf '\nunset ALPHAPOOL_ALPHA_MINER_ARGS\nALPHAPOOL_ALPHA_MINER_ARGS="--pool localhost"\n' >>"${config_dir}/profiles.env"
  if GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool alphapool --miner alpha-miner >/dev/null 2>&1; then
    fail "command string was accepted"
  fi

  cat >>"${config_dir}/profiles.env" <<'EOF'
unset ALPHAPOOL_ALPHA_MINER_ARGS
ALPHAPOOL_WALLET=legacy-wallet
ALPHAPOOL_PASSWORD='legacy password;value'
EOF
  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool alphapool --miner alpha-miner >/dev/null
  . "${config_dir}/miner.env"
  assert_equals legacy-wallet "${MINER_ARG_3}" "legacy wallet fallback"
  assert_equals 'legacy password;value' "${MINER_ARG_7}" "legacy password fallback"
}

test_krig_gost_redirect_help() {
  local output

  output="$("${ROOT_DIR}/scripts/krig_gost_redirect.sh" --help)"
  [[ "${output}" == *"<enable|disable|status>"* ]] || fail "KRig redirect usage is missing commands"
}

test_profile_cli() {
  local config_dir="${TEST_ROOT}/cli-config"
  local output
  local password="pa'ss\\word"
  local test_wallet="wallet value"
  local test_worker="worker value"

  mkdir -p "${config_dir}"
  cp "${ROOT_DIR}/configs/client.env" \
    "${ROOT_DIR}/configs/miner.env" \
    "${ROOT_DIR}/configs/miners.env" \
    "${ROOT_DIR}/configs/profiles.env" \
    "${config_dir}/"

  output="$("${ROOT_DIR}/gost-thread" profiles validate luckypool)"
  [[ "${output}" == *"Validated 1 profile"* ]] || \
    fail "CLI did not default to the project profiles file"

  output="$(GOST_THREAD_CONFIG_DIR="${config_dir}" "${ROOT_DIR}/gost-thread" profiles list)"
  [[ "${output}" == *"luckypool"* ]] || fail "profile list omitted luckypool"
  [[ "${output}" == *"kryptex"* ]] || fail "profile list omitted kryptex"
  if [[ "${output}" == *"kryptex-krig-miner"* ]]; then
    fail "profile list included a miner-specific endpoint as a pool"
  fi

  output="$(GOST_THREAD_CONFIG_DIR="${config_dir}" "${ROOT_DIR}/gost-thread" profiles show luckypool)"
  [[ "${output}" == *"pearl-eu1.luckypool.io:3360"* ]] || fail "profile show omitted target"
  [[ "${output}" == *"Arguments [lpminer]"* ]] || fail "profile show omitted miner args"

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles add fortune-test \
    --target-host global.pearlfortune.org \
    --target-port 8888 \
    --miner pearlfortune >/dev/null
  # shellcheck source=/dev/null
  . "${config_dir}/profiles.env"
  assert_equals "--proxy" "${FORTUNE_TEST_PEARLFORTUNE_ARGS[0]}" \
    "CLI-generated PearlFortune option"
  assert_equals "{LOCAL_ADDRESS}" "${FORTUNE_TEST_PEARLFORTUNE_ARGS[1]}" \
    "CLI-generated PearlFortune proxy"
  assert_equals "-gpu" "${FORTUNE_TEST_PEARLFORTUNE_ARGS[6]}" \
    "CLI-generated PearlFortune GPU option"
  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles remove fortune-test --miner pearlfortune >/dev/null
  if grep -q '^FORTUNE_TEST_' "${config_dir}/profiles.env"; then
    fail "removing the last miner did not remove the pool profile"
  fi

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles add escape-test \
    --target-host global.pearlfortune.org \
    --target-port 8888 \
    --miner pearlfortune \
    --supported-miners pearlfortune \
    --arg "--proxy \'{LOCAL_ADDRESS}\'" \
    --arg "--address \"${test_wallet}\"" \
    --arg "--worker \"${test_worker}\"" \
    --arg="-gpu" >/dev/null
  # shellcheck source=/dev/null
  . "${config_dir}/profiles.env"
  assert_equals 7 "${#ESCAPE_TEST_PEARLFORTUNE_ARGS[@]}" \
    "CLI escaped argument count"
  assert_equals "--proxy" "${ESCAPE_TEST_PEARLFORTUNE_ARGS[0]}" \
    "CLI escaped option"
  assert_equals "{LOCAL_ADDRESS}" "${ESCAPE_TEST_PEARLFORTUNE_ARGS[1]}" \
    "CLI escaped single-quoted value"
  assert_equals "wallet value" "${ESCAPE_TEST_PEARLFORTUNE_ARGS[3]}" \
    "CLI escaped double-quoted value"
  assert_equals "worker value" "${ESCAPE_TEST_PEARLFORTUNE_ARGS[5]}" \
    "CLI escaped worker value"
  grep -Fq "  --proxy '{LOCAL_ADDRESS}'" "${config_dir}/profiles.env" || \
    fail "CLI did not keep the proxy option and value on one line"
  grep -Fq "  --address 'wallet value'" "${config_dir}/profiles.env" || \
    fail "CLI did not keep the address option and value on one line"
  grep -Fq "  --worker 'worker value'" "${config_dir}/profiles.env" || \
    fail "CLI did not keep the worker option and value on one line"
  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles remove-profile escape-test >/dev/null
  if grep -q '^ESCAPE_TEST_' "${config_dir}/profiles.env"; then
    fail "remove-profile left profile entries behind"
  fi

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles add testpool \
    --target-host pool.example.com \
    --target-port 4321 \
    --miner srbminer \
    --supported-miners "srbminer peakminer" \
    --wallet "wallet with spaces" \
    --password "${password}" \
    --arg=--algorithm \
    --arg=pearlhash >/dev/null

  # shellcheck source=/dev/null
  . "${config_dir}/profiles.env"
  assert_equals "pool.example.com" "${TESTPOOL_TARGET_HOST}" "CLI profile target host"
  assert_equals "4321" "${TESTPOOL_TARGET_PORT}" "CLI profile target port"
  assert_equals "srbminer peakminer" "${TESTPOOL_SUPPORTED_MINERS}" "CLI profile supported miners"
  assert_equals "wallet with spaces" "${TESTPOOL_WALLET}" "CLI profile wallet"
  assert_equals "${password}" "${TESTPOOL_PASSWORD}" "CLI profile password"
  assert_equals "--algorithm" "${TESTPOOL_SRBMINER_ARGS[0]}" "CLI profile miner option"
  assert_equals "pearlhash" "${TESTPOOL_SRBMINER_ARGS[1]}" "CLI profile miner argument"
  assert_equals "--url" "${TESTPOOL_PEAKMINER_ARGS[0]}" \
    "CLI-generated additional miner option"
  assert_equals "wallet with spaces.rtx3090" "${TESTPOOL_PEAKMINER_ARGS[3]}" \
    "CLI-generated additional miner user"

  output="$(GOST_THREAD_CONFIG_DIR="${config_dir}" "${ROOT_DIR}/gost-thread" profiles show testpool)"
  [[ "${output}" == *"Password: <set>"* ]] || fail "profile show did not report the profile password"
  if [[ "${output}" == *"${password}"* ]]; then
    fail "profile show exposed the profile password"
  fi

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles update testpool \
    --target-host updated.example.com \
    --target-port 5555 >/dev/null
  # shellcheck source=/dev/null
  . "${config_dir}/profiles.env"
  assert_equals "updated.example.com" "${TESTPOOL_TARGET_HOST}" "CLI updated profile host"
  assert_equals "5555" "${TESTPOOL_TARGET_PORT}" "CLI updated profile port"
  assert_equals "wallet with spaces" "${TESTPOOL_WALLET}" "CLI update preserved wallet"
  assert_equals "${password}" "${TESTPOOL_PASSWORD}" "CLI update preserved password"

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles set-args testpool \
    --miner peakminer \
    --arg=--url \
    --arg='{LOCAL_ADDRESS}' >/dev/null
  # shellcheck source=/dev/null
  . "${config_dir}/profiles.env"
  assert_equals "--url" "${TESTPOOL_PEAKMINER_ARGS[0]}" "CLI peakminer option"
  assert_equals "{LOCAL_ADDRESS}" "${TESTPOOL_PEAKMINER_ARGS[1]}" "CLI peakminer placeholder"

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles set-endpoint testpool \
    --miner peakminer \
    --target-host override.example.com \
    --target-port 4444 >/dev/null
  # shellcheck source=/dev/null
  . "${config_dir}/profiles.env"
  assert_equals "override.example.com" "${TESTPOOL_PEAKMINER_TARGET_HOST}" \
    "CLI peakminer endpoint host"
  assert_equals "4444" "${TESTPOOL_PEAKMINER_TARGET_PORT}" \
    "CLI peakminer endpoint port"
  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles validate testpool >/dev/null

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles use testpool --miner peakminer >/dev/null
  # shellcheck source=/dev/null
  . "${config_dir}/miner.env"
  # shellcheck source=/dev/null
  . "${config_dir}/client.env"
  assert_equals "testpool" "${ACTIVE_POOL}" "CLI active pool"
  assert_equals "peakminer" "${ACTIVE_MINER}" "CLI active miner"
  assert_equals "127.0.0.1:3333" "${MINER_ARG_1}" "CLI applied miner argument"
  assert_equals "tcp://127.0.0.1:3333/override.example.com:4444" "${LOCAL_FORWARD}" \
    "CLI applied miner endpoint"

  if GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles add testpool \
    --target-host duplicate.example.com \
    --target-port 1234 \
    --miner srbminer >/dev/null 2>&1; then
    fail "duplicate profile was accepted"
  fi

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles clear-args testpool --miner peakminer >/dev/null
  if grep -q '^TESTPOOL_PEAKMINER_ARGS=' "${config_dir}/profiles.env"; then
    fail "profile clear-args left the argument array behind"
  fi
  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles clear-endpoint testpool --miner peakminer >/dev/null
  if grep -Eq '^TESTPOOL_PEAKMINER_TARGET_(HOST|PORT)=' "${config_dir}/profiles.env"; then
    fail "profile clear-endpoint left the endpoint behind"
  fi

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles delete testpool --miner srbminer >/dev/null
  grep -q '^TESTPOOL_TARGET_HOST=' "${config_dir}/profiles.env" || \
    fail "removing one miner removed the whole pool profile"
  if grep -q '^TESTPOOL_SRBMINER_ARGS=' "${config_dir}/profiles.env"; then
    fail "removing one miner left its argument array behind"
  fi
  # shellcheck source=/dev/null
  . "${config_dir}/profiles.env"
  assert_equals "peakminer" "${TESTPOOL_DEFAULT_MINER}" \
    "profile default miner after removing the default miner"
  assert_equals "peakminer" "${TESTPOOL_SUPPORTED_MINERS}" \
    "profile supported miners after removing one miner"

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles remove testpool --miner peakminer >/dev/null
  if grep -Eq '^TESTPOOL_[A-Za-z0-9_]*=' "${config_dir}/profiles.env"; then
    fail "removing the last miner left profile variables behind"
  fi
  grep -q '^LUCKYPOOL_TARGET_HOST=' "${config_dir}/profiles.env" || \
    fail "profile remove changed unrelated profiles"

  if GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles add invalid \
    --target-host pool.example.com \
    --target-port 70000 \
    --miner srbminer >/dev/null 2>&1; then
    fail "invalid profile port was accepted"
  fi

  if GOST_THREAD_CONFIG_DIR="${config_dir}" \
    "${ROOT_DIR}/gost-thread" profiles add invalid \
    --target-host pool.example.com \
    --target-port 3333 \
    --miner missing-miner >/dev/null 2>&1; then
    fail "unregistered miner was accepted"
  fi
}

test_github_install_and_update() {
  local config_dir="${TEST_ROOT}/install-config"
  local systemd_dir="${TEST_ROOT}/systemd"
  local libexec_dir="${TEST_ROOT}/libexec"
  local miners_dir="${TEST_ROOT}/miners"
  local api_dir="${TEST_ROOT}/api/repos/pearlfortune/pearl-miner/releases"
  local krig_api_dir="${TEST_ROOT}/api/repos/kryptex/krig-miner/releases"
  local bundle_dir="${TEST_ROOT}/bundle"
  local asset_dir="${TEST_ROOT}/assets"
  local fake_systemctl="${TEST_ROOT}/systemctl"
  local asset_name
  local asset_file
  local digest
  local output

  mkdir -p "${config_dir}" "${systemd_dir}" "${libexec_dir}" "${api_dir}" "${krig_api_dir}" "${bundle_dir}/package" "${asset_dir}"
  printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == "daemon-reload" ]]' >"${fake_systemctl}"
  chmod +x "${fake_systemctl}"

  asset_name="pearlfortune-v1.0.0.tar.gz"
  asset_file="${asset_dir}/${asset_name}"
  printf '%s\n' '#!/usr/bin/env bash' 'echo version-one' >"${bundle_dir}/package/miner-cuda13"
  chmod +x "${bundle_dir}/package/miner-cuda13"
  tar -czf "${asset_file}" -C "${bundle_dir}" package
  digest="$(sha256_file "${asset_file}")"
  write_release_json "${api_dir}/latest" v1.0.0 "${asset_name}" "file://${asset_file}" "${digest}"

  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" pearlfortune >/dev/null

  [[ -x "${miners_dir}/pearlfortune/miner-cuda13" ]] || fail "GitHub miner was not installed"
  [[ -f "${config_dir}/profiles.env" ]] || fail "profiles.env was not installed"
  output="$("${miners_dir}/pearlfortune/miner-cuda13")"
  assert_equals "version-one" "${output}" "initial GitHub install"

  asset_name="krig-miner-1.4.0-linux-x64.tar.gz"
  asset_file="${asset_dir}/${asset_name}"
  rm -rf "${bundle_dir}/package"
  mkdir -p "${bundle_dir}/package"
  printf '%s\n' '#!/usr/bin/env bash' 'echo krig-version' >"${bundle_dir}/package/krig-miner"
  chmod +x "${bundle_dir}/package/krig-miner"
  tar -czf "${asset_file}" -C "${bundle_dir}" package
  digest="$(sha256_file "${asset_file}")"
  write_release_json "${krig_api_dir}/latest" v1.4.0 "${asset_name}" "file://${asset_file}" "${digest}"

  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" krig-miner >/dev/null
  [[ -x "${miners_dir}/krig-miner/krig-miner" ]] || fail "Krig Miner was not installed"
  output="$("${miners_dir}/krig-miner/krig-miner")"
  assert_equals "krig-version" "${output}" "Krig Miner install"

  local onezero_api_dir="${TEST_ROOT}/api/repos/OneZeroMiner/onezerominer/releases"
  mkdir -p "${onezero_api_dir}"
  rm -rf "${bundle_dir}/package"
  mkdir -p "${bundle_dir}/package"
  printf '%s\n' '#!/usr/bin/env bash' 'echo onezero-version' >"${bundle_dir}/package/onezerominer"
  chmod +x "${bundle_dir}/package/onezerominer"
  asset_name="onezerominer-linux-1.8.3.tar.gz"
  asset_file="${asset_dir}/${asset_name}"
  tar -czf "${asset_file}" -C "${bundle_dir}" package
  digest="$(sha256_file "${asset_file}")"
  write_release_json "${onezero_api_dir}/latest" v1.8.3 "${asset_name}" "file://${asset_file}" "${digest}"
  # Upstream also publishes a generic tarball and a Windows build; neither
  # should produce a second match or replace the explicit Linux archive.
  jq '.assets += [{name:"onezerominer-1.8.3.tar.gz"}, {name:"onezerominer-win64-1.8.3.zip"}]' \
    "${onezero_api_dir}/latest" >"${onezero_api_dir}/latest.tmp"
  mv "${onezero_api_dir}/latest.tmp" "${onezero_api_dir}/latest"
  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --no-systemd onezerominer >/dev/null
  output="$("${miners_dir}/onezerominer/onezerominer")"
  assert_equals onezero-version "${output}" "OneZeroMiner Linux install"

  printf '%s\n' 'CUSTOM_MINERS_CONFIG=preserve' >>"${config_dir}/miners.env"
  printf '%s\n' 'CUSTOM_PROFILES_CONFIG=preserve' >>"${config_dir}/profiles.env"
  printf '%s\n' 'CUSTOM_RUNTIME_CONFIG=preserve' >>"${config_dir}/miner.env"
  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" pearlfortune >/dev/null
  grep -q '^CUSTOM_MINERS_CONFIG=preserve$' "${config_dir}/miners.env" || fail "miners.env was unexpectedly replaced"
  grep -q '^CUSTOM_PROFILES_CONFIG=preserve$' "${config_dir}/profiles.env" || fail "profiles.env was unexpectedly replaced"
  grep -q '^CUSTOM_RUNTIME_CONFIG=preserve$' "${config_dir}/miner.env" || fail "miner.env was unexpectedly replaced"

  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --replace-config pearlfortune >/dev/null
  grep -q "^PEARL_MINERS_DIR=${miners_dir}$" "${config_dir}/miners.env" || fail "miners.env was not replaced"
  grep -q '^DEFAULT_POOL=luckypool$' "${config_dir}/profiles.env" || fail "profiles.env was not replaced"
  grep -q '^CUSTOM_RUNTIME_CONFIG=preserve$' "${config_dir}/miner.env" || fail "miner.env was unexpectedly replaced"
  if grep -Eq '^CUSTOM_(MINERS|PROFILES)_CONFIG=' \
    "${config_dir}/miners.env" "${config_dir}/profiles.env"; then
    fail "custom source configuration survived --replace-config"
  fi

  rm -f "${config_dir}/miner.env"
  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --replace-config pearlfortune >/dev/null
  [[ ! -e "${config_dir}/miner.env" ]] || fail "--replace-config copied the static miner.env template"

  output="$(PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --update pearlfortune)"
  [[ "${output}" == *"already at the latest Release"* ]] || fail "same GitHub Release was not skipped"

  rm -rf "${bundle_dir}/package"
  mkdir -p "${bundle_dir}/package"
  printf '%s\n' '#!/usr/bin/env bash' 'echo version-two' >"${bundle_dir}/package/miner-cuda13"
  chmod +x "${bundle_dir}/package/miner-cuda13"
  asset_name="pearlfortune-v1.1.0fix.tar.gz"
  asset_file="${asset_dir}/${asset_name}"
  tar -czf "${asset_file}" -C "${bundle_dir}" package
  digest="$(sha256_file "${asset_file}")"
  write_release_json "${api_dir}/latest" v1.1.0 "${asset_name}" "file://${asset_file}" "${digest}"

  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --update pearlfortune >/dev/null
  output="$("${miners_dir}/pearlfortune/miner-cuda13")"
  assert_equals "version-two" "${output}" "GitHub update"
  grep -q "RELEASE_TAG='v1.1.0'" "${miners_dir}/pearlfortune/.gost-thread-release.env" || \
    fail "updated Release metadata was not written"

  mkdir -p "${miners_dir}/alpha_miner"
  printf '%s\n' '#!/usr/bin/env bash' 'echo fixed-version' >"${miners_dir}/alpha_miner/alpha-miner"
  chmod +x "${miners_dir}/alpha_miner/alpha-miner"
  output="$(PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --update alpha-miner)"
  [[ "${output}" == *"uses a fixed URL; keeping the installed version"* ]] || \
    fail "--update did not preserve a fixed-URL miner"
  output="$("${miners_dir}/alpha_miner/alpha-miner")"
  assert_equals "fixed-version" "${output}" "fixed-URL update policy"

  GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${TEST_ROOT}/no-systemd-units" \
    GOST_THREAD_LIBEXEC_DIR="${TEST_ROOT}/no-systemd-libexec" \
    GOST_THREAD_SYSTEMCTL=/usr/bin/false \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --no-systemd alpha-miner >/dev/null
  [[ ! -e "${TEST_ROOT}/no-systemd-units" ]] || fail "direct install wrote systemd units"
  [[ ! -e "${TEST_ROOT}/no-systemd-libexec" ]] || fail "direct install wrote systemd helpers"

}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing test command: $1"
}

require_command jq
require_command curl
require_command tar
test_switch_profile_and_runner
test_krig_gost_redirect_help
test_profile_cli
test_github_install_and_update
echo "All script tests passed."
