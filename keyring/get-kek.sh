#!/usr/bin/env bash
# Output the KEK to -o/--output (default /dev/null). Use -o /dev/stdout to
# capture. Exit 1 on failure; errors to stderr.
#
# Bash: kek=$(get-kek.sh -o /dev/stdout) || exit 1
# Python: subprocess.run(["./get-kek.sh", "-o", "/dev/stdout"], ...)

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"
# shellcheck source=lib.sh
source "${_script_dir}/lib.sh"

output_file="/dev/null"

# Parse options using getopt for both short and long option names
OPTS=$(getopt -o o: --long output: -n "$(basename "${0}")" -- "${@}")
if [[ ${?} != 0 ]]; then
    printf '%s\n' "Failed parsing options." >&2
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -o|--output)
            output_file="${2}"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            printf '%s\n' "Invalid option: ${1}" >&2
            exit 1
            ;;
    esac
done

if [[ "${output_file}" == "/dev/null" ]]; then
    printf '%s\n' \
      "secrets: ${_script_path}: output sent to /dev/null by default." \
      " To get output, specify -o <file> or -o /dev/stdout." >&2
fi

kek=$(secrets_get_kek)
if [[ -z "${kek}" ]]; then
    printf '%s\n' "secrets: ${_script_path}: failed (KEK not in keyring)" >&2
    printf '%s\n' "secrets: to initialize: source ${_script_dir}/init.sh" >&2
    exit 1
fi

printf '%s' "${kek}" > "${output_file}"
