#!/usr/bin/env bash
# Example: mint a static token using curl
# Usage: ./mint-token-curl.example.static_token.sh
# Environment variables:
#   TOKMINT_BASE_URL: baseURL of the tokmint service
#   TOKMINT_PROFILE: profile name
#   TOKMINT_DOMAIN: domain name
#   TOKMINT_CLIENT_ID: token ID

TOKMINT_BASE_URL="http://localhost:9876"
TOKMINT_PROFILE="sailpoint"
TOKMINT_DOMAIN="autodesk-sbx.api.identitynow.com"
TOKMINT_CLIENT_ID="448b235c95c945a0a206b3d06f5f3bf9"
_q="profile=${TOKMINT_PROFILE}&domain=${TOKMINT_DOMAIN}"
_q="${_q}&client_id=${TOKMINT_CLIENT_ID}"
_url="${TOKMINT_BASE_URL}/v1/token?${_q}"
curl -sS -X POST "${_url}"
