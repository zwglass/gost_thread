#!/usr/bin/env bash
set -euo pipefail

sudo systemctl start gost-client.service
sudo systemctl status gost-client.service --no-pager
