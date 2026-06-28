#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${GOST_THREAD_REPO:-https://github.com/zwglass/gost_thread}"
BRANCH="${GOST_THREAD_BRANCH:-master}"
INSTALL_DIR="${GOST_THREAD_INSTALL_DIR:-/opt/gost_thread}"
TMP_DIR="$(mktemp -d)"
PROMPT_VALUE=""

cleanup() {
  rm -rf "${TMP_DIR}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root:"
    echo "  curl -fsSL ${REPO_URL}/raw/${BRANCH}/install.sh | sudo bash"
    exit 1
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}"
    exit 1
  fi
}

require_tty() {
  if [[ ! -r /dev/tty ]]; then
    echo "Interactive install requires a TTY."
    echo "Run this command from a normal SSH terminal, or clone the repo and run install.sh locally."
    exit 1
  fi
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local env_name="${3:-}"
  local value

  if [[ -n "${env_name}" && -n "${!env_name:-}" ]]; then
    PROMPT_VALUE="${!env_name}"
    return
  fi

  require_tty
  read -r -p "${prompt} [${default_value}]: " value </dev/tty
  PROMPT_VALUE="${value:-${default_value}}"
}

prompt_required() {
  local prompt="$1"
  local env_name="${2:-}"
  local value

  if [[ -n "${env_name}" && -n "${!env_name:-}" ]]; then
    PROMPT_VALUE="${!env_name}"
    return
  fi

  while true; do
    require_tty
    read -r -p "${prompt}: " value </dev/tty
    if [[ -n "${value}" ]]; then
      PROMPT_VALUE="${value}"
      return
    fi

    echo "This value is required." >/dev/tty
  done
}

prompt_secret() {
  local prompt="$1"
  local env_name="${2:-}"
  local value

  if [[ -n "${env_name}" && -n "${!env_name:-}" ]]; then
    PROMPT_VALUE="${!env_name}"
    return
  fi

  while true; do
    require_tty
    read -r -s -p "${prompt}: " value </dev/tty
    echo >/dev/tty

    if [[ -n "${value}" ]]; then
      PROMPT_VALUE="${value}"
      return
    fi

    echo "This value is required." >/dev/tty
  done
}

validate_credential() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "${name} can only contain letters, numbers, dot, underscore, and hyphen."
    exit 1
  fi
}

install_gost_if_missing() {
  if command -v gost >/dev/null 2>&1; then
    return
  fi

  echo "gost is not installed. Installing gost first..."
  bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install
}

download_project() {
  local archive="${TMP_DIR}/gost_thread.tar.gz"
  local extracted="${TMP_DIR}/src"

  mkdir -p "${extracted}"
  curl -fsSL "${REPO_URL}/archive/refs/heads/${BRANCH}.tar.gz" -o "${archive}"
  tar -xzf "${archive}" -C "${extracted}" --strip-components=1

  install -d -m 0755 "${INSTALL_DIR}"
  cp -R "${extracted}/." "${INSTALL_DIR}/"
}

