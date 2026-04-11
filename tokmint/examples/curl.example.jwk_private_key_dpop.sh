#!/usr/bin/env bash

TOKMINT_BASE_URL="http://localhost:9876"

curl -sS -G -X POST "${TOKMINT_BASE_URL}/v1/token" \
  --data-urlencode "profile=okta" \
  --data-urlencode "domain=autodesk-us-preview.okta.mil" \
  --data-urlencode "client_id=0oa1665uiwpMCiu2X0k7" \
  --data-urlencode "key_id=KPqu2qotSWt9YgUgrHLCW_nCJ0ktkusRZJ-xgoQjpPw" \
  --data-urlencode "dpop_htm=GET" \
  --data-urlencode "dpop_htu=https://autodesk-us-preview-admin.okta.mil/api/v1/groups" \
  | jq .
