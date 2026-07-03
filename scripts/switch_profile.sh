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

if [[ -n "${miner_service}" ]]; then
  echo "${PROFILE_PREFIX}_MINER_SERVICE is no longer supported."
  echo "Use a pearl-miner.service profile with MINER_BIN, MINER_WORKDIR, MINER_POOL, and MINER_ARGS."
  exit 1
fi

require_value TARGET_HOST "${target_host}"
require_value TARGET_PORT "${target_port}"
require_value MINER_BIN "${miner_bin}"
require_value MINER_WORKDIR "${miner_workdir}"
require_value MINER_POOL "${miner_pool}"
require_value MINER_ARGS "${miner_args}"

if [[ "${RESTART_SERVICES}" == "1" ]] && systemctl cat pearl-miner.service >/dev/null 2>&1 && [[ ! -x "${miner_bin}" ]]; then
  echo "Miner binary is not installed or is not executable: ${miner_bin}"
  echo "Update ${PROFILE_PREFIX}_MINER_BIN in ${PROFILES_FILE}, or install the miner first."
  exit 1
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
install -m 0644 "${miner_tmp}" "${MINER_FILE}"

restart_if_installed gost-client.service
restart_if_installed pearl-miner.service

echo "Switched profile: ${PROFILE}"
echo "GOST target: ${target_host}:${target_port}"
echo "Miner binary: ${miner_bin}"
echo "Miner pool: ${miner_pool}"
