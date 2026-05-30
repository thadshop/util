#!/usr/bin/env bash
# Executable: run from util clone; do not `source` this file.
#
# Install helper: check deps, create tokmint venv, configure SECCONFIG_DIR.
#   ./install/install.sh check
#   ./install/install.sh venv
#   ./install/install.sh configure
#   ./install/install.sh install
#   ./install/install.sh help

set -e

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_install_dir="$(dirname "${_script_path}")"
UTIL_ROOT="$(dirname "${_install_dir}")"
PYTHON="python3.12"
VENV_DIR="${UTIL_ROOT}/tokmint/.venv"
VENV_PY="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
MERGE_PY="${_install_dir}/merge_sops_yaml.py"

_print_help() {
    local me="${0}"
    printf '%s\n' "util installer — Linux (Ubuntu/Debian) only"
    printf '%s\n' ""
    printf '%s\n' "usage: ${me} <command>"
    printf '%s\n' "       ${me}              # same as: ${me} help"
    printf '%s\n' ""
    printf '%s\n' "commands:"
    printf '%s\n' "  check       Verify apt packages, python3.12, pip, sops, age, …"
    printf '%s\n' "  venv        Create tokmint/.venv and pip install packages"
    printf '%s\n' \
      "  configure   Prompt for SECCONFIG_DIR; create tokmint/, .sops.yaml,"
    printf '%s\n' "              and env.bash (requires venv)"
    printf '%s\n' "  install     check, then venv, then configure"
    printf '%s\n' "  help        Show this message (-h, --help)"
    printf '%s\n' ""
    printf '%s\n' "typical first run (from util clone):"
    printf '%s\n' "  ./install/install.sh install"
    printf '%s\n' ""
    printf '%s\n' "defaults and paths (install):"
    printf '%s\n' "  python3.12          interpreter for check and venv"
    printf '%s\n' "  tokmint/.venv/      Python venv (git-ignored)"
    printf '%s\n' \
      "  ~/secconfig         default SECCONFIG_DIR if unset at configure"
    printf '%s\n' \
      "  configure creates:  \$SECCONFIG_DIR/.sops.yaml, .../tokmint/, env.bash"
    printf '%s\n' "                      (dirs 700, files 600)"
    printf '%s\n' ""
    printf '%s\n' "environment variables — before install:"
    printf '%s\n' \
      "  (none required)     check and venv ignore util env vars"
    printf '%s\n' \
      "  SECCONFIG_DIR       optional; configure prompt default ~/secconfig;"
    printf '%s\n' \
      "                      relative paths use \$PWD. Not read during install:"
    printf '%s\n' "                      TOKMINT_*, KEYRING_*"
    printf '%s\n' ""
    printf '%s\n' "environment variables — after configure (runtime):"
    printf '%s\n' "  required:"
    printf '%s\n' \
      "    SECCONFIG_DIR     root for .sops.yaml and encrypted YAML (set in"
    printf '%s\n' "                      env.bash)"
    printf '%s\n' "  optional (defaults):"
    printf '%s\n' \
      "    TOKMINT_SECCONFIG_SUBDIR   tokmint  (profiles: .../tokmint/*.enc.yaml)"
    printf '%s\n' \
      "    KEYRING_DATA_DIR           ~/.local/share/util/keyring"
    printf '%s\n' "    KEYRING_OPENSSL_BIN        /usr/bin/openssl"
    printf '%s\n' \
      "    KEYRING_DEK_WRAP_RECIPE_DIR  keyring/dek-wrap-recipes in clone"
    printf '%s\n' "    TOKMINT_PORT               9876"
    printf '%s\n' "    TOKMINT_LOG_LEVEL          INFO"
    printf '%s\n' \
      "    TOKMINT_UNSAFE_LOGGING     unset (do not enable in production)"
    printf '%s\n' "    TOKMINT_JSONL_FMT_FLUSH_MS 1000"
    printf '%s\n' ""
    printf '%s\n' "after configure:"
    printf '%s\n' "  . \"\${SECCONFIG_DIR}/env.bash\""
    printf '%s\n' "  source ${UTIL_ROOT}/keyring/init.bash   # passphrase; not in env.bash"
    printf '%s\n' "  ${VENV_PY} -m tokmint"
    printf '%s\n' ""
    printf '%s\n' "more detail: ${UTIL_ROOT}/install/README.md"
    printf '%s\n' "             ${UTIL_ROOT}/CLAUDE.md (environment variables table)"
}

