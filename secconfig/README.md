# secconfig

Load YAML config files with sops-encrypted secrets. Uses the repo's
`keyring/get-dek.sh` to obtain the age key; no cleartext secrets on disk.

**Linux only.** Requires `/dev/shm` (tmpfs); cleartext keys are never written to disk.

## Requirements

- Linux (with `/dev/shm`)
- Python 3.9+
- PyYAML: `pip install pyyaml`
- [sops](https://github.com/getsops/sops) installed and in `PATH`: https://github.com/getsops/sops/releases or: `go install github.com/getsops/sops/v3/cmd/sops@latest`
- Keyring initialized (source `keyring/init.sh`, run
  `rotate-kek.sh` to create DEK if needed)

Importing secconfig runs a prerequisite check. If any are missing, import fails
with a clear message listing what to fix.

## Project directory (`SECCONFIG_DIR`)

Optional. Set this environment variable to the directory that holds
encrypted configs, `.sops.yaml`, and other sops metadata:

```bash
export SECCONFIG_DIR=/path/to/your/app-config
```

If set, it is validated at import (and when loading config): the path must
exist, be a directory, and be readable and searchable. If not, errors include
the resolved path and reason (missing, not a directory, permission denied).

Relative paths passed to `load_config()` are resolved under `SECCONFIG_DIR`.
Absolute paths are unchanged. When decrypting, if `.sops.yaml` exists directly
under `SECCONFIG_DIR`, it is passed to sops via `SOPS_CONFIG`. A starter file
is `examples/example-SECCONFIG_DIR.sops.yaml` (copy it to
`$SECCONFIG_DIR/.sops.yaml` and set `age:`).

## Installation

```bash
pip install -e /path/to/util/secconfig
```

## Usage

```python
from pathlib import Path
from secconfig import SECCONFIG_DIR_ENV, load_config

# With SECCONFIG_DIR set in the environment:
config = load_config("config.enc.yaml")

# Or an absolute path:
config = load_config(Path("/path/to/config.enc.yaml"))
```

For sops-encrypted files, the package automatically detects encryption and
decrypts using the DEK from the kernel keyring (via get-dek.sh).

## Security

The package refuses to run when:

- A debugger is attached (`sys.gettrace()`)
- A profiler is active (`sys.getprofile()`)
- Python was started with `-d` or `-v`
- `faulthandler` is enabled

This reduces the risk of secrets leaking via stack dumps or verbose output.

## Test fixtures vs real config

**Real configs** belong in your app directory (often via `SECCONFIG_DIR` and
paths you pass to `load_config`). Store production `.sops.yaml` and encrypted
files there.

**This repo (examples and scripts):**

| Path | Role |
|------|------|
| `examples/example-config.yaml` | Plain YAML sample for tests |
| `examples/example-config.enc.yaml` | Encrypted sample (regenerate with script below) |
| `examples/.sops.yaml` | Local sops rules for the sample encrypt script (often gitignored) |
| `examples/create-sample-encrypted.sh` | Builds `example-config.enc.yaml` and `.sops.yaml` for `tests/` |
| `examples/example-SECCONFIG_DIR.sops.yaml` | Template for `$SECCONFIG_DIR/.sops.yaml` (e.g. `encrypted_suffix: '_secrypt'`) |
| `scripts/encrypt-config.sh` | Encrypt one plain `*.yaml` under `SECCONFIG_DIR` → `*.enc.yaml` |
| `scripts/decrypt-config.sh` | Decrypt to stdout (cleartext warning + confirm `y`) |

Keyring init fixtures live under `../keyring/` (`secrets-test.txt` /
`secrets-test.enc`); see [keyring/README.md](../keyring/README.md).

## Testing

```bash
cd secconfig/
pip install -e .
python tests/test_config.py
```

To test decryption before loading encrypted configs:

```bash
python tests/test_decryption.py
```

For plain config only, `examples/example-config.yaml` is included. To test
with encrypted config:

```bash
cd examples/
./create-sample-encrypted.sh   # example-config.enc.yaml from example-config.yaml
cd ..
python tests/test_config.py
```

## Creating encrypted config files

**No bash script per config file.** Use a `.sops.yaml` file in your project (or
directory) to define which files get encrypted and which keys within them.

### 1. Create `.sops.yaml`

Place it in your project root or alongside your config files. sops looks for it
in the current directory and parents.

```yaml
creation_rules:
  # Matched against the file you pass to sops -e (plaintext path), not --output.
  - path_regex: myconfig(\.enc)?\.yaml$
    age: age1xxxxxxxxxxxx         # your age public key
    encrypted_regex: '^password$' # only encrypt keys named "password"
```

**Key options** (use one per rule; they are mutually exclusive):

| Option               | Effect                                      |
|----------------------|---------------------------------------------|
| `encrypted_regex`    | Encrypt only keys matching the regex        |
| `encrypted_suffix`   | Encrypt only keys ending with suffix (e.g. `_secret`) |
| `unencrypted_regex`  | Encrypt all except keys matching regex      |
| `unencrypted_suffix` | Encrypt all except keys with suffix (default: `_unencrypted`) |

### 2. Get your age public key

```bash
# From your DEK (after rotate-kek.sh). Key must be in a file; use /dev/shm:
path/to/get-dek.sh > /dev/shm/age-key && age-keygen -y /dev/shm/age-key
rm -f /dev/shm/age-key
```

Or use `create-sample-encrypted.sh` as a reference; it does this automatically.

### 3. Encrypt

```bash
sops -e --output example-config.enc.yaml example-config.yaml
```

`sops` matches `path_regex` against the **input** file (`example-config.yaml`
here). Use `--output` only to choose where the ciphertext is written; it does
not change which creation rule applies.

### Helper script (`scripts/encrypt-config.sh`)

With `SECCONFIG_DIR` set and `$SECCONFIG_DIR/.sops.yaml` in place, encrypt a
plaintext tree file to the matching `*.enc.yaml` next to it:

```bash
export SECCONFIG_DIR=/path/to/your/config
/path/to/util/secconfig/scripts/encrypt-config.sh subdir/myapp.yaml
# creates subdir/myapp.enc.yaml
```

`-f` / `--force` overwrites an existing output file; `--help` lists options.
The script checks the output directory is writable before calling sops. It sets
`SOPS_CONFIG` to the root `.sops.yaml`; it does not need `get-dek.sh`
(encryption uses public `age:` recipients only).

### Decrypt helper (`scripts/decrypt-config.sh`)

Print decrypted YAML to stdout (runs `get-dek.sh`, writes the DEK to a
`/dev/shm` file, sets `SOPS_AGE_KEY_FILE`, then `sops decrypt`). It first
prints a cleartext warning on stderr and requires typing lowercase `y`
(default is no):

```bash
export SECCONFIG_DIR=/path/to/your/config
/path/to/util/secconfig/scripts/decrypt-config.sh subdir/myapp.enc.yaml
```

`-k` / `--get-dek` / `GET_DEK_PATH` sets the path to `get-dek.sh`
(the executable that prints the DEK), not a file that stores the key.
Default is `../../keyring/get-dek.sh` relative to the script. If
`$SECCONFIG_DIR/.sops.yaml` exists, it is exported as `SOPS_CONFIG` (same as the
Python loader). `--help` lists options.

### References

- [sops documentation](https://sops.pages.dev/)
- [creation rules](https://github.com/getsops/sops#encrypting-using-age)
