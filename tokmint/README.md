# tokmint

Local HTTP service that returns **static API tokens** from YAML profiles (Phase 1).
See **`DESIGN.md`** for the full contract. **`examples/profile.reference.yaml`**
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
p = Path('examples/profile.reference.yaml')
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

## Example request

```bash
curl -s -X POST 'http://127.0.0.1:9876/v1/token?profile=test&base_url=https://tenant.example.com&token_id=default'
```

## SOPS-encrypted profile (manual test)

**`.sops.yaml` for `tokmint/`:** copy patterns from
**`examples/dot.sops.yaml.tokmint.example`** into **`$SECCONFIG_DIR/.sops.yaml`**
(order matters: put **before** any broad `.*\.yaml$` rule). It encrypts only
keys named **`token_value`** and **`client_secret`**.

Tokmint loads profiles through **`secconfig.load_config`**, which decrypts
**sops** files the same way as plain YAML. Requirements match
**`../secconfig/README.md`**: Linux with **`/dev/shm`**, **`sops`** on
**`PATH`**, and a working **`../keyring/get-dek.sh`** (KEK/DEK in the
keyring).

**`encrypt-config.sh`** writes **`tokmint/test.enc.yaml`** from **`test.yaml`**
when run under **`SECCONFIG_DIR`**; that output path is what tokmint loads for
**`profile=test`**.

Example: encrypt only the **`token_value`** field (plaintext input must match
**`path_regex`** — here **`tokmint/test.plain.yaml`**):

```bash
repo=/path/to/util
export SECCONFIG_DIR="${repo}/path/to/your-secconfig-root"
mkdir -p "${SECCONFIG_DIR}/tokmint"

# Plain profile (input file for sops -e)
cat > "${SECCONFIG_DIR}/tokmint/test.plain.yaml" <<'EOF'
bases:
  - base_url: https://tenant.example.com
    tokens:
      - token_id: default
        token_value: my-sops-secret
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
    encrypted_regex: '^token_value\$'
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
