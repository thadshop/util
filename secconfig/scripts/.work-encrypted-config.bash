# SOURCE ONLY — sourced by new-encrypted-config.sh and edit-encrypted-config.sh.
# Do not execute directly.

# shellcheck shell=bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf '%s\n' \
        '.work-encrypted-config.bash: source from new-encrypted-config.sh' \
        ' or edit-encrypted-config.sh' >&2
    exit 1
fi

_impl_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_impl_path}")"
_keyring_dir="$(cd "${_script_dir}/../../keyring" && pwd)"

# shellcheck source=../../keyring/lib.bash
source "${_keyring_dir}/lib.bash"

if [[ -z "${WE_MSG_PREFIX+x}" ]]; then
    printf '%s\n' 'internal: set WE_MSG_PREFIX before sourcing impl' >&2
    exit 1
fi

_with_sops_dek="${_keyring_dir}/with-sops-dek.sh"
_default_get_dek="${_keyring_dir}/get-dek.sh"

_get_dek="${GET_DEK_PATH:-${_default_get_dek}}"
_explicit_sops=""
_plain_file=""
_staging_file=""
_tmp_encrypted=""
_wek_picked_encrypted=""

wek_new_usage() {
    printf '%s\n' \
        "usage: new-encrypted-config.sh [-k|--get-dek SCRIPT]" >&2
    printf '%s\n' \
        "                                 [-c|--sops-config FILE] [-h|--help]" \
        >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  Empty plaintext in /dev/shm; edit; encrypt with sops." >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  -c sets SOPS_CONFIG (overrides \${SECCONFIG_DIR}/.sops.yaml)." >&2
    printf '%s\n' \
        "  -k / GET_DEK_PATH → get-dek.sh (default: ${_default_get_dek})." >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  With \${SECCONFIG_DIR} set: pick output dir (list + files) then" >&2
    printf '%s\n' \
        "  basename, or enter a full path. Else: full path only. Tty/stdin" >&2
    printf '%s\n' \
        "  like edit-encrypted-config.sh." >&2
}

wek_edit_usage() {
    printf '%s\n' \
        "usage: edit-encrypted-config.sh [-k|--get-dek SCRIPT]" >&2
    printf '%s\n' \
        "                                  [-c|--sops-config FILE] [-h|--help]" \
        >&2
    printf '%s\n' \
        "                                  [ENCRYPTED_FILE]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  Decrypt to /dev/shm; edit; re-encrypt (backup prompts)." >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  With no file: lists matches under \${SECCONFIG_DIR} when set;" >&2
    printf '%s\n' \
        "  enter a list number or path, or type a path if there is no list." >&2
    printf '%s\n' \
        "  Empty input aborts. Reads from /dev/tty, else stdin." >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  -c sets SOPS_CONFIG (overrides \${SECCONFIG_DIR}/.sops.yaml)." >&2
    printf '%s\n' \
        "  -k / GET_DEK_PATH → get-dek.sh (default: ${_default_get_dek})." >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  To create a new encrypted file, use new-encrypted-config.sh" >&2
}

cleanup_plain() {
    if [[ -n "${_plain_file}" ]] && [[ -f "${_plain_file}" ]]; then
        rm -f "${_plain_file}"
        printf '%s\n' "Removed plaintext: ${_plain_file}" >&2
    fi
}

cleanup_staging() {
    if [[ -n "${_staging_file}" ]] && [[ -f "${_staging_file}" ]]; then
        rm -f "${_staging_file}"
    fi
}

cleanup_tmp_enc() {
    if [[ -n "${_tmp_encrypted}" ]] && [[ -f "${_tmp_encrypted}" ]]; then
        rm -f "${_tmp_encrypted}"
    fi
}

