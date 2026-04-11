# util

**Personal utilities developed by Thad Anders, which I hope others find useful
too. Please let me know!**

**Linux only.** Everything in this repo targets Linux; other platforms are not
supported.

## Contents

### `keyring/`

Shell library and scripts for Linux **kernel keyring** secrets: passphrase →
KEK, wrapped **age** DEK on disk, **sops**-friendly helpers. **No cleartext
secrets on disk** for that stack.

**[→ Full documentation: keyring/README.md](keyring/README.md)**

Scripts use **`.bash`** for files you **`source`** and **`.sh`** for files you
**run**; see the note at the top of that README.

### `secconfig/`

Python package: load **YAML** configs with **sops**-encrypted values (uses
`keyring/get-dek.sh` for the age key). Shell helpers in **`secconfig/scripts/`**
call **`keyring/with-sops-dek.sh`** for decrypt; expect the full **util** repo.

```bash
pip install -e secconfig/
```

**[→ Full documentation: secconfig/README.md](secconfig/README.md)**

### `tokmint/`

Local HTTP service (FastAPI, `localhost:9876`) that mints API tokens for
tools like Postman. Reads **sops**-encrypted YAML profiles via **secconfig**:
**Mode A** returns a static credential; **Mode B** performs an OAuth 2.0
**client_credentials** grant supporting **`client_secret_post`**,
**`client_secret_basic`**, and **`private_key_jwt`** client authentication,
with optional **DPoP**-bound tokens.

```bash
pip install -e secconfig/ -e tokmint/
python -m tokmint
```

**[→ Full documentation: tokmint/README.md](tokmint/README.md)**

## Where to keep real secrets

Do **not** store production secrets in this repo’s sample paths
(`keyring/keyring-test.*`, `secconfig/examples/`). Keep real encrypted configs
and `.sops.yaml` in **your application** directory; use `SECCONFIG_DIR` and
`load_config()` as described in **secconfig**’s README.

Shell helpers that handle passphrases refuse unsafe modes (e.g. `bash -x`);
see **[keyring/README.md](keyring/README.md)** under **Security: leak
prevention**.
