#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${GOST_THREAD_CONFIG_DIR:-/etc/gost-thread}"
SYSTEMD_DIR="${GOST_THREAD_SYSTEMD_DIR:-/etc/systemd/system}"
LIBEXEC_DIR="${GOST_THREAD_LIBEXEC_DIR:-/usr/local/lib/gost-thread}"
SYSTEMCTL_BIN="${GOST_THREAD_SYSTEMCTL:-systemctl}"
MINERS_CONFIG="${CONFIG_DIR}/miners.env"
MINER_RUNTIME_CONFIG="${CONFIG_DIR}/miner.env"
PROFILES_CONFIG="${CONFIG_DIR}/profiles.env"
GITHUB_API_BASE="${GOST_THREAD_GITHUB_API_BASE:-https://api.github.com}"
UPDATE_GITHUB=0
INSTALL_ALL=0
REPLACE_CONFIG=0
SELECTED_MINERS=()
UPDATED_MINERS=()

usage() {
  cat <<EOF
Usage: sudo $0 [--all] [--update] [--replace-config] [miner ...]

With no miner names, all configured miners are installed. Existing miners are
left unchanged unless --update is supplied. --update applies only to miners
managed through GitHub Releases; fixed-URL miners remain pinned.

Existing configuration files are preserved by default. Use --replace-config
to replace miners.env and profiles.env with the repository templates. The
runtime-generated miner.env is never replaced by this option.

Examples:
  sudo $0
  sudo $0 tw-pearl-miner
  sudo $0 --update wildrig tw-pearl-miner
  sudo $0 --all --update
  sudo $0 --replace-config --all
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 && "${CONFIG_DIR}" == "/etc/gost-thread" ]]; then
    echo "Please run as root: sudo $0 [--all] [--update] [--replace-config] [miner ...]"
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

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --all)
        INSTALL_ALL=1
        shift
        ;;
      --update)
        UPDATE_GITHUB=1
        shift
        ;;
      --replace-config | --replace-configs)
        REPLACE_CONFIG=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --*)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        SELECTED_MINERS+=("$1")
        shift
        ;;
    esac
  done

  if [[ "${INSTALL_ALL}" == "1" && "${#SELECTED_MINERS[@]}" -gt 0 ]]; then
    echo "--all cannot be combined with explicit miner names."
    exit 1
  fi
}

detect_base_dir() {
  if [[ -n "${PEARL_MINERS_DIR:-}" ]]; then
    printf "%s" "${PEARL_MINERS_DIR}"
    return
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local sudo_home
    sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
    printf "%s" "${sudo_home:-/home/${SUDO_USER}}/programs/pearl_miners"
    return
  fi
  printf "%s" "${HOME}/programs/pearl_miners"
}

install_default_config() {
  local base_dir
  local tmp_file

  install -d -m 0755 "${CONFIG_DIR}"
  if [[ -f "${MINERS_CONFIG}" && "${REPLACE_CONFIG}" != "1" ]]; then
    return
  fi

  base_dir="$(detect_base_dir)"
  tmp_file="$(mktemp)"
  awk -v base_dir="${base_dir}" '
    /^PEARL_MINERS_DIR=/ {
      print "PEARL_MINERS_DIR=" base_dir
      next
    }
    { print }
  ' "${ROOT_DIR}/configs/miners.env" >"${tmp_file}"
  install -m 0644 "${tmp_file}" "${MINERS_CONFIG}"
  rm -f "${tmp_file}"
}

install_default_profiles_config() {
  if [[ -f "${PROFILES_CONFIG}" && "${REPLACE_CONFIG}" != "1" ]]; then
    return
  fi

  install -m 0644 "${ROOT_DIR}/configs/profiles.env" "${PROFILES_CONFIG}"
}

install_default_runtime_config() {
  local tmp_file

  # --replace-config only refreshes source configuration. miner.env is runtime
  # state and must not be created or overwritten from the static template.
  if [[ "${REPLACE_CONFIG}" == "1" || -f "${MINER_RUNTIME_CONFIG}" ]]; then
    return
  fi
  tmp_file="$(mktemp)"
  sed "s|/home/youruser/programs/pearl_miners|${PEARL_MINERS_DIR}|g" \
    "${ROOT_DIR}/configs/miner.env" >"${tmp_file}"
  install -m 0644 "${tmp_file}" "${MINER_RUNTIME_CONFIG}"
  rm -f "${tmp_file}"
}

