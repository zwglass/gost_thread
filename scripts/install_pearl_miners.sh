#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
SYSTEMD_DIR="${GOST_THREAD_SYSTEMD_DIR:-/etc/systemd/system}"
LIBEXEC_DIR="${GOST_THREAD_LIBEXEC_DIR:-/usr/local/lib/gost-thread}"
MINER_CONFIG="${CONFIG_DIR}/miner.env"
PROFILES_CONFIG="${CONFIG_DIR}/profiles.env"
AKOYA_ENV_FILE_FROM_ENV="${AKOYA_ENV_FILE:-}"
AKOYA_ENV_FILE="${AKOYA_ENV_FILE_FROM_ENV:-/etc/akoya-miner/akoya-miner.env}"
AKOYA_INSTALL_URL="${AKOYA_INSTALL_URL:-https://get.akoyapool.com/install.sh}"
DEFAULT_ALPHA_MINER_DOWNLOAD_URL="https://pearl.alphapool.tech/downloads/alpha-miner"
DEFAULT_LPMINER_DOWNLOAD_URL="https://pearl.luckypool.io/lpminer/lpminer-0.1.9.tar.gz"
ALPHA_MINER_DOWNLOAD_URL="${ALPHA_MINER_DOWNLOAD_URL:-}"
LPMINER_DOWNLOAD_URL="${LPMINER_DOWNLOAD_URL:-}"

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

upsert_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  if [[ -f "${file}" ]]; then
    sed "/^${key}=/d" "${file}" >"${tmp_file}"
  fi
  echo "${key}=${value}" >>"${tmp_file}"
  install -m 0644 "${tmp_file}" "${file}"
  rm -f "${tmp_file}"
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

install_akoya_if_missing() {
  local profile_env_file
  local pool_wallet
  local pool_host
  local pool_port
  local pool_tls

  if systemctl cat akoya-miner.service >/dev/null 2>&1; then
    echo "akoya-miner.service already installed"
    return
  fi

  if [[ -x /opt/akoya-miner/akoya-miner || -x /usr/local/bin/akoya-miner ]]; then
    echo "akoya-miner binary exists but service is missing; rerunning official installer"
  fi

  if [[ -z "${AKOYA_ENV_FILE_FROM_ENV}" ]]; then
    profile_env_file="$(read_env_value "${PROFILES_CONFIG}" "AKOYA_ENV_FILE")"
    AKOYA_ENV_FILE="${profile_env_file:-${AKOYA_ENV_FILE}}"
  fi
  pool_wallet="${AKOYA_POOL_WALLET:-$(read_env_value "${PROFILES_CONFIG}" "AKOYA_POOL_WALLET")}"

  if [[ ! -f "${AKOYA_ENV_FILE}" ]]; then
    pool_host="$(read_env_value "${PROFILES_CONFIG}" "AKOYA_AKOYA_POOL_HOST")"
    pool_port="$(read_env_value "${PROFILES_CONFIG}" "AKOYA_AKOYA_POOL_PORT")"
    pool_tls="$(read_env_value "${PROFILES_CONFIG}" "AKOYA_AKOYA_POOL_TLS")"

    if [[ -z "${pool_wallet}" || -z "${pool_host}" || -z "${pool_port}" ]]; then
      echo "Akoya first-time env config is incomplete in ${PROFILES_CONFIG}."
      echo "Set AKOYA_POOL_WALLET, AKOYA_AKOYA_POOL_HOST, and AKOYA_AKOYA_POOL_PORT."
      exit 1
    fi

    echo "Creating ${AKOYA_ENV_FILE} from Akoya profile pool settings"
    install -d -m 0755 "$(dirname "${AKOYA_ENV_FILE}")"
    upsert_env_value "${AKOYA_ENV_FILE}" AKOYA_POOL_WALLET "${pool_wallet}"
    upsert_env_value "${AKOYA_ENV_FILE}" AKOYA_POOL_HOST "${pool_host}"
    upsert_env_value "${AKOYA_ENV_FILE}" AKOYA_POOL_PORT "${pool_port}"
    [[ -n "${pool_tls}" ]] && upsert_env_value "${AKOYA_ENV_FILE}" AKOYA_POOL_TLS "${pool_tls}"
  fi

  if [[ -n "${pool_wallet}" ]]; then
    export AKOYA_POOL_WALLET="${pool_wallet}"
  fi

  echo "Installing akoya-miner with the official installer"
  local installer
  installer="$(mktemp)"
  curl -fsSL "${AKOYA_INSTALL_URL}" -o "${installer}"
  bash "${installer}"
  rm -f "${installer}"
}

