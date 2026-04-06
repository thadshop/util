# SOURCE ONLY — do not execute (`bash init.bash`). From ~/.profile or ~/.bashrc:
#   source /path/to/util/keyring/init.bash
#
# Source this from .profile or .bashrc to initialize keyring on login.
# On first use per session: prompts for passphrase, hashes it,
# stores in keyring.
# On subsequent shells (same session): uses existing keyring entry,
# no prompt.
#
# BASH_SOURCE[0] is set by Bash (not an env var) to the path of
# this script.
# realpath canonicalizes so we get the directory even when
# sourced as "init.bash".

_keyring_init_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
if [[ -f "${_keyring_init_dir}/lib.bash" ]]; then
    # shellcheck source=lib.bash
    source "${_keyring_init_dir}/lib.bash"
    if [[ -t 0 ]]; then
        if ! keyring_check_prereqs; then
            printf '%s\n' 'keyring: initialization failed. To retry, run:' >&2
            printf '%s\n' "  source ${_keyring_init_dir}/init.bash" >&2
            printf '%s\n' 'or open a new terminal.' >&2
        elif ! keyring_init; then
            printf '%s\n' '' >&2
            printf '%s\n' 'keyring: initialization failed. To retry, run:' >&2
            printf '%s\n' "  source ${_keyring_init_dir}/init.bash" >&2
            printf '%s\n' 'or open a new terminal.' >&2
        fi
    fi
fi
