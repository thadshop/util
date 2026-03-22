#!/usr/bin/env bash
# Output the KEK to stdout. Usable from Bash or Python.
# Exit 1 on failure; errors to stderr.
#
# Bash: kek=$(get-kek.sh) || { printf '%s\n' 'failed'; exit 1; }
# Python: subprocess.run(["./get-kek.sh"], capture_output=True, text=True)

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"
# shellcheck source=lib.sh
source "${_script_dir}/lib.sh"

output_file="/dev/null"

while [[ ${#} -gt 0 ]]; do
    case "${1}" in
        -o|--output)
            output_file="${2}"
            shift 2
            ;;
        *)
            printf '%s\n' "secrets: ${_script_path}: unrecognized argument '${1}'" >&2
            exit 1
            ;;
    esac
done

if [[ "${output_file}" == "/dev/null" ]]; then
    printf '%s\n' "secrets: ${_script_path}: output sent to /dev/null by default. Specify -o <file> to save output, or -o /dev/stdout for stdout." >&2
fi

kek=$(secrets_get_kek)
if [[ -z "${kek}" ]]; then
    printf '%s\n' "secrets: ${_script_path}: failed (KEK not in keyring)" >&2
    printf '%s\n' "secrets: to initialize: source ${_script_dir}/init.sh" >&2
    exit 1
fi

printf '%s' "${kek}" > "${output_file}"
