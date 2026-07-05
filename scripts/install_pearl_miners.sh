#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
SYSTEMD_DIR="${GOST_THREAD_SYSTEMD_DIR:-/etc/systemd/system}"
LIBEXEC_DIR="${GOST_THREAD_LIBEXEC_DIR:-/usr/local/lib/gost-thread}"
MINER_CONFIG="${CONFIG_DIR}/miner.env"
PROFILES_CONFIG="${CONFIG_DIR}/profiles.env"
DEFAULT_ALPHA_MINER_DOWNLOAD_URL="https://pearl.alphapool.tech/downloads/alpha-miner"
DEFAULT_LPMINER_DOWNLOAD_URL="https://pearl.luckypool.io/lpminer/lpminer-0.1.9.tar.gz"
DEFAULT_PEARLHASH_MINER_DOWNLOAD_URL="https://pearlhash.xyz/downloads/pearl-miner-v12"
DEFAULT_PEARLFORTUNE_DOWNLOAD_URL="https://github.com/pearlfortune/pearl-miner/releases/download/v1.2.3/pearlfortune-v1.2.3.tar.gz"
ALPHA_MINER_DOWNLOAD_URL="${ALPHA_MINER_DOWNLOAD_URL:-}"
LPMINER_DOWNLOAD_URL="${LPMINER_DOWNLOAD_URL:-}"
PEARLHASH_MINER_DOWNLOAD_URL="${PEARLHASH_MINER_DOWNLOAD_URL:-}"
PEARLFORTUNE_DOWNLOAD_URL="${PEARLFORTUNE_DOWNLOAD_URL:-}"

detect_base_dir() {
  if [[ -n "${PEARL_MINERS_DIR:-}" ]]; then
    printf "%s" "${PEARL_MINERS_DIR}"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local sudo_home
    sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
    printf "%s" "${sudo_home:-/home/${SUDO_USER}}/programs/pearl_miners"
    return
  fi

  printf "%s" "${HOME}/programs/pearl_miners"
}

MINERS_BASE_DIR="$(detect_base_dir)"
LPMINER_DIR="${LPMINER_DIR:-${MINERS_BASE_DIR}/lpminer}"
LPMINER_BIN="${LPMINER_BIN:-${LPMINER_DIR}/lpminer}"
ALPHA_MINER_DIR="${ALPHA_MINER_DIR:-${MINERS_BASE_DIR}/alpha_miner}"
ALPHA_MINER_BIN="${ALPHA_MINER_BIN:-${ALPHA_MINER_DIR}/alpha-miner}"
PEARLHASH_MINER_DIR="${PEARLHASH_MINER_DIR:-${MINERS_BASE_DIR}/pearlhash}"
PEARLHASH_MINER_BIN="${PEARLHASH_MINER_BIN:-${PEARLHASH_MINER_DIR}/pearl-miner}"
PEARLFORTUNE_DIR="${PEARLFORTUNE_DIR:-${MINERS_BASE_DIR}/pearlfortune}"
PEARLFORTUNE_BIN="${PEARLFORTUNE_BIN:-${PEARLFORTUNE_DIR}/miner-cuda13}"

require_root() {
  if [[ "${EUID}" -ne 0 && "${CONFIG_DIR}" == "/etc/gost-thread" ]]; then
    echo "Please run as root: sudo $0"
    exit 1
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}"
    exit 1
  fi
}

read_env_value() {
  local file="$1"
  local key="$2"

  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

replace_env_value_if_present() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  if grep -q "^${key}=" "${file}"; then
    tmp_file="$(mktemp)"
    awk -v key="${key}" -v value="${value}" '
      index($0, key "=") == 1 {
        print key "=" value
        next
      }
      { print }
    ' "${file}" >"${tmp_file}"
    install -m 0644 "${tmp_file}" "${file}"
    rm -f "${tmp_file}"
  fi
}

ensure_env_value_if_missing() {
  local file="$1"
  local key="$2"
  local value="$3"

  if ! grep -q "^${key}=" "${file}"; then
    echo "${key}=${value}" >>"${file}"
  fi
}

