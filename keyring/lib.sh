# Bash secrets library - Linux kernel keyring + age/sops foundation
# Stores KEK (Key Encryption Key) in kernel keyring (per-user,
# survives logout); never cleartext on disk.
#
# Usage: source this file, then call secrets_init
# (e.g. from .profile or .bashrc)
#
# Keyring: Uses persistent keyring on Ubuntu server/workstation.
# Falls back to user keyring (@u) on WSL2 where get_persistent
# is not supported. Both provide user-scoped persistence.

if [[ -z "${SECRETS_KEYRING_KEY_NAME+x}" ]]; then
    readonly SECRETS_KEYRING_KEY_NAME='util_secrets_kek'
fi

_SECRETS_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

secrets_check_prereqs() {
    # Check all prerequisites for full secrets functionality.
    # Returns 0 if all present, 1 otherwise. Prints missing items to stderr.
    local missing=()
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
    if ! command -v openssl >/dev/null 2>&1; then
        missing+=('openssl: apt install openssl')
    fi
    if [[ ! -d /dev/shm ]]; then
        missing+=('/dev/shm: Linux tmpfs required (not available)')
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf '%s\n' 'secrets: missing prerequisites:' >&2
        for m in "${missing[@]}"; do
            printf '%s\n' "  - ${m}" >&2
        done
        printf '%s\n' '' >&2
        return 1
    fi
    return 0
}

secrets_no_debug() {
    # Return 0 if safe to handle secrets (no xtrace/verbose).
    # Exit with error otherwise; both can leak passphrase.
    local _msg
    if [[ -o xtrace ]]; then
        _msg='secrets: refused (xtrace enabled would leak passphrase).'
        _msg+=' Disable with set +x.'
        printf '%s\n' "${_msg}" >&2
        return 1
    fi
    if [[ -o verbose ]]; then
        _msg='secrets: refused (verbose mode would leak passphrase).'
        _msg+=' Disable with set +v.'
        printf '%s\n' "${_msg}" >&2
        return 1
    fi
    return 0
}

