#!/usr/bin/env bash
set -euo pipefail

POOL_HOST="${KRIG_GOST_POOL_HOST:-prl.kryptex.network}"
POOL_PORT="${KRIG_GOST_POOL_PORT:-8048}"
LOCAL_HOST="${KRIG_GOST_LOCAL_HOST:-127.0.0.1}"
LOCAL_PORT="${KRIG_GOST_LOCAL_PORT:-8048}"
CHAIN="GOST_THREAD_KRIG"
IPTABLES_BIN="${IPTABLES_BIN:-iptables}"

usage() {
  cat <<EOF
Usage: sudo $0 <enable|disable|status>

Manage OUTPUT DNAT rules for KRig through the local GOST listener.

The pool hostname continues to resolve to its public IP address. Matching TCP
traffic for ${POOL_HOST}:${POOL_PORT} is redirected locally to
${LOCAL_HOST}:${LOCAL_PORT}, where gost-client.service must be listening.

Commands:
  enable   Resolve the pool's current IPv4 addresses and install the redirect.
  disable  Remove every redirect rule managed by this script.
  status   Show the managed chain and whether its OUTPUT jump is active.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo $0 <enable|disable|status>" >&2
    exit 1
  fi
}

require_iptables() {
  if ! command -v "${IPTABLES_BIN}" >/dev/null 2>&1; then
    echo "iptables is required (set IPTABLES_BIN to override the command)." >&2
    exit 1
  fi
}

pool_ips() {
  local ips

  ips="$(getent ahostsv4 "${POOL_HOST}" | awk '{print $1}' | sort -u)"
  if [[ -z "${ips}" ]]; then
    echo "Could not resolve an IPv4 address for ${POOL_HOST}." >&2
    exit 1
  fi
  printf '%s\n' "${ips}"
}

output_jump_exists() {
  "${IPTABLES_BIN}" -t nat -C OUTPUT -p tcp --dport "${POOL_PORT}" -j "${CHAIN}" >/dev/null 2>&1
}

remove_output_jumps() {
  while output_jump_exists; do
    "${IPTABLES_BIN}" -t nat -D OUTPUT -p tcp --dport "${POOL_PORT}" -j "${CHAIN}"
  done
}

enable_redirect() {
  local ip

  "${IPTABLES_BIN}" -t nat -N "${CHAIN}" 2>/dev/null || true
  "${IPTABLES_BIN}" -t nat -F "${CHAIN}"
  while IFS= read -r ip; do
    "${IPTABLES_BIN}" -t nat -A "${CHAIN}" -p tcp -d "${ip}" --dport "${POOL_PORT}" \
      -j DNAT --to-destination "${LOCAL_HOST}:${LOCAL_PORT}"
  done < <(pool_ips)

  if ! output_jump_exists; then
    "${IPTABLES_BIN}" -t nat -A OUTPUT -p tcp --dport "${POOL_PORT}" -j "${CHAIN}"
  fi

  echo "Enabled KRig GOST redirect: ${POOL_HOST}:${POOL_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}"
  status_redirect
}

disable_redirect() {
  remove_output_jumps
  if "${IPTABLES_BIN}" -t nat -S "${CHAIN}" >/dev/null 2>&1; then
    "${IPTABLES_BIN}" -t nat -F "${CHAIN}"
    "${IPTABLES_BIN}" -t nat -X "${CHAIN}"
  fi
  echo "Disabled KRig GOST redirect."
}

status_redirect() {
  if ! "${IPTABLES_BIN}" -t nat -S "${CHAIN}" >/dev/null 2>&1; then
    echo "KRig GOST redirect is disabled."
    return 0
  fi

  if output_jump_exists; then
    echo "KRig GOST redirect is enabled:"
  else
    echo "KRig GOST chain exists, but no OUTPUT jump is active:"
  fi
  "${IPTABLES_BIN}" -t nat -S "${CHAIN}"
}

main() {
  local command="${1:-}"

  case "${command}" in
    enable | disable | status)
      [[ "$#" -eq 1 ]] || { usage >&2; exit 1; }
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  require_root
  require_iptables

  case "${command}" in
    enable) enable_redirect ;;
    disable) disable_redirect ;;
    status) status_redirect ;;
  esac
}

main "$@"