wek_parse_options() {
    local OPTS
    if ! OPTS=$(getopt -o k:c:h --long get-dek:,sops-config:,help \
        -n "${WE_MSG_PREFIX}" -- "${@}"); then
        return 1
    fi
    eval set -- "${OPTS}"

    while true; do
        case "${1}" in
            -k|--get-dek)
                _get_dek="${2}"
                shift 2
                ;;
            -c|--sops-config)
                _explicit_sops="${2}"
                shift 2
                ;;
            -h|--help)
                return 2
                ;;
            --)
                shift
                break
                ;;
            *)
                printf '%s\n' "${WE_MSG_PREFIX}: invalid option: ${1}" >&2
                return 1
                ;;
        esac
    done
    return 0
}

_require_prereqs() {
    if ! command -v sops >/dev/null 2>&1; then
        printf '%s\n' "${WE_MSG_PREFIX}: sops not in PATH" >&2
        return 1
    fi
    we_require_shm
    if [[ ! -x "${_with_sops_dek}" ]]; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: with-sops-dek not executable: ${_with_sops_dek}" \
            >&2
        return 1
    fi
    if [[ ! -x "${_get_dek}" ]]; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: get-dek not executable: ${_get_dek}" >&2
        return 1
    fi
    return 0
}

_resolve_sops_config() {
    if [[ -n "${_explicit_sops}" ]]; then
        if [[ ! -f "${_explicit_sops}" ]]; then
            printf '%s\n' \
                "${WE_MSG_PREFIX}: --sops-config not a file: ${_explicit_sops}" \
                >&2
            return 1
        fi
        _SOPS_CFG="$(cd "$(dirname "${_explicit_sops}")" && pwd)/$(basename \
            "${_explicit_sops}")"
        return 0
    fi
    if [[ -n "${SECCONFIG_DIR:-}" ]]; then
        _root="$(cd "${SECCONFIG_DIR}" && pwd)"
        _cand="${_root}/.sops.yaml"
        if [[ -f "${_cand}" ]]; then
            _SOPS_CFG="${_cand}"
            return 0
        fi
    fi
    printf '%s\n' \
        "${WE_MSG_PREFIX}: need --sops-config or SECCONFIG_DIR with" \
        ' .sops.yaml' >&2
    return 1
}

_with_sops_cmd() {
    "${_with_sops_dek}" -k "${_get_dek}" -c "${_SOPS_CFG}" -- "${@}"
}

_staging_suffix_from_path() {
    local _base
    _base="$(basename "${1}")"
    case "${_base}" in
        *.enc.yaml) printf '%s' '.yaml' ;;
        *.enc.yml) printf '%s' '.yml' ;;
        *.enc.pem) printf '%s' '.pem' ;;
        *.yaml) printf '%s' '.yaml' ;;
        *.yml) printf '%s' '.yml' ;;
        *.pem) printf '%s' '.pem' ;;
        *) printf '%s' '.dat' ;;
    esac
}

