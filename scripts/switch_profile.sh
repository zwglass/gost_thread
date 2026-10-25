#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_FILE="${CONFIG_DIR}/profiles.env"
MINERS_FILE="${CONFIG_DIR}/miners.env"
CLIENT_FILE="${CONFIG_DIR}/client.env"
MINER_FILE="${CONFIG_DIR}/miner.env"
RESTART_SERVICES="${GOST_THREAD_RESTART_SERVICES:-1}"
SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
KRIG_REDIRECT_SCRIPT="${GOST_THREAD_KRIG_REDIRECT_SCRIPT:-${ROOT_DIR}/scripts/krig_gost_redirect.sh}"
KRIG_REDIRECT_FALLBACK="${GOST_THREAD_KRIG_REDIRECT_FALLBACK:-/usr/local/lib/gost-thread/krig-gost-redirect}"
if [[ -v GOST_THREAD_MANAGE_KRIG_REDIRECT ]]; then
  MANAGE_KRIG_REDIRECT="${GOST_THREAD_MANAGE_KRIG_REDIRECT}"
elif [[ "${CONFIG_DIR}" == "/etc/gost-thread" ]]; then
  MANAGE_KRIG_REDIRECT=1
else
  MANAGE_KRIG_REDIRECT=0
fi
POOL=""
MINER=""
EXTRA_MINER_ARGS=()
MINER_ARGS=()

usage() {
  cat <<EOF
Usage: sudo $0 --pool <pool> [--miner <miner>] [--miner-arg <argument>]...

Options:
  --pool NAME          Select the remote pool.
  --miner NAME         Select a compatible miner (defaults to the pool default).
  --miner-arg ARG      Append one literal miner argument; may be repeated.
  -h, --help           Show this help.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 && "${CONFIG_DIR}" == "/etc/gost-thread" ]]; then
    echo "Please run as root: sudo $0 --pool <pool> [--miner <miner>]"
    exit 1
  fi
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --pool)
        [[ "$#" -ge 2 ]] || { echo "Missing value for --pool"; exit 1; }
        POOL="$2"
        shift 2
        ;;
      --pool=*)
        POOL="${1#*=}"
        shift
        ;;
      --miner)
        [[ "$#" -ge 2 ]] || { echo "Missing value for --miner"; exit 1; }
        MINER="$2"
        shift 2
        ;;
      --miner=*)
        MINER="${1#*=}"
        shift
        ;;
      --miner-arg)
        [[ "$#" -ge 2 ]] || { echo "Missing value for --miner-arg"; exit 1; }
        EXTRA_MINER_ARGS+=("$2")
        shift 2
        ;;
      --miner-arg=*)
        EXTRA_MINER_ARGS+=("${1#*=}")
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "${POOL}" ]]; then
    echo "--pool is required."
    usage
    exit 1
  fi

  validate_identifier pool "${POOL}"
  if [[ -n "${MINER}" ]]; then
    validate_identifier miner "${MINER}"
  fi
}

validate_identifier() {
  local label="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid ${label} name: ${value}"
    exit 1
  fi
}

config_prefix() {
  printf "%s" "$1" | tr "[:lower:]-" "[:upper:]_"
}

config_value() {
  local prefix="$1"
  local suffix="$2"
  local key="${prefix}_${suffix}"

  printf "%s" "${!key:-}"
}

require_value() {
  local label="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    echo "Missing ${label}."
    exit 1
  fi
}

restore_missing_config() {
  local destination="$1"
  local template="$2"

  if [[ -f "${destination}" ]]; then
    return
  fi
  if [[ ! -f "${template}" ]]; then
    echo "Missing config and template: ${destination}, ${template}" >&2
    exit 1
  fi
  install -d -m 0755 "${CONFIG_DIR}"
  install -m 0644 "${template}" "${destination}"
  echo "Restored missing config: ${destination}"
}

