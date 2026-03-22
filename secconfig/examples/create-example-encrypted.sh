#!/usr/bin/env bash
# Create example-config.enc.yaml from example-config.yaml using sops.
# Requires: bash secrets initialized, sops, age-keygen.
# Run from secconfig/examples/ or with that dir as cwd.

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_get_dek="${_script_dir}/../../keyring/get-dek.sh"
_config="${_script_dir}/example-config.yaml"
_enc_config="${_script_dir}/example-config.enc.yaml"
_sops_config="${_script_dir}/.sops.yaml"

if [[ ! -f "${_config}" ]]; then
    printf '%s\n' "example-config.yaml not found" >&2
    exit 1
fi

if [[ ! -x "${_get_dek}" ]]; then
    printf '%s\n' "get-dek.sh not found or not executable" >&2
    exit 1
fi

# Get DEK, write to /dev/shm, extract public key
_key_file="/dev/shm/secconfig-age-key-$$"
trap 'rm -f "${_key_file}"' EXIT
"${_get_dek}" > "${_key_file}"
chmod 600 "${_key_file}"

_public_key=$(age-keygen -y "${_key_file}")

# Create .sops.yaml (encrypted_regex: only encrypt password values).
# path_regex matches the file passed to sops -e (plaintext path), not --output.
# Optional (\\.enc)? so the same rule applies
# if you edit example-config.enc.yaml.
printf '%s\n' "creation_rules:" > "${_sops_config}"
printf '%s\n' \
  '  - path_regex: example-config(\.enc)?\.yaml$' >> "${_sops_config}"
printf '%s\n' "    encrypted_regex: '^password$'" >> "${_sops_config}"
printf '%s\n' "    age: ${_public_key}" >> "${_sops_config}"

# Encrypt (plaintext path must match path_regex above)
sops -e --output "${_enc_config}" "${_config}"
printf '%s\n' "Created ${_enc_config}"