config_prefix() {
  printf "%s" "$1" | tr "[:lower:]-" "[:upper:]_"
}

miner_value() {
  local prefix="$1"
  local suffix="$2"
  local key="${prefix}_${suffix}"

  printf "%s" "${!key:-}"
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

validate_selection() {
  local miner

  if [[ "${INSTALL_ALL}" == "1" || "${#SELECTED_MINERS[@]}" -eq 0 ]]; then
    read -r -a SELECTED_MINERS <<<"${MINER_IDS:-}"
  fi
  if [[ "${#SELECTED_MINERS[@]}" -eq 0 ]]; then
    echo "MINER_IDS is empty in ${MINERS_CONFIG}."
    exit 1
  fi

  for miner in "${SELECTED_MINERS[@]}"; do
    if [[ ! "${miner}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "Invalid miner name: ${miner}"
      exit 1
    fi
    if ! contains_word "${MINER_IDS:-}" "${miner}"; then
      echo "Unknown miner: ${miner}"
      echo "Available miners: ${MINER_IDS:-none}"
      exit 1
    fi
  done
}

validate_install_paths() {
  local miner_name="$1"
  local workdir="$2"
  local miner_bin="$3"

  if [[ -z "${PEARL_MINERS_DIR:-}" || "${PEARL_MINERS_DIR}" != /* || "${PEARL_MINERS_DIR}" == "/" ]]; then
    echo "PEARL_MINERS_DIR must be an absolute, non-root directory: ${PEARL_MINERS_DIR:-not set}"
    return 1
  fi
  if [[ "${PEARL_MINERS_DIR}" == *"/../"* || "${PEARL_MINERS_DIR}" == */.. ]]; then
    echo "PEARL_MINERS_DIR must not contain parent-directory traversal: ${PEARL_MINERS_DIR}"
    return 1
  fi
  if [[ "${workdir}" != "${PEARL_MINERS_DIR}/"* ]]; then
    echo "${miner_name} workdir must be inside PEARL_MINERS_DIR: ${workdir}"
    return 1
  fi
  if [[ "${miner_bin}" != "${workdir}/"* ]]; then
    echo "${miner_name} binary must be inside its workdir: ${miner_bin}"
    return 1
  fi
  if [[ "${workdir}" == *"/../"* || "${workdir}" == */.. || "${miner_bin}" == *"/../"* || "${miner_bin}" == */.. ]]; then
    echo "${miner_name} paths must not contain parent-directory traversal."
    return 1
  fi
}

download_file() {
  local url="$1"
  local output_file="$2"
  local label="$3"
  local attempt

  for attempt in 1 2 3; do
    echo "Downloading ${label} (${attempt}/3): ${url}"
    if curl -fsSL --connect-timeout 20 --retry 2 "${url}" -o "${output_file}" && [[ -s "${output_file}" ]]; then
      return 0
    fi
    rm -f "${output_file}"
  done

  echo "Failed to download ${label}: ${url}"
  return 1
}

github_api_get() {
  local url="$1"
  local output_file="$2"
  local curl_args=(-fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl "${curl_args[@]}" "${url}" -o "${output_file}"
}

resolve_latest_github_release() {
  local repo="$1"
  local asset_regex="$2"
  local json_file="$3"
  local match_count

  echo "Checking latest stable GitHub Release: ${repo}"
  if ! github_api_get "${GITHUB_API_BASE}/repos/${repo}/releases/latest" "${json_file}"; then
    echo "Unable to query the latest GitHub Release for ${repo}."
    return 1
  fi

  GITHUB_RELEASE_TAG="$(jq -er '.tag_name' "${json_file}")" || {
    echo "GitHub response for ${repo} does not contain tag_name."
    return 1
  }
  match_count="$(jq --arg regex "${asset_regex}" '[.assets[] | select(.name | test($regex))] | length' "${json_file}")"
  if [[ "${match_count}" != "1" ]]; then
    echo "Expected exactly one Linux asset for ${repo}, but regex matched ${match_count}: ${asset_regex}"
    echo "Release assets:"
    jq -r '.assets[].name | "  " + .' "${json_file}"
    return 1
  fi

  GITHUB_ASSET_NAME="$(jq -r --arg regex "${asset_regex}" '.assets[] | select(.name | test($regex)) | .name' "${json_file}")"
  GITHUB_ASSET_URL="$(jq -r --arg regex "${asset_regex}" '.assets[] | select(.name | test($regex)) | .browser_download_url' "${json_file}")"
  GITHUB_ASSET_DIGEST="$(jq -r --arg regex "${asset_regex}" '.assets[] | select(.name | test($regex)) | (.digest // "")' "${json_file}")"
}

read_installed_release_value() {
  local workdir="$1"
  local key="$2"
  local release_file="${workdir}/.gost-thread-release.env"

  if [[ ! -f "${release_file}" ]]; then
    return
  fi
  sed -n "s/^${key}=//p" "${release_file}" | tail -n 1
}

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    echo "Neither sha256sum nor shasum is available." >&2
    return 1
  fi
}

verify_digest() {
  local file="$1"
  local expected_digest="$2"
  local expected_hash
  local actual_hash

  if [[ -z "${expected_digest}" ]]; then
    echo "Warning: upstream did not publish a digest for $(basename "${file}")."
    return
  fi
  if [[ "${expected_digest}" != sha256:* ]]; then
    echo "Unsupported asset digest: ${expected_digest}"
    return 1
  fi

  expected_hash="${expected_digest#sha256:}"
  actual_hash="$(sha256_file "${file}")"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    echo "SHA-256 mismatch for $(basename "${file}")."
    echo "  expected: ${expected_hash}"
    echo "  actual:   ${actual_hash}"
    return 1
  fi
  echo "Verified SHA-256: ${actual_hash}"
}

write_release_metadata() {
  local directory="$1"
  local source="$2"
  local tag="$3"
  local asset_name="$4"
  local digest="$5"

  {
    printf "SOURCE='%s'\n" "${source//\'/\'\\\'\'}"
    printf "RELEASE_TAG='%s'\n" "${tag//\'/\'\\\'\'}"
    printf "ASSET_NAME='%s'\n" "${asset_name//\'/\'\\\'\'}"
    printf "ASSET_DIGEST='%s'\n" "${digest//\'/\'\\\'\'}"
  } >"${directory}/.gost-thread-release.env"
  chmod 0644 "${directory}/.gost-thread-release.env"
}

install_binary_payload() {
  local miner_name="$1"
  local url="$2"
  local miner_bin="$3"
  local workdir="$4"
  local source="$5"
  local tag="$6"
  local asset_name="$7"
  local digest="$8"
  local tmp_file
  local staged_bin

  install -d -m 0755 "${workdir}"
  tmp_file="$(mktemp)"
  staged_bin="${miner_bin}.new.$$"
  if ! download_file "${url}" "${tmp_file}" "${miner_name}" || ! verify_digest "${tmp_file}" "${digest}"; then
    rm -f "${tmp_file}" "${staged_bin}"
    return 1
  fi

  install -m 0755 "${tmp_file}" "${staged_bin}"
  mv -f "${staged_bin}" "${miner_bin}"
  write_release_metadata "${workdir}" "${source}" "${tag}" "${asset_name}" "${digest}"
  rm -f "${tmp_file}"
}

install_archive_payload() {
  local miner_name="$1"
  local url="$2"
  local miner_bin="$3"
  local workdir="$4"
  local binary_name="$5"
  local source="$6"
  local tag="$7"
  local asset_name="$8"
  local digest="$9"
  local tmp_file
  local extract_dir
  local extracted_bin
  local extracted_root
  local parent_dir
  local staged_dir
  local backup_dir

  require_command tar
  parent_dir="$(dirname "${workdir}")"
  install -d -m 0755 "${parent_dir}"
  tmp_file="$(mktemp)"
  extract_dir="$(mktemp -d)"
  staged_dir="$(mktemp -d "${parent_dir}/.$(basename "${workdir}").new.XXXXXX")"
  backup_dir="${workdir}.backup.$$"

  if ! download_file "${url}" "${tmp_file}" "${miner_name}" || ! verify_digest "${tmp_file}" "${digest}"; then
    rm -rf "${extract_dir}" "${staged_dir}"
    rm -f "${tmp_file}"
    return 1
  fi
  if ! tar -xzf "${tmp_file}" -C "${extract_dir}"; then
    echo "Downloaded asset is not a valid gzip tar archive: ${asset_name}"
    rm -rf "${extract_dir}" "${staged_dir}"
    rm -f "${tmp_file}"
    return 1
  fi

  extracted_bin="$(find "${extract_dir}" -type f -name "${binary_name}" -print -quit)"
  if [[ -z "${extracted_bin}" ]]; then
    echo "Could not find ${binary_name} inside ${asset_name}."
    rm -rf "${extract_dir}" "${staged_dir}"
    rm -f "${tmp_file}"
    return 1
  fi
  extracted_root="$(dirname "${extracted_bin}")"
  cp -R "${extracted_root}/." "${staged_dir}/"
  chmod +x "${staged_dir}/$(basename "${miner_bin}")"
  write_release_metadata "${staged_dir}" "${source}" "${tag}" "${asset_name}" "${digest}"

  if [[ -e "${workdir}" ]]; then
    mv "${workdir}" "${backup_dir}"
  fi
  if ! mv "${staged_dir}" "${workdir}"; then
    echo "Failed to activate ${miner_name}; restoring the previous installation."
    if [[ -e "${backup_dir}" ]]; then
      mv "${backup_dir}" "${workdir}"
    fi
    rm -rf "${extract_dir}" "${staged_dir}"
    rm -f "${tmp_file}"
    return 1
  fi

  rm -rf "${backup_dir}" "${extract_dir}"
  rm -f "${tmp_file}"
}

install_payload() {
  local miner_name="$1"
  local url="$2"
  local install_type="$3"
  local miner_bin="$4"
  local workdir="$5"
  local binary_name="$6"
  local source="$7"
  local tag="$8"
  local asset_name="$9"
  local digest="${10}"

  case "${install_type}" in
    binary)
      install_binary_payload "${miner_name}" "${url}" "${miner_bin}" "${workdir}" "${source}" "${tag}" "${asset_name}" "${digest}"
      ;;
    archive-dir)
      install_archive_payload "${miner_name}" "${url}" "${miner_bin}" "${workdir}" "${binary_name}" "${source}" "${tag}" "${asset_name}" "${digest}"
      ;;
    *)
      echo "Unsupported install type for ${miner_name}: ${install_type}"
      return 1
      ;;
  esac
}

