#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
MINER_FILE="${CONFIG_DIR}/miner.env"
SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
USE_SUDO="${GOST_THREAD_USE_SUDO:-1}"
CLIENT_READY_ATTEMPTS="${GOST_THREAD_CLIENT_READY_ATTEMPTS:-10}"
LOCAL_MINER_SERVICE="pearl-miner.service"
CLIENT_SERVICE="gost-client.service"
CLIENT_CONFIG_UPDATED=0

usage() {
  cat <<EOF
Usage: $0 [--pool <pool> [--miner <miner>] [--miner-arg <argument>]...]

With no options, start the currently configured miner. With --pool, switch the
pool/miner configuration first. --miner-arg may be repeated and preserves each
argument exactly.
EOF
}

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

validate_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --pool | --miner | --miner-arg)
        [[ "$#" -ge 2 ]] || { echo "Missing value for $1"; exit 1; }
        shift 2
        ;;
      --pool=*)
        shift
        ;;
      --miner=* | --miner-arg=*)
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  return 0
}

run_switch_profile() {
  if [[ "${USE_SUDO}" == "1" ]]; then
    sudo env GOST_THREAD_RESTART_SERVICES=0 "${ROOT_DIR}/scripts/switch_profile.sh" "$@"
  else
    GOST_THREAD_RESTART_SERVICES=0 "${ROOT_DIR}/scripts/switch_profile.sh" "$@"
  fi
  CLIENT_CONFIG_UPDATED=1
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
  local pool
  local pool_address
  local pool_host
  local pool_port

  if [[ ! -f "${MINER_FILE}" ]]; then
    echo "Missing miner config: ${MINER_FILE}"
    return 1
  fi

  pool="$(read_env_value "${MINER_FILE}" MINER_POOL)"
  pool="${pool#\'}"
  pool="${pool%\'}"
  pool_address="${pool#*://}"
  pool_host="${pool_address%:*}"
  pool_port="${pool_address##*:}"

  if [[ -z "${pool_host}" || -z "${pool_port}" || "${pool_host}" == "${pool_port}" ]]; then
    echo "Invalid MINER_POOL in ${MINER_FILE}: ${pool:-not set}"
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
  pool_is_ready
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

main() {
  validate_args "$@"
  if [[ "$#" -gt 0 ]]; then
    run_switch_profile "$@"
  fi

  if [[ "${CLIENT_CONFIG_UPDATED}" == "1" ]]; then
    restart_client
  fi
  ensure_client_ready

  enable_if_installed "${LOCAL_MINER_SERVICE}"
  run_systemctl start "${LOCAL_MINER_SERVICE}"
  run_systemctl status "${LOCAL_MINER_SERVICE}" --no-pager
}

main "$@"