_usage_unknown() {
    _print_help >&2
}

_die() {
    printf '%s\n' "install.sh: ${1}" >&2
    exit 1
}

_need_cmd() {
    if ! command -v "${1}" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

_check_apt_pkg() {
    local pkg="${1}"
    if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null \
        | grep -q 'install ok installed'; then
        return 1
    fi
    return 0
}

_check_fail() {
    printf '%s\n' 'install.sh: missing prerequisites:' >&2
    while (($# > 0)); do
        printf '%s\n' "${1}" >&2
        shift
    done
    exit 1
}

_cmd_check() {
    local err=()

    if [[ "$(uname -s)" != "Linux" ]]; then
        _die "Linux only"
    fi

    if ! _need_cmd dpkg-query; then
        _die "check requires Debian/Ubuntu (dpkg-query not found)"
    fi

    if ! _check_apt_pkg keyutils; then
        err+=("  - keyutils (apt)" "    sudo apt install keyutils")
    fi
    if ! _check_apt_pkg age; then
        err+=("  - age (apt)" "    sudo apt install age")
    fi
    if ! _check_apt_pkg openssl; then
        err+=("  - openssl (apt)" "    sudo apt install openssl")
    fi
    if ! _check_apt_pkg python3.12; then
        err+=("  - python3.12 (apt)" "    sudo apt install python3.12")
    fi
    if ! _check_apt_pkg python3.12-venv; then
        if ! _need_cmd "${PYTHON}" \
            || ! "${PYTHON}" -m venv --help >/dev/null 2>&1; then
            err+=(
              "  - python3.12-venv (apt) or venv module"
              "    sudo apt install python3.12-venv"
            )
        fi
    fi

    if ! _need_cmd "${PYTHON}"; then
        err+=(
          "  - ${PYTHON} on PATH"
          "    sudo apt install python3.12"
        )
    elif ! "${PYTHON}" -c \
        'import sys; exit(0 if sys.version_info >= (3, 12) else 1)' \
        2>/dev/null; then
        _die "${PYTHON} is not 3.12 or newer"
    fi

    if _need_cmd "${PYTHON}"; then
        if ! "${PYTHON}" -m pip --version >/dev/null 2>&1; then
            err+=(
              "  - pip for ${PYTHON}"
              "    sudo apt install python3-pip"
            )
        fi
    fi

    if ! _need_cmd keyctl; then
        err+=("  - keyctl" "    sudo apt install keyutils")
    fi
    if ! _need_cmd age; then
        err+=("  - age" "    sudo apt install age")
    fi
    if ! _need_cmd age-keygen; then
        err+=("  - age-keygen" "    sudo apt install age")
    fi
    if ! _need_cmd openssl; then
        err+=("  - openssl" "    sudo apt install openssl")
    elif [[ ! -x /usr/bin/openssl ]]; then
        err+=(
          "  - openssl at /usr/bin/openssl"
          "    sudo apt install openssl  # or KEYRING_OPENSSL_BIN"
        )
    fi

    if ! _need_cmd sops; then
        err+=(
          "  - sops on PATH"
          "    https://github.com/getsops/sops/releases"
          "    or: go install github.com/getsops/sops/v3/cmd/sops@latest"
        )
    fi

    if [[ ! -d /dev/shm ]]; then
        err+=(
          "  - /dev/shm (tmpfs)"
          "    required for keyring cleartext DEK workflows"
        )
    fi

    if [[ ${#err[@]} -gt 0 ]]; then
        _check_fail "${err[@]}"
    fi

    printf '%s\n' \
      'install.sh: check passed (Ubuntu/Debian deps, Python 3.12+, pip, sops)'
}

_require_venv() {
    if [[ ! -x "${VENV_PY}" ]]; then
        _die "tokmint venv missing; run: ${0} venv"
    fi
}

_cmd_venv() {
    _cmd_check
    if [[ -x "${VENV_PY}" ]]; then
        printf '%s\n' "install.sh: venv already exists at ${VENV_DIR}"
        return 0
    fi
    printf '%s\n' "install.sh: creating venv at ${VENV_DIR}"
    "${PYTHON}" -m venv "${VENV_DIR}"
    "${VENV_PIP}" install --upgrade pip
    "${VENV_PIP}" install -e "${UTIL_ROOT}/secconfig" \
        -e "${UTIL_ROOT}/tokmint/[dev]"
    printf '%s\n' "install.sh: venv ready"
}

_dir_mode() {
    stat -c '%a' "${1}" 2>/dev/null || printf '%s' '000'
}

_check_secret_dir_perms() {
    local dir="${1}"
    local mode
    mode="$(_dir_mode "${dir}")"
    if [[ "${mode}" != "700" ]]; then
        printf '%s\n' \
          "install.sh: ${dir} must be mode 700 (got ${mode}); fix or choose another path" \
          >&2
        return 1
    fi
    return 0
}

_ensure_dir_700() {
    local dir="${1}"
    if [[ -d "${dir}" ]]; then
        _check_secret_dir_perms "${dir}" || return 1
        return 0
    fi
    local parent
    parent="$(dirname "${dir}")"
    if [[ ! -d "${parent}" ]]; then
        printf '%s\n' "Parent directory does not exist: ${parent}" >&2
        printf '%s' 'Create it? [y/N] ' >&2
        local ans
        if ! read -r ans; then
            return 1
        fi
        if [[ "${ans}" != "y" ]] && [[ "${ans}" != "Y" ]]; then
            _die "aborted"
        fi
        mkdir -p "${parent}"
        chmod 700 "${parent}"
    fi
    mkdir -p "${dir}"
    chmod 700 "${dir}"
    return 0
}

_prompt_secconfig_dir() {
    local default="${SECCONFIG_DIR:-${HOME}/secconfig}"
    local input
    printf '%s' "SECCONFIG_DIR [${default}]: " >&2
    if ! read -r input; then
        return 1
    fi
    if [[ -z "${input}" ]]; then
        input="${default}"
    fi
    if [[ "${input}" != /* ]]; then
        input="${PWD}/${input}"
    fi
    SECCONFIG_DIR="$(realpath -m "${input}")"
    export SECCONFIG_DIR
}

_try_fill_age_in_sops_yaml() {
    local sops_yaml="${SECCONFIG_DIR}/.sops.yaml"
    local pub
    if [[ ! -f "${sops_yaml}" ]]; then
        return 0
    fi
    if ! grep -q 'age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY' "${sops_yaml}" \
        2>/dev/null; then
        return 0
    fi
    local get_pub="${UTIL_ROOT}/keyring/get-age-public-key.sh"
    if [[ ! -x "${get_pub}" ]]; then
        return 0
    fi
    if ! pub="$("${get_pub}" 2>/dev/null)"; then
        printf '%s\n' \
          'install.sh: .sops.yaml still has placeholder age:; run keyring init' \
          '  then get-age-public-key.sh and edit .sops.yaml' >&2
        return 0
    fi
    "${VENV_PY}" - "${sops_yaml}" "${pub}" <<'PY'
import sys
from pathlib import Path
import yaml
path = Path(sys.argv[1])
pub = sys.argv[2].strip()
text = path.read_text(encoding="utf-8")
doc = yaml.safe_load(text)
for rule in doc.get("creation_rules") or []:
    if rule.get("age") == "age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY":
        rule["age"] = pub
path.write_text(yaml.dump(doc, default_flow_style=False, sort_keys=False),
                encoding="utf-8")
path.chmod(0o600)
PY
    printf '%s\n' 'install.sh: filled age: from keyring DEK public key'
}

_write_env_bash() {
    local env_file="${SECCONFIG_DIR}/env.bash"
    cat > "${env_file}" <<EOF
# Generated by util install/install.sh — source in your shell:
#   . ${env_file}
export SECCONFIG_DIR='${SECCONFIG_DIR}'
export TOKMINT_SECCONFIG_SUBDIR='tokmint'
# Optional (defaults shown):
# export KEYRING_DATA_DIR="\${HOME}/.local/share/util/keyring"
# export KEYRING_OPENSSL_BIN='/usr/bin/openssl'
# export TOKMINT_PORT='9876'
# export TOKMINT_LOG_LEVEL='INFO'
# Keyring (once per boot / after expiry):
#   source ${UTIL_ROOT}/keyring/init.bash
# Tokmint service:
#   ${VENV_PY} -m tokmint
EOF
    chmod 600 "${env_file}"
}

_print_env_summary() {
    printf '%s\n' ''
    printf '%s\n' 'Environment variables:'
    printf '%s\n' '  Required (after configure):'
    printf '%s\n' "    SECCONFIG_DIR=${SECCONFIG_DIR}"
    printf '%s\n' '  Optional (recommended defaults):'
    printf '%s\n' '    TOKMINT_SECCONFIG_SUBDIR=tokmint'
    printf '%s\n' \
      "    KEYRING_DATA_DIR=\${HOME}/.local/share/util/keyring"
    printf '%s\n' '    KEYRING_OPENSSL_BIN=/usr/bin/openssl'
    printf '%s\n' '    TOKMINT_PORT=9876'
    printf '%s\n' '    TOKMINT_LOG_LEVEL=INFO'
    printf '%s\n' ''
    printf '%s\n' "Source env.bash:  . ${SECCONFIG_DIR}/env.bash"
    printf '%s\n' "Keyring init:     source ${UTIL_ROOT}/keyring/init.bash"
    printf '%s\n' "Run tokmint:      ${VENV_PY} -m tokmint"
}

_cmd_configure() {
    _require_venv
    _prompt_secconfig_dir || _die "failed to read SECCONFIG_DIR"
    local tokmint_dir="${SECCONFIG_DIR}/tokmint"
    if [[ -e "${SECCONFIG_DIR}" ]] && [[ ! -d "${SECCONFIG_DIR}" ]]; then
        _die "SECCONFIG_DIR exists but is not a directory: ${SECCONFIG_DIR}"
    fi
    if ! _ensure_dir_700 "${SECCONFIG_DIR}"; then
        exit 1
    fi
    if [[ -e "${tokmint_dir}" ]] && [[ ! -d "${tokmint_dir}" ]]; then
        _die "tokmint path exists but is not a directory: ${tokmint_dir}"
    fi
    if [[ -d "${tokmint_dir}" ]]; then
        _check_secret_dir_perms "${tokmint_dir}" || exit 1
    else
        mkdir -p "${tokmint_dir}"
        chmod 700 "${tokmint_dir}"
    fi
    if [[ ! -f "${MERGE_PY}" ]]; then
        _die "missing ${MERGE_PY}"
    fi
    "${VENV_PY}" "${MERGE_PY}" \
        --secconfig-dir "${SECCONFIG_DIR}" \
        --util-root "${UTIL_ROOT}"
    _try_fill_age_in_sops_yaml
    _write_env_bash
    _print_env_summary
    printf '%s\n' 'install.sh: configure finished'
}

_cmd_install() {
    _cmd_check
    _cmd_venv
    _cmd_configure
    printf '%s\n' 'install.sh: install finished'
}

main() {
    local cmd="${1:-}"
    case "${cmd}" in
        check)
            _cmd_check
            ;;
        venv)
            _cmd_venv
            ;;
        configure)
            _cmd_configure
            ;;
        install)
            _cmd_install
            ;;
        -h|--help|help|'')
            _print_help
            exit 0
            ;;
        *)
            _usage_unknown
            _die "unknown command: ${cmd}"
            ;;
    esac
}

main "${@}"
