#!/usr/bin/env bash
set -euo pipefail

sudo systemctl stop gost-client.service
sudo systemctl status gost-client.service --no-pager || true
