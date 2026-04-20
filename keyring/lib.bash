# SOURCE ONLY — do not execute (`bash lib.bash`). Defines functions only.
# In Bash: source /path/to/lib.bash
#
# Bash keyring library - Linux kernel keyring + openssl-wrapped DEK + sops
# Stores KEK (Key Encryption Key) in kernel keyring (per-user,
# survives logout); never cleartext on disk.
#
# Usage: source this file, then call keyring_init
# (e.g. from .profile or .bashrc)
#
# Keyring: Uses persistent keyring on Ubuntu server/workstation.
# Falls back to user keyring (@u) on WSL2 where get_persistent
# is not supported. Both provide user-scoped persistence.

if [[ -z "${KEYRING_KEK_KEY_NAME+x}" ]]; then
    readonly KEYRING_KEK_KEY_NAME='util_keyring_kek'
fi

_KEYRING_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# Secret data dir: dek.encrypted and keyring-test.enc live here.
# Override with KEYRING_DATA_DIR env var; default is XDG data home.
_KEYRING_DATA_DIR="${KEYRING_DATA_DIR:-${HOME}/.local/share/util/keyring}"

# Fixed openssl smoke inputs (not recipe policy). See file header.
# shellcheck source=dek-wrap-test-vectors.bash
if ! source "${_KEYRING_DIR}/dek-wrap-test-vectors.bash" 2>/dev/null; then
    printf '%s\n' \
      "keyring: could not source ${_KEYRING_DIR}/dek-wrap-test-vectors.bash" \
      >&2
    return 1 2>/dev/null || exit 1
fi

_keyring_recipes_dir() {
    printf '%s' \
      "${KEYRING_DEK_WRAP_RECIPE_DIR:-${_KEYRING_DIR}/dek-wrap-recipes}"
}

keyring_openssl_bin() {
    printf '%s' "${KEYRING_OPENSSL_BIN:-/usr/bin/openssl}"
}

