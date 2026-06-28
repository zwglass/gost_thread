#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
PROFILES_FILE="${CONFIG_DIR}/profiles.env"
MINER_FILE="${CONFIG_DIR}/miner.env"
SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
USE_SUDO="${GOST_THREAD_USE_SUDO:-1}"
CLIENT_READY_ATTEMPTS="${GOST_THREAD_CLIENT_READY_ATTEMPTS:-10}"
LOCAL_MINER_SERVICE="lpminer.service"
AKOYA_SERVICE="akoya-miner.service"
CLIENT_SERVICE="gost-client.service"

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [profile]"
  exit 1
fi

run_systemctl() {
  if [[ "${USE_SUDO}" == "1" ]]; then
    sudo "${SYSTEMCTL_BIN}" "$@"
  else
    "${SYSTEMCTL_BIN}" "$@"
  fi
}

service_exists() {
  "${SYSTEMCTL_BIN}" cat "$1" >/dev/null 2>&1
}

stop_if_installed() {
  local service="$1"

  if service_exists "${service}"; then
    run_systemctl stop "${service}" || true
  fi
}

read_env_value() {
  local file="$1"
  local key="$2"

  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

run_switch_profile() {
  local profile="$1"

  if [[ "${USE_SUDO}" == "1" ]]; then
    sudo env GOST_THREAD_RESTART_SERVICES=0 "${ROOT_DIR}/scripts/switch_profile.sh" "${profile}"
  else
    GOST_THREAD_RESTART_SERVICES=0 "${ROOT_DIR}/scripts/switch_profile.sh" "${profile}"
  fi
}

profile_prefix() {
  printf "%s" "$1" | tr "[:lower:]-" "[:upper:]_"
}

profile_value() {
  local prefix="$1"
  local suffix="$2"
  local key="${prefix}_${suffix}"

  printf "%s" "${!key:-}"
}

tcp_probe() {
  local host="$1"
  local port="$2"

  if command -v timeout >/dev/null 2>&1; then
    timeout 1 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

pool_is_ready() {
  local miner_file="$1"
  local pool
  local pool_address
  local pool_host
  local pool_port

  if [[ ! -f "${miner_file}" ]]; then
    return 1
  fi

  pool="$(read_env_value "${miner_file}" MINER_POOL)"
  pool_address="${pool#*://}"
  pool_host="${pool_address%:*}"
  pool_port="${pool_address##*:}"

  if [[ -z "${pool_host}" || -z "${pool_port}" || "${pool_host}" == "${pool_port}" ]]; then
    echo "Invalid MINER_POOL in ${miner_file}: ${pool:-not set}"
    return 1
  fi

  for ((i = 1; i <= CLIENT_READY_ATTEMPTS; i++)); do
    if tcp_probe "${pool_host}" "${pool_port}"; then
      return 0
    fi
    sleep 1
  done

  echo "${pool_host}:${pool_port} is not ready after ${CLIENT_READY_ATTEMPTS} attempts"
  return 1
}

client_is_ready() {
  if ! service_exists "${CLIENT_SERVICE}"; then
    echo "${CLIENT_SERVICE} is not installed."
    return 1
  fi

  if ! "${SYSTEMCTL_BIN}" is-active --quiet "${CLIENT_SERVICE}" >/dev/null 2>&1; then
    echo "${CLIENT_SERVICE} is not active."
    return 1
  fi

  pool_is_ready "${MINER_FILE}"
}

restart_client() {
  echo "Restarting ${CLIENT_SERVICE} before starting ${LOCAL_MINER_SERVICE}..."
  "${ROOT_DIR}/scripts/stop_client.sh" || true
  "${ROOT_DIR}/scripts/start_client.sh"
}

ensure_client_ready() {
  if client_is_ready; then
    return
  fi

  restart_client

  if ! client_is_ready; then
    echo "${CLIENT_SERVICE} is still not ready after restart."
    exit 1
  fi
}

selected_service="${LOCAL_MINER_SERVICE}"

if [[ "$#" -eq 1 ]]; then
  profile="$1"

  if [[ ! "${profile}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid profile name: ${profile}"
    exit 1
  fi

  if [[ ! -f "${PROFILES_FILE}" ]]; then
    echo "Missing profiles config: ${PROFILES_FILE}"
    exit 1
  fi

  # shellcheck source=/dev/null
  . "${PROFILES_FILE}"

  prefix="$(profile_prefix "${profile}")"
  selected_service="$(profile_value "${prefix}" MINER_SERVICE)"
  selected_service="${selected_service:-${LOCAL_MINER_SERVICE}}"

  if [[ "${selected_service}" == "${LOCAL_MINER_SERVICE}" ]]; then
    stop_if_installed "${AKOYA_SERVICE}"
    run_switch_profile "${profile}"
  else
    stop_if_installed "${LOCAL_MINER_SERVICE}"
  fi
else
  stop_if_installed "${AKOYA_SERVICE}"
fi

if [[ "${selected_service}" == "${LOCAL_MINER_SERVICE}" ]]; then
  ensure_client_ready
fi

run_systemctl start "${selected_service}"
run_systemctl status "${selected_service}" --no-pager
