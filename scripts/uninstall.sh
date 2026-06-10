#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo $0"
    exit 1
  fi
}

require_root

systemctl stop gost-server.service gost-client.service lpminer.service 2>/dev/null || true
systemctl disable gost-server.service gost-client.service lpminer.service 2>/dev/null || true

rm -f /etc/systemd/system/gost-server.service
rm -f /etc/systemd/system/gost-client.service
rm -f /etc/systemd/system/lpminer.service
rm -f /usr/local/lib/gost-thread/wait-for-lpminer-pool
rm -f /etc/gost-thread/server.env
rm -f /etc/gost-thread/client.env
rm -f /etc/gost-thread/lpminer.env
rmdir /etc/gost-thread 2>/dev/null || true

systemctl daemon-reload

echo "Removed gost-thread systemd services and config files."