_keyring_openssl_version_current() {
    local ssl line ver
    ssl="$(keyring_openssl_bin)"
    line=$("${ssl}" version 2>/dev/null | head -1)
    ver=$(printf '%s' "${line}" | sed -n \
      's/.*OpenSSL \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    printf '%s' "${ver}"
}

_keyring_version_ge() {
    local cur="${1}"
    local min="${2}"
    [[ -n "${cur}" ]] && [[ -n "${min}" ]] || return 1
    [[ "$(printf '%s\n' "${min}" "${cur}" | sort -V | tail -1)" == "${cur}" ]]
}

_keyring_openssl_below_min_warn_ack() {
    local min_v cur_v
    min_v="${_KEYRING_RW_OPENSSL_MIN}"
    cur_v="$(_keyring_openssl_version_current)"
    if _keyring_version_ge "${cur_v}" "${min_v}"; then
        return 0
    fi
    printf '%s\n' \
      "keyring: WARNING: OpenSSL ${cur_v} is older than recipe minimum" \
      " ${min_v} (smoke test still must pass)." >&2
    if [[ -t 0 ]] && [[ -c /dev/tty ]]; then
        local _ack
        printf '%s' 'Type YES to continue, anything else aborts: ' >/dev/tty
        if ! read -r _ack </dev/tty; then
            printf '%s\n' '' >&2
            return 1
        fi
        if [[ "${_ack}" != YES ]]; then
            printf '%s\n' 'keyring: aborted (OpenSSL below minimum).' >&2
            return 1
        fi
    fi
    return 0
}

_keyring_dek_recipe_load_from_nn() {
    local nn="${1}"
    local dir f line key val
    dir="$(_keyring_recipes_dir)"
    f="${dir}/dek-wrap-recipe-${nn}.conf"
    if [[ ! -f "${f}" ]]; then
        printf '%s\n' "keyring: missing recipe file: ${f}" >&2
        return 1
    fi
    _KEYRING_RW_RECIPE_NN=''
    _KEYRING_RW_MAGIC=''
    _KEYRING_RW_HEADER_MAJ=''
    _KEYRING_RW_HEADER_MIN=''
    _KEYRING_RW_CIPHER=''
    _KEYRING_RW_MD=''
    _KEYRING_RW_ITER=''
    _KEYRING_RW_OPENSSL_MIN=''
    _KEYRING_RW_OPENSSL_TESTED=''
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        if [[ ! "${line}" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
            printf '%s\n' "keyring: invalid recipe line in ${f}" >&2
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val%$'\r'}"
        case "${key}" in
            RECIPE_ID)
                _KEYRING_RW_RECIPE_NN="${val}"
                ;;
            HEADER_MAGIC)
                _KEYRING_RW_MAGIC="${val}"
                ;;
            HEADER_FORMAT_MAJOR)
                _KEYRING_RW_HEADER_MAJ="${val}"
                ;;
            HEADER_FORMAT_MINOR)
                _KEYRING_RW_HEADER_MIN="${val}"
                ;;
            OPENSSL_CIPHER)
                _KEYRING_RW_CIPHER="${val}"
                ;;
            OPENSSL_MD)
                _KEYRING_RW_MD="${val}"
                ;;
            PBKDF2_ITER)
                _KEYRING_RW_ITER="${val}"
                ;;
            OPENSSL_MIN_VERSION)
                _KEYRING_RW_OPENSSL_MIN="${val}"
                ;;
            OPENSSL_TESTED_WITH)
                _KEYRING_RW_OPENSSL_TESTED="${val}"
                ;;
            *)
                printf '%s\n' \
                  "keyring: unknown recipe key ${key} in ${f}" >&2
                return 1
                ;;
        esac
    done < "${f}"

    if [[ "${_KEYRING_RW_RECIPE_NN}" != "${nn}" ]]; then
        printf '%s\n' \
          "keyring: RECIPE_ID ${_KEYRING_RW_RECIPE_NN} != filename ${nn}" \
          " in ${f}" >&2
        return 1
    fi
    if [[ ${#_KEYRING_RW_MAGIC} -ne 8 ]] || \
      [[ ! "${_KEYRING_RW_MAGIC}" =~ ^[A-Za-z0-9]+$ ]]; then
        printf '%s\n' "keyring: HEADER_MAGIC must be 8 alphanumeric chars" >&2
        return 1
    fi
    if [[ ! "${_KEYRING_RW_HEADER_MAJ}" =~ ^[0-9]+$ ]] || \
      [[ ! "${_KEYRING_RW_HEADER_MIN}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' 'keyring: header format major/minor must be digits' >&2
        return 1
    fi
    if [[ "${_KEYRING_RW_CIPHER}" != aes-256-cbc ]]; then
        printf '%s\n' \
          'keyring: OPENSSL_CIPHER not allowed (only aes-256-cbc)' >&2
        return 1
    fi
    if [[ "${_KEYRING_RW_MD}" != sha256 ]]; then
        printf '%s\n' 'keyring: OPENSSL_MD not allowed (only sha256)' >&2
        return 1
    fi
    if [[ ! "${_KEYRING_RW_ITER}" =~ ^[0-9]+$ ]] || \
      [[ "${_KEYRING_RW_ITER}" -lt 100000 ]] || \
      [[ "${_KEYRING_RW_ITER}" -gt 10000000 ]]; then
        printf '%s\n' 'keyring: PBKDF2_ITER out of allowed range' >&2
        return 1
    fi
    if [[ ! "${_KEYRING_RW_OPENSSL_MIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        printf '%s\n' 'keyring: OPENSSL_MIN_VERSION invalid' >&2
        return 1
    fi
    return 0
}

_keyring_dek_recipe_load_from_numeric_id() {
    local id="${1}"
    local nn
    if [[ ! "${id}" =~ ^[0-9]+$ ]] || [[ "${id}" -lt 1 ]] || \
      [[ "${id}" -gt 99 ]]; then
        printf '%s\n' 'keyring: invalid recipe id in header' >&2
        return 1
    fi
    printf -v nn '%02d' "${id}"
    _keyring_dek_recipe_load_from_nn "${nn}"
}

_keyring_dek_wrap_smoke() {
    local ssl ppass pplain pct pdec
    if [[ -z "${SMOKE_PASSPHRASE:-}" ]] || [[ -z "${SMOKE_PLAINTEXT+x}" ]]; then
        printf '%s\n' \
          'keyring: SMOKE_PASSPHRASE / SMOKE_PLAINTEXT not set' \
          ' (dek-wrap-test-vectors.bash)' >&2
        return 1
    fi
    ssl="$(keyring_openssl_bin)"
    ppass="$(mktemp /dev/shm/keyring-smoke-pass.XXXXXX)" || return 1
    pplain="$(mktemp /dev/shm/keyring-smoke-plain.XXXXXX)" || {
        rm -f "${ppass}"
        return 1
    }
    pct="$(mktemp /dev/shm/keyring-smoke-ct.XXXXXX)" || {
        rm -f "${ppass}" "${pplain}"
        return 1
    }
    pdec="$(mktemp /dev/shm/keyring-smoke-dec.XXXXXX)" || {
        rm -f "${ppass}" "${pplain}" "${pct}"
        return 1
    }
    chmod 600 "${ppass}" "${pplain}" "${pct}" "${pdec}" || {
        rm -f "${ppass}" "${pplain}" "${pct}" "${pdec}"
        return 1
    }
    if ! printf '%s' "${SMOKE_PASSPHRASE}" > "${ppass}"; then
        rm -f "${ppass}" "${pplain}" "${pct}" "${pdec}"
        return 1
    fi
    if ! printf '%s' "${SMOKE_PLAINTEXT}" > "${pplain}"; then
        rm -f "${ppass}" "${pplain}" "${pct}" "${pdec}"
        return 1
    fi
    if ! "${ssl}" enc -e "-${_KEYRING_RW_CIPHER}" -salt -pbkdf2 \
      -iter "${_KEYRING_RW_ITER}" -md "${_KEYRING_RW_MD}" \
      -pass "file:${ppass}" -out "${pct}" -in "${pplain}"; then
        rm -f "${ppass}" "${pplain}" "${pct}" "${pdec}"
        printf '%s\n' 'keyring: DEK wrap smoke encrypt failed' >&2
        return 1
    fi
    if ! "${ssl}" enc -d "-${_KEYRING_RW_CIPHER}" -pbkdf2 \
      -iter "${_KEYRING_RW_ITER}" -md "${_KEYRING_RW_MD}" \
      -pass "file:${ppass}" -in "${pct}" -out "${pdec}"; then
        rm -f "${ppass}" "${pplain}" "${pct}" "${pdec}"
        printf '%s\n' 'keyring: DEK wrap smoke decrypt failed' >&2
        return 1
    fi
    if ! cmp -s "${pplain}" "${pdec}"; then
        rm -f "${ppass}" "${pplain}" "${pct}" "${pdec}"
        printf '%s\n' 'keyring: DEK wrap smoke round-trip mismatch' >&2
        return 1
    fi
    rm -f "${ppass}" "${pplain}" "${pct}" "${pdec}"
    return 0
}

_keyring_dek_prepare_openssl_for_recipe() {
    local ssl
    ssl="$(keyring_openssl_bin)"
    if [[ ! -x "${ssl}" ]]; then
        printf '%s\n' "keyring: openssl not executable: ${ssl}" >&2
        return 1
    fi
    if ! _keyring_openssl_below_min_warn_ack; then
        return 1
    fi
    if [[ "${KEYRING_INTERNAL_SKIP_DEK_SMOKE:-}" == 1 ]]; then
        return 0
    fi
    if ! _keyring_dek_wrap_smoke; then
        return 1
    fi
    return 0
}

# Header bytes 8–9 can be 0x00 (e.g. format minor 0). Bash variables treat
# NUL as end-of-string, so never parse the 16-byte header with ${var:offset}.
_keyring_dek_read_byte_at() {
    local path="${1}"
    local skip="${2}"
    local b
    b=$(dd if="${path}" bs=1 skip="${skip}" count=1 status=none 2>/dev/null \
      | LC_ALL=C od -An -v -tu1 | awk 'NF {print $1; exit}')
    [[ -n "${b}" ]] || return 1
    printf '%d' "${b}"
}

_keyring_dek_read_u16_be_from_file() {
    local path="${1}"
    local off="${2}"
    local h0 h1
    h0=$(_keyring_dek_read_byte_at "${path}" "${off}") || return 1
    h1=$(_keyring_dek_read_byte_at "${path}" $(( off + 1 ))) || return 1
    printf '%d' $(( h0 * 256 + h1 ))
}

_keyring_dek_read_u32_be_from_file() {
    local path="${1}"
    local off="${2}"
    local n=0 i b
    for (( i = 0; i < 4; i++ )); do
        b=$(_keyring_dek_read_byte_at "${path}" $(( off + i ))) || return 1
        n=$(( n * 256 + b ))
    done
    printf '%d' "${n}"
}

_keyring_dek_header_matches_recipe() {
    local path magic_from hmaj hmin plen fsz rid_file
    path="${_KEYRING_DEK_PARSE_PATH}"
    magic_from=$(LC_ALL=C head -c 8 "${path}") || return 1
    if [[ "${magic_from}" != "${_KEYRING_RW_MAGIC}" ]]; then
        printf '%s\n' 'keyring: dek.encrypted magic mismatch' >&2
        return 1
    fi
    hmaj=$(_keyring_dek_read_byte_at "${path}" 8) || return 1
    hmin=$(_keyring_dek_read_byte_at "${path}" 9) || return 1
    if [[ "${hmaj}" -ne "${_KEYRING_RW_HEADER_MAJ}" ]] || \
      [[ "${hmin}" -ne "${_KEYRING_RW_HEADER_MIN}" ]]; then
        printf '%s\n' \
          'keyring: dek.encrypted header format mismatch for this recipe' \
          >&2
        return 1
    fi
    rid_file=$(_keyring_dek_read_u16_be_from_file "${path}" 10) || return 1
    if [[ "${rid_file}" -ne $((10#${_KEYRING_RW_RECIPE_NN})) ]]; then
        printf '%s\n' 'keyring: header recipe id mismatch' >&2
        return 1
    fi
    plen=$(_keyring_dek_read_u32_be_from_file "${path}" 12) || return 1
    fsz=$(stat -c '%s' "${path}" 2>/dev/null) || return 1
    if [[ "${plen}" -lt 1 ]] || [[ $(( 16 + plen )) -ne "${fsz}" ]]; then
        printf '%s\n' \
          'keyring: dek.encrypted size does not match header payload length' \
          >&2
        return 1
    fi
    _KEYRING_DEK_PARSED_PLEN="${plen}"
    return 0
}

_keyring_append_u16_be() {
    local n="${1}"
    local f="${2}"
    printf '%b' "$(printf '\\%03o\\%03o' \
      $(( (n >> 8) & 255 )) $(( n & 255 )) )" >> "${f}"
}

_keyring_append_u32_be() {
    local n="${1}"
    local f="${2}"
    printf '%b' "$(printf '\\%03o\\%03o\\%03o\\%03o' \
      $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
      $(( (n >> 8) & 255 )) $(( n & 255 )) )" >> "${f}"
}

keyring_write_dek_meta() {
    local dek_path="${1}"
    local recipe_nn="${2}"
    local meta ssl line iso
    meta="${dek_path}.meta"
    ssl="$(keyring_openssl_bin)"
    line=$("${ssl}" version 2>/dev/null | head -1)
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' 'unknown')
    {
        printf '%s\n' '# AUTOGENERATED by util keyring — do not edit by hand.'
        printf '%s\n' "RECIPE_ID=${recipe_nn}"
        printf '%s\n' "OPENSSL_MIN_VERSION=${_KEYRING_RW_OPENSSL_MIN}"
        printf '%s\n' "OPENSSL_TESTED_WITH=${_KEYRING_RW_OPENSSL_TESTED}"
        printf '%s\n' "WRAPPED_AT=${iso}"
        printf '%s\n' "OPENSSL_VERSION_LINE=${line}"
        printf '%s\n' \
          "DETAIL=DEK wrapped with openssl enc; see dek-wrap-recipes/."
    } > "${meta}.new" || return 1
    chmod 600 "${meta}.new" || {
        rm -f "${meta}.new"
        return 1
    }
    mv -f "${meta}.new" "${meta}" || return 1
    return 0
}

keyring_check_prereqs() {
    # Check all prerequisites for full keyring functionality.
    # Returns 0 if all present, 1 otherwise. Prints missing items to stderr.
    local missing=()
    local ssl rdir
    if ! command -v keyctl >/dev/null 2>&1; then
        missing+=('keyctl: apt install keyutils')
    fi
    if ! command -v sops >/dev/null 2>&1; then
        missing+=('sops: https://github.com/getsops/sops/releases or: ' \
          'go install github.com/getsops/sops/v3/cmd/sops@latest')
    fi
    if ! command -v age-keygen >/dev/null 2>&1; then
        missing+=('age-keygen: apt install age')
    fi
    if ! command -v age >/dev/null 2>&1; then
        missing+=('age: apt install age (encrypt.sh and age workflows)')
    fi
    ssl="$(keyring_openssl_bin)"
    if [[ ! -x "${ssl}" ]]; then
        missing+=("openssl: not executable at ${ssl}; install openssl or set" \
          ' KEYRING_OPENSSL_BIN')
    fi
    rdir="$(_keyring_recipes_dir)"
    if [[ ! -f "${rdir}/dek-wrap-recipe-01.conf" ]]; then
        missing+=("DEK wrap recipe missing: ${rdir}/dek-wrap-recipe-01.conf")
    fi
    if [[ ! -d /dev/shm ]]; then
        missing+=('/dev/shm: Linux tmpfs required (not available)')
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf '%s\n' 'keyring: missing prerequisites:' >&2
        for m in "${missing[@]}"; do
            printf '%s\n' "  - ${m}" >&2
        done
        printf '%s\n' '' >&2
        return 1
    fi
    if ! _keyring_dek_recipe_load_from_nn '01'; then
        return 1
    fi
    if ! _keyring_openssl_below_min_warn_ack; then
        return 1
    fi
    if ! _keyring_dek_wrap_smoke; then
        return 1
    fi
    return 0
}

keyring_no_debug() {
    # Return 0 if safe to handle secrets (no xtrace/verbose).
    # Exit with error otherwise; both can leak passphrase.
    local _msg
    if [[ -o xtrace ]]; then
        _msg='keyring: refused (xtrace enabled would leak passphrase).'
        _msg+=' Disable with set +x.'
        printf '%s\n' "${_msg}" >&2
        return 1
    fi
    if [[ -o verbose ]]; then
        _msg='keyring: refused (verbose mode would leak passphrase).'
        _msg+=' Disable with set +v.'
        printf '%s\n' "${_msg}" >&2
        return 1
    fi
    return 0
}

keyring_get_keyring() {
    # Returns keyring to use: persistent keyring ID (Ubuntu) or
    # @u (WSL2 fallback). Persistent preferred; @u when
    # get_persistent fails.
    local persistent_id
    persistent_id=$(keyctl get_persistent @s 2>/dev/null)
    if [[ -n "${persistent_id}" ]]; then
        printf '%s\n' "${persistent_id}"
    else
        printf '%s\n' '@u'
    fi
}

keyring_check_keyring() {
    # Check if keyctl is available and a usable keyring exists
    if ! command -v keyctl >/dev/null 2>&1; then
        printf '%s\n' 'keyring: keyctl not found (install keyutils)' >&2
        return 1
    fi
    local keyring_id
    keyring_id=$(keyring_get_keyring)
    if [[ -z "${keyring_id}" ]]; then
        printf '%s\n' 'keyring: no keyring available' >&2
        return 1
    fi
    if [[ "${keyring_id}" = '@u' ]] && \
      ! keyctl show @u >/dev/null 2>&1; then
        printf '%s\n' 'keyring: user keyring not available' >&2
        return 1
    fi
    return 0
}

keyring_decrypt_dek_with_kek() {
    # Unwrap dek.encrypted: util header + openssl enc (PBKDF2). KEK material is
    # SHA-256 hex of user passphrase (written to a tmp pass file for openssl).
    # Args: kek_material, enc_path, [out_path]. If out_path is set, write
    # cleartext there; otherwise write DEK to stdout (via tmp file).
    local kek_material="${1}"
    local enc_path="${2}"
    local out_path="${3-}"
    local ssl rid _tmp passf payf _fsz plen
    ssl="$(keyring_openssl_bin)"
    if [[ ! -x "${ssl}" ]]; then
        return 1
    fi
    _fsz=$(stat -c '%s' "${enc_path}" 2>/dev/null) || return 1
    if [[ "${_fsz}" -lt 16 ]]; then
        printf '%s\n' \
          'keyring: dek.encrypted too small or corrupt' \
          ' (expected util header).' >&2
        return 1
    fi
    rid=$(_keyring_dek_read_u16_be_from_file "${enc_path}" 10) || {
        printf '%s\n' 'keyring: could not read dek.encrypted header' >&2
        return 1
    }
    if ! _keyring_dek_recipe_load_from_numeric_id "${rid}"; then
        return 1
    fi
    _KEYRING_DEK_PARSE_PATH="${enc_path}"
    if ! _keyring_dek_header_matches_recipe; then
        return 1
    fi
    if ! _keyring_openssl_below_min_warn_ack; then
        return 1
    fi
    plen="${_KEYRING_DEK_PARSED_PLEN}"
    payf="$(mktemp /dev/shm/keyring-dek-payload.XXXXXX)" || return 1
    passf="$(mktemp /dev/shm/keyring-dek-pass.XXXXXX)" || {
        rm -f "${payf}"
        return 1
    }
    chmod 600 "${payf}" "${passf}" || {
        rm -f "${payf}" "${passf}"
        return 1
    }
    if ! tail -c "${plen}" "${enc_path}" > "${payf}"; then
        rm -f "${payf}" "${passf}"
        return 1
    fi
    if ! printf '%s' "${kek_material}" > "${passf}"; then
        rm -f "${payf}" "${passf}"
        return 1
    fi
    if [[ -n "${out_path}" ]]; then
        if ! "${ssl}" enc -d "-${_KEYRING_RW_CIPHER}" -pbkdf2 \
          -iter "${_KEYRING_RW_ITER}" -md "${_KEYRING_RW_MD}" \
          -pass "file:${passf}" -in "${payf}" -out "${out_path}"; then
            rm -f "${payf}" "${passf}"
            return 1
        fi
        rm -f "${payf}" "${passf}"
        return 0
    fi
    _tmp="$(mktemp /dev/shm/keyring-dek.XXXXXX)" || {
        rm -f "${payf}" "${passf}"
        return 1
    }
    chmod 600 "${_tmp}" || {
        rm -f "${payf}" "${passf}" "${_tmp}"
        return 1
    }
    if ! "${ssl}" enc -d "-${_KEYRING_RW_CIPHER}" -pbkdf2 \
      -iter "${_KEYRING_RW_ITER}" -md "${_KEYRING_RW_MD}" \
      -pass "file:${passf}" -in "${payf}" -out "${_tmp}"; then
        rm -f "${payf}" "${passf}" "${_tmp}"
        return 1
    fi
    rm -f "${payf}" "${passf}"
    cat "${_tmp}"
    rm -f "${_tmp}"
    return 0
}

keyring_encrypt_dek_with_kek() {
    # Wrap age DEK plaintext with KEK via openssl enc into dek.encrypted
    # (16-byte util header + openssl ciphertext). Optional 4th arg: recipe
    # numeric id (default 1). Honors KEYRING_INTERNAL_SKIP_DEK_SMOKE=1 to skip
    # redundant smoke when check_prereqs already ran.
    local kek_material="${1}"
    local dek_plain="${2}"
    local out_path="${3}"
    local recipe_num="${4:-1}"
    local ssl _dir _plain_tmp _pay_tmp _hdr_tmp _full_tmp passf plen nn
    ssl="$(keyring_openssl_bin)"
    if [[ ! -x "${ssl}" ]]; then
        return 1
    fi
    if ! _keyring_dek_recipe_load_from_numeric_id "${recipe_num}"; then
        return 1
    fi
    if ! _keyring_dek_prepare_openssl_for_recipe; then
        return 1
    fi
    _dir="$(dirname "${out_path}")"
    if [[ ! -d "${_dir}" ]]; then
        return 1
    fi
    _plain_tmp="$(mktemp /dev/shm/keyring-wrap-plain.XXXXXX)" || return 1
    chmod 600 "${_plain_tmp}" || {
        rm -f "${_plain_tmp}"
        return 1
    }
    if ! printf '%s' "${dek_plain}" > "${_plain_tmp}"; then
        rm -f "${_plain_tmp}"
        return 1
    fi
    passf="$(mktemp /dev/shm/keyring-wrap-pass.XXXXXX)" || {
        rm -f "${_plain_tmp}"
        return 1
    }
    chmod 600 "${passf}" || {
        rm -f "${_plain_tmp}" "${passf}"
        return 1
    }
    if ! printf '%s' "${kek_material}" > "${passf}"; then
        rm -f "${_plain_tmp}" "${passf}"
        return 1
    fi
    _pay_tmp="$(mktemp "${_dir}/.dek-payload.XXXXXX.tmp")" || {
        rm -f "${_plain_tmp}" "${passf}"
        return 1
    }
    chmod 600 "${_pay_tmp}" || {
        rm -f "${_plain_tmp}" "${passf}" "${_pay_tmp}"
        return 1
    }
    if ! "${ssl}" enc -e "-${_KEYRING_RW_CIPHER}" -salt -pbkdf2 \
      -iter "${_KEYRING_RW_ITER}" -md "${_KEYRING_RW_MD}" \
      -pass "file:${passf}" -out "${_pay_tmp}" -in "${_plain_tmp}"; then
        rm -f "${_plain_tmp}" "${passf}" "${_pay_tmp}"
        return 1
    fi
    rm -f "${_plain_tmp}" "${passf}"
    plen=$(stat -c '%s' "${_pay_tmp}") || {
        rm -f "${_pay_tmp}"
        return 1
    }
    if [[ "${plen}" -lt 1 ]]; then
        rm -f "${_pay_tmp}"
        return 1
    fi
    _hdr_tmp="$(mktemp "${_dir}/.dek-hdr.XXXXXX.tmp")" || {
        rm -f "${_pay_tmp}"
        return 1
    }
    chmod 600 "${_hdr_tmp}" || {
        rm -f "${_pay_tmp}" "${_hdr_tmp}"
        return 1
    }
    if ! printf '%s' "${_KEYRING_RW_MAGIC}" > "${_hdr_tmp}"; then
        rm -f "${_pay_tmp}" "${_hdr_tmp}"
        return 1
    fi
    printf '%b' "$(printf '\\%03o\\%03o' \
      "$((_KEYRING_RW_HEADER_MAJ + 0))" \
      "$((_KEYRING_RW_HEADER_MIN + 0))")" >> "${_hdr_tmp}" || {
        rm -f "${_pay_tmp}" "${_hdr_tmp}"
        return 1
    }
    _keyring_append_u16_be "$((10#${_KEYRING_RW_RECIPE_NN}))" "${_hdr_tmp}" \
      || {
        rm -f "${_pay_tmp}" "${_hdr_tmp}"
        return 1
    }
    _keyring_append_u32_be "${plen}" "${_hdr_tmp}" || {
        rm -f "${_pay_tmp}" "${_hdr_tmp}"
        return 1
    }
    _full_tmp="$(mktemp "${_dir}/.dek-full.XXXXXX.tmp")" || {
        rm -f "${_pay_tmp}" "${_hdr_tmp}"
        return 1
    }
    chmod 600 "${_full_tmp}" || {
        rm -f "${_pay_tmp}" "${_hdr_tmp}" "${_full_tmp}"
        return 1
    }
    if ! cat "${_hdr_tmp}" "${_pay_tmp}" > "${_full_tmp}"; then
        rm -f "${_pay_tmp}" "${_hdr_tmp}" "${_full_tmp}"
        return 1
    fi
    rm -f "${_hdr_tmp}" "${_pay_tmp}"
    if ! mv -f "${_full_tmp}" "${out_path}"; then
        rm -f "${_full_tmp}"
        return 1
    fi
    chmod 600 "${out_path}" || return 1
    printf -v nn '%02d' "${recipe_num}"
    keyring_write_dek_meta "${out_path}" "${nn}" || return 1
    return 0
}

keyring_test_decryption() {
    # Verify decryption will work (KEK, DEK, optionally keyring-test.enc).
    # Uses the same shell as the caller so _KEYRING_DATA_DIR matches init
    # (subprocess get-dek.sh only sees exported env; unexported KEYRING_DATA_DIR
    # would point at the wrong dek.encrypted).
    # Returns 0 if OK, 1 otherwise. Prints to stderr on failure.
    local test_enc="${_KEYRING_DATA_DIR}/keyring-test.enc"
    local key_file dek_file kek
    if ! keyring_no_debug; then
        return 1
    fi
    if ! keyring_check_keyring; then
        return 1
    fi
    dek_file="${_KEYRING_DATA_DIR}/dek.encrypted"
    kek=$(keyring_get_kek) || true
    if [[ -z "${kek}" ]]; then
        return 1
    fi
    if [[ ! -f "${dek_file}" ]]; then
        kek=''
        return 1
    fi
    if ! keyring_decrypt_dek_with_kek "${kek}" "${dek_file}" "/dev/null"; then
        kek=''
        return 1
    fi
    if [[ -f "${test_enc}" ]] && command -v sops >/dev/null 2>&1; then
        key_file="/dev/shm/keyring-check-key-$$"
        trap 'rm -f "${key_file}" 2>/dev/null' RETURN
        if ! keyring_decrypt_dek_with_kek "${kek}" "${dek_file}" \
          "${key_file}"; then
            kek=''
            return 1
        fi
        kek=''
        chmod 600 "${key_file}"
        if ! SOPS_AGE_KEY_FILE="${key_file}" sops -d "${test_enc}" \
          >/dev/null 2>&1; then
            printf '%s\n' 'keyring: cannot decrypt keyring-test.enc' >&2
            return 1
        fi
    else
        kek=''
    fi
    return 0
}

keyring_kek_exists() {
    # Return 0 if KEK exists in keyring, 1 otherwise
    local keyring_id
    keyring_id=$(keyring_get_keyring)
    if [[ -n "${keyring_id}" ]]; then
        keyctl search "${keyring_id}" user \
            "${KEYRING_KEK_KEY_NAME}" >/dev/null 2>&1
    else
        return 1
    fi
}

_keyring_dek_decrypt_fail() {
    local dek_path="${1}"
    local init_path rotate_path test_enc_path _run_again
    init_path="$(realpath "${_KEYRING_DIR}/init.bash" 2>/dev/null || \
      printf '%s' "${_KEYRING_DIR}/init.bash")"
    rotate_path="$(realpath "${_KEYRING_DIR}/rotate-kek.sh" 2>/dev/null || \
      printf '%s' "${_KEYRING_DIR}/rotate-kek.sh")"
    test_enc_path="$(realpath "${_KEYRING_DATA_DIR}/keyring-test.enc" \
      2>/dev/null || printf '%s' "${_KEYRING_DATA_DIR}/keyring-test.enc")"
    printf '%s\n' "keyring: WARNING:" >&2
    printf '%s\n' "  passphrase cannot decrypt DEK at ${dek_path}" >&2
    _run_again='keyring: Run init again with the passphrase used when'
    _run_again+=' encrypting:'
    printf '%s\n' "${_run_again}" >&2
    printf '%s\n' "  source ${init_path}" >&2
    printf '%s\n' 'keyring: Or delete and start from scratch' >&2
    printf '%s\n' '  (' >&2
    printf '%s\n' '    WARNING: This will make' >&2
    printf '%s\n' '    any data encrypted with the DEK unrecoverable' >&2
    printf '%s\n' '  ):' >&2
    printf '%s\n' "  rm -f ${dek_path} ${test_enc_path}" >&2
    printf '%s\n' "  source ${init_path}" >&2
    printf '%s\n' "  ${rotate_path}" >&2
}

keyring_init() {
    # Prompt for passphrase (no echo), hash with SHA256, store in
    # persistent keyring.
    # If dek.encrypted exists: one prompt; correctness checked by decrypt.
    # If no DEK yet (new passphrase): two prompts and they must match.
    # Idempotent: if KEK already exists, does nothing.
    # Returns 0 on success, 1 on failure.
    if ! keyring_check_keyring; then
        return 1
    fi

    if keyring_kek_exists; then
        if keyring_test_decryption; then
            printf '%s\n' 'keyring: ready (decryption verified)' >&2
        else
            printf '%s\n' 'keyring: ready (KEK in keyring)' >&2
        fi
        return 0
    fi

    if ! keyring_no_debug; then
        return 1
    fi

    local passphrase
    local passphrase_confirm
    local hash
    local keyring_id
    local dek_file="${_KEYRING_DATA_DIR}/dek.encrypted"
    local prompt_msg
    local confirm_msg="Confirm passphrase: "

    if [[ -f "${dek_file}" ]]; then
        prompt_msg="Enter keyring passphrase (verified against DEK, "
        prompt_msg+="stored in kernel keyring for this session): "
        if ! read -r -s -p "${prompt_msg}" passphrase; then
            printf '%s\n' '' >&2
            printf '%s\n' 'keyring: failed to read passphrase' >&2
            passphrase=''
            passphrase_confirm=''
            return 1
        fi
        printf '%s\n' '' >&2
        passphrase_confirm=''
    else
        prompt_msg="Enter keyring passphrase (stored in kernel "
        prompt_msg+="keyring for this user until logout/reboot): "
        if ! read -r -s -p "${prompt_msg}" passphrase; then
            printf '%s\n' '' >&2
            printf '%s\n' 'keyring: failed to read passphrase' >&2
            passphrase=''
            passphrase_confirm=''
            return 1
        fi
        printf '%s\n' '' >&2

        if ! read -r -s -p "${confirm_msg}" passphrase_confirm; then
            printf '%s\n' '' >&2
            printf '%s\n' \
              'keyring: failed to read passphrase confirmation' >&2
            passphrase=''
            passphrase_confirm=''
            return 1
        fi
        printf '%s\n' '' >&2
    fi

    # Clear passphrase on exit (error, signal, or normal)
    trap 's=${?}; passphrase=""; passphrase_confirm=""; exit ${s}' EXIT

    if [[ -z "${passphrase}" ]]; then
        printf '%s\n' 'keyring: passphrase cannot be empty' >&2
        passphrase=''
        passphrase_confirm=''
        trap - EXIT
        return 1
    fi

    if [[ ! -f "${dek_file}" ]]; then
        if [[ "${passphrase}" != "${passphrase_confirm}" ]]; then
            printf '%s\n' 'keyring: passphrases do not match' >&2
            passphrase=''
            passphrase_confirm=''
            trap - EXIT
            return 1
        fi
    fi

    if ! hash=$(printf '%s' "${passphrase}" | sha256sum 2>/dev/null | \
      cut -d' ' -f1); then
        printf '%s\n' 'keyring: failed to hash passphrase' >&2
        passphrase=''
        passphrase_confirm=''
        trap - EXIT
        return 1
    fi

    # When DEK exists, verify passphrase can decrypt it before storing KEK
    local test_enc="${_KEYRING_DATA_DIR}/keyring-test.enc"
    local key_file decrypted
    local dek_file_abs
    dek_file_abs="$(realpath "${dek_file}" 2>/dev/null || \
      printf '%s' "${dek_file}")"

    if [[ -f "${dek_file}" ]]; then
        key_file="/dev/shm/keyring-init-key-$$"
        trap 'rm -f "${key_file}" 2>/dev/null' RETURN
        if ! keyring_decrypt_dek_with_kek "${hash}" "${dek_file}" \
          "${key_file}"; then
            _keyring_dek_decrypt_fail "${dek_file_abs}"
            passphrase=''
            passphrase_confirm=''
            trap - EXIT
            return 1
        fi
        if [[ ! -s "${key_file}" ]]; then
            _keyring_dek_decrypt_fail "${dek_file_abs}"
            passphrase=''
            passphrase_confirm=''
            trap - EXIT
            return 1
        fi
        if [[ -f "${test_enc}" ]]; then
            decrypted=$(SOPS_AGE_KEY_FILE="${key_file}" sops -d "${test_enc}" \
              2>/dev/null)
            rm -f "${key_file}" 2>/dev/null
            # Human-readable decrypted content indicates success (cleartext may
            # have changed since encryption; exact match not required)
            if [[ -z "${decrypted}" ]] || \
              ! [[ "${decrypted}" =~ ^[[:print:][:space:]]+$ ]]; then
                printf '%s\n' \
                  'keyring: passphrase cannot decrypt keyring-test.enc' >&2
                passphrase=''
                passphrase_confirm=''
                trap - EXIT
                return 1
            fi
            printf '%s\n' \
              'keyring: initialized (keyring-test.enc decrypted)' >&2
        else
            rm -f "${key_file}" 2>/dev/null
            local rotate_script _rot
            _rot="${_KEYRING_DIR}/rotate-kek.sh"
            rotate_script="$(realpath "${_rot}" 2>/dev/null || \
              printf '%s' "${_rot}")"
            printf '%s\n' \
              'keyring: initialized (keyring-test.enc missing). Run:' >&2
            printf '%s\n' "  ${rotate_script}" >&2
            printf '%s\n' '  to create keyring-test.enc for validation.' >&2
        fi
    else
        local rotate_script _rot
        _rot="${_KEYRING_DIR}/rotate-kek.sh"
        rotate_script="$(realpath "${_rot}" 2>/dev/null || \
          printf '%s' "${_rot}")"
        printf '%s\n' 'keyring: initialized (no DEK yet). Run:' >&2
        printf '%s\n' "  ${rotate_script}" >&2
        printf '%s\n' \
          '  to create encryption keys and enable config decryption.' >&2
    fi

    passphrase=''
    passphrase_confirm=''
    trap - EXIT

    keyring_id=$(keyring_get_keyring)
    if [[ -z "${keyring_id}" ]]; then
        printf '%s\n' 'keyring: failed to get keyring' >&2
        return 1
    fi

    if ! keyctl add user "${KEYRING_KEK_KEY_NAME}" "${hash}" \
      "${keyring_id}" >/dev/null 2>&1; then
        printf '%s\n' 'keyring: failed to add key to keyring' >&2
        return 1
    fi

    return 0
}

keyring_get_kek() {
    # Output KEK to stdout. Returns 0 if found, 1 otherwise.
    # Use: kek=$(keyring_get_kek) or keyring_get_kek | some_command
    if ! keyring_no_debug; then
        return 1
    fi
    if ! keyring_check_keyring; then
        return 1
    fi

    local keyring_id
    keyring_id=$(keyring_get_keyring)
    if [[ -z "${keyring_id}" ]]; then
        printf '%s\n' 'keyring: failed to get keyring' >&2
        return 1
    fi

    local key_id
    key_id=$(keyctl search "${keyring_id}" user \
      "${KEYRING_KEK_KEY_NAME}" 2>/dev/null)
    if [[ -z "${key_id}" ]]; then
        return 1
    fi

    keyctl pipe "${key_id}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Interactive cleartext-in-/dev/shm workflows (age encrypt.sh / decrypt.sh and
# secconfig sops scripts). Callers must set WE_MSG_PREFIX before use.
# ---------------------------------------------------------------------------

we_print_edit_instructions() {
    # Cleartext editing instructions (path is the /dev/shm file to edit).
    local _plain="${1}"
    printf '%s\n' ""
    printf '%s\n' "Plaintext file (edit and save however you prefer):"
    printf '%s\n' "  ${_plain}"
    printf '%s\n' ""
    printf '%s\n' \
        "After saving, return here and press Enter. The plaintext will be" \
        "removed once encryption succeeds or if you exit (Ctrl-C) this script."
    printf '%s\n' ""
}

we_ensure_plain_nonempty_or_confirm() {
    # After first Enter: if file still 0 bytes, prompt p/e/a.
    local _pf="${1}"
    local _ch
    while [[ ! -s "${_pf}" ]]; do
        printf '%s\n' '' >&2
        printf '%s\n' 'Plaintext file is empty (0 bytes).' >&2
        printf '%s\n' \
            '  p — Proceed and encrypt empty content' >&2
        printf '%s\n' \
            '  e — Edit the file more; press Enter here when done' >&2
        printf '%s\n' '  a — Abort' >&2
        printf '%s' 'Choice [p/e/a]: ' >&2
        read -r _ch
        case "${_ch}" in
            p|P)
                return 0
                ;;
            e|E)
                printf '%s\n' "  File: ${_pf}" >&2
                printf '%s' \
                    'Press Enter when you have saved and want to continue... ' \
                    >&2
                read -r _
                ;;
            a|A|abort|Abort|ABORT)
                printf '%s\n' "${WE_MSG_PREFIX}: aborted" >&2
                exit 1
                ;;
            *)
                printf '%s\n' 'Invalid choice; use p, e, or a.' >&2
                ;;
        esac
    done
    return 0
}

we_prompt_press_enter_after_edit() {
    # Arg: prompt verb (e.g. encrypt | re-encrypt).
    local _verb="${1:-encrypt}"
    printf '%s' \
        "Press Enter when the file is saved and you want to ${_verb}... "
    read -r _
}

we_read_new_encrypted_path_and_mkdir() {
    # Read final path, optional mkdir -p; sets WE_OUT_FINAL.
    local _out_raw _odir _mk
    printf '%s' 'Full path for new encrypted file: ' >&2
    read -r _out_raw
    if [[ -z "${_out_raw}" ]]; then
        printf '%s\n' "${WE_MSG_PREFIX}: no output path" >&2
        exit 1
    fi
    WE_OUT_FINAL="$(realpath -m "${_out_raw}")"
    _odir="$(dirname "${WE_OUT_FINAL}")"
    if [[ ! -d "${_odir}" ]]; then
        printf '%s' "Create directory ${_odir}? [y/N] " >&2
        read -r _mk
        if [[ "${_mk}" != y ]]; then
            printf '%s\n' "${WE_MSG_PREFIX}: cancelled" >&2
            exit 1
        fi
        mkdir -p "${_odir}"
    fi
}

we_confirm_overwrite() {
    # If path exists, require y to overwrite. Returns 1 if user declines.
    local _path="${1}"
    local _reply
    if [[ ! -e "${_path}" ]]; then
        return 0
    fi
    printf '%s\n' "Path already exists: ${_path}" >&2
    printf '%s' 'Overwrite? [y/N] ' >&2
    read -r _reply
    if [[ "${_reply}" != y ]]; then
        printf '%s\n' "${WE_MSG_PREFIX}: cancelled" >&2
        return 1
    fi
    return 0
}

we_backup_resolve_and_mv_live() {
    # Resolve backup path, mv live ciphertext to backup; sets WE_BACKUP.
    local _enc_in="${1}"
    local _default_backup="${_enc_in}.old"
    local _backup="" _backup_raw _backup_dir _reply _retry
    printf '%s\n' \
        "Backup path for the current encrypted file (default below)." >&2
    printf '%s\n' "  Default: ${_default_backup}" >&2
    printf '%s' 'Enter backup path, or Enter for default: ' >&2
    read -r _backup_raw
    if [[ -z "${_backup_raw}" ]]; then
        _backup="${_default_backup}"
    else
        _backup="$(realpath -m "${_backup_raw}")"
    fi

    while true; do
        _backup_dir="$(dirname "${_backup}")"
        if [[ ! -d "${_backup_dir}" ]]; then
            printf '%s\n' \
                "${WE_MSG_PREFIX}: backup directory missing: ${_backup_dir}" \
                >&2
            printf '%s' 'Enter a new backup path, or type abort: ' >&2
            read -r _retry
            case "${_retry}" in
                abort|Abort|ABORT)
                    printf '%s\n' "${WE_MSG_PREFIX}: aborted" >&2
                    exit 1
                    ;;
            esac
            if [[ -z "${_retry}" ]]; then
                continue
            fi
            _backup="$(realpath -m "${_retry}")"
            continue
        fi

        if [[ -e "${_backup}" ]]; then
            printf '%s\n' "Path already exists: ${_backup}" >&2
            printf '%s' 'Overwrite? [y/N] ' >&2
            read -r _reply
            if [[ "${_reply}" != y ]]; then
                printf '%s\n' \
                    'Enter a new backup path, or type abort to exit:' >&2
                printf '%s' '> ' >&2
                read -r _retry
                case "${_retry}" in
                    abort|Abort|ABORT)
                        printf '%s\n' "${WE_MSG_PREFIX}: aborted" >&2
                        exit 1
                        ;;
                esac
                if [[ -z "${_retry}" ]]; then
                    continue
                fi
                _backup="$(realpath -m "${_retry}")"
                continue
            fi
        fi

        if mv -f "${_enc_in}" "${_backup}"; then
            printf '%s\n' "Previous ciphertext moved to: ${_backup}" >&2
            export WE_BACKUP="${_backup}"
            return 0
        fi

        printf '%s\n' \
            "${WE_MSG_PREFIX}: could not move ciphertext to ${_backup}" >&2
        printf '%s\n' \
            '(check permissions). Enter a different backup path, or abort:' >&2
        printf '%s' '> ' >&2
        read -r _retry
        case "${_retry}" in
            abort|Abort|ABORT)
                printf '%s\n' "${WE_MSG_PREFIX}: aborted" >&2
                exit 1
                ;;
        esac
        if [[ -z "${_retry}" ]]; then
            continue
        fi
        _backup="$(realpath -m "${_retry}")"
    done
}

we_optional_delete_backup_prompt() {
    local _backup="${1}"
    local _delb
    printf '%s' "Delete backup at ${_backup}? [y/N] " >&2
    read -r _delb
    if [[ "${_delb}" == y ]]; then
        rm -f "${_backup}"
        printf '%s\n' "Deleted backup." >&2
    else
        printf '%s\n' "Backup kept at ${_backup}" >&2
    fi
}

we_require_shm() {
    if [[ ! -d /dev/shm ]]; then
        printf '%s\n' "${WE_MSG_PREFIX}: /dev/shm not found" >&2
        exit 1
    fi
}