configure_project() {
  local role="$1"
  local gost_bin
  local server_ip
  local server_port
  local local_port
  local target_host
  local target_port
  local gost_user
  local gost_password

  gost_bin="$(command -v gost)"
  prompt_with_default "Server relay port" "8443" "GOST_SERVER_PORT"
  server_port="${PROMPT_VALUE}"
  prompt_with_default "GOST username" "gostuser" "GOST_AUTH_USER"
  gost_user="${PROMPT_VALUE}"
  prompt_secret "GOST password" "GOST_AUTH_PASSWORD"
  gost_password="${PROMPT_VALUE}"
  validate_credential "GOST username" "${gost_user}"
  validate_credential "GOST password" "${gost_password}"

  sed -i "s|^GOST_BIN=.*|GOST_BIN=${gost_bin}|" "${INSTALL_DIR}/configs/server.env"
  sed -i "s|^GOST_USER=.*|GOST_USER=${gost_user}|" "${INSTALL_DIR}/configs/server.env"
  sed -i "s|^GOST_PASSWORD=.*|GOST_PASSWORD=${gost_password}|" "${INSTALL_DIR}/configs/server.env"
  sed -i "s|^SERVER_LISTEN=.*|SERVER_LISTEN=relay+tls://${gost_user}:${gost_password}@0.0.0.0:${server_port}|" "${INSTALL_DIR}/configs/server.env"

  sed -i "s|^GOST_BIN=.*|GOST_BIN=${gost_bin}|" "${INSTALL_DIR}/configs/client.env"
  sed -i "s|^GOST_USER=.*|GOST_USER=${gost_user}|" "${INSTALL_DIR}/configs/client.env"
  sed -i "s|^GOST_PASSWORD=.*|GOST_PASSWORD=${gost_password}|" "${INSTALL_DIR}/configs/client.env"

  if [[ "${role}" == "client" || "${role}" == "both" ]]; then
    prompt_required "Server public IP or domain" "GOST_SERVER_HOST"
    server_ip="${PROMPT_VALUE}"
    prompt_with_default "Local listen port" "3333" "GOST_LOCAL_PORT"
    local_port="${PROMPT_VALUE}"
    prompt_with_default "Target host" "pearl-ca1.luckypool.io" "GOST_TARGET_HOST"
    target_host="${PROMPT_VALUE}"
    prompt_with_default "Target port" "3360" "GOST_TARGET_PORT"
    target_port="${PROMPT_VALUE}"

    sed -i "s|^LOCAL_FORWARD=.*|LOCAL_FORWARD=tcp://127.0.0.1:${local_port}/${target_host}:${target_port}|" "${INSTALL_DIR}/configs/client.env"
    sed -i "s|^REMOTE_RELAY=.*|REMOTE_RELAY=relay+tls://${gost_user}:${gost_password}@${server_ip}:${server_port}|" "${INSTALL_DIR}/configs/client.env"
    sed -i "s|^LOCAL_LISTEN=.*|LOCAL_LISTEN=tcp://127.0.0.1:${local_port}|" "${INSTALL_DIR}/configs/profiles.env"
    sed -i "s|^LUCKYPOOL_TARGET_HOST=.*|LUCKYPOOL_TARGET_HOST=${target_host}|" "${INSTALL_DIR}/configs/profiles.env"
    sed -i "s|^LUCKYPOOL_TARGET_PORT=.*|LUCKYPOOL_TARGET_PORT=${target_port}|" "${INSTALL_DIR}/configs/profiles.env"
    sed -i "s|stratum+tcp://127.0.0.1:3333|stratum+tcp://127.0.0.1:${local_port}|g" "${INSTALL_DIR}/configs/profiles.env"
    sed -i "s|stratum+tcp://127.0.0.1:3333|stratum+tcp://127.0.0.1:${local_port}|g" "${INSTALL_DIR}/configs/miner.env"
  fi
}

start_services() {
  local role="$1"

  case "${role}" in
    server)
      systemctl restart gost-server.service
      ;;
    client)
      systemctl restart gost-client.service
      ;;
    both)
      systemctl restart gost-server.service
      systemctl restart gost-client.service
      ;;
  esac
}

main() {
  local role="${1:-}"

  trap cleanup EXIT

  require_root
  require_command curl
  require_command tar
  require_command sed
  require_command systemctl

  if [[ -z "${role}" ]]; then
    echo "Choose install role:" >/dev/tty
    echo "  1) server" >/dev/tty
    echo "  2) client" >/dev/tty
    echo "  3) both" >/dev/tty
    read -r -p "Role [client]: " role </dev/tty

    case "${role:-client}" in
      1 | server) role="server" ;;
      2 | client) role="client" ;;
      3 | both) role="both" ;;
      *)
        echo "Invalid role: ${role}"
        exit 1
        ;;
    esac
  fi

  case "${role}" in
    server | client | both) ;;
    *)
      echo "Usage: $0 [server|client|both]"
      exit 1
      ;;
  esac

  install_gost_if_missing
  download_project
  configure_project "${role}"

  "${INSTALL_DIR}/scripts/install_gost.sh" --role "${role}"
  start_services "${role}"

  echo
  echo "Installed gost_thread to: ${INSTALL_DIR}"
  echo "Role: ${role}"
  echo "Service started."
  echo
  echo "Status:"
  echo "  systemctl status gost-server --no-pager"
  echo "  systemctl status gost-client --no-pager"
}

main "$@"
