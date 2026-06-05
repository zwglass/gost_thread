#!/usr/bin/env bash
set -euo pipefail

sudo systemctl status gost-server.service --no-pager || true
echo
sudo systemctl status gost-client.service --no-pager || true
echo
sudo systemctl status lpminer.service --no-pager || true