download_file() {
  local url="$1"
  local output_file="$2"
  local label="$3"
  local attempt=1
  local max_attempts=3

  while ((attempt <= max_attempts)); do
    echo "Downloading ${label} (${attempt}/${max_attempts}): ${url}"
    if curl -fL --connect-timeout 20 "${url}" -o "${output_file}" && [[ -s "${output_file}" ]]; then
      return 0
    fi

    rm -f "${output_file}"
    if ((attempt < max_attempts)); then
      echo "Download failed; retrying in 2 seconds..."
      sleep 2
    fi
    attempt=$((attempt + 1))
  done

  echo "Failed to download ${label}: ${url}"
  echo "Check network connectivity, or override the URL with the ${label} download setting."
  return 1
}

install_binary_miner() {
  local miner_name="$1"
  local miner_url="$2"
  local miner_dir="$3"
  local miner_bin="$4"
  local url_var_name="$5"
  local tmp_file
  local tmp_dir
  local extracted_bin

  if [[ -x "${miner_bin}" ]]; then
    echo "${miner_name} already installed: ${miner_bin}"
    return
  fi

  if [[ -z "${miner_url}" ]]; then
    echo "${miner_name} is missing and no download URL is configured."
    echo "Set ${url_var_name} or install it manually at:"
    echo "  ${miner_bin}"
    exit 1
  fi

  echo "Installing ${miner_name} to ${miner_bin}"
  install -d -m 0755 "${miner_dir}"
  tmp_file="$(mktemp)"
  if ! download_file "${miner_url}" "${tmp_file}" "${url_var_name}"; then
    rm -f "${tmp_file}"
    exit 1
  fi

  case "${miner_url}" in
    *.tar.gz | *.tgz)
      require_command tar
      tmp_dir="$(mktemp -d)"
      if ! tar -xzf "${tmp_file}" -C "${tmp_dir}"; then
        echo "Downloaded archive is not a valid gzip tar file: ${miner_url}"
        rm -rf "${tmp_dir}"
        rm -f "${tmp_file}"
        exit 1
      fi
      extracted_bin="$(
        find "${tmp_dir}" -type f \( -name "$(basename "${miner_bin}")" -o -name "${miner_name}" \) -print -quit
      )"
      if [[ -z "${extracted_bin}" ]]; then
        echo "Could not find ${miner_name} binary inside downloaded archive: ${miner_url}"
        rm -rf "${tmp_dir}"
        rm -f "${tmp_file}"
        exit 1
      fi
      install -m 0755 "${extracted_bin}" "${miner_bin}"
      rm -rf "${tmp_dir}"
      ;;
    *)
      install -m 0755 "${tmp_file}" "${miner_bin}"
      ;;
  esac

  rm -f "${tmp_file}"
}

install_archive_dir_miner() {
  local miner_name="$1"
  local miner_url="$2"
  local miner_dir="$3"
  local miner_bin="$4"
  local url_var_name="$5"
  local tmp_file
  local tmp_dir
  local extracted_bin
  local extracted_dir

  if [[ -x "${miner_bin}" ]]; then
    echo "${miner_name} already installed: ${miner_bin}"
    return
  fi

  if [[ -z "${miner_url}" ]]; then
    echo "${miner_name} is missing and no download URL is configured."
    echo "Set ${url_var_name} or install it manually at:"
    echo "  ${miner_bin}"
    exit 1
  fi

  echo "Installing ${miner_name} to ${miner_dir}"
  require_command tar
  install -d -m 0755 "${miner_dir}"
  tmp_file="$(mktemp)"
  tmp_dir="$(mktemp -d)"
  if ! download_file "${miner_url}" "${tmp_file}" "${url_var_name}"; then
    rm -rf "${tmp_dir}"
    rm -f "${tmp_file}"
    exit 1
  fi

  if ! tar -xzf "${tmp_file}" -C "${tmp_dir}"; then
    echo "Downloaded archive is not a valid gzip tar file: ${miner_url}"
    rm -rf "${tmp_dir}"
    rm -f "${tmp_file}"
    exit 1
  fi

  extracted_bin="$(find "${tmp_dir}" -type f -name "$(basename "${miner_bin}")" -print -quit)"
  if [[ -z "${extracted_bin}" ]]; then
    echo "Could not find ${miner_name} binary inside downloaded archive: ${miner_url}"
    rm -rf "${tmp_dir}"
    rm -f "${tmp_file}"
    exit 1
  fi

  extracted_dir="$(dirname "${extracted_bin}")"
  cp -R "${extracted_dir}/." "${miner_dir}/"
  chmod +x "${miner_bin}"
  rm -rf "${tmp_dir}"
  rm -f "${tmp_file}"
}

