#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Example: mint a static token using curl
# Usage: ./mint-token-curl.example.static_token.sh
# Environment variables:
#   TOKMINT_BASE_URL: full origin, e.g. http://127.0.0.1:9876 (include scheme)
#   TOKMINT_PROFILE: profile name
#   TOKMINT_DOMAIN: domain name
#   TOKMINT_TOKEN_ID: token ID

TOKMINT_BASE_URL="http://localhost:9876"
TOKMINT_PROFILE="example"
TOKMINT_DOMAIN="tenant.example.com"
TOKMINT_TOKEN_ID="6f4b"
_q="profile=${TOKMINT_PROFILE}&domain=${TOKMINT_DOMAIN}"
_q="${_q}&token_id=${TOKMINT_TOKEN_ID}"
_url="${TOKMINT_BASE_URL}/v1/token?${_q}"
curl -sS -X POST "${_url}"
