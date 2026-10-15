#!/usr/bin/env bash
# Run an isolated foreground tunnel/miner pair without touching systemd state.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: $0 [--pool <pool> [--miner <miner>] [--miner-arg <argument>]...]"
  echo "Runs in foreground; Ctrl-C stops only this invocation's tunnel and miner."
  echo "Set GOST_THREAD_CONFIG_DIR to a separate configuration directory."
  exit 0
fi
command -v timeout >/dev/null 2>&1 || { echo 'Missing required command: timeout'; exit 1; }
RUNTIME_DIR="$(mktemp -d)"
client_pid=""
miner_pid=""
cleanup() {
  trap '' INT TERM
  local pid
  for pid in "${miner_pid}" "${client_pid}"; do
    if [[ -n "${pid}" ]]; then kill -TERM "${pid}" 2>/dev/null || true; fi
  done
  # Allow orderly shutdown, then bound cleanup for unresponsive children.
  for ((i=0; i<50; i++)); do
    if ! kill -0 "${miner_pid:-99999999}" 2>/dev/null && ! kill -0 "${client_pid:-99999999}" 2>/dev/null; then break; fi
    sleep 0.1
  done
  for pid in "${miner_pid}" "${client_pid}"; do
    if [[ -n "${pid}" ]]; then
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  rm -rf "${RUNTIME_DIR}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for name in client.env miner.env profiles.env miners.env; do
  if [[ -f "${CONFIG_DIR}/${name}" ]]; then cp "${CONFIG_DIR}/${name}" "${RUNTIME_DIR}/${name}"; fi
done
if [[ "$#" -gt 0 ]]; then
  GOST_THREAD_CONFIG_DIR="${RUNTIME_DIR}" GOST_THREAD_RESTART_SERVICES=0 \
    GOST_THREAD_MANAGE_KRIG_REDIRECT=0 "${ROOT_DIR}/scripts/switch_profile.sh" "$@"
fi
for name in client.env miner.env; do
  [[ -f "${RUNTIME_DIR}/${name}" ]] || { echo "Missing configuration: ${CONFIG_DIR}/${name}"; exit 1; }
done
set -a
. "${RUNTIME_DIR}/client.env"
. "${RUNTIME_DIR}/miner.env"
set +a
# KRig requires host-wide NAT changes; those could affect an existing service.
[[ "${ACTIVE_MINER:-}" != krig-miner ]] || { echo 'Direct mode does not support KRig host-wide redirects.'; exit 1; }
[[ -x "${GOST_BIN:-}" && -x "${MINER_BIN:-}" && -d "${MINER_WORKDIR:-}" ]] || {
  echo 'GOST/miner binary or miner workdir is missing.'; exit 1;
}
: "${LOCAL_FORWARD:?Missing LOCAL_FORWARD}" "${REMOTE_RELAY:?Missing REMOTE_RELAY}" "${MINER_POOL:?Missing MINER_POOL}"
if bash "${ROOT_DIR}/scripts/wait_for_pearl_miner_pool.sh" 1 >/dev/null 2>&1; then
  echo "Configured local port is already in use; choose a separate LOCAL_LISTEN/LOCAL_FORWARD and MINER_POOL."
  exit 1
fi
"${GOST_BIN}" "-L=${LOCAL_FORWARD}" "-F=${REMOTE_RELAY}" &
client_pid=$!
bash "${ROOT_DIR}/scripts/wait_for_pearl_miner_pool.sh" "${GOST_THREAD_CLIENT_READY_ATTEMPTS:-10}"
kill -0 "${client_pid}" 2>/dev/null || { wait "${client_pid}"; exit 1; }
"${ROOT_DIR}/scripts/run_pearl_miner.sh" &
miner_pid=$!
while kill -0 "${client_pid}" 2>/dev/null && kill -0 "${miner_pid}" 2>/dev/null; do sleep 0.2; done
if ! kill -0 "${miner_pid}" 2>/dev/null; then
  wait "${miner_pid}"
else
  wait "${client_pid}" || exit "$?"
  echo 'Tunnel exited before miner.'
  exit 1
fi