install_default_configs() {
  local local_listen
  local local_pool_address

  install -d -m 0755 "${CONFIG_DIR}"

  if [[ ! -f "${MINER_CONFIG}" ]]; then
    install -m 0644 "${ROOT_DIR}/configs/miner.env" "${MINER_CONFIG}"
  fi

  if [[ ! -f "${PROFILES_CONFIG}" ]]; then
    install -m 0644 "${ROOT_DIR}/configs/profiles.env" "${PROFILES_CONFIG}"
  fi

  local_listen="$(read_env_value "${PROFILES_CONFIG}" LOCAL_LISTEN)"
  local_listen="${local_listen:-tcp://127.0.0.1:3333}"
  local_pool_address="${local_listen#*://}"

  replace_env_value_if_present "${MINER_CONFIG}" MINER_BIN "${LPMINER_BIN}"
  replace_env_value_if_present "${MINER_CONFIG}" MINER_WORKDIR "${LPMINER_DIR}"
  replace_env_value_if_present "${PROFILES_CONFIG}" LUCKYPOOL_MINER_BIN "${LPMINER_BIN}"
  replace_env_value_if_present "${PROFILES_CONFIG}" LUCKYPOOL_MINER_WORKDIR "${LPMINER_DIR}"
  replace_env_value_if_present "${PROFILES_CONFIG}" ALPHAPOOL_MINER_BIN "${ALPHA_MINER_BIN}"
  replace_env_value_if_present "${PROFILES_CONFIG}" ALPHAPOOL_MINER_WORKDIR "${ALPHA_MINER_DIR}"
  replace_env_value_if_present "${PROFILES_CONFIG}" PEARLHASH_MINER_BIN "${PEARLHASH_MINER_BIN}"
  replace_env_value_if_present "${PROFILES_CONFIG}" PEARLHASH_MINER_WORKDIR "${PEARLHASH_MINER_DIR}"
  replace_env_value_if_present "${PROFILES_CONFIG}" PEARLFORTUNE_MINER_BIN "${PEARLFORTUNE_BIN}"
  replace_env_value_if_present "${PROFILES_CONFIG}" PEARLFORTUNE_MINER_WORKDIR "${PEARLFORTUNE_DIR}"
  replace_env_value_if_present "${PROFILES_CONFIG}" PEARLFORTUNE_MINER_LD_LIBRARY_PATH ""
  ensure_env_value_if_missing "${PROFILES_CONFIG}" LPMINER_DOWNLOAD_URL "${DEFAULT_LPMINER_DOWNLOAD_URL}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" ALPHA_MINER_DOWNLOAD_URL "${DEFAULT_ALPHA_MINER_DOWNLOAD_URL}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" PEARLHASH_MINER_DOWNLOAD_URL "${DEFAULT_PEARLHASH_MINER_DOWNLOAD_URL}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" PEARLFORTUNE_DOWNLOAD_URL "${DEFAULT_PEARLFORTUNE_DOWNLOAD_URL}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" PEARLFORTUNE_TARGET_HOST "global.pearlfortune.org"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" PEARLFORTUNE_TARGET_PORT "443"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" PEARLFORTUNE_MINER_BIN "${PEARLFORTUNE_BIN}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" PEARLFORTUNE_MINER_WORKDIR "${PEARLFORTUNE_DIR}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" PEARLFORTUNE_MINER_POOL "${local_listen}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" PEARLFORTUNE_MINER_ARGS "\"--proxy ${local_pool_address} --address prl1p22pq5hnskyrpysvtx8yqayq8vurrrfu0jzmyeqtjxs7r75k8jvuqpqspma --worker \${WORKER_NAME} -gpu\""
}