install_one_miner() {
  local miner_name="$1"
  local prefix
  local source
  local install_type
  local miner_bin
  local workdir
  local binary_name
  local download_url
  local github_repo
  local asset_regex
  local installed_tag
  local installed_asset
  local release_json
  local required

  prefix="$(config_prefix "${miner_name}")"
  source="$(miner_value "${prefix}" SOURCE)"
  install_type="$(miner_value "${prefix}" INSTALL_TYPE)"
  miner_bin="$(miner_value "${prefix}" BIN)"
  workdir="$(miner_value "${prefix}" WORKDIR)"
  binary_name="$(miner_value "${prefix}" BINARY_NAME)"

  for required in source install_type miner_bin workdir binary_name; do
    if [[ -z "${!required}" ]]; then
      echo "Missing ${prefix}_$(printf '%s' "${required}" | tr '[:lower:]' '[:upper:]') in ${MINERS_CONFIG}."
      return 1
    fi
  done
  validate_install_paths "${miner_name}" "${workdir}" "${miner_bin}" || return 1

  case "${source}" in
    fixed)
      if [[ -x "${miner_bin}" ]]; then
        if [[ "${UPDATE_GITHUB}" == "1" ]]; then
          echo "${miner_name} uses a fixed URL; keeping the installed version: ${miner_bin}"
        else
          echo "${miner_name} already installed: ${miner_bin}"
        fi
        return
      fi
      download_url="$(miner_value "${prefix}" DOWNLOAD_URL)"
      if [[ -z "${download_url}" ]]; then
        echo "Missing ${prefix}_DOWNLOAD_URL in ${MINERS_CONFIG}."
        return 1
      fi
      echo "Installing fixed version of ${miner_name}."
      install_payload "${miner_name}" "${download_url}" "${install_type}" "${miner_bin}" "${workdir}" "${binary_name}" fixed fixed "$(basename "${download_url}")" ""
      ;;
    github)
      if [[ -x "${miner_bin}" && "${UPDATE_GITHUB}" != "1" ]]; then
        echo "${miner_name} already installed: ${miner_bin}"
        return
      fi

      github_repo="$(miner_value "${prefix}" GITHUB_REPO)"
      asset_regex="$(miner_value "${prefix}" ASSET_REGEX)"
      if [[ -z "${github_repo}" || -z "${asset_regex}" ]]; then
        echo "Missing ${prefix}_GITHUB_REPO or ${prefix}_ASSET_REGEX in ${MINERS_CONFIG}."
        return 1
      fi
      require_command jq
      release_json="$(mktemp)"
      if ! resolve_latest_github_release "${github_repo}" "${asset_regex}" "${release_json}"; then
        rm -f "${release_json}"
        return 1
      fi
      rm -f "${release_json}"

      installed_tag="$(read_installed_release_value "${workdir}" RELEASE_TAG)"
      installed_tag="${installed_tag#\'}"
      installed_tag="${installed_tag%\'}"
      installed_asset="$(read_installed_release_value "${workdir}" ASSET_NAME)"
      installed_asset="${installed_asset#\'}"
      installed_asset="${installed_asset%\'}"
      if [[ -x "${miner_bin}" && "${installed_tag}" == "${GITHUB_RELEASE_TAG}" && "${installed_asset}" == "${GITHUB_ASSET_NAME}" ]]; then
        echo "${miner_name} is already at the latest Release: ${GITHUB_RELEASE_TAG} (${GITHUB_ASSET_NAME})"
        return
      fi

      if [[ -x "${miner_bin}" && -z "${installed_tag}" ]]; then
        echo "${miner_name} has no version metadata; replacing it with latest Release ${GITHUB_RELEASE_TAG}."
      else
        echo "Installing ${miner_name} Release ${GITHUB_RELEASE_TAG} (${GITHUB_ASSET_NAME})."
      fi
      install_payload "${miner_name}" "${GITHUB_ASSET_URL}" "${install_type}" "${miner_bin}" "${workdir}" "${binary_name}" github "${GITHUB_RELEASE_TAG}" "${GITHUB_ASSET_NAME}" "${GITHUB_ASSET_DIGEST}"
      UPDATED_MINERS+=("${miner_name}")
      ;;
    *)
      echo "Unsupported source for ${miner_name}: ${source}"
      return 1
      ;;
  esac
}

