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
    --pool alphapool --miner tw-pearl-miner --miner-arg=--no-tui >/dev/null

  client_config="$(<"${config_dir}/client.env")"
  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" \
    --pool alphapool --miner tw-pearl-miner --miner-arg=--no-tui >/dev/null
  assert_equals "${client_config}" "$(<"${config_dir}/client.env")" \
    "client config after repeated profile switch"

  # shellcheck source=/dev/null
  . "${config_dir}/miner.env"
  assert_equals "alphapool" "${ACTIVE_POOL}" "active pool"
  assert_equals "tw-pearl-miner" "${ACTIVE_MINER}" "active miner"
  assert_equals "x;d=262144;mdl=mdl1pgsyjwlla6vaqfp428s2ltf78zhh3kkklx8rmvehxpa6dph8kghrskygxsh" "${MINER_ARG_7}" "quoted password argument"
  assert_equals "--no-tui" "${MINER_ARG_8}" "extra argument"

  if GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool pearlhash --miner tw-pearl-miner >/dev/null 2>&1; then
    fail "unsupported pool/miner combination was accepted"
  fi

  for selection in \
    "luckypool lpminer" \
    "luckypool tw-pearl-miner" \
    "alphapool alpha-miner" \
    "pearlhash wildrig" \
    "pearlhash onezerominer" \
    "pearlfortune pearlfortune" \
    "herominers peakminer" \
    "herominers tw-pearl-miner" \
    "pearlfortune tw-pearl-miner" \
    "kryptex onezerominer" \
    "kryptex srbminer" \
    "kryptex peakminer" \
    "kryptex tw-pearl-miner" \
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
  assert_equals 127.0.0.1:3333 "${MINER_ARG_3}" "PearlHash OneZeroMiner local pool"
  assert_equals "${WALLET_ADDRESS}" "${MINER_ARG_5}" "PearlHash OneZeroMiner wallet"
  assert_equals --worker "${MINER_ARG_6}" "PearlHash OneZeroMiner worker option"
  assert_equals "${WORKER_NAME}" "${MINER_ARG_7}" "PearlHash OneZeroMiner worker"
  assert_equals --pass "${MINER_ARG_8}" "PearlHash OneZeroMiner password option"
  assert_equals x "${MINER_ARG_9}" "PearlHash OneZeroMiner password"
  assert_equals "tcp://127.0.0.1:3333/pool.pearlhash.xyz:9000" "${LOCAL_FORWARD}" "PearlHash OneZeroMiner GOST forward"

  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool kryptex --miner onezerominer >/dev/null
  . "${config_dir}/miner.env"
  . "${config_dir}/profiles.env"
  . "${config_dir}/client.env"
  assert_equals pearlhash "${MINER_ARG_1}" "OneZeroMiner algorithm"
  assert_equals 127.0.0.1:3333 "${MINER_ARG_3}" "OneZeroMiner local pool"
  assert_equals "${WALLET_ADDRESS}.${WORKER_NAME}" "${MINER_ARG_5}" "OneZeroMiner username"
  assert_equals --pass "${MINER_ARG_6}" "OneZeroMiner password option"
  assert_equals x "${MINER_ARG_7}" "OneZeroMiner password"
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
    --pool alphapool --miner tw-pearl-miner --miner-arg=--no-tui >/dev/null
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
ALPHAPOOL_TW_PEARL_MINER_ARGS=(
  --custom 'space ; $(must-not-run)'
  --endpoint '{LOCAL_ADDRESS}/{TARGET_HOST}:{TARGET_PORT}'
  ''
)
EOF
  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool alphapool --miner tw-pearl-miner \
    '--miner-arg={LOCAL_ADDRESS}' >/dev/null
  . "${config_dir}/miner.env"
  assert_equals 'space ; $(must-not-run)' "${MINER_ARG_1}" "literal custom argument"
  assert_equals '127.0.0.1:3333/eu1.alphapool.tech:5566' "${MINER_ARG_3}" "runtime placeholders"
  assert_equals '' "${MINER_ARG_4}" "empty argument"
  assert_equals '{LOCAL_ADDRESS}' "${MINER_ARG_5}" "literal extra argument"
  assert_equals 6 "${MINER_ARG_COUNT}" "configured command replaces defaults"

  printf '\nALPHAPOOL_TW_PEARL_MINER_ARGS=()\n' >>"${config_dir}/profiles.env"
  if GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool alphapool --miner tw-pearl-miner >/dev/null 2>&1; then
    fail "empty argument array was accepted"
  fi
  printf '\nunset ALPHAPOOL_TW_PEARL_MINER_ARGS\nALPHAPOOL_TW_PEARL_MINER_ARGS="--pool localhost"\n' >>"${config_dir}/profiles.env"
  if GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool alphapool --miner tw-pearl-miner >/dev/null 2>&1; then
    fail "command string was accepted"
  fi

  cat >>"${config_dir}/profiles.env" <<'EOF'