resolve_download_urls() {
  local profile_lpminer_url
  local profile_alpha_miner_url
  local profile_pearlhash_miner_url
  local profile_pearlfortune_url

  profile_lpminer_url="$(read_env_value "${PROFILES_CONFIG}" LPMINER_DOWNLOAD_URL)"
  profile_alpha_miner_url="$(read_env_value "${PROFILES_CONFIG}" ALPHA_MINER_DOWNLOAD_URL)"
  profile_pearlhash_miner_url="$(read_env_value "${PROFILES_CONFIG}" PEARLHASH_MINER_DOWNLOAD_URL)"
  profile_pearlfortune_url="$(read_env_value "${PROFILES_CONFIG}" PEARLFORTUNE_DOWNLOAD_URL)"

  LPMINER_DOWNLOAD_URL="${LPMINER_DOWNLOAD_URL:-${profile_lpminer_url:-${DEFAULT_LPMINER_DOWNLOAD_URL}}}"
  ALPHA_MINER_DOWNLOAD_URL="${ALPHA_MINER_DOWNLOAD_URL:-${profile_alpha_miner_url:-${DEFAULT_ALPHA_MINER_DOWNLOAD_URL}}}"
  PEARLHASH_MINER_DOWNLOAD_URL="${PEARLHASH_MINER_DOWNLOAD_URL:-${profile_pearlhash_miner_url:-${DEFAULT_PEARLHASH_MINER_DOWNLOAD_URL}}}"
  PEARLFORTUNE_DOWNLOAD_URL="${PEARLFORTUNE_DOWNLOAD_URL:-${profile_pearlfortune_url:-${DEFAULT_PEARLFORTUNE_DOWNLOAD_URL}}}"
}

check_client_tunnel_if_installed() {
  local pool_address
  local pool_host
  local pool_port

  if ! systemctl cat gost-client.service >/dev/null 2>&1; then
    echo "gost-client.service is not installed; skipping tunnel readiness check."
    return
  fi

  if ! systemctl is-active --quiet gost-client.service; then
    echo "gost-client.service is installed but not active; skipping miner restart."
    return
  fi

  pool_address="$(read_env_value "${MINER_CONFIG}" "MINER_POOL")"
  pool_address="${pool_address#*://}"
  pool_host="${pool_address%:*}"
  pool_port="${pool_address##*:}"

  if [[ -z "${pool_host}" || -z "${pool_port}" || "${pool_host}" == "${pool_port}" ]]; then
    echo "Invalid MINER_POOL in ${MINER_CONFIG}: ${pool_address}"
    exit 1
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout 1 bash -c "</dev/tcp/${pool_host}/${pool_port}" >/dev/null 2>&1 || {
      echo "The miner pool endpoint is not listening: ${pool_host}:${pool_port}"
      echo "Install/start the GOST client before starting pearl-miner.service."
    }
  fi
}

install_services() {
  install -d -m 0755 "${LIBEXEC_DIR}"
  install -m 0755 "${ROOT_DIR}/scripts/wait_for_pearl_miner_pool.sh" "${LIBEXEC_DIR}/wait-for-pearl-miner-pool"
  install -m 0644 "${ROOT_DIR}/systemd/pearl-miner.service" "${SYSTEMD_DIR}/pearl-miner.service"

  systemctl daemon-reload
  systemctl stop pearl-miner.service lpminer.service 2>/dev/null || true
  systemctl disable pearl-miner.service lpminer.service 2>/dev/null || true
}

require_root
require_command curl
install_default_configs
resolve_download_urls
install_binary_miner lpminer "${LPMINER_DOWNLOAD_URL}" "${LPMINER_DIR}" "${LPMINER_BIN}" LPMINER_DOWNLOAD_URL
install_binary_miner alpha-miner "${ALPHA_MINER_DOWNLOAD_URL}" "${ALPHA_MINER_DIR}" "${ALPHA_MINER_BIN}" ALPHA_MINER_DOWNLOAD_URL
install_binary_miner pearlhash-miner "${PEARLHASH_MINER_DOWNLOAD_URL}" "${PEARLHASH_MINER_DIR}" "${PEARLHASH_MINER_BIN}" PEARLHASH_MINER_DOWNLOAD_URL
install_archive_dir_miner pearlfortune "${PEARLFORTUNE_DOWNLOAD_URL}" "${PEARLFORTUNE_DIR}" "${PEARLFORTUNE_BIN}" PEARLFORTUNE_DOWNLOAD_URL
install_services
check_client_tunnel_if_installed

echo "Installed Pearl miner services and configs"
echo
echo "Miner paths:"
echo "  lpminer:      ${LPMINER_BIN}"
echo "  alpha-miner:  ${ALPHA_MINER_BIN}"
echo "  pearlhash:    ${PEARLHASH_MINER_BIN}"
echo "  pearlfortune: ${PEARLFORTUNE_BIN}"
echo
echo "Start a profile:"
echo "  sudo ./scripts/start_pearl_miners.sh luckypool"
echo "  sudo ./scripts/start_pearl_miners.sh alphapool"
echo "  sudo ./scripts/start_pearl_miners.sh pearlhash"
echo "  sudo ./scripts/start_pearl_miners.sh pearlfortune"