restore_missing_profile_value() {
  local key="$1"
  local template="${ROOT_DIR}/configs/profiles.env"
  local value

  if [[ -n "$(read_env_value "${PROFILES_FILE}" "${key}")" ]]; then
    return
  fi
  value="$(read_env_value "${template}" "${key}")"
  if [[ -z "${value}" ]]; then
    echo "Missing required profile setting and template value: ${key}" >&2
    exit 1
  fi
  printf '\n%s=%s\n' "${key}" "${value}" >>"${PROFILES_FILE}"
  echo "Restored missing profile setting: ${key}"
}

ensure_krig_redirect_script() {
  if [[ -x "${KRIG_REDIRECT_SCRIPT}" ]]; then
    return
  fi
  if [[ -x "${KRIG_REDIRECT_FALLBACK}" ]]; then
    install -d -m 0755 "$(dirname "${KRIG_REDIRECT_SCRIPT}")"
    install -m 0755 "${KRIG_REDIRECT_FALLBACK}" "${KRIG_REDIRECT_SCRIPT}"
    echo "Restored KRig redirect script: ${KRIG_REDIRECT_SCRIPT}"
    return
  fi
  echo "KRig redirect script is missing: ${KRIG_REDIRECT_SCRIPT}" >&2
  echo "Run ./scripts/install_pearl_miners.sh krig-miner to install its fallback copy." >&2
  exit 1
}

manage_krig_redirect() {
  local action="$1"
  local target_host="${2:-}"
  local target_port="${3:-}"

  if [[ "${MANAGE_KRIG_REDIRECT}" != "1" ]]; then
    return 0
  fi
  ensure_krig_redirect_script

  if [[ "${action}" == "enable" ]]; then
    KRIG_GOST_POOL_HOST="${target_host}" \
      KRIG_GOST_POOL_PORT="${target_port}" \
      KRIG_GOST_LOCAL_PORT="${target_port}" \
      "${KRIG_REDIRECT_SCRIPT}" enable
  else
    "${KRIG_REDIRECT_SCRIPT}" disable
  fi
}

read_env_value() {
  local file="$1"
  local key="$2"
  local value

  value="$(sed -n "s/^${key}=//p" "${file}" | tail -n 1)"
  # These client settings never legitimately contain shell quoting characters.
  # Removing them directly also repairs configs polluted by repeated quoting in
  # linear time, regardless of how many escaped quote sequences accumulated.
  value="${value//\\/}"
  value="${value//\'/}"
  value="${value//\"/}"
  printf "%s" "${value}"
}

quote_env_value() {
  local value="$1"

  printf "'%s'" "${value//\'/\'\\\'\'}"
}

list_pools() {
  sed -n 's/^\([A-Z0-9_][A-Z0-9_]*\)_TARGET_HOST=.*/\1/p' "${PROFILES_FILE}" \
    | tr "[:upper:]_" "[:lower:]-" \
    | sort
}

list_miners() {
  printf "%s\n" ${MINER_IDS:-} | sort
}

contains_word() {
  local words="$1"
  local wanted="$2"
  local word

  for word in ${words}; do
    if [[ "${word}" == "${wanted}" ]]; then
      return 0
    fi
  done
  return 1
}

append_arg() {
  MINER_ARGS+=("$1")
}

append_option() {
  MINER_ARGS+=("$1" "$2")
}

build_miner_args() {
  local key="$(config_prefix "$2")_$(config_prefix "$1")_ARGS"
  local declaration
  local argument
  local local_address="$3"
  local target_host="$4"
  local target_port="$5"

  if ! declaration="$(declare -p "${key}" 2>/dev/null)"; then
    # Existing installed profiles keep working until their arrays are migrated.
    require_value "wallet for $2" "$6"
    build_legacy_miner_args "$@"
    return
  fi
  if [[ "${declaration}" != "declare -a "* ]]; then
    echo "${key} must be an indexed Bash argument array." >&2
    exit 1
  fi
  local -n configured_args="${key}"
  if [[ "${#configured_args[@]}" -eq 0 ]]; then
    echo "${key} must contain at least one argument." >&2
    exit 1
  fi
  MINER_ARGS=()
  for argument in "${configured_args[@]}"; do
    argument="${argument//\{LOCAL_ADDRESS\}/${local_address}}"
    argument="${argument//\{TARGET_HOST\}/${target_host}}"
    argument="${argument//\{TARGET_PORT\}/${target_port}}"
    MINER_ARGS+=("${argument}")
  done
  MINER_ARGS+=("${EXTRA_MINER_ARGS[@]}")
}

