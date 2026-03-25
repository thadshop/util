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

### `secconfig/`

Python package: load **YAML** configs with **sops**-encrypted values (uses
`keyring/get-dek.sh` for the age key). Shell helpers in **`secconfig/scripts/`**
call **`keyring/with-sops-dek.sh`** for decrypt; expect the full **util** repo.

```bash
pip install -e secconfig/
```

**[→ Full documentation: secconfig/README.md](secconfig/README.md)**

## Where to keep real secrets

Do **not** store production secrets in this repo’s sample paths
(`keyring/secrets-test.*`, `secconfig/examples/`). Keep real encrypted configs
and `.sops.yaml` in **your application** directory; use `SECCONFIG_DIR` and
`load_config()` as described in **secconfig**’s README.

Shell helpers that handle passphrases refuse unsafe modes (e.g. `bash -x`);
see **[keyring/README.md](keyring/README.md)** under **Security: leak
prevention**.
