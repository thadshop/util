# SOURCE ONLY — do not execute (`bash lib.bash`). Defines functions only.
# In Bash: source /path/to/lib.bash
#
# Bash keyring library - Linux kernel keyring + age/sops foundation
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

keyring_check_prereqs() {
    # Check all prerequisites for full keyring functionality.
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
        printf '%s\n' 'keyring: missing prerequisites:' >&2
        for m in "${missing[@]}"; do
            printf '%s\n' "  - ${m}" >&2
        done
        printf '%s\n' '' >&2
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

keyring_encrypt_dek_with_kek() {
    # Encrypt DEK plaintext with KEK material; writes dek.encrypted format.
    # Args: kek_material, dek_plaintext, out_path. Returns openssl status.
    local kek_material="${1}"
    local dek_plain="${2}"
    local out_path="${3}"
    printf '%s' "${dek_plain}" | openssl enc -aes-256-cbc -salt -pbkdf2 \
      -pass file:<(printf '%s' "${kek_material}") -out "${out_path}" \
      2>/dev/null
}

keyring_test_decryption() {
    # Verify decryption will work (KEK, DEK, optionally keyring-test.enc).
    # Returns 0 if OK, 1 otherwise. Prints to stderr on failure.
    local get_dek="${_KEYRING_DIR}/get-dek.sh"
    local test_enc="${_KEYRING_DIR}/keyring-test.enc"
    local key_file
    if ! "${get_dek}"; then
        return 1
    fi
    if [[ -f "${test_enc}" ]] && command -v sops >/dev/null 2>&1; then
        key_file="/dev/shm/keyring-check-key-$$"
        trap 'rm -f "${key_file}" 2>/dev/null' RETURN
        if ! "${get_dek}" -o "${key_file}" 2>/dev/null; then
            return 1
        fi
        chmod 600 "${key_file}"
        if ! SOPS_AGE_KEY_FILE="${key_file}" sops -d "${test_enc}" \
          >/dev/null 2>&1; then
            printf '%s\n' 'keyring: cannot decrypt keyring-test.enc' >&2
            return 1
        fi
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
    test_enc_path="$(realpath "${_KEYRING_DIR}/keyring-test.enc" \
      2>/dev/null || printf '%s' "${_KEYRING_DIR}/keyring-test.enc")"
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
        if keyring_test_decryption 2>/dev/null; then
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
    local dek_file="${_KEYRING_DIR}/dek.encrypted"
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
    local test_enc="${_KEYRING_DIR}/keyring-test.enc"
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