# Plaintext path for sops -e before writing ciphertext. sops matches
# creation_rules path_regex to this path (relative to .sops.yaml dir), not to
# the final .enc.yaml. Use <stem>.plain.XXXXXX.suffix so rules like
# .*\.plain\.ya?ml match; a bare .edit-staging-plain.* name often matches
# nothing if .sops.yaml only lists service-specific paths.
_wek_mktemp_staging_for_final() {
    local _final="${1}"
    local _odir _base _stem _suf
    _odir="$(dirname "${_final}")"
    _base="$(basename "${_final}")"
    _suf="$(_staging_suffix_from_path "${_final}")"
    case "${_base}" in
        *.enc.yaml)
            _stem="${_base%.enc.yaml}"
            ;;
        *.enc.yml)
            _stem="${_base%.enc.yml}"
            ;;
        *.enc.pem)
            _stem="${_base%.enc.pem}"
            ;;
        *)
            _stem="${_base%.*}"
            ;;
    esac
    if [[ -z "${_stem}" ]] || [[ "${_stem}" == "." ]]; then
        _stem="staging"
    fi
    if [[ "${_stem}" == */* ]]; then
        _stem="staging"
    fi
    mktemp "${_odir}/${_stem}.plain.XXXXXX${_suf}"
}

_encrypted_suffix_from_path() {
    local _base
    _base="$(basename "${1}")"
    case "${_base}" in
        *.enc.yaml) printf '%s' '.enc.yaml' ;;
        *.enc.yml) printf '%s' '.enc.yml' ;;
        *.yaml) printf '%s' '.yaml' ;;
        *.yml) printf '%s' '.yml' ;;
        *.pem) printf '%s' '.pem' ;;
        *) printf '%s' '.enc' ;;
    esac
}

_encrypt_validate_install() {
    local _staging="${1}"
    local _final="${2}"
    local _dir _enc_suf
    _dir="$(cd "$(dirname "${_final}")" && pwd)"
    _enc_suf="$(_encrypted_suffix_from_path "${_final}")"
    cleanup_tmp_enc
    _tmp_encrypted="$(mktemp "${_dir}/.edit-cipher.XXXXXX${_enc_suf}")"
    export SOPS_CONFIG="${_SOPS_CFG}"
    if ! sops -e --output "${_tmp_encrypted}" "${_staging}"; then
        printf '%s\n' "${WE_MSG_PREFIX}: sops encrypt failed" >&2
        printf '%s\n' \
            "${WE_MSG_PREFIX}: hint: extend .sops.yaml path_regex for the" \
            " plaintext path sops sees (staging file):" >&2
        printf '%s\n' "  ${_staging}" >&2
        return 1
    fi
    rm -f "${_staging}"
    _staging_file=""
    if ! _with_sops_cmd sops decrypt --output /dev/null \
        "${_tmp_encrypted}"; then
        printf '%s\n' "${WE_MSG_PREFIX}: validation decrypt failed" >&2
        return 1
    fi
    if ! we_confirm_overwrite "${_final}"; then
        return 1
    fi
    mv -f "${_tmp_encrypted}" "${_final}"
    _tmp_encrypted=""
    printf '%s\n' "Wrote validated ciphertext: ${_final}" >&2
    return 0
}

# Read one line into variable named by $1; tty first, else stdin. Returns 1 on
# EOF.
_wek_read_pick_line() {
    local _vn="${1}"
    if [[ -r /dev/tty ]]; then
        if ! IFS= read -r "${_vn}" </dev/tty; then
            return 1
        fi
    else
        if ! IFS= read -r "${_vn}"; then
            return 1
        fi
    fi
    return 0
}

# Comma-separated file basenames in $1 (non-dirs, maxdepth 1); stdout.
_wek_dir_files_summary() {
    local _d="${1}"
    local -a _fs=()
    mapfile -t _fs < <(
        find "${_d}" -maxdepth 1 -mindepth 1 ! -type d -printf '%f\n' \
            2>/dev/null | LC_ALL=C sort
    )
    local _n=${#_fs[@]}
    local _max=8
    local _lim _i
    if [[ ${_n} -eq 0 ]]; then
        printf '%s' '(none)'
        return 0
    fi
    if [[ ${_n} -le ${_max} ]]; then
        _lim=${_n}
    else
        _lim=${_max}
    fi
    for ((_i = 0; _i < _lim; _i++)); do
        printf '%s' "${_fs[${_i}]}"
        if [[ $((_i + 1)) -lt ${_lim} ]]; then
            printf '%s' ', '
        fi
    done
    if [[ ${_n} -gt ${_max} ]]; then
        printf '%s' ", ... (+$((_n - _max)) more)"
    fi
    return 0
}

# List files in directory $1 (non-dirs); stderr, indented.
_wek_dir_files_list() {
    local _d="${1}"
    local -a _fs=()
    local _i _n _max=60 _lim
    mapfile -t _fs < <(
        find "${_d}" -maxdepth 1 -mindepth 1 ! -type d -printf '%f\n' \
            2>/dev/null | LC_ALL=C sort
    )
    _n=${#_fs[@]}
    if [[ ${_n} -eq 0 ]]; then
        printf '%s\n' '      (no files)' >&2
        return 0
    fi
    if [[ ${_n} -le ${_max} ]]; then
        _lim=${_n}
    else
        _lim=${_max}
    fi
    for ((_i = 0; _i < _lim; _i++)); do
        printf '      - %s\n' "${_fs[${_i}]}" >&2
    done
    if [[ ${_n} -gt ${_max} ]]; then
        printf '      ... and %d more\n' "$((_n - _lim))" >&2
    fi
    return 0
}

# Create dirname(WE_OUT_FINAL) if missing; y/N like we_read path helper.
_wek_mkdir_out_parent() {
    local _odir _mk
    _odir="$(dirname "${WE_OUT_FINAL}")"
    if [[ -d "${_odir}" ]]; then
        return 0
    fi
    printf '%s' "Create directory ${_odir}? [y/N] " >&2
    if ! _wek_read_pick_line _mk; then
        printf '%s\n' "${WE_MSG_PREFIX}: cancelled" >&2
        exit 1
    fi
    if [[ "${_mk}" != y ]]; then
        printf '%s\n' "${WE_MSG_PREFIX}: cancelled" >&2
        exit 1
    fi
    mkdir -p "${_odir}"
    return 0
}

# Interactive output path for new ciphertext; sets WE_OUT_FINAL (global).
wek_new_prompt_output_path_and_mkdir() {
    local _root _line _ndirs _i _chosen _join _rp_dir _want _fn
    local -a _dirs=()

    WE_OUT_FINAL=""
    _chosen=""

    if [[ -z "${SECCONFIG_DIR:-}" ]]; then
        we_read_new_encrypted_path_and_mkdir
        return 0
    fi
    if [[ ! -d "${SECCONFIG_DIR}" ]]; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: SECCONFIG_DIR is not a directory:" \
            " ${SECCONFIG_DIR}" >&2
        we_read_new_encrypted_path_and_mkdir
        return 0
    fi

    _root="$(cd "${SECCONFIG_DIR}" && pwd)" || exit 1
    mapfile -t _dirs < <(find "${_root}" -type d -print | LC_ALL=C sort)
    _ndirs=${#_dirs[@]}
    if [[ ${_ndirs} -eq 0 ]]; then
        we_read_new_encrypted_path_and_mkdir
        return 0
    fi

    printf '%s\n' "Directories under SECCONFIG_DIR (${_root}):" "" >&2
    for ((_i = 0; _i < _ndirs; _i++)); do
        _rel="${_dirs[${_i}]#${_root}/}"
        if [[ -z "${_rel}" ]]; then
            _rel="."
        fi
        printf '%4d) %s\n' "$((_i + 1))" "${_rel}" >&2
        printf '      files: %s\n' \
            "$(_wek_dir_files_summary "${_dirs[${_i}]}")" >&2
    done
    printf '%s\n' "" >&2
    printf '%s\n' \
        'Enter directory number (1-'"${_ndirs}"'), path relative to' \
        ' SECCONFIG_DIR, full ciphertext path (absolute or ~), ./' \
        ' or ../ for cwd, or empty to abort:' >&2

    while true; do
        if ! _wek_read_pick_line _line; then
            printf '%s\n' "${WE_MSG_PREFIX}: cancelled" >&2
            exit 1
        fi
        _line="${_line#"${_line%%[![:space:]]*}"}"
        _line="${_line%"${_line##*[![:space:]]}"}"

        if [[ -z "${_line}" ]]; then
            printf '%s\n' "${WE_MSG_PREFIX}: aborted" >&2
            exit 1
        fi

        if [[ "${_line}" == .. ]] || [[ "${_line}" == ../ ]]; then
            printf '%s\n' \
                "${WE_MSG_PREFIX}: use a directory number or an explicit" \
                ' path' >&2
            continue
        fi

        if [[ "${_line}" == . ]]; then
            _chosen="${_root}"
            break
        fi

        if [[ "${_line}" =~ ^[0-9]+$ ]]; then
            if [[ "${_line}" -ge 1 ]] && [[ "${_line}" -le ${_ndirs} ]]; then
                _chosen="${_dirs[$((_line - 1))]}"
                break
            fi
            printf '%s\n' \
                "${WE_MSG_PREFIX}: not in range 1-${_ndirs}; try again" >&2
            continue
        fi

        if [[ "${_line}" == /* ]] || [[ "${_line}" == \~* ]]; then
            if [[ "${_line}" == \~* ]]; then
                _line="${_line/#\~/${HOME}}"
            fi
            WE_OUT_FINAL="$(realpath -m "${_line}")"
            _wek_mkdir_out_parent
            return 0
        fi

        if [[ "${_line}" == ./* ]] || [[ "${_line}" == ../* ]]; then
            WE_OUT_FINAL="$(realpath -m "${_line}")"
            _wek_mkdir_out_parent
            return 0
        fi

        _join="${_root}/${_line}"
        if _rp_dir="$(realpath "${_join}" 2>/dev/null)" && \
            [[ -d "${_rp_dir}" ]]; then
            case "${_rp_dir}" in
                "${_root}"/* | "${_root}")
                    _chosen="${_rp_dir}"
                    break
                    ;;
                *)
                    printf '%s\n' \
                        "${WE_MSG_PREFIX}: directory outside SECCONFIG_DIR" \
                        >&2
                    continue
                    ;;
            esac
        fi

        _want="$(realpath -m "${_join}")"
        case "${_want}" in
            "${_root}"/*)
                WE_OUT_FINAL="${_want}"
                _wek_mkdir_out_parent
                return 0
                ;;
        esac

        WE_OUT_FINAL="$(realpath -m "${_line}")"
        _wek_mkdir_out_parent
        return 0
    done

    printf '%s\n' "" "Chosen directory: ${_chosen}" "" >&2
    printf '%s\n' 'Files there:' >&2
    _wek_dir_files_list "${_chosen}"
    printf '%s\n' "" >&2
    printf '%s\n' \
        'New ciphertext filename (basename only, e.g. myapp.enc.yaml),' \
        ' or empty to abort:' >&2

    while true; do
        if ! _wek_read_pick_line _fn; then
            printf '%s\n' "${WE_MSG_PREFIX}: cancelled" >&2
            exit 1
        fi
        _fn="${_fn#"${_fn%%[![:space:]]*}"}"
        _fn="${_fn%"${_fn##*[![:space:]]}"}"

        if [[ -z "${_fn}" ]]; then
            printf '%s\n' "${WE_MSG_PREFIX}: aborted" >&2
            exit 1
        fi

        if [[ "${_fn}" == */* ]]; then
            printf '%s\n' \
                "${WE_MSG_PREFIX}: use basename only (no slashes), or" \
                ' cancel and enter a full path at the directory step' >&2
            continue
        fi
        if [[ "${_fn}" == . ]] || [[ "${_fn}" == .. ]]; then
            printf '%s\n' "${WE_MSG_PREFIX}: invalid filename" >&2
            continue
        fi

        WE_OUT_FINAL="${_chosen}/${_fn}"
        return 0
    done
}

