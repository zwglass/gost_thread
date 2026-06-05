#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="/etc/gost-thread"
SYSTEMD_DIR="/etc/systemd/system"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo $0"
    exit 1
  fi
}

read_env_value() {
  local file="$1"
  local key="$2"

  sed -n "s/^${key}=//p" "${file}" | tail -n 1
}

check_lpminer_installed() {
  local lpminer_bin

  lpminer_bin="$(read_env_value "${ROOT_DIR}/configs/lpminer.env" "LPMINER_BIN")"

  if [[ -z "${lpminer_bin}" ]]; then
    echo "LPMINER_BIN is required in configs/lpminer.env."
    exit 1
  fi

  if [[ ! -x "${lpminer_bin}" ]]; then
    echo "lpminer is not installed or is not executable at: ${lpminer_bin}"
    echo
    echo "Update LPMINER_BIN and LPMINER_WORKDIR in:"
    echo "  configs/lpminer.env"
    echo
    echo "Current expected binary:"
    echo "  ${lpminer_bin}"
    exit 1
  fi
}

require_root
check_lpminer_installed

install -d -m 0755 "${CONFIG_DIR}"
install -m 0644 "${ROOT_DIR}/configs/lpminer.env" "${CONFIG_DIR}/lpminer.env"
install -m 0644 "${ROOT_DIR}/systemd/lpminer.service" "${SYSTEMD_DIR}/lpminer.service"

systemctl daemon-reload
systemctl enable lpminer.service
systemctl restart lpminer.service

echo "Installed and started lpminer.service"
echo
echo "Status:"
echo "  sudo systemctl status lpminer --no-pager"
echo
echo "Logs:"
echo "  sudo journalctl -u lpminer -f"
