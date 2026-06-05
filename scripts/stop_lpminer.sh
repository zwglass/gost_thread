#!/usr/bin/env bash
set -euo pipefail

sudo systemctl stop lpminer.service
sudo systemctl status lpminer.service --no-pager || true