secrets_get_keyring() {
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

secrets_check_keyring() {
    # Check if keyctl is available and a usable keyring exists
    if ! command -v keyctl >/dev/null 2>&1; then
        printf '%s\n' 'secrets: keyctl not found (install keyutils)' >&2
        return 1
    fi
    local keyring_id
    keyring_id=$(secrets_get_keyring)
    if [[ -z "${keyring_id}" ]]; then
        printf '%s\n' 'secrets: no keyring available' >&2
        return 1
    fi
    if [[ "${keyring_id}" = '@u' ]] && \
      ! keyctl show @u >/dev/null 2>&1; then
        printf '%s\n' 'secrets: user keyring not available' >&2
        return 1
    fi
    return 0
}

secrets_decrypt_dek_with_kek() {
    # Decrypt dek.encrypted using KEK material (e.g. hex hash string).
    # Args: kek_material, enc_path, [out_path]. If out_path is set, write
    # cleartext there; otherwise write to stdout. Returns openssl status.
    local kek_material="${1}"
    local enc_path="${2}"
    local out_path="${3-}"
    if [[ -n "${out_path}" ]]; then
        openssl enc -d -aes-256-cbc -pbkdf2 \
          -pass file:<(printf '%s' "${kek_material}") -in "${enc_path}" \
          > "${out_path}" 2>/dev/null
    else
        openssl enc -d -aes-256-cbc -pbkdf2 \
          -pass file:<(printf '%s' "${kek_material}") -in "${enc_path}" \
          2>/dev/null
    fi
}

secrets_encrypt_dek_with_kek() {
    # Encrypt DEK plaintext with KEK material; writes dek.encrypted format.
    # Args: kek_material, dek_plaintext, out_path. Returns openssl status.
    local kek_material="${1}"
    local dek_plain="${2}"
    local out_path="${3}"
    printf '%s' "${dek_plain}" | openssl enc -aes-256-cbc -salt -pbkdf2 \
      -pass file:<(printf '%s' "${kek_material}") -out "${out_path}" \
      2>/dev/null
}

secrets_test_decryption() {
    # Verify decryption will work (KEK, DEK, optionally secrets-test.enc).
    # Returns 0 if OK, 1 otherwise. Prints to stderr on failure.
    local get_dek="${_SECRETS_DIR}/get-dek.sh"
    local test_enc="${_SECRETS_DIR}/secrets-test.enc"
    local key_file
    if ! "${get_dek}"; then
        return 1
    fi
    if [[ -f "${test_enc}" ]] && command -v sops >/dev/null 2>&1; then
        key_file="/dev/shm/secrets-check-key-$$"
        trap 'rm -f "${key_file}" 2>/dev/null' RETURN
        if ! "${get_dek}" -o "${key_file}" 2>/dev/null; then
            return 1
        fi
        chmod 600 "${key_file}"
        if ! SOPS_AGE_KEY_FILE="${key_file}" sops -d "${test_enc}" \
          >/dev/null 2>&1; then
            printf '%s\n' 'secrets: cannot decrypt secrets-test.enc' >&2
            return 1
        fi
    fi
    return 0
}

secrets_kek_exists() {
    # Return 0 if KEK exists in keyring, 1 otherwise
    local keyring_id
    keyring_id=$(secrets_get_keyring)
    [[ -n "${keyring_id}" ]] && \
      keyctl search "${keyring_id}" user \
      "${SECRETS_KEYRING_KEY_NAME}" >/dev/null 2>&1
}

_secrets_dek_decrypt_fail() {
    local dek_path="${1}"
    local init_path rotate_path test_enc_path _run_again
    init_path="$(realpath "${_SECRETS_DIR}/init.sh" 2>/dev/null || \
      printf '%s' "${_SECRETS_DIR}/init.sh")"
    rotate_path="$(realpath "${_SECRETS_DIR}/rotate-kek.sh" 2>/dev/null || \
      printf '%s' "${_SECRETS_DIR}/rotate-kek.sh")"
    test_enc_path="$(realpath "${_SECRETS_DIR}/secrets-test.enc" \
      2>/dev/null || printf '%s' "${_SECRETS_DIR}/secrets-test.enc")"
    printf '%s\n' "secrets: WARNING:" >&2
    printf '%s\n' "  passphrase cannot decrypt DEK at ${dek_path}" >&2
    _run_again='secrets: Run init again with the passphrase used when'
    _run_again+=' encrypting:'
    printf '%s\n' "${_run_again}" >&2
    printf '%s\n' "  source ${init_path}" >&2
    printf '%s\n' 'secrets: Or delete and start from scratch' >&2
    printf '%s\n' '  (' >&2
    printf '%s\n' '    WARNING: This will make' >&2
    printf '%s\n' '    any data encrypted with the DEK unrecoverable' >&2
    printf '%s\n' '  ):' >&2
    printf '%s\n' "  rm -f ${dek_path} ${test_enc_path}" >&2
    printf '%s\n' "  source ${init_path}" >&2
    printf '%s\n' "  ${rotate_path}" >&2
}

secrets_init() {
    # Prompt for passphrase (no echo), hash with SHA256, store in
    # persistent keyring.
    # Idempotent: if KEK already exists, does nothing.
    # Returns 0 on success, 1 on failure.
    if ! secrets_check_keyring; then
        return 1
    fi

    if secrets_kek_exists; then
        if secrets_test_decryption 2>/dev/null; then
            printf '%s\n' 'secrets: ready (decryption verified)' >&2
        else
            printf '%s\n' 'secrets: ready (KEK in keyring)' >&2
        fi
        return 0
    fi

    if ! secrets_no_debug; then
        return 1
    fi

    local prompt_msg="Enter secrets passphrase (stored in kernel "
    prompt_msg+="keyring for this user until logout/reboot): "
    local confirm_msg="Confirm passphrase: "
    local passphrase
    local passphrase_confirm
    local hash
    local keyring_id

    if ! read -r -s -p "${prompt_msg}" passphrase; then
        printf '%s\n' '' >&2
        printf '%s\n' 'secrets: failed to read passphrase' >&2
        passphrase=''
        passphrase_confirm=''
        return 1
    fi
    printf '%s\n' '' >&2

    if ! read -r -s -p "${confirm_msg}" passphrase_confirm; then
        printf '%s\n' '' >&2
        printf '%s\n' 'secrets: failed to read passphrase confirmation' >&2
        passphrase=''
        passphrase_confirm=''
        return 1
    fi
    printf '%s\n' '' >&2

    # Clear passphrase on exit (error, signal, or normal)
    trap 's=${?}; passphrase=""; passphrase_confirm=""; exit ${s}' EXIT

    if [[ -z "${passphrase}" ]]; then
        printf '%s\n' 'secrets: passphrase cannot be empty' >&2
        passphrase=''
        passphrase_confirm=''
        trap - EXIT
        return 1
    fi

    if [[ "${passphrase}" != "${passphrase_confirm}" ]]; then
        printf '%s\n' 'secrets: passphrases do not match' >&2
        passphrase=''
        passphrase_confirm=''
        trap - EXIT
        return 1
    fi

    if ! hash=$(printf '%s' "${passphrase}" | sha256sum 2>/dev/null | \
      cut -d' ' -f1); then
        printf '%s\n' 'secrets: failed to hash passphrase' >&2
        passphrase=''
        passphrase_confirm=''
        trap - EXIT
        return 1
    fi

    # When DEK exists, verify passphrase can decrypt it before storing KEK
    local dek_file="${_SECRETS_DIR}/dek.encrypted"
    local test_enc="${_SECRETS_DIR}/secrets-test.enc"
    local key_file decrypted
    local dek_file_abs
    dek_file_abs="$(realpath "${dek_file}" 2>/dev/null || \
      printf '%s' "${dek_file}")"

    if [[ -f "${dek_file}" ]]; then
        key_file="/dev/shm/secrets-init-key-$$"
        trap 'rm -f "${key_file}" 2>/dev/null' RETURN
        if ! secrets_decrypt_dek_with_kek "${hash}" "${dek_file}" \
          "${key_file}"; then
            _secrets_dek_decrypt_fail "${dek_file_abs}"
            passphrase=''
            passphrase_confirm=''
            trap - EXIT
            return 1
        fi
        if [[ ! -s "${key_file}" ]]; then
            _secrets_dek_decrypt_fail "${dek_file_abs}"
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
                  'secrets: passphrase cannot decrypt secrets-test.enc' >&2
                passphrase=''
                passphrase_confirm=''
                trap - EXIT
                return 1
            fi
            printf '%s\n' \
              'secrets: initialized (secrets-test.enc decrypted)' >&2
        else
            rm -f "${key_file}" 2>/dev/null
            local rotate_script _rot
            _rot="${_SECRETS_DIR}/rotate-kek.sh"
            rotate_script="$(realpath "${_rot}" 2>/dev/null || \
              printf '%s' "${_rot}")"
            printf '%s\n' \
              'secrets: initialized (secrets-test.enc missing). Run:' >&2
            printf '%s\n' "  ${rotate_script}" >&2
            printf '%s\n' '  to create secrets-test.enc for validation.' >&2
        fi
    else
        local rotate_script _rot
        _rot="${_SECRETS_DIR}/rotate-kek.sh"
        rotate_script="$(realpath "${_rot}" 2>/dev/null || \
          printf '%s' "${_rot}")"
        printf '%s\n' 'secrets: initialized (no DEK yet). Run:' >&2
        printf '%s\n' "  ${rotate_script}" >&2
        printf '%s\n' \
          '  to create encryption keys and enable config decryption.' >&2
    fi

    passphrase=''
    passphrase_confirm=''
    trap - EXIT

    keyring_id=$(secrets_get_keyring)
    if [[ -z "${keyring_id}" ]]; then
        printf '%s\n' 'secrets: failed to get keyring' >&2
        return 1
    fi

    if ! keyctl add user "${SECRETS_KEYRING_KEY_NAME}" "${hash}" \
      "${keyring_id}" >/dev/null 2>&1; then
        printf '%s\n' 'secrets: failed to add key to keyring' >&2
        return 1
    fi

    return 0
}

secrets_get_kek() {
    # Output KEK to stdout. Returns 0 if found, 1 otherwise.
    # Use: kek=$(secrets_get_kek) or secrets_get_kek | some_command
    if ! secrets_no_debug; then
        return 1
    fi
    if ! secrets_check_keyring; then
        return 1
    fi

    local keyring_id
    keyring_id=$(secrets_get_keyring)
    if [[ -z "${keyring_id}" ]]; then
        printf '%s\n' 'secrets: failed to get keyring' >&2
        return 1
    fi

    local key_id
    key_id=$(keyctl search "${keyring_id}" user \
      "${SECRETS_KEYRING_KEY_NAME}" 2>/dev/null)
    if [[ -z "${key_id}" ]]; then
        return 1
    fi

    keyctl pipe "${key_id}" 2>/dev/null
}