build_legacy_miner_args() {
  local miner="$1"
  local pool="$2"
  local local_address="$3"
  local target_host="$4"
  local target_port="$5"
  local wallet="$6"
  local worker="$7"
  local password="$8"
  local stratum_pool="stratum+tcp://${local_address}"

  MINER_ARGS=()
  case "${miner}" in
    lpminer)
      append_option --algo pearl
      append_option --pool "${stratum_pool}"
      append_option --wallet "${wallet}"
      append_option --worker "${worker}"
      ;;
    alpha-miner)
      append_option --pool "${stratum_pool}"
      append_option --address "${wallet}"
      append_option --worker "${worker}"
      append_option --password "${password}"
      ;;
    wildrig)
      append_option --algo pearl
      append_option --url "${stratum_pool}"
      append_option --user "${wallet}"
      append_option --pass "${password}"
      append_option --worker "${worker}"
      ;;
    pearlfortune)
      append_option --proxy "${local_address}"
      append_option --address "${wallet}"
      append_option --worker "${worker}"
      append_arg -gpu
      ;;
    peakminer)
      append_option --url "${local_address}"
      append_option --user "${wallet}.${worker}"
      ;;
    srbminer)
      append_arg --disable-cpu
      append_option --algorithm pearlhash
      append_option --pool "${local_address}"
      append_option --wallet "${wallet}.${worker}"
      append_option --password "${password}"
      ;;
    krig-miner)
      # KRig validates the pool hostname and rejects a loopback URL. The
      # matching GOST listener is selected below; the host must remain the
      # official Kryptex endpoint so KRig accepts it and keeps its TLS SNI.
      append_option --url "stratum+ssl://${target_host}:${target_port}"
      append_option --user "${wallet}/${worker}"
      append_option --password "${password}"
      ;;
    *)
      echo "No argument builder is implemented for miner: ${miner}"
      exit 1
      ;;
  esac

  MINER_ARGS+=("${EXTRA_MINER_ARGS[@]}")
}

restart_if_installed() {
  local service="$1"

  if [[ "${RESTART_SERVICES}" != "1" ]]; then
    return
  fi
  if "${SYSTEMCTL_BIN}" cat "${service}" >/dev/null 2>&1; then
    "${SYSTEMCTL_BIN}" restart "${service}"
  fi
}