install_services() {
  install -d -m 0755 "${LIBEXEC_DIR}"
  install -d -m 0755 "${SYSTEMD_DIR}"
  install -m 0755 "${ROOT_DIR}/scripts/wait_for_pearl_miner_pool.sh" "${LIBEXEC_DIR}/wait-for-pearl-miner-pool"
  install -m 0755 "${ROOT_DIR}/scripts/run_pearl_miner.sh" "${LIBEXEC_DIR}/run-pearl-miner"
  install -m 0644 "${ROOT_DIR}/systemd/pearl-miner.service" "${SYSTEMD_DIR}/pearl-miner.service"

  if command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1; then
    "${SYSTEMCTL_BIN}" daemon-reload
  fi
}

restart_active_miner_if_updated() {
  local active_miner
  local updated

  if [[ "${#UPDATED_MINERS[@]}" -eq 0 || ! -f "${MINER_RUNTIME_CONFIG}" ]]; then
    return
  fi
  active_miner="$(sed -n 's/^ACTIVE_MINER=//p' "${MINER_RUNTIME_CONFIG}" | tail -n 1)"
  active_miner="${active_miner#\'}"
  active_miner="${active_miner%\'}"
  for updated in "${UPDATED_MINERS[@]}"; do
    if [[ "${updated}" == "${active_miner}" ]] && "${SYSTEMCTL_BIN}" is-active --quiet pearl-miner.service 2>/dev/null; then
      echo "Restarting pearl-miner.service to activate ${updated}."
      "${SYSTEMCTL_BIN}" restart pearl-miner.service
      return
    fi
  done
}

main() {
  local miner
  local failures=0

  parse_args "$@"
  require_root
  require_command curl
  install_default_config
  install_default_profiles_config

  # shellcheck source=/dev/null
  . "${MINERS_CONFIG}"
  validate_selection
  install_default_runtime_config

  for miner in "${SELECTED_MINERS[@]}"; do
    if ! install_one_miner "${miner}"; then
      echo "Installation failed for ${miner}."
      failures=$((failures + 1))
    fi
  done

  install_services
  restart_active_miner_if_updated

  if ((failures > 0)); then
    echo "${failures} miner installation(s) failed. Existing installations were preserved."
    exit 1
  fi

  echo "Miner installation completed."
  echo "Installed configuration: ${MINERS_CONFIG}, ${PROFILES_CONFIG}, ${MINER_RUNTIME_CONFIG}"
  echo "Select a pool/miner explicitly:"
  echo "  sudo ./scripts/start_pearl_miners.sh --pool luckypool --miner lpminer"
  echo "  sudo ./scripts/start_pearl_miners.sh --pool luckypool --miner tw-pearl-miner"
}

main "$@"