_run_new() {
    _require_prereqs || exit 1
    _resolve_sops_config || exit 1

    _plain_file="$(mktemp '/dev/shm/edit-new-plain.XXXXXX.yaml')"
    : > "${_plain_file}"
    chmod 600 "${_plain_file}"

    printf '%s\n' "Created empty file: ${_plain_file}"
    we_print_edit_instructions "${_plain_file}"
    we_prompt_press_enter_after_edit encrypt
    we_ensure_plain_nonempty_or_confirm "${_plain_file}"

    wek_new_prompt_output_path_and_mkdir
    local _final="${WE_OUT_FINAL}"

    _staging_file="$(_wek_mktemp_staging_for_final "${_final}")"
    chmod 600 "${_staging_file}"
    cp "${_plain_file}" "${_staging_file}"

    if ! _encrypt_validate_install "${_staging_file}" "${_final}"; then
        exit 1
    fi

    trap - EXIT
    rm -f "${_plain_file}"
    printf '%s\n' "Removed plaintext: ${_plain_file}"
}

_run_edit() {
    if [[ ${#} -ne 1 ]]; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: requires exactly one encrypted file" >&2
        wek_edit_usage
        exit 1
    fi
    _require_prereqs || exit 1
    _resolve_sops_config || exit 1

    local _enc_in
    _enc_in="$(realpath "${1}")"
    if [[ ! -f "${_enc_in}" ]]; then
        printf '%s\n' "${WE_MSG_PREFIX}: not a file: ${_enc_in}" >&2
        exit 1
    fi

    local _suf
    _suf="$(_staging_suffix_from_path "${_enc_in}")"
    _plain_file="$(mktemp "/dev/shm/edit-plain.XXXXXX${_suf}")"
    chmod 600 "${_plain_file}"

    if ! _with_sops_cmd sops decrypt --output "${_plain_file}" "${_enc_in}"; then
        printf '%s\n' "${WE_MSG_PREFIX}: decrypt failed" >&2
        rm -f "${_plain_file}"
        exit 1
    fi

    printf '%s\n' "Decrypted to: ${_plain_file}"
    we_print_edit_instructions "${_plain_file}"
    we_prompt_press_enter_after_edit re-encrypt
    we_ensure_plain_nonempty_or_confirm "${_plain_file}"

    _staging_file="$(_wek_mktemp_staging_for_final "${_enc_in}")"
    chmod 600 "${_staging_file}"
    cp "${_plain_file}" "${_staging_file}"

    we_backup_resolve_and_mv_live "${_enc_in}"

    if ! _encrypt_validate_install "${_staging_file}" "${_enc_in}"; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: failed after moving old file. Restore:" >&2
        printf '  mv -f %q %q\n' "${WE_BACKUP}" "${_enc_in}" >&2
        exit 1
    fi

    we_optional_delete_backup_prompt "${WE_BACKUP}"

    trap - EXIT
    rm -f "${_plain_file}"
    printf '%s\n' "Removed plaintext: ${_plain_file}"
}

# Set _wek_picked_encrypted to an absolute path to a regular file, or return 1.
wek_prompt_pick_encrypted_file() {
    local _root _line _n _i _rp _try _rel
    local -a _cand=()

    _wek_picked_encrypted=""
    _root=""

    if [[ -n "${SECCONFIG_DIR:-}" ]]; then
        if [[ -d "${SECCONFIG_DIR}" ]]; then
            _root="$(cd "${SECCONFIG_DIR}" && pwd)" || return 1
        else
            printf '%s\n' \
                "${WE_MSG_PREFIX}: SECCONFIG_DIR is not a directory:" \
                " ${SECCONFIG_DIR}" >&2
        fi
    fi

    if [[ -n "${_root}" ]]; then
        mapfile -t _cand < <(
            find "${_root}" -type f \
                \( -name '*.enc.yaml' -o -name '*.enc.yml' \
                -o -name '*.enc.pem' \) \
                -print | LC_ALL=C sort
        )
    fi

    _n=${#_cand[@]}
    if [[ ${_n} -gt 0 ]]; then
        printf '%s\n' \
            "Encrypted files under SECCONFIG_DIR (${_root}):" "" >&2
        for ((_i = 0; _i < _n; _i++)); do
            _rel="${_cand[${_i}]#${_root}/}"
            printf '%3d) %s\n' "$((_i + 1))" "${_rel}" >&2
        done
        printf '%s\n' "" >&2
        printf '%s\n' \
            'Enter list number (1-'"${_n}"'), path (relative to SECCONFIG_DIR' \
            ' or absolute under it), or empty to abort:' >&2
    else
        if [[ -n "${_root}" ]]; then
            printf '%s\n' \
                "${WE_MSG_PREFIX}: no *.enc.yaml / *.enc.yml / *.enc.pem" \
                " under ${_root}" >&2
            printf '%s\n' \
                'Enter path (relative to SECCONFIG_DIR or absolute under it),' \
                ' or empty to abort:' >&2
        else
            printf '%s\n' \
                "${WE_MSG_PREFIX}: no SECCONFIG_DIR list (unset or not a" \
                ' directory).' >&2
            printf '%s\n' \
                'Enter path to encrypted file (relative or absolute),' \
                ' or empty to abort:' >&2
        fi
    fi

    while true; do
        if ! _wek_read_pick_line _line; then
            printf '%s\n' "${WE_MSG_PREFIX}: cancelled" >&2
            return 1
        fi
        _line="${_line#"${_line%%[![:space:]]*}"}"
        _line="${_line%"${_line##*[![:space:]]}"}"

        if [[ -z "${_line}" ]]; then
            printf '%s\n' "${WE_MSG_PREFIX}: aborted" >&2
            return 1
        fi

        if [[ "${_line}" =~ ^[0-9]+$ ]] && [[ ${_n} -gt 0 ]]; then
            if [[ "${_line}" -ge 1 ]] && [[ "${_line}" -le ${_n} ]]; then
                _wek_picked_encrypted="${_cand[$((_line - 1))]}"
                return 0
            fi
            printf '%s\n' \
                "${WE_MSG_PREFIX}: not in range 1-${_n}; try again" >&2
            continue
        fi

        if [[ "${_line}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' \
                "${WE_MSG_PREFIX}: enter a file path, not a number" >&2
            continue
        fi

        if [[ -n "${_root}" ]]; then
            if [[ "${_line}" == /* ]]; then
                _try="${_line}"
            else
                _try="${_root}/${_line}"
            fi
        else
            _try="${_line}"
        fi
        if ! _rp="$(realpath "${_try}" 2>/dev/null)"; then
            printf '%s\n' \
                "${WE_MSG_PREFIX}: not a valid path: ${_line}" >&2
            continue
        fi
        if [[ ! -f "${_rp}" ]]; then
            printf '%s\n' \
                "${WE_MSG_PREFIX}: not a file: ${_rp}" >&2
            continue
        fi
        if [[ -n "${_root}" ]]; then
            case "${_rp}" in
                "${_root}"/*) ;;
                *)
                    printf '%s\n' \
                        "${WE_MSG_PREFIX}: path must be under SECCONFIG_DIR:" \
                        " ${_root}" >&2
                    continue
                    ;;
            esac
        fi
        _wek_picked_encrypted="${_rp}"
        return 0
    done
}

wek_new() {
    trap 'cleanup_plain; cleanup_staging; cleanup_tmp_enc' EXIT

    if ! keyring_no_debug; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: refused (xtrace or verbose enabled)" >&2
        exit 1
    fi

    local _parse_rc=0
    wek_parse_options "${@}" || _parse_rc="${?}"
    if [[ ${_parse_rc} -eq 2 ]]; then
        wek_new_usage
        exit 0
    fi
    if [[ ${_parse_rc} -ne 0 ]]; then
        wek_new_usage
        exit 1
    fi

    if [[ ${#} -gt 0 ]]; then
        printf '%s\n' "${WE_MSG_PREFIX}: unexpected arguments: ${*}" >&2
        wek_new_usage
        exit 1
    fi

    _run_new
}

wek_edit() {
    trap 'cleanup_plain; cleanup_staging; cleanup_tmp_enc' EXIT

    if ! keyring_no_debug; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: refused (xtrace or verbose enabled)" >&2
        exit 1
    fi

    local _parse_rc=0
    wek_parse_options "${@}" || _parse_rc="${?}"
    if [[ ${_parse_rc} -eq 2 ]]; then
        wek_edit_usage
        exit 0
    fi
    if [[ ${_parse_rc} -ne 0 ]]; then
        wek_edit_usage
        exit 1
    fi

    # Legacy: edit-encrypted-config.sh edit FILE
    if [[ ${#} -eq 2 ]] && [[ "${1}" == edit ]]; then
        set -- "${2}"
    fi

    if [[ ${#} -eq 1 ]] && [[ "${1}" == new ]]; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: use new-encrypted-config.sh to create a file" \
            >&2
        exit 2
    fi

    if [[ ${#} -eq 0 ]]; then
        wek_prompt_pick_encrypted_file || exit 1
        set -- "${_wek_picked_encrypted}"
    fi

    if [[ ${#} -ne 1 ]]; then
        printf '%s\n' \
            "${WE_MSG_PREFIX}: requires zero or one encrypted file" >&2
        wek_edit_usage
        exit 1
    fi

    _run_edit "${@}"
}
