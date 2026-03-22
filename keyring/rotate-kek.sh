#!/usr/bin/env bash
# Rotate the KEK and re-encrypt the DEK with the new KEK.
# If DEK does not exist, creates it (generates new age key).
# Requires: age-keygen, openssl, keyutils.
#
# The encrypted DEK is stored at:
#   <script_dir>/dek.encrypted

_script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
_dek_file="${_script_dir}/dek.encrypted"
# shellcheck source=lib.sh
source "${_script_dir}/lib.sh"

# Encrypt DEK with KEK using openssl (KEK from fd, no passphrase in argv)
_secrets_encrypt_dek() {
    local kek="${1}"
    local dek="${2}"
    local out_file="${3}"
    printf '%s' "${dek}" | openssl enc -aes-256-cbc -salt -pbkdf2 \
      -pass file:<(printf '%s' "${kek}") -out "${out_file}"
}

# Decrypt DEK with KEK (stderr suppressed; caller checks output format)
_secrets_decrypt_dek() {
    local kek="${1}"
    local enc_file="${2}"
    openssl enc -d -aes-256-cbc -pbkdf2 \
      -pass file:<(printf '%s' "${kek}") -in "${enc_file}" 2>/dev/null
}

_secrets_rotate_kek() {
    if ! secrets_no_debug; then
        return 1
    fi
    if ! secrets_check_keyring; then
        return 1
    fi

    local old_kek
    local new_kek
    local dek
    local new_passphrase
    local new_confirm
    local keyring_id
    local key_id

    old_kek=$(secrets_get_kek)
    if [[ -z "${old_kek}" ]]; then
        printf '%s\n' 'secrets: KEK not in keyring. Run:' >&2
        printf '%s\n' "  source ${_script_dir}/init.sh" >&2
        return 1
    fi

    if [[ -f "${_dek_file}" ]]; then
        dek=$(_secrets_decrypt_dek "${old_kek}" "${_dek_file}")
        if [[ -z "${dek}" ]] || \
          ! [[ "${dek}" =~ ^AGE-SECRET-KEY-1.+ ]]; then
            printf '%s\n' "secrets: failed to decrypt DEK at ${_dek_file}" \
              >&2
            printf '%s\n' '  (wrong passphrase?)' >&2
            old_kek=''
            return 1
        fi
    else
        printf '%s\n' "secrets: no DEK file at ${_dek_file}" >&2
        printf '%s\n' 'secrets: generating new age key as DEK...' >&2
        dek=$(age-keygen 2>/dev/null | grep -E '^AGE-SECRET-KEY-' || true)
        if [[ -z "${dek}" ]]; then
            printf '%s\n' 'secrets: age-keygen failed' >&2
            return 1
        fi
    fi

    printf '%s\n' 'Enter new passphrase (will become new KEK):' >&2
    if ! read -r -s -p "New passphrase: " new_passphrase; then
        printf '%s\n' '' >&2
        old_kek=''
        dek=''
        return 1
    fi
    printf '%s\n' '' >&2
    if ! read -r -s -p "Confirm new passphrase: " new_confirm; then
        printf '%s\n' '' >&2
        new_passphrase=''
        old_kek=''
        dek=''
        return 1
    fi
    printf '%s\n' '' >&2

    if [[ "${new_passphrase}" != "${new_confirm}" ]]; then
        printf '%s\n' 'secrets: passphrases do not match' >&2
        new_passphrase=''
        new_confirm=''
        old_kek=''
        dek=''
        return 1
    fi

    if [[ -z "${new_passphrase}" ]]; then
        printf '%s\n' 'secrets: passphrase cannot be empty' >&2
        new_passphrase=''
        new_confirm=''
        old_kek=''
        dek=''
        return 1
    fi

    new_kek=$(printf '%s' "${new_passphrase}" | sha256sum 2>/dev/null | \
      cut -d' ' -f1)
    new_passphrase=''
    new_confirm=''

    if [[ -z "${new_kek}" ]]; then
        printf '%s\n' 'secrets: failed to hash new passphrase' >&2
        old_kek=''
        dek=''
        return 1
    fi

    if ! _secrets_encrypt_dek "${new_kek}" "${dek}" "${_dek_file}"; then
        printf '%s\n' "secrets: failed to encrypt DEK at ${_dek_file}" >&2
        new_kek=''
        old_kek=''
        dek=''
        return 1
    fi

    keyring_id=$(secrets_get_keyring)
    if [[ -z "${keyring_id}" ]]; then
        printf '%s\n' 'secrets: failed to get keyring' >&2
        new_kek=''
        old_kek=''
        dek=''
        return 1
    fi

    key_id=$(keyctl search "${keyring_id}" user \
      "${SECRETS_KEYRING_KEY_NAME}" 2>/dev/null)
    if [[ -n "${key_id}" ]]; then
        keyctl unlink "${key_id}" "${keyring_id}" 2>/dev/null
    fi

    if ! keyctl add user "${SECRETS_KEYRING_KEY_NAME}" "${new_kek}" \
      "${keyring_id}" >/dev/null 2>&1; then
        printf '%s\n' 'secrets: failed to add new KEK to keyring' >&2
        new_kek=''
        old_kek=''
        dek=''
        return 1
    fi

    # Create secrets-test.enc from cleartext (same encryption as config files)
    if [[ ! -d /dev/shm ]]; then
        printf '%s\n' \
          'secrets: could not create secrets-test.enc (/dev/shm unavailable)' \
          >&2
    elif ! command -v sops >/dev/null 2>&1; then
        printf '%s\n' \
          'secrets: could not create secrets-test.enc (sops not in PATH;' >&2
        printf '%s\n' \
          '  see https://github.com/getsops/sops/releases)' >&2
    else
        local test_plain test_enc key_file public_key sops_err
        test_plain="${_script_dir}/secrets-test.txt"
        test_enc="${_script_dir}/secrets-test.enc"
        key_file="/dev/shm/secrets-test-key-$$"
        trap 'rm -f "${key_file}" 2>/dev/null' RETURN
        printf '%s' "${dek}" > "${key_file}"
        chmod 600 "${key_file}"
        public_key=$(age-keygen -y "${key_file}" 2>/dev/null)
        if [[ -z "${public_key}" ]]; then
            printf '%s\n' \
              'secrets: could not create secrets-test.enc (age-keygen -y failed)' \
              >&2
        elif [[ ! -f "${test_plain}" ]]; then
            printf '%s\n' \
              "secrets: could not create secrets-test.enc (${test_plain} missing)" \
              >&2
        else
            sops_err=$(cd "${_script_dir}" && \
              sops -e --input-type binary --output-type binary \
              --age "${public_key}" --output secrets-test.enc \
              secrets-test.txt 2>&1)
            if [[ ${?} -eq 0 ]]; then
                printf '%s\n' 'secrets: created secrets-test.enc' >&2
            else
                printf '%s\n' \
                  'secrets: could not create secrets-test.enc (sops failed):' \
                  >&2
                printf '%s\n' "${sops_err}" | sed 's/^/  /' >&2
            fi
        fi
    fi

    new_kek=''
    old_kek=''
    dek=''
    printf '%s\n' 'secrets: KEK rotated, DEK re-encrypted' >&2
    return 0
}

_secrets_rotate_kek
