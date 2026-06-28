#!/usr/bin/env bash
set -euo pipefail

SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
USE_SUDO="${GOST_THREAD_USE_SUDO:-1}"

run_with_optional_sudo() {
  if [[ "${USE_SUDO}" == "1" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

run_with_optional_sudo "${SYSTEMCTL_BIN}" stop gost-client.service
run_with_optional_sudo "${SYSTEMCTL_BIN}" status gost-client.service --no-pager || true
