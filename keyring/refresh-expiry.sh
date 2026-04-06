#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Reset the persistent keyring expiry timer so the KEK does not
# expire. No-op on WSL2 (uses @u, no expiry to reset).
# Add to crontab to run periodically (e.g. daily).
#
# Crontab example (daily at 2am):
#   0 2 * * * /path/to/util/keyring/refresh-expiry.sh

if keyctl get_persistent @s >/dev/null 2>&1; then
    # Persistent keyring available; refresh resets expiry
    exit 0
fi
# WSL2 or kernel without persistent keyring: using @u, no
# expiry to reset
exit 0
