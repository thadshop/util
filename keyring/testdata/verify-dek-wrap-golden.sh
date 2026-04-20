#!/usr/bin/env bash
# Decrypt committed golden-dek-wrapped.bin (recipe 01 + test vectors).

set -euo pipefail

_td="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_golden="${_td}/golden-dek-wrapped.bin"
_recipe="${_td}/../dek-wrap-recipes/dek-wrap-recipe-01.conf"
_vectors="${_td}/../dek-wrap-test-vectors.bash"
_ssl="${KEYRING_OPENSSL_BIN:-/usr/bin/openssl}"

if [[ ! -f "${_golden}" ]] || [[ ! -f "${_recipe}" ]] || \
  [[ ! -f "${_vectors}" ]]; then
    printf '%s\n' 'missing golden, recipe, or test vectors file' >&2
    exit 1
fi

# shellcheck source=../dek-wrap-test-vectors.bash
source "${_vectors}"

_cipher=$(sed -n 's/^OPENSSL_CIPHER=//p' "${_recipe}" | head -1)
_md=$(sed -n 's/^OPENSSL_MD=//p' "${_recipe}" | head -1)
_iter=$(sed -n 's/^PBKDF2_ITER=//p' "${_recipe}" | head -1)

_plen=$(python3 -c "import struct,sys
p=sys.argv[1]
d=open(p,'rb').read(16)
assert d[:8]==b'UTILDEK1', d[:8]
print(struct.unpack('>I',d[12:16])[0])
" "${_golden}")

_fsz=$(stat -c '%s' "${_golden}")
if [[ $((16 + _plen)) -ne "${_fsz}" ]]; then
    printf '%s\n' 'golden file size does not match header' >&2
    exit 1
fi

pay=$(mktemp /dev/shm/verify-golden.XXXXXX)
pf=$(mktemp /dev/shm/verify-golden.XXXXXX)
out=$(mktemp /dev/shm/verify-golden.XXXXXX)
chmod 600 "${pay}" "${pf}" "${out}"
trap 'rm -f "${pay}" "${pf}" "${out}"' EXIT

dd if="${_golden}" of="${pay}" bs=1 skip=16 count="${_plen}" status=none
printf '%s' "${SMOKE_PASSPHRASE}" > "${pf}"

"${_ssl}" enc -d "-${_cipher}" -pbkdf2 -iter "${_iter}" -md "${_md}" \
  -pass "file:${pf}" -in "${pay}" -out "${out}"

if ! cmp -s "${out}" <(printf '%s' "${SMOKE_PLAINTEXT}"); then
    printf '%s\n' 'golden decrypt mismatch' >&2
    exit 1
fi

printf '%s\n' \
  'ok: golden-dek-wrapped.bin decrypts to SMOKE_PLAINTEXT (test vectors)'
