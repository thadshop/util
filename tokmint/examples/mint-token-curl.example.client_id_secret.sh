#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Example: mint a bearer token using client_id and client_secret using curl
# Usage: ./mint-token-curl.example.client_id_secret.sh
# Environment variables:
#   TOKMINT_BASE_URL: baseURL of the tokmint service
#   TOKMINT_PROFILE: profile name
#   TOKMINT_DOMAIN: domain name
#   TOKMINT_CLIENT_ID: token ID

TOKMINT_BASE_URL="http://localhost:9876"
TOKMINT_PROFILE="example"
TOKMINT_DOMAIN="tenant.example.com"
TOKMINT_CLIENT_ID="6f4b"
_q="profile=${TOKMINT_PROFILE}&domain=${TOKMINT_DOMAIN}"
_q="${_q}&client_id=${TOKMINT_CLIENT_ID}"
_url="${TOKMINT_BASE_URL}/v1/token?${_q}"
curl -sS -X POST "${_url}"
