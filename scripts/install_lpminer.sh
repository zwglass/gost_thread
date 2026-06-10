#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="/etc/gost-thread"
SYSTEMD_DIR="/etc/systemd/system"
LIBEXEC_DIR="/usr/local/lib/gost-thread"

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

check_client_tunnel() {
  local pool_address
  local pool_host
  local pool_port

  if ! systemctl cat gost-client.service >/dev/null 2>&1; then
    echo "gost-client.service is not installed."
    echo "Install and start the GOST client tunnel before installing lpminer."
    exit 1
  fi

  if ! systemctl is-active --quiet gost-client.service; then
    echo "gost-client.service is not active."
    echo
    systemctl status gost-client.service --no-pager -l || true
    echo
    echo "Recent client logs:"
    journalctl -u gost-client.service -n 30 --no-pager || true
    exit 1
  fi

  pool_address="$(read_env_value "${ROOT_DIR}/configs/lpminer.env" "LPMINER_POOL")"
  pool_address="${pool_address#*://}"
  pool_host="${pool_address%:*}"
  pool_port="${pool_address##*:}"

  if [[ -z "${pool_host}" || -z "${pool_port}" || "${pool_host}" == "${pool_port}" ]]; then
    echo "Invalid LPMINER_POOL in configs/lpminer.env: ${pool_address}"
    exit 1
  fi

  if ! timeout 1 bash -c "</dev/tcp/${pool_host}/${pool_port}" 2>/dev/null; then
    echo "The lpminer pool endpoint is not listening: ${pool_host}:${pool_port}"
    echo "Check gost-client.service and /etc/gost-thread/client.env."
    echo
    echo "Recent client logs:"
    journalctl -u gost-client.service -n 30 --no-pager || true
    exit 1
  fi
}

require_root
check_lpminer_installed
check_client_tunnel

install -d -m 0755 "${CONFIG_DIR}"
install -d -m 0755 "${LIBEXEC_DIR}"
install -m 0644 "${ROOT_DIR}/configs/lpminer.env" "${CONFIG_DIR}/lpminer.env"
install -m 0755 "${ROOT_DIR}/scripts/wait_for_lpminer_pool.sh" "${LIBEXEC_DIR}/wait-for-lpminer-pool"
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
