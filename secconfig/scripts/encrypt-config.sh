#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Encrypt a plaintext YAML under SECCONFIG_DIR → *.enc.yaml next to input.
# Uses $SECCONFIG_DIR/.sops.yaml (public age keys in rules; no DEK on encrypt).
# Same util checkout layout as decrypt-config.sh (see keyring/with-sops-dek.sh).

set -e

usage() {
    printf '%s\n' \
        "usage: encrypt-config.sh [-f|--force] -i|--input FILE [--help]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  -i is required. Plain YAML path relative to \$SECCONFIG_DIR, absolute" >&2
    printf '%s\n' \
        "  under that tree, or - / /dev/stdin (staged under \$SECCONFIG_DIR)." >&2
    printf '%s\n' \
        "  SECCONFIG_DIR must name the directory with .sops.yaml." >&2
    printf '%s\n' \
        "  Writes <name>.enc.yaml next to <name>.yaml (or .yml)." >&2
    printf '%s\n' \
        "  With stdin, names use a temp basename under \$SECCONFIG_DIR." >&2
}

_force=0
_in=""
_stdin_staged=""
OPTS=$(getopt -o fhi: --long force,help,input: -n "$(basename "${0}")" -- \
    "${@}")
if [[ ${?} != 0 ]]; then
    printf '%s\n' "Failed parsing options." >&2
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -f|--force)
            _force=1
            shift
            ;;
        -i|--input)
            _in="${2}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            printf '%s\n' "Invalid option: ${1}" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ${#} -ne 0 ]]; then
    printf '%s\n' \
        "encrypt-config: unexpected arguments (use -i for input)" >&2
    usage
    exit 1
fi

if [[ -z "${_in}" ]]; then
    printf '%s\n' \
        'encrypt-config: -i|--input is required (use - for stdin).' >&2
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

trap 'rm -f "${_stdin_staged}"' EXIT

if [[ "${_in}" == "-" ]] || [[ "${_in}" == "/dev/stdin" ]]; then
    _stdin_staged="$(mktemp "${_root}/.encrypt-config-stdin.XXXXXX.yaml")"
    chmod 600 "${_stdin_staged}"
    cat > "${_stdin_staged}"
    _in="${_stdin_staged}"
elif [[ "${_in}" != /* ]]; then
    _in="${_root}/${_in}"
fi

_in="$(cd "$(dirname "${_in}")" && pwd)/$(basename "${_in}")"

if [[ -z "${_stdin_staged}" ]] && [[ "${_in}" != "${_root}"/* \
    ]]; then
    printf '%s\n' 'encrypt-config: file must be under SECCONFIG_DIR' >&2
    exit 1
fi

if [[ ! -f "${_in}" ]]; then
    printf '%s\n' "encrypt-config: not a file: ${_in}" >&2
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
