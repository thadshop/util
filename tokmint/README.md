# tokmint

Local HTTP service that returns **API tokens** from YAML profiles:

- **Mode A** — static credential stored in the profile
- **Mode B** — OAuth 2.0 **client_credentials** grant; supports
  **`client_secret_post`**, **`client_secret_basic`**, and
  **`private_key_jwt`** client authentication, with optional **DPoP**-bound
  tokens

See **`DESIGN.md`** for the full contract. **`examples/tokmint.example.profile.yaml`**
is a commented layout for Mode A, Mode B, and intended OAuth/JWT fields.

The machine-readable definition is **JSON Schema** (Draft 2020-12):
**`tokmint/schemas/profile.schema.json`** (bundled in the **`tokmint`** package).
Optional **`jsonschema`** extra (included in **`.[dev]`**) enables
**`tokmint.profile_schema.validate_profile_document()`** after **`yaml.safe_load`**.

```bash
.venv/bin/python -c "
import yaml
from pathlib import Path
from tokmint.profile_schema import validate_profile_document
p = Path('examples/tokmint.example.profile.yaml')
validate_profile_document(yaml.safe_load(p.read_text()))
print('ok')
"
```

External tools (e.g. **`check-jsonschema`**) can validate the same file against
that JSON Schema after converting YAML to JSON if needed.

## Setup

From this directory, with **`SECCONFIG_DIR`** pointing at your config root:

```bash
python3 -m venv .venv
.venv/bin/pip install -e ../secconfig -e ".[dev]"
export SECCONFIG_DIR=/path/to/your/secconfig/root
```

Profiles live under **`$SECCONFIG_DIR/tokmint/{profile}.enc.yaml`** (override
directory name with **`TOKMINT_SECCONFIG_SUBDIR`**). Matches the secconfig
**`*.enc.yaml`** convention. **`SECCONFIG_DIR`** must be an existing directory;
otherwise **`POST /v1/token`** responds with **503**.

## Run

```bash
export SECCONFIG_DIR=...
.venv/bin/python -m tokmint
```

Listens on **`127.0.0.1:9876`** by default (**`TOKMINT_PORT`** overrides).

Equivalent:

```bash
.venv/bin/uvicorn tokmint.app:app --host 127.0.0.1 --port 9876
```

## Example requests

**Mode A** (static token; query param **`token_id`**; do not set **`client_id`**):

```bash
curl -s -X POST 'http://127.0.0.1:9876/v1/token?profile=test&domain=tenant.example.com&token_id=default'
```

**Mode B** (OAuth client credentials; set **`client_id`**; omit **`token_id`**).
The profile selects the token endpoint via **`auth_servers[].path`** + request
**`domain`**. Tokmint POSTs to `https://{domain}{path}` with TLS verification
enabled.

**`client_secret_post`** or **`client_secret_basic`**:

```bash
curl -s -X POST \
  'http://127.0.0.1:9876/v1/token?profile=myprofile&domain=idp.example.com&client_id=my-client-id'
```

**`private_key_jwt`** — pass **`key_id`** to select a signing key by `kid`:

```bash
curl -s -X POST \
  'http://127.0.0.1:9876/v1/token?profile=myprofile&domain=idp.example.com&client_id=my-client-id&key_id=my-kid'
```

With **DPoP** — also pass **`dpop_key_id`** (defaults to `key_id`),
**`dpop_htm`**, and **`dpop_htu`**:

```bash
curl -s -X POST \
  'http://127.0.0.1:9876/v1/token?profile=myprofile&domain=idp.example.com&client_id=my-client-id&key_id=my-kid&dpop_htm=GET&dpop_htu=https%3A%2F%2Fidp.example.com%2Fapi%2Fv1%2Fusers'
```

See **`examples/tokmint.example.profile.yaml`** for the full profile structure
covering all client authentication methods. Copy-paste-ready scripts for each
authentication method are in **`examples/curl.example.*.sh`**; Postman
pre-request scripts are in **`examples/postman-prerequest.example.*.js`**.

## SOPS-encrypted profile (manual test)

**`.sops.yaml` for `tokmint/`:** copy patterns from
**`examples/sops.example.dot-sops.yaml`** into **`$SECCONFIG_DIR/.sops.yaml`**
(order matters: put **before** any broad `.*\.yaml$` rule). The
`encrypted_regex` covers **`credential`**, **`client_secret`**, **`jwk`**, and
keys ending in **`_secret`**.  For **`private_key_jwt`** profiles the signing
key material is either:

- **Inline JWK** (`signing_keys[].jwk`) — the entire `jwk` map is
  sops-encrypted as one unit; the non-secret fields (`kty`, `crv`, `kid`) are
  only visible after decryption.