unset ALPHAPOOL_TW_PEARL_MINER_ARGS
ALPHAPOOL_WALLET=legacy-wallet
ALPHAPOOL_PASSWORD='legacy password;value'
EOF
  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" --pool alphapool --miner tw-pearl-miner >/dev/null
  . "${config_dir}/miner.env"
  assert_equals legacy-wallet "${MINER_ARG_3}" "legacy wallet fallback"
  assert_equals 'legacy password;value' "${MINER_ARG_7}" "legacy password fallback"
}

test_krig_gost_redirect_help() {
  local output

  output="$("${ROOT_DIR}/scripts/krig_gost_redirect.sh" --help)"
  [[ "${output}" == *"<enable|disable|status>"* ]] || fail "KRig redirect usage is missing commands"
}

test_github_install_and_update() {
  local config_dir="${TEST_ROOT}/install-config"
  local systemd_dir="${TEST_ROOT}/systemd"
  local libexec_dir="${TEST_ROOT}/libexec"
  local miners_dir="${TEST_ROOT}/miners"
  local api_dir="${TEST_ROOT}/api/repos/egg5233/tw-pearl-miner/releases"
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

  asset_name="tw-pearl-miner-1.0.0.c12.tar.gz"
  asset_file="${asset_dir}/${asset_name}"
  printf '%s\n' '#!/usr/bin/env bash' 'echo version-one' >"${bundle_dir}/package/pearl-gpu-miner"
  chmod +x "${bundle_dir}/package/pearl-gpu-miner"
  tar -czf "${asset_file}" -C "${bundle_dir}" package
  digest="$(sha256_file "${asset_file}")"
  write_release_json "${api_dir}/latest" v1.0.0 "${asset_name}" "file://${asset_file}" "${digest}"

  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" tw-pearl-miner >/dev/null

  [[ -x "${miners_dir}/tw-pearl-miner/pearl-gpu-miner" ]] || fail "GitHub miner was not installed"
  [[ -f "${config_dir}/profiles.env" ]] || fail "profiles.env was not installed"
  output="$("${miners_dir}/tw-pearl-miner/pearl-gpu-miner")"
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
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" tw-pearl-miner >/dev/null
  grep -q '^CUSTOM_MINERS_CONFIG=preserve$' "${config_dir}/miners.env" || fail "miners.env was unexpectedly replaced"
  grep -q '^CUSTOM_PROFILES_CONFIG=preserve$' "${config_dir}/profiles.env" || fail "profiles.env was unexpectedly replaced"
  grep -q '^CUSTOM_RUNTIME_CONFIG=preserve$' "${config_dir}/miner.env" || fail "miner.env was unexpectedly replaced"

  PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --replace-config tw-pearl-miner >/dev/null
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
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --replace-config tw-pearl-miner >/dev/null
  [[ ! -e "${config_dir}/miner.env" ]] || fail "--replace-config copied the static miner.env template"

  output="$(PEARL_MINERS_DIR="${miners_dir}" \
    GOST_THREAD_CONFIG_DIR="${config_dir}" \
    GOST_THREAD_SYSTEMD_DIR="${systemd_dir}" \
    GOST_THREAD_LIBEXEC_DIR="${libexec_dir}" \
    GOST_THREAD_SYSTEMCTL="${fake_systemctl}" \
    GOST_THREAD_GITHUB_API_BASE="file://${TEST_ROOT}/api" \
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --update tw-pearl-miner)"
  [[ "${output}" == *"already at the latest Release"* ]] || fail "same GitHub Release was not skipped"

  rm -rf "${bundle_dir}/package"
  mkdir -p "${bundle_dir}/package"
  printf '%s\n' '#!/usr/bin/env bash' 'echo version-two' >"${bundle_dir}/package/pearl-gpu-miner"
  chmod +x "${bundle_dir}/package/pearl-gpu-miner"
  asset_name="tw-pearl-miner-1.1.0.c12.tar.gz"
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
    "${ROOT_DIR}/scripts/install_pearl_miners.sh" --update tw-pearl-miner >/dev/null
  output="$("${miners_dir}/tw-pearl-miner/pearl-gpu-miner")"
  assert_equals "version-two" "${output}" "GitHub update"
  grep -q "RELEASE_TAG='v1.1.0'" "${miners_dir}/tw-pearl-miner/.gost-thread-release.env" || \
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
test_github_install_and_update
echo "All script tests passed."
