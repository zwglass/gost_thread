#!/usr/bin/env bash
set -euo pipefail

sudo systemctl start lpminer.service
sudo systemctl status lpminer.service --no-pager