- **Encrypted PEM file** (`signing_keys[].encrypted_pem_path`) — the path
  itself is plaintext in the profile; the PEM file it points to is encrypted
  separately with `keyring/encrypt.sh`.

Tokmint loads profiles through **`secconfig.load_config`**, which decrypts
**sops** files the same way as plain YAML. Requirements match
**`../secconfig/README.md`**: Linux with **`/dev/shm`**, **`sops`** on
**`PATH`**, and a working **`../keyring/get-dek.sh`** (KEK/DEK in the
keyring).

**`encrypt-config.sh`** writes **`tokmint/test.enc.yaml`** from **`test.yaml`**
when run under **`SECCONFIG_DIR`**; that output path is what tokmint loads for
**`profile=test`**.

Example: encrypt only the **`credential`** field (plaintext input must match
**`path_regex`** — here **`tokmint/test.plain.yaml`**):

```bash
repo=/path/to/util
export SECCONFIG_DIR="${repo}/path/to/your-secconfig-root"
mkdir -p "${SECCONFIG_DIR}/tokmint"

# Plain profile (input file for sops -e)
cat > "${SECCONFIG_DIR}/tokmint/test.plain.yaml" <<'EOF'
domains:
  - domain: tenant.example.com
    tokens:
      Bearer:
        - token_id: default
          credential: my-sops-secret
EOF

# Age public key from your DEK (same as secconfig examples)
_key="/dev/shm/tokmint-age-$$"
trap 'rm -f "${_key}"' EXIT
"${repo}/keyring/get-dek.sh" -o "${_key}"
chmod 600 "${_key}"
_pub="$(age-keygen -y "${_key}")"

cat > "${SECCONFIG_DIR}/.sops.yaml" <<EOF
creation_rules:
  - path_regex: .*tokmint/test\.plain\.yaml\$
    encrypted_regex: '^credential\$'
    age: ${_pub}
EOF

export SOPS_CONFIG="${SECCONFIG_DIR}/.sops.yaml"
sops -e --output "${SECCONFIG_DIR}/tokmint/test.enc.yaml" \
  "${SECCONFIG_DIR}/tokmint/test.plain.yaml"
rm -f "${SECCONFIG_DIR}/tokmint/test.plain.yaml"

# Run tokmint with SECCONFIG_DIR set; curl as in "Example request"
```

If decryption fails (wrong key, missing sops, **`get-dek`** error), the API
returns **500** with **`PROFILE_LOAD_FAILED`** (see **`DESIGN.md`**).

## Logging

Set **`TOKMINT_LOG_LEVEL`** to control log verbosity (default: **`INFO`**):

| Level | What is logged |
|---|---|
| `DEBUG` | JWT internals, key algorithm selection, DPoP proof fields |
| `VERBOSE` | Full HTTP request/response headers and bodies (secrets redacted) |
| `INFO` | Normal operation: startup, token minted, errors |
| `WARNING` / `ERROR` | Degraded or failed requests |

All output is JSON Lines (one JSON object per line) on **stderr**.

### jsonl-fmt

**`jsonl-fmt`** is a companion CLI (installed alongside **`tokmint`**) that
formats the JSON Lines stream for easier reading and copy-paste.

```bash
# Pretty-print each log line as it arrives (default)
python -m tokmint 2>&1 | jsonl-fmt

# Emit a pretty JSON array after each burst of activity
TOKMINT_LOG_LEVEL=VERBOSE python -m tokmint 2>&1 | jsonl-fmt -a

# Compact array — minimal copy-paste into a JSON beautifier (e.g. CyberChef)
TOKMINT_LOG_LEVEL=VERBOSE python -m tokmint 2>&1 | jsonl-fmt -ac
```

In **`-a`** mode each burst of lines is collected into a single array and
emitted after a quiet period, so one token request typically produces one
array.  Each entry is wrapped as **`{"log": {...}}`** for structured log
objects or **`{"raw": "..."}`** for unstructured lines (uvicorn access log,
etc.).

The flush timeout defaults to **1000 ms** and can be overridden:

```bash
TOKMINT_JSONL_FMT_FLUSH_MS=500 python -m tokmint 2>&1 | jsonl-fmt -a
```

## Tests

```bash
.venv/bin/python -m pytest tests/ -q
```

**Note:** `tests/conftest.py` patches **`secconfig.loader._check_no_debug`** so
**`load_config`** works under pytest’s tracer. Production still uses the guard.

## secconfig import

**`secconfig`** must be installed (editable **`../secconfig`** from this repo).
Importing **`secconfig`** no longer runs **`check_prereqs()`** automatically; call
it explicitly if you want fail-fast environment validation before **`load_config`**.