install_default_configs() {
  install -d -m 0755 "${CONFIG_DIR}"

  if [[ ! -f "${MINER_CONFIG}" ]]; then
    install -m 0644 "${ROOT_DIR}/configs/miner.env" "${MINER_CONFIG}"
  fi

  if [[ ! -f "${PROFILES_CONFIG}" ]]; then
    install -m 0644 "${ROOT_DIR}/configs/profiles.env" "${PROFILES_CONFIG}"
  fi

  replace_env_value_if_present "${MINER_CONFIG}" MINER_BIN "${LPMINER_BIN}"
  replace_env_value_if_present "${MINER_CONFIG}" MINER_WORKDIR "${LPMINER_DIR}"
  replace_env_value_if_present "${PROFILES_CONFIG}" LUCKYPOOL_MINER_BIN "${LPMINER_BIN}"
  replace_env_value_if_present "${PROFILES_CONFIG}" LUCKYPOOL_MINER_WORKDIR "${LPMINER_DIR}"
  replace_env_value_if_present "${PROFILES_CONFIG}" ALPHAPOOL_MINER_BIN "${ALPHA_MINER_BIN}"
  replace_env_value_if_present "${PROFILES_CONFIG}" ALPHAPOOL_MINER_WORKDIR "${ALPHA_MINER_DIR}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" LPMINER_DOWNLOAD_URL "${DEFAULT_LPMINER_DOWNLOAD_URL}"
  ensure_env_value_if_missing "${PROFILES_CONFIG}" ALPHA_MINER_DOWNLOAD_URL "${DEFAULT_ALPHA_MINER_DOWNLOAD_URL}"
}

resolve_download_urls() {
  local profile_lpminer_url
  local profile_alpha_miner_url

  profile_lpminer_url="$(read_env_value "${PROFILES_CONFIG}" LPMINER_DOWNLOAD_URL)"
  profile_alpha_miner_url="$(read_env_value "${PROFILES_CONFIG}" ALPHA_MINER_DOWNLOAD_URL)"

  LPMINER_DOWNLOAD_URL="${LPMINER_DOWNLOAD_URL:-${profile_lpminer_url:-${DEFAULT_LPMINER_DOWNLOAD_URL}}}"
  ALPHA_MINER_DOWNLOAD_URL="${ALPHA_MINER_DOWNLOAD_URL:-${profile_alpha_miner_url:-${DEFAULT_ALPHA_MINER_DOWNLOAD_URL}}}"
}

ensure_unit_conflict() {
  local unit_file="$1"
  local conflict_service="$2"
  local tmp_file

  if sed -n 's/^Conflicts=//p' "${unit_file}" | tr ' ' '\n' | grep -Fxq "${conflict_service}"; then
    return
  fi

  tmp_file="$(mktemp)"
  awk -v conflict="Conflicts=${conflict_service}" '
    /^\[Unit\]$/ {
      print
      print conflict
      next
    }
    { print }
  ' "${unit_file}" >"${tmp_file}"
  install -m 0644 "${tmp_file}" "${unit_file}"
  rm -f "${tmp_file}"
}

service_has_conflict() {
  local service="$1"
  local conflict_service="$2"

  systemctl cat "${service}" 2>/dev/null | sed -n 's/^Conflicts=//p' | tr ' ' '\n' | grep -Fxq "${conflict_service}"
}

ensure_akoya_conflict() {
  local dropin_dir="${SYSTEMD_DIR}/akoya-miner.service.d"
  local dropin_file="${dropin_dir}/gost-thread.conf"

  if ! systemctl cat akoya-miner.service >/dev/null 2>&1; then
    echo "akoya-miner.service is not installed; cannot add Conflicts drop-in."
    exit 1
  fi

  if service_has_conflict akoya-miner.service pearl-miner.service; then
    echo "akoya-miner.service already conflicts with pearl-miner.service"
    return
  fi

  install -d -m 0755 "${dropin_dir}"
  {
    echo "[Unit]"
    echo "Conflicts=pearl-miner.service"
  } >"${dropin_file}"
  chmod 0644 "${dropin_file}"
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
  ensure_unit_conflict "${SYSTEMD_DIR}/pearl-miner.service" akoya-miner.service
  ensure_akoya_conflict

  systemctl daemon-reload
  systemctl stop pearl-miner.service lpminer.service akoya-miner.service 2>/dev/null || true
  systemctl disable pearl-miner.service lpminer.service akoya-miner.service 2>/dev/null || true
}

require_root
require_command curl
install_default_configs
resolve_download_urls
install_binary_miner lpminer "${LPMINER_DOWNLOAD_URL}" "${LPMINER_DIR}" "${LPMINER_BIN}" LPMINER_DOWNLOAD_URL
install_binary_miner alpha-miner "${ALPHA_MINER_DOWNLOAD_URL}" "${ALPHA_MINER_DIR}" "${ALPHA_MINER_BIN}" ALPHA_MINER_DOWNLOAD_URL
install_akoya_if_missing
install_services
check_client_tunnel_if_installed

echo "Installed Pearl miner services and configs"
echo
echo "Miner paths:"
echo "  lpminer:      ${LPMINER_BIN}"
echo "  alpha-miner:  ${ALPHA_MINER_BIN}"
echo "  akoya-miner:  official installer path"
echo
echo "Start a profile:"
echo "  sudo ./scripts/start_pearl_miners.sh luckypool"
echo "  sudo ./scripts/start_pearl_miners.sh alphapool"
echo "  sudo ./scripts/start_pearl_miners.sh akoya"