write_runtime_configs() {
  local target_host="$1"
  local target_port="$2"
  local miner_bin="$3"
  local miner_workdir="$4"
  local miner_ld_library_path="$5"
  local local_listen="$6"
  local client_tmp
  local miner_tmp
  local gost_bin
  local gost_user
  local gost_password
  local remote_relay
  local i

  gost_bin="$(read_env_value "${CLIENT_FILE}" GOST_BIN)"
  gost_user="$(read_env_value "${CLIENT_FILE}" GOST_USER)"
  gost_password="$(read_env_value "${CLIENT_FILE}" GOST_PASSWORD)"
  remote_relay="$(read_env_value "${CLIENT_FILE}" REMOTE_RELAY)"
  require_value "GOST_BIN in ${CLIENT_FILE}" "${gost_bin}"
  require_value "REMOTE_RELAY in ${CLIENT_FILE}" "${remote_relay}"

  client_tmp="$(mktemp)"
  miner_tmp="$(mktemp)"
  trap 'rm -f "${client_tmp:-}" "${miner_tmp:-}"' EXIT

  {
    echo "GOST_BIN=$(quote_env_value "${gost_bin}")"
    echo "GOST_USER=$(quote_env_value "${gost_user}")"
    echo "GOST_PASSWORD=$(quote_env_value "${gost_password}")"
    echo "LOCAL_FORWARD=$(quote_env_value "${local_listen}/${target_host}:${target_port}")"
    echo "REMOTE_RELAY=$(quote_env_value "${remote_relay}")"
  } >"${client_tmp}"

  {
    echo "ACTIVE_POOL=$(quote_env_value "${POOL}")"
    echo "ACTIVE_MINER=$(quote_env_value "${MINER}")"
    echo "MINER_BIN=$(quote_env_value "${miner_bin}")"
    echo "MINER_WORKDIR=$(quote_env_value "${miner_workdir}")"
    echo "MINER_POOL=$(quote_env_value "${local_listen}")"
    echo "MINER_LD_LIBRARY_PATH=$(quote_env_value "${miner_ld_library_path}")"
    echo "MINER_ARG_COUNT=${#MINER_ARGS[@]}"
    for ((i = 0; i < ${#MINER_ARGS[@]}; i++)); do
      echo "MINER_ARG_${i}=$(quote_env_value "${MINER_ARGS[$i]}")"
    done
  } >"${miner_tmp}"

  install -m 0644 "${client_tmp}" "${CLIENT_FILE}"
  install -m 0644 "${miner_tmp}" "${MINER_FILE}"
}

main() {
  local pool_prefix
  local miner_prefix
  local target_host
  local target_port
  local default_miner
  local supported_miners
  local wallet
  local password
  local worker
  local local_listen
  local local_address
  local miner_bin
  local miner_workdir
  local miner_ld_library_path
  local miner_target_host
  local miner_target_port

  parse_args "$@"
  require_root

  restore_missing_config "${PROFILES_FILE}" "${ROOT_DIR}/configs/profiles.env"
  restore_missing_config "${MINERS_FILE}" "${ROOT_DIR}/configs/miners.env"
  if [[ ! -f "${CLIENT_FILE}" ]]; then
    echo "Missing client config: ${CLIENT_FILE}" >&2
    echo "It contains relay credentials and will not be recreated automatically." >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  . "${PROFILES_FILE}"
  # shellcheck source=/dev/null
  . "${MINERS_FILE}"

  pool_prefix="$(config_prefix "${POOL}")"
  target_host="$(config_value "${pool_prefix}" TARGET_HOST)"
  target_port="$(config_value "${pool_prefix}" TARGET_PORT)"
  default_miner="$(config_value "${pool_prefix}" DEFAULT_MINER)"
  supported_miners="$(config_value "${pool_prefix}" SUPPORTED_MINERS)"
  wallet="$(config_value "${pool_prefix}" WALLET)"
  password="$(config_value "${pool_prefix}" PASSWORD)"

  if [[ -z "${target_host}" ]]; then
    echo "Unknown pool: ${POOL}"
    echo "Available pools:"
    list_pools | sed 's/^/  /'
    exit 1
  fi

  MINER="${MINER:-${default_miner}}"
  require_value "${pool_prefix}_DEFAULT_MINER in ${PROFILES_FILE}" "${MINER}"
  validate_identifier miner "${MINER}"
  if ! contains_word "${MINER_IDS:-}" "${MINER}"; then
    echo "Unknown miner: ${MINER}"
    echo "Available miners:"
    list_miners | sed 's/^/  /'
    exit 1
  fi
  if ! contains_word "${supported_miners}" "${MINER}"; then
    echo "Unsupported pool/miner combination: ${POOL}/${MINER}"
    echo "Supported miners for ${POOL}: ${supported_miners:-none}"
    exit 1
  fi

  miner_prefix="$(config_prefix "${MINER}")"
  miner_bin="$(config_value "${miner_prefix}" BIN)"
  miner_workdir="$(config_value "${miner_prefix}" WORKDIR)"
  miner_ld_library_path="$(config_value "${miner_prefix}" LD_LIBRARY_PATH)"
  miner_target_host="$(config_value "${pool_prefix}_${miner_prefix}" TARGET_HOST)"
  miner_target_port="$(config_value "${pool_prefix}_${miner_prefix}" TARGET_PORT)"
  local_listen="${LOCAL_LISTEN:-}"
  worker="${WORKER_NAME:-}"
  wallet="${wallet:-${WALLET_ADDRESS:-}}"
  password="${password:-x}"

  require_value "${pool_prefix}_TARGET_PORT in ${PROFILES_FILE}" "${target_port}"
  require_value "LOCAL_LISTEN in ${PROFILES_FILE}" "${local_listen}"
  require_value "WORKER_NAME in ${PROFILES_FILE}" "${worker}"
  require_value "${miner_prefix}_BIN in ${MINERS_FILE}" "${miner_bin}"
  require_value "${miner_prefix}_WORKDIR in ${MINERS_FILE}" "${miner_workdir}"

  if [[ "${MINER}" == "krig-miner" ]]; then
    restore_missing_profile_value "KRYPTEX_KRIG_MINER_TARGET_HOST"
    restore_missing_profile_value "KRYPTEX_KRIG_MINER_TARGET_PORT"
    # Reload the restored values before applying the miner-specific endpoint.
    # shellcheck source=/dev/null
    . "${PROFILES_FILE}"
    miner_target_host="$(config_value "${pool_prefix}_${miner_prefix}" TARGET_HOST)"
    miner_target_port="$(config_value "${pool_prefix}_${miner_prefix}" TARGET_PORT)"
  fi

  if [[ -n "${miner_target_host}" || -n "${miner_target_port}" ]]; then
    require_value "${pool_prefix}_${miner_prefix}_TARGET_HOST in ${PROFILES_FILE}" "${miner_target_host}"
    require_value "${pool_prefix}_${miner_prefix}_TARGET_PORT in ${PROFILES_FILE}" "${miner_target_port}"
    target_host="${miner_target_host}"
    target_port="${miner_target_port}"
  fi

  # KRig only accepts Kryptex's official TLS endpoint in --url. Bind GOST to
  # that endpoint's local port so a host-level DNS/NAT redirect can send the
  # official hostname to this listener without exposing the old :3333 URL to
  # the miner. Other miner profiles retain the shared LOCAL_LISTEN setting.
  if [[ "${MINER}" == "krig-miner" ]]; then
    local_listen="tcp://127.0.0.1:${target_port}"
  fi

  if [[ "${RESTART_SERVICES}" == "1" ]] && "${SYSTEMCTL_BIN}" cat pearl-miner.service >/dev/null 2>&1 && [[ ! -x "${miner_bin}" ]]; then
    echo "Miner binary is not installed or is not executable: ${miner_bin}"
    echo "Install it first: sudo ./scripts/install_pearl_miners.sh ${MINER}"
    exit 1
  fi

  local_address="${local_listen#*://}"
  if [[ -z "${local_address}" || "${local_address}" == "${local_listen}" ]]; then
    echo "Invalid LOCAL_LISTEN in ${PROFILES_FILE}: ${local_listen}"
    exit 1
  fi

  build_miner_args "${MINER}" "${POOL}" "${local_address}" "${target_host}" "${target_port}" "${wallet}" "${worker}" "${password}"
  write_runtime_configs "${target_host}" "${target_port}" "${miner_bin}" "${miner_workdir}" "${miner_ld_library_path}" "${local_listen}"

  if [[ "${MINER}" == "krig-miner" ]]; then
    manage_krig_redirect enable "${target_host}" "${target_port}"
  else
    manage_krig_redirect disable
  fi

  restart_if_installed gost-client.service
  restart_if_installed pearl-miner.service

  echo "Switched pool/miner: ${POOL}/${MINER}"
  echo "GOST target: ${target_host}:${target_port}"
  echo "Miner binary: ${miner_bin}"
  printf "Miner command:"
  printf " %q" "${miner_bin}" "${MINER_ARGS[@]}"
  echo
}

main "$@"
