#!/usr/bin/env bash

TOKMINT_BASE_URL="http://localhost:9876"

curl -sS -G -X POST "${TOKMINT_BASE_URL}/v1/token" \
  --data-urlencode "profile=okta" \
  --data-urlencode "domain=autodesk-us-preview.okta.mil" \
  --data-urlencode "token_id=00T1md8ssvC07vaIO0k6" \
  | jq .
