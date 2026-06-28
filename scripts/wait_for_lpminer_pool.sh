#!/usr/bin/env bash
set -euo pipefail

attempts="${1:-60}"
pool="${MINER_POOL:-${LPMINER_POOL:-}}"
pool_address="${pool#*://}"
pool_host="${pool_address%:*}"
pool_port="${pool_address##*:}"

if [[ -z "${pool_host}" || -z "${pool_port}" || "${pool_host}" == "${pool_port}" ]]; then
  echo "Invalid MINER_POOL: ${pool:-not set}"
  exit 1
fi

for ((i = 1; i <= attempts; i++)); do
  if timeout 1 bash -c "</dev/tcp/${pool_host}/${pool_port}" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 1
done

echo "${pool_host}:${pool_port} is not ready after ${attempts} attempts"
exit 1
