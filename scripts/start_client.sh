#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
USE_SUDO="${GOST_THREAD_USE_SUDO:-1}"

run_with_optional_sudo() {
  if [[ "${USE_SUDO}" == "1" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

if [[ "$#" -gt 0 ]]; then
  run_with_optional_sudo "${ROOT_DIR}/scripts/switch_profile.sh" "$@"
fi

run_with_optional_sudo "${SYSTEMCTL_BIN}" start gost-client.service
run_with_optional_sudo "${SYSTEMCTL_BIN}" status gost-client.service --no-pager
