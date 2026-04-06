#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Rotate the KEK and re-encrypt the DEK with the new KEK.
# If DEK does not exist, creates it (generates new age key).
# Requires: age-keygen, openssl, keyutils.

_script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
_dek_file="${_script_dir}/dek.encrypted"
# shellcheck source=lib.bash
source "${_script_dir}/lib.bash"

# Rotate KEK
_keyring_rotate_kek() {
    if ! keyring_no_debug; then
        return 1
    fi
    if ! keyring_check_keyring; then
        return 1
    fi

    local old_kek
    local new_kek
    local dek
    local new_passphrase
    local new_confirm
    local keyring_id
    local key_id

    old_kek=$(keyring_get_kek)
    if [[ -z "${old_kek}" ]]; then
        printf '%s\n' 'keyring: KEK not in keyring. Run:' >&2
        printf '%s\n' "  source ${_script_dir}/init.bash" >&2
        return 1
    fi

    if [[ -f "${_dek_file}" ]]; then
        dek=$(keyring_decrypt_dek_with_kek "${old_kek}" "${_dek_file}")
        if [[ -z "${dek}" ]] || \
          ! [[ "${dek}" =~ ^AGE-SECRET-KEY-1.+ ]]; then
            printf '%s\n' "keyring: failed to decrypt DEK at ${_dek_file}" \
              >&2
            printf '%s\n' '  (wrong passphrase?)' >&2
            old_kek=''
            return 1
        fi
    else
        printf '%s\n' "keyring: no DEK file at ${_dek_file}" >&2
        printf '%s\n' 'keyring: generating new age key as DEK...' >&2
        dek=$(age-keygen 2>/dev/null | grep -E '^AGE-SECRET-KEY-' || true)
        if [[ -z "${dek}" ]]; then
            printf '%s\n' 'keyring: age-keygen failed' >&2
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
        printf '%s\n' 'keyring: passphrases do not match' >&2
        new_passphrase=''
        new_confirm=''
        old_kek=''
        dek=''
        return 1
    fi

    if [[ -z "${new_passphrase}" ]]; then
        printf '%s\n' 'keyring: passphrase cannot be empty' >&2
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
        printf '%s\n' 'keyring: failed to hash new passphrase' >&2
        old_kek=''
        dek=''
        return 1
    fi

    if ! keyring_encrypt_dek_with_kek "${new_kek}" "${dek}" "${_dek_file}"; \
      then
        printf '%s\n' "keyring: failed to encrypt DEK at ${_dek_file}" >&2
        new_kek=''
        old_kek=''
        dek=''
        return 1
    fi

    keyring_id=$(keyring_get_keyring)
    if [[ -z "${keyring_id}" ]]; then
        printf '%s\n' 'keyring: failed to get keyring' >&2
        new_kek=''
        old_kek=''
        dek=''
        return 1
    fi

    key_id=$(keyctl search "${keyring_id}" user \
      "${KEYRING_KEK_KEY_NAME}" 2>/dev/null)
    if [[ -n "${key_id}" ]]; then
        keyctl unlink "${key_id}" "${keyring_id}" 2>/dev/null
    fi

    if ! keyctl add user "${KEYRING_KEK_KEY_NAME}" "${new_kek}" \
      "${keyring_id}" >/dev/null 2>&1; then
        printf '%s\n' 'keyring: failed to add new KEK to keyring' >&2
        new_kek=''
        old_kek=''
        dek=''
        return 1
    fi

    # Create keyring-test.enc from cleartext (same encryption as config files)
    if [[ ! -d /dev/shm ]]; then
        printf '%s\n' \
          'keyring: could not create keyring-test.enc (/dev/shm unavailable)' \
          >&2
    elif ! command -v sops >/dev/null 2>&1; then
        printf '%s\n' \
          'keyring: could not create keyring-test.enc (sops not in PATH;' >&2
        printf '%s\n' \
          '  see https://github.com/getsops/sops/releases)' >&2
    else
        local test_plain test_enc key_file public_key sops_err
        test_plain="${_script_dir}/keyring-test.txt"
        test_enc="${_script_dir}/keyring-test.enc"
        key_file="/dev/shm/keyring-test-key-$$"
        trap 'rm -f "${key_file}" 2>/dev/null' RETURN
        printf '%s' "${dek}" > "${key_file}"
        chmod 600 "${key_file}"
        public_key=$(age-keygen -y "${key_file}" 2>/dev/null)
        if [[ -z "${public_key}" ]]; then
            printf '%s\n' \
              'keyring: could not create keyring-test.enc (age-keygen -y failed)' \
              >&2
        elif [[ ! -f "${test_plain}" ]]; then
            printf '%s\n' \
              "keyring: could not create keyring-test.enc (${test_plain} missing)" \
              >&2
        else
            sops_err=$(cd "${_script_dir}" && \
              sops -e --input-type binary --output-type binary \
              --age "${public_key}" --output keyring-test.enc \
              keyring-test.txt 2>&1)
            if [[ ${?} -eq 0 ]]; then
                printf '%s\n' 'keyring: created keyring-test.enc' >&2
            else
                printf '%s\n' \
                  'keyring: could not create keyring-test.enc (sops failed):' \
                  >&2
                printf '%s\n' "${sops_err}" | sed 's/^/  /' >&2
            fi
        fi
    fi

    new_kek=''
    old_kek=''
    dek=''
    printf '%s\n' 'keyring: KEK rotated, DEK re-encrypted' >&2
    return 0
}

_keyring_rotate_kek
