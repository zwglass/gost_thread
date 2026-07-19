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
  local fake_miner="${TEST_ROOT}/fake-miner"
  local output
  local selection
  local pool
  local miner

  mkdir -p "${config_dir}"
  cp "${ROOT_DIR}/configs/profiles.env" "${ROOT_DIR}/configs/miners.env" "${ROOT_DIR}/configs/client.env" "${config_dir}/"

  GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
    "${ROOT_DIR}/scripts/switch_profile.sh" \
    --pool alphapool --miner tw-pearl-miner --miner-arg=--no-tui >/dev/null

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
    "alphapool alpha-miner" \
    "pearlhash wildrig" \
    "pearlfortune pearlfortune" \
    "herominers peakminer" \
    "kryptex srbminer"; do
    read -r pool miner <<<"${selection}"
    GOST_THREAD_CONFIG_DIR="${config_dir}" GOST_THREAD_RESTART_SERVICES=0 \
      "${ROOT_DIR}/scripts/switch_profile.sh" --pool "${pool}" --miner "${miner}" >/dev/null
  done

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
}

test_github_install_and_update() {
  local config_dir="${TEST_ROOT}/install-config"
  local systemd_dir="${TEST_ROOT}/systemd"
  local libexec_dir="${TEST_ROOT}/libexec"
  local miners_dir="${TEST_ROOT}/miners"
  local api_dir="${TEST_ROOT}/api/repos/egg5233/tw-pearl-miner/releases"
  local bundle_dir="${TEST_ROOT}/bundle"
  local asset_dir="${TEST_ROOT}/assets"
  local fake_systemctl="${TEST_ROOT}/systemctl"
  local asset_name
  local asset_file
  local digest
  local output

  mkdir -p "${config_dir}" "${systemd_dir}" "${libexec_dir}" "${api_dir}" "${bundle_dir}/package" "${asset_dir}"
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
  grep -q '^ACTIVE_POOL=luckypool$' "${config_dir}/miner.env" || fail "miner.env was not replaced"
  if grep -Eq '^CUSTOM_(MINERS|PROFILES|RUNTIME)_CONFIG=' \
    "${config_dir}/miners.env" "${config_dir}/profiles.env" "${config_dir}/miner.env"; then
    fail "custom configuration survived --replace-config"
  fi

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
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing test command: $1"
}

require_command jq
require_command curl
require_command tar
test_switch_profile_and_runner
test_github_install_and_update
echo "All script tests passed."
