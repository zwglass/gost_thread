#!/usr/bin/env bash
set -euo pipefail

sudo systemctl start gost-server.service
sudo systemctl status gost-server.service --no-pager
