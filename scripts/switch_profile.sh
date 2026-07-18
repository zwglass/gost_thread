#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
PROFILES_FILE="${CONFIG_DIR}/profiles.env"
MINERS_FILE="${CONFIG_DIR}/miners.env"
CLIENT_FILE="${CONFIG_DIR}/client.env"
MINER_FILE="${CONFIG_DIR}/miner.env"
RESTART_SERVICES="${GOST_THREAD_RESTART_SERVICES:-1}"
SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
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

read_env_value() {
  local file="$1"
  local key="$2"

  sed -n "s/^${key}=//p" "${file}" | tail -n 1
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
  local miner="$1"
  local pool="$2"
  local local_address="$3"
  local wallet="$4"
  local worker="$5"
  local password="$6"
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
    tw-pearl-miner)
      append_option --pool "${local_address}"
      append_option --wallet "${wallet}"
      append_option --worker "${worker}"
      if [[ "${pool}" == "pearlfortune" ]]; then
        append_arg --pf
      elif [[ "${pool}" == "alphapool" ]]; then
        append_option --password "${password}"
      fi
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

  parse_args "$@"
  require_root

  for file in "${PROFILES_FILE}" "${MINERS_FILE}" "${CLIENT_FILE}"; do
    if [[ ! -f "${file}" ]]; then
      echo "Missing config: ${file}"
      exit 1
    fi
  done

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
  local_listen="${LOCAL_LISTEN:-}"
  worker="${WORKER_NAME:-}"
  wallet="${wallet:-${WALLET_ADDRESS:-}}"
  password="${password:-x}"

  require_value "${pool_prefix}_TARGET_PORT in ${PROFILES_FILE}" "${target_port}"
  require_value "LOCAL_LISTEN in ${PROFILES_FILE}" "${local_listen}"
  require_value "WORKER_NAME in ${PROFILES_FILE}" "${worker}"
  require_value "wallet for ${POOL}" "${wallet}"
  require_value "${miner_prefix}_BIN in ${MINERS_FILE}" "${miner_bin}"
  require_value "${miner_prefix}_WORKDIR in ${MINERS_FILE}" "${miner_workdir}"

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

  build_miner_args "${MINER}" "${POOL}" "${local_address}" "${wallet}" "${worker}" "${password}"
  write_runtime_configs "${target_host}" "${target_port}" "${miner_bin}" "${miner_workdir}" "${miner_ld_library_path}" "${local_listen}"

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
