#!/usr/bin/env bash

TOKMINT_BASE_URL="http://localhost:9876"

curl -sS -G -X POST "${TOKMINT_BASE_URL}/v1/token" \
  --data-urlencode "profile=sailpoint" \
  --data-urlencode "domain=autodesk-sbx.api.identitynow.com" \
  --data-urlencode "client_id=448b235c95c945a0a206b3d06f5f3bf9" \
  | jq .
