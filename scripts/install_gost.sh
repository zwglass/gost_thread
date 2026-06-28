#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="/etc/gost-thread"
SYSTEMD_DIR="/etc/systemd/system"
ROLE="both"

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

check_gost_installed() {
  local server_gost_bin
  local client_gost_bin

  server_gost_bin="$(read_env_value "${ROOT_DIR}/configs/server.env" "GOST_BIN")"
  client_gost_bin="$(read_env_value "${ROOT_DIR}/configs/client.env" "GOST_BIN")"

  if [[ -z "${server_gost_bin}" || -z "${client_gost_bin}" ]]; then
    echo "GOST_BIN is required in configs/server.env and configs/client.env."
    exit 1
  fi

  if [[ "${server_gost_bin}" != "${client_gost_bin}" ]]; then
    echo "GOST_BIN must be the same in configs/server.env and configs/client.env."
    echo "  server: ${server_gost_bin}"
    echo "  client: ${client_gost_bin}"
    exit 1
  fi

  if [[ ! -x "${server_gost_bin}" ]]; then
    echo "gost is not installed or is not executable at: ${server_gost_bin}"
    echo
    echo "Install gost first:"
    echo "  bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install"
    echo
    echo "Then check the actual binary path:"
    echo "  which gost"
    echo "  gost -V"
    echo
    echo "If the path is different, update GOST_BIN in:"
    echo "  configs/server.env"
    echo "  configs/client.env"
    exit 1
  fi
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --role)
        ROLE="${2:-}"
        shift 2
        ;;
      --role=*)
        ROLE="${1#*=}"
        shift
        ;;
      -h | --help)
        echo "Usage: $0 [--role server|client|both]"
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        echo "Usage: $0 [--role server|client|both]"
        exit 1
        ;;
    esac
  done

  case "${ROLE}" in
    server | client | both) ;;
    *)
      echo "Invalid role: ${ROLE}"
      echo "Usage: $0 [--role server|client|both]"
      exit 1
      ;;
  esac
}

require_root
parse_args "$@"
check_gost_installed

install -d -m 0755 "${CONFIG_DIR}"
install -m 0644 "${ROOT_DIR}/configs/server.env" "${CONFIG_DIR}/server.env"
install -m 0644 "${ROOT_DIR}/configs/client.env" "${CONFIG_DIR}/client.env"
install -m 0644 "${ROOT_DIR}/configs/profiles.env" "${CONFIG_DIR}/profiles.env"
install -m 0644 "${ROOT_DIR}/systemd/gost-server.service" "${SYSTEMD_DIR}/gost-server.service"
install -m 0644 "${ROOT_DIR}/systemd/gost-client.service" "${SYSTEMD_DIR}/gost-client.service"

systemctl daemon-reload

case "${ROLE}" in
  server)
    systemctl enable gost-server.service
    systemctl disable gost-client.service 2>/dev/null || true
    ;;
  client)
    systemctl enable gost-client.service
    systemctl disable gost-server.service 2>/dev/null || true
    ;;
  both)
    systemctl enable gost-server.service
    systemctl enable gost-client.service
    ;;
esac

echo "Installed systemd services:"
case "${ROLE}" in
  server)
    echo "  gost-server.service"
    ;;
  client)
    echo "  gost-client.service"
    ;;
  both)
    echo "  gost-server.service"
    echo "  gost-client.service"
    ;;
esac
echo
echo "Start with:"
case "${ROLE}" in
  server)
    echo "  sudo systemctl start gost-server"
    ;;
  client)
    echo "  sudo systemctl start gost-client"
    ;;
  both)
    echo "  sudo systemctl start gost-server"
    echo "  sudo systemctl start gost-client"
    ;;
esac
