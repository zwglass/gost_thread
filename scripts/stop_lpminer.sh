#!/usr/bin/env bash
set -euo pipefail

SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
USE_SUDO="${GOST_THREAD_USE_SUDO:-1}"
MINER_SERVICES=(lpminer.service akoya-miner.service)

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

for service in "${MINER_SERVICES[@]}"; do
  if service_exists "${service}"; then
    run_systemctl stop "${service}" || true
  fi
done

for service in "${MINER_SERVICES[@]}"; do
  if service_exists "${service}"; then
    run_systemctl status "${service}" --no-pager || true
  else
    echo "${service} is not installed."
  fi
done
