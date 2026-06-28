#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
PROFILES_FILE="${CONFIG_DIR}/profiles.env"
CLIENT_FILE="${CONFIG_DIR}/client.env"
MINER_FILE="${CONFIG_DIR}/miner.env"
RESTART_SERVICES="${GOST_THREAD_RESTART_SERVICES:-1}"

require_root() {
  if [[ "${EUID}" -ne 0 && "${CONFIG_DIR}" == "/etc/gost-thread" ]]; then
    echo "Please run as root: sudo $0 [profile]"
    exit 1
  fi
}

read_env_value() {
  local file="$1"
  local key="$2"

  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

quote_env_value() {
  local value="$1"

  printf "'%s'" "${value//\'/\'\\\'\'}"
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
  install -m 0600 "${tmp_file}" "${file}"
  rm -f "${tmp_file}"
}

profile_value() {
  local key="${PROFILE_PREFIX}_$1"

  printf "%s" "${!key:-}"
}

require_value() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    echo "Missing ${PROFILE_PREFIX}_${name} in ${PROFILES_FILE}"
    exit 1
  fi
}

require_global_value() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    echo "Missing ${name} in ${PROFILES_FILE}"
    exit 1
  fi
}

require_client_value() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    echo "Missing ${name} in ${CLIENT_FILE}"
    exit 1
  fi
}

restart_if_installed() {
  local service="$1"

  if [[ "${RESTART_SERVICES}" != "1" ]]; then
    return
  fi

  if systemctl cat "${service}" >/dev/null 2>&1; then
    systemctl restart "${service}"
  fi
}

write_akoya_env_if_configured() {
  local env_file="$1"
  local pool_host="$2"
  local pool_port="$3"
  local pool_tls="$4"

  if [[ -z "${env_file}" && -z "${pool_host}" && -z "${pool_port}" && -z "${pool_tls}" ]]; then
    return
  fi

  require_value ENV_FILE "${env_file}"

  if [[ ! -f "${env_file}" ]]; then
    echo "Missing Akoya env file: ${env_file}"
    echo "Install Akoya first, or update ${PROFILE_PREFIX}_ENV_FILE in ${PROFILES_FILE}."
    exit 1
  fi

  [[ -n "${pool_host}" ]] && upsert_env_value "${env_file}" AKOYA_POOL_HOST "${pool_host}"
  [[ -n "${pool_port}" ]] && upsert_env_value "${env_file}" AKOYA_POOL_PORT "${pool_port}"
  [[ -n "${pool_tls}" ]] && upsert_env_value "${env_file}" AKOYA_POOL_TLS "${pool_tls}"
}

require_root

if [[ ! -f "${PROFILES_FILE}" ]]; then
  echo "Missing profiles config: ${PROFILES_FILE}"
  exit 1
fi

if [[ ! -f "${CLIENT_FILE}" ]]; then
  echo "Missing client config: ${CLIENT_FILE}"
  exit 1
fi

# shellcheck source=/dev/null
. "${PROFILES_FILE}"

PROFILE="${1:-${DEFAULT_PROFILE:-}}"
if [[ -z "${PROFILE}" ]]; then
  echo "Usage: sudo $0 <profile>"
  exit 1
fi

if [[ ! "${PROFILE}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Invalid profile name: ${PROFILE}"
  exit 1
fi

PROFILE_PREFIX="$(printf "%s" "${PROFILE}" | tr "[:lower:]-" "[:upper:]_")"

target_host="$(profile_value TARGET_HOST)"
target_port="$(profile_value TARGET_PORT)"
miner_service="$(profile_value MINER_SERVICE)"
miner_bin="$(profile_value MINER_BIN)"
miner_workdir="$(profile_value MINER_WORKDIR)"
miner_pool="$(profile_value MINER_POOL)"
miner_args="$(profile_value MINER_ARGS)"
akoya_env_file="$(profile_value ENV_FILE)"
akoya_pool_host="$(profile_value AKOYA_POOL_HOST)"
akoya_pool_port="$(profile_value AKOYA_POOL_PORT)"
akoya_pool_tls="$(profile_value AKOYA_POOL_TLS)"

require_value TARGET_HOST "${target_host}"
require_value TARGET_PORT "${target_port}"

if [[ -z "${miner_service}" ]]; then
  require_value MINER_BIN "${miner_bin}"
  require_value MINER_WORKDIR "${miner_workdir}"
  require_value MINER_POOL "${miner_pool}"
  require_value MINER_ARGS "${miner_args}"

  if [[ "${RESTART_SERVICES}" == "1" ]] && systemctl cat pearl-miner.service >/dev/null 2>&1 && [[ ! -x "${miner_bin}" ]]; then
    echo "Miner binary is not installed or is not executable: ${miner_bin}"
    echo "Update ${PROFILE_PREFIX}_MINER_BIN in ${PROFILES_FILE}, or install the miner first."
    exit 1
  fi
fi

gost_bin="$(read_env_value "${CLIENT_FILE}" GOST_BIN)"
gost_user="$(read_env_value "${CLIENT_FILE}" GOST_USER)"
gost_password="$(read_env_value "${CLIENT_FILE}" GOST_PASSWORD)"
remote_relay="$(read_env_value "${CLIENT_FILE}" REMOTE_RELAY)"
local_listen="${LOCAL_LISTEN:-}"

require_global_value LOCAL_LISTEN "${local_listen}"
require_client_value GOST_BIN "${gost_bin}"
require_client_value REMOTE_RELAY "${remote_relay}"

client_tmp="$(mktemp)"
miner_tmp="$(mktemp)"
trap 'rm -f "${client_tmp}" "${miner_tmp}"' EXIT

{
  echo "GOST_BIN=${gost_bin}"
  echo "GOST_USER=${gost_user}"
  echo "GOST_PASSWORD=${gost_password}"
  echo "LOCAL_FORWARD=${local_listen}/${target_host}:${target_port}"
  echo "REMOTE_RELAY=${remote_relay}"
} >"${client_tmp}"

{
  echo "MINER_BIN=${miner_bin}"
  echo "MINER_WORKDIR=${miner_workdir}"
  echo "MINER_POOL=${miner_pool}"
  echo "MINER_ARGS=$(quote_env_value "${miner_args}")"
} >"${miner_tmp}"

install -m 0644 "${client_tmp}" "${CLIENT_FILE}"
if [[ -z "${miner_service}" ]]; then
  install -m 0644 "${miner_tmp}" "${MINER_FILE}"
else
  write_akoya_env_if_configured "${akoya_env_file}" "${akoya_pool_host}" "${akoya_pool_port}" "${akoya_pool_tls}"
fi

restart_if_installed gost-client.service
if [[ -n "${miner_service}" ]]; then
  restart_if_installed "${miner_service}"
else
  restart_if_installed pearl-miner.service
fi

echo "Switched profile: ${PROFILE}"
echo "GOST target: ${target_host}:${target_port}"
if [[ -n "${miner_service}" ]]; then
  echo "Miner service: ${miner_service}"
else
  echo "Miner binary: ${miner_bin}"
fi
