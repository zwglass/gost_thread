#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${MINER_BIN:-}" ]]; then
  echo "MINER_BIN is not set."
  exit 1
fi
if [[ -z "${MINER_WORKDIR:-}" ]]; then
  echo "MINER_WORKDIR is not set."
  exit 1
fi
if [[ ! "${MINER_ARG_COUNT:-}" =~ ^[0-9]+$ ]]; then
  echo "MINER_ARG_COUNT is invalid: ${MINER_ARG_COUNT:-not set}"
  exit 1
fi

args=()
for ((i = 0; i < MINER_ARG_COUNT; i++)); do
  key="MINER_ARG_${i}"
  if [[ ! -v "${key}" ]]; then
    echo "Missing miner argument: ${key}"
    exit 1
  fi
  args+=("${!key}")
done

cd "${MINER_WORKDIR}"
if [[ -n "${MINER_LD_LIBRARY_PATH:-}" ]]; then
  export LD_LIBRARY_PATH="${MINER_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
fi

exec "${MINER_BIN}" "${args[@]}"
