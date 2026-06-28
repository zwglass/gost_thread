#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [profile]"
  exit 1
fi

if [[ "$#" -eq 1 ]]; then
  sudo "${ROOT_DIR}/scripts/switch_profile.sh" "$1"
fi

sudo systemctl start lpminer.service
sudo systemctl status lpminer.service --no-pager
