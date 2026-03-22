#!/usr/bin/env bash
# Encrypt a plaintext YAML under SECCONFIG_DIR to *.enc.yaml using sops.
# Uses $SECCONFIG_DIR/.sops.yaml (creation_rules, e.g. encrypted_suffix).
# Encrypting uses public age keys from .sops.yaml; get-dek.sh is not required.
#
# Usage:
#   export SECCONFIG_DIR=/path/to/config
#   encrypt-config.sh [-f|--force] [--help] path/to/plain.yaml
#
# path may be relative to SECCONFIG_DIR or absolute (must stay under it).
# -f / --force overwrites an existing output file.

set -e

usage() {
    printf '%s\n' \
      "usage: encrypt-config.sh [-f|--force] [--help] <plain.yaml>" >&2
    printf '%s\n' "  SECCONFIG_DIR must name the directory with .sops.yaml." \
      >&2
    printf '%s\n' "  Writes <name>.enc.yaml next to <name>.yaml (or .yml)." \
      >&2
}

_force=0
while [[ ${#} -gt 0 ]]; do
    case ${1} in
        -f|--force)
            _force=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            printf '%s\n' "encrypt-config: unknown option: ${1}" >&2
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ ${#} -ne 1 ]]; then
    usage
    exit 1
fi

if [[ -z "${SECCONFIG_DIR:-}" ]]; then
    printf '%s\n' 'encrypt-config: SECCONFIG_DIR is not set or empty' >&2
    exit 1
fi

if ! command -v sops >/dev/null 2>&1; then
    printf '%s\n' 'encrypt-config: sops not in PATH' >&2
    exit 1
fi

_root="$(cd "${SECCONFIG_DIR}" && pwd)"
_sops_cfg="${_root}/.sops.yaml"
if [[ ! -f "${_sops_cfg}" ]]; then
    printf '%s\n' "encrypt-config: missing ${_sops_cfg}" >&2
    exit 1
fi

_in="${1}"
if [[ "${_in}" != /* ]]; then
    _in="${_root}/${_in}"
fi

if [[ ! -f "${_in}" ]]; then
    printf '%s\n' "encrypt-config: not a file: ${_in}" >&2
    exit 1
fi

_in="$(cd "$(dirname "${_in}")" && pwd)/$(basename "${_in}")"

if [[ "${_in}" != "${_root}"/* ]]; then
    printf '%s\n' 'encrypt-config: file must be under SECCONFIG_DIR' >&2
    exit 1
fi

_base="$(basename "${_in}")"
if [[ "${_base}" == *.enc.yaml ]] || [[ "${_base}" == *.enc.yml ]]; then
    printf '%s\n' \
      'encrypt-config: input name already looks encrypted (*.enc.*)' >&2
    exit 1
fi

case "${_base}" in
    *.yaml) _out="$(dirname "${_in}")/${_base%.yaml}.enc.yaml" ;;
    *.yml) _out="$(dirname "${_in}")/${_base%.yml}.enc.yaml" ;;
    *)
        printf '%s\n' \
          'encrypt-config: filename must end in .yaml or .yml' >&2
        exit 1
        ;;
esac

_out_dir="$(dirname "${_out}")"
if [[ ! -d "${_out_dir}" ]]; then
    printf '%s\n' \
      "encrypt-config: output directory missing: ${_out_dir}" >&2
    exit 1
fi
if [[ ! -w "${_out_dir}" ]]; then
    printf '%s\n' \
      "encrypt-config: output directory not writable: ${_out_dir}" >&2
    exit 1
fi

# Likely already a sops file (avoid double-encrypting)
if head -n 40 "${_in}" | grep -q '^sops:'; then
    printf '%s\n' \
      'encrypt-config: file already has sops metadata (encrypted?)' >&2
    exit 1
fi

if [[ -f "${_out}" ]] && [[ ${_force} -eq 0 ]]; then
    printf '%s\n' \
      "encrypt-config: ${_out} exists (use -f or --force)" >&2
    exit 1
fi

export SOPS_CONFIG="${_sops_cfg}"
sops -e --output "${_out}" "${_in}"
printf '%s\n' "Created ${_out}"
