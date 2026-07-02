#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
PROFILES_FILE="${CONFIG_DIR}/profiles.env"
MINER_FILE="${CONFIG_DIR}/miner.env"
SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
USE_SUDO="${GOST_THREAD_USE_SUDO:-1}"
CLIENT_READY_ATTEMPTS="${GOST_THREAD_CLIENT_READY_ATTEMPTS:-10}"
LOCAL_MINER_SERVICE="pearl-miner.service"
AKOYA_SERVICE="akoya-miner.service"
CLIENT_SERVICE="gost-client.service"
CLIENT_READY_ENDPOINT=""
CLIENT_CONFIG_UPDATED=0

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

disable_if_installed() {
  local service="$1"

  if service_exists "${service}"; then
    run_systemctl disable "${service}" || true
  fi
}

enable_if_installed() {
  local service="$1"

  if service_exists "${service}"; then
    run_systemctl enable "${service}"
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

  CLIENT_CONFIG_UPDATED=1
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

endpoint_is_ready() {
  local endpoint="$1"
  local pool_host="${endpoint%:*}"
  local pool_port="${endpoint##*:}"

  if [[ -z "${pool_host}" || -z "${pool_port}" || "${pool_host}" == "${pool_port}" ]]; then
    echo "Invalid client ready endpoint: ${endpoint:-not set}"
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

  if [[ -n "${CLIENT_READY_ENDPOINT}" ]]; then
    endpoint_is_ready "${CLIENT_READY_ENDPOINT}"
  else
    pool_is_ready "${MINER_FILE}"
  fi
}

restart_client() {
  echo "Restarting ${CLIENT_SERVICE} before starting miner service..."
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
requires_gost=1

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
  target_host="$(profile_value "${prefix}" TARGET_HOST)"
  target_port="$(profile_value "${prefix}" TARGET_PORT)"
  akoya_pool_host="$(profile_value "${prefix}" AKOYA_POOL_HOST)"
  akoya_pool_port="$(profile_value "${prefix}" AKOYA_POOL_PORT)"

  if [[ "${selected_service}" == "${LOCAL_MINER_SERVICE}" ]]; then
    stop_if_installed "${AKOYA_SERVICE}"
    disable_if_installed "${AKOYA_SERVICE}"
    run_switch_profile "${profile}"
  else
    stop_if_installed "${LOCAL_MINER_SERVICE}"
    disable_if_installed "${LOCAL_MINER_SERVICE}"
    if [[ -n "${target_host}" || -n "${target_port}" ]]; then
      if [[ -n "${akoya_pool_host}" && -n "${akoya_pool_port}" ]]; then
        CLIENT_READY_ENDPOINT="${akoya_pool_host}:${akoya_pool_port}"
      fi
      run_switch_profile "${profile}"
    else
      requires_gost=0
    fi
  fi
else
  stop_if_installed "${AKOYA_SERVICE}"
  disable_if_installed "${AKOYA_SERVICE}"
fi

if [[ "${requires_gost}" == "1" ]]; then
  if [[ "${CLIENT_CONFIG_UPDATED}" == "1" ]]; then
    restart_client
  fi
  ensure_client_ready
fi

enable_if_installed "${selected_service}"
run_systemctl start "${selected_service}"
run_systemctl status "${selected_service}" --no-pager
