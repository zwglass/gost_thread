#!/usr/bin/env bash
set -euo pipefail

sudo systemctl stop gost-server.service
sudo systemctl status gost-server.service --no-pager || true
