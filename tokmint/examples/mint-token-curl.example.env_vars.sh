#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Example: call tokmint POST /v1/token with curl.
# Prerequisites: tokmint running (see tokmint/README.md), profile file:
#   $SECCONFIG_DIR/tokmint/{profile}.enc.yaml
# (Only that basename today, not .enc.yml; contents may be plain or SOPS.)
#
# Query params must be on the URL (not as POST body). Override with env:
#   TOKMINT_BASE_URL   default http://127.0.0.1:9876
#   TOKMINT_PROFILE / TOKMINT_DOMAIN / TOKMINT_TOKEN_ID
#
# Usage:
#   ./mint-token-curl.example.sh
#   TOKMINT_PROFILE=okta TOKMINT_DOMAIN=dev-12345.okta.com \
#     ./mint-token-curl.example.sh

set -e

usage() {
    printf '%s\n' \
      "usage: $(basename "${0}") [-h|--help]" >&2
    printf '%s\n' \
      "  POST /v1/token with curl. Env: TOKMINT_BASE_URL, TOKMINT_PROFILE," >&2
    printf '%s\n' \
      "  TOKMINT_DOMAIN, TOKMINT_TOKEN_ID" >&2
}

if [[ "${1:-}" == -h ]] || [[ "${1:-}" == --help ]]; then
    usage
    exit 0
fi

: "${TOKMINT_BASE_URL:=http://127.0.0.1:9876}"
: "${TOKMINT_PROFILE:=test}"
: "${TOKMINT_DOMAIN:=tenant.example.com}"
: "${TOKMINT_TOKEN_ID:=default}"

_base="${TOKMINT_BASE_URL}"
while [[ "${_base}" == */ ]]; do
    _base="${_base%/}"
done

# URL-encode query keys and values (profile/domain may contain odd chars).
_qs="$(
    export TOKMINT_PROFILE TOKMINT_DOMAIN TOKMINT_TOKEN_ID
    python3 <<'PY'
import os
import urllib.parse as u

print(
    u.urlencode(
        {
            "profile": os.environ["TOKMINT_PROFILE"],
            "domain": os.environ["TOKMINT_DOMAIN"],
            "token_id": os.environ["TOKMINT_TOKEN_ID"],
        }
    )
)
PY
)"

_url="${_base}/v1/token?${_qs}"

printf '%s\n' "POST ${_url}" >&2
printf '%s\n' "---" >&2

_body="$(curl -sS --connect-timeout 3 -X POST "${_url}")"
printf '%s\n' "${_body}"

# If jq is available, print a ready-made Authorization value (same idea as
# examples/postman-prerequest.example.js).
if command -v jq >/dev/null 2>&1; then
    _tt="$(printf '%s' "${_body}" | jq -r '.token_type // empty')"
    _at="$(printf '%s' "${_body}" | jq -r '.access_token // empty')"
    if [[ -n "${_tt}" ]] && [[ -n "${_at}" ]]; then
        printf '%s\n' "---" >&2
        printf '%s\n' "Authorization: ${_tt} ${_at}" >&2
    fi
fi
