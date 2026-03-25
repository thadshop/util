# Source this from .profile or .bashrc to initialize secrets on login.
# On first use per session: prompts for passphrase, hashes it,
# stores in keyring.
# On subsequent shells (same session): uses existing keyring entry,
# no prompt.
#
# BASH_SOURCE[0] is set by Bash (not an env var) to the path of
# this script.
# realpath canonicalizes so we get the directory even when
# sourced as "init.sh".

_secrets_init_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
if [[ -f "${_secrets_init_dir}/lib.sh" ]]; then
    # shellcheck source=lib.sh
    source "${_secrets_init_dir}/lib.sh"
    if [[ -t 0 ]]; then
        if ! secrets_check_prereqs; then
            printf '%s\n' 'secrets: initialization failed. To retry, run:' >&2
            printf '%s\n' "  source ${_secrets_init_dir}/init.sh" >&2
            printf '%s\n' 'or open a new terminal.' >&2
        elif ! secrets_init; then
            printf '%s\n' '' >&2
            printf '%s\n' 'secrets: initialization failed. To retry, run:' >&2
            printf '%s\n' "  source ${_secrets_init_dir}/init.sh" >&2
            printf '%s\n' 'or open a new terminal.' >&2
        fi
    fi
fi
