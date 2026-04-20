#!/usr/bin/env bash
# Regenerate golden-dek-wrapped.bin after changing recipe 01 crypto params
# or keyring/dek-wrap-test-vectors.bash.

set -euo pipefail

_td="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_recipe="${_td}/../dek-wrap-recipes/dek-wrap-recipe-01.conf"
_vectors="${_td}/../dek-wrap-test-vectors.bash"
_out="${_td}/golden-dek-wrapped.bin"
_ssl="${KEYRING_OPENSSL_BIN:-/usr/bin/openssl}"

if [[ ! -f "${_recipe}" ]] || [[ ! -f "${_vectors}" ]]; then
    printf '%s\n' "missing ${_recipe} or ${_vectors}" >&2
    exit 1
fi

# shellcheck source=../dek-wrap-test-vectors.bash
source "${_vectors}"

_magic=$(sed -n 's/^HEADER_MAGIC=//p' "${_recipe}" | head -1)
_maj=$(sed -n 's/^HEADER_FORMAT_MAJOR=//p' "${_recipe}" | head -1)
_min=$(sed -n 's/^HEADER_FORMAT_MINOR=//p' "${_recipe}" | head -1)
_rid=$(sed -n 's/^RECIPE_ID=//p' "${_recipe}" | head -1)
_cipher=$(sed -n 's/^OPENSSL_CIPHER=//p' "${_recipe}" | head -1)
_md=$(sed -n 's/^OPENSSL_MD=//p' "${_recipe}" | head -1)
_iter=$(sed -n 's/^PBKDF2_ITER=//p' "${_recipe}" | head -1)

pf=$(mktemp /dev/shm/regen-golden.XXXXXX)
pl=$(mktemp /dev/shm/regen-golden.XXXXXX)
ct=$(mktemp /dev/shm/regen-golden.XXXXXX)
chmod 600 "${pf}" "${pl}" "${ct}"
trap 'rm -f "${pf}" "${pl}" "${ct}"' EXIT

printf '%s' "${SMOKE_PASSPHRASE}" > "${pf}"
printf '%s' "${SMOKE_PLAINTEXT}" > "${pl}"

"${_ssl}" enc -e "-${_cipher}" -salt -pbkdf2 -iter "${_iter}" -md "${_md}" \
  -pass "file:${pf}" -out "${ct}" -in "${pl}"

PLEN=$(stat -c '%s' "${ct}")
python3 -c "import struct,sys
magic,maj,min,rid_s,plen,ct_path,out_path=sys.argv[1:]
maj_i=int(maj); min_i=int(min); rid=int(rid_s,10)
ct=open(ct_path,'rb').read()
assert len(ct)==int(plen)
hdr=(magic.encode('ascii') + bytes([maj_i,min_i]) +
     struct.pack('>H',rid) + struct.pack('>I',len(ct)))
open(out_path,'wb').write(hdr+ct)
" "${_magic}" "${_maj}" "${_min}" "${_rid}" "${PLEN}" "${ct}" "${_out}"

printf '%s\n' "wrote ${_out}"
