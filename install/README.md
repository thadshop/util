# util installer

Linux-only scripts in this directory. Run from your **util clone** (any working
directory is fine; paths below are relative to the repo root).

```bash
cd /path/to/util
./install/install.sh install    # or: ./install/install.sh help
```

Run with **no arguments** or **`help`** to print usage, commands, install
defaults, and environment variables (same tables as below, in the terminal).

Full environment-variable reference for **keyring**, **secconfig**, and
**tokmint** after install: [../CLAUDE.md](../CLAUDE.md) (Environment variables).

## Before you run

### You do not need any util env vars for `check` or `venv`

`check` and `venv` only need system packages and `python3.12` on `PATH`. They
ignore `SECCONFIG_DIR`, `KEYRING_DATA_DIR`, and other runtime variables.

### Optional before `configure` / `install`

| Variable | When it matters | Default if unset |
|----------|-----------------|------------------|
| **`SECCONFIG_DIR`** | Default answer at the **configure** prompt | `~/secconfig` |

If you already know where configs should live, set it before configure:

```bash
export SECCONFIG_DIR="$HOME/myapp/config"
./install/install.sh configure
```

Press Enter at the prompt to accept that path, or type another. Relative paths
are resolved against your **current working directory**, not the repo root.

The installer does **not** read `TOKMINT_SECCONFIG_SUBDIR`, `KEYRING_*`, or
`TOKMINT_*` during install; those are documented below for **after** install.

### Fixed install paths (not overridden by env)

| Path | Purpose |
|------|---------|
| `tokmint/.venv/` | Python 3.12 venv (git-ignored) |
| `install/merge_sops_yaml.py` | `.sops.yaml` merge helper |
| `python3.12` | Hard-coded interpreter name for venv and `check` |

### After `configure` — written for you

`configure` creates (mode **700** dirs, **600** files):

- `$SECCONFIG_DIR/.sops.yaml`
- `$SECCONFIG_DIR/tokmint/` (profiles go here as `*.enc.yaml`)
- `$SECCONFIG_DIR/env.bash` — **source this** in new shells

`env.bash` sets **`SECCONFIG_DIR`** and comments out common optional variables.

## Environment variables (runtime)

### Required for tokmint / secconfig

| Variable | Recommended value | Set by |
|----------|-------------------|--------|
| **`SECCONFIG_DIR`** | Path you chose at configure (e.g. `$HOME/secconfig`) | `env.bash` |

### Optional (defaults in parentheses)

| Variable | Component | Default |
|----------|-----------|---------|
| **`TOKMINT_SECCONFIG_SUBDIR`** | tokmint | `tokmint` → profiles under `$SECCONFIG_DIR/tokmint/` |
| **`KEYRING_DATA_DIR`** | keyring | `~/.local/share/util/keyring` |
| **`KEYRING_OPENSSL_BIN`** | keyring | `/usr/bin/openssl` |
| **`KEYRING_DEK_WRAP_RECIPE_DIR`** | keyring | `keyring/dek-wrap-recipes` in the clone |
| **`TOKMINT_PORT`** | tokmint | `9876` |
| **`TOKMINT_LOG_LEVEL`** | tokmint | `INFO` |
| **`TOKMINT_UNSAFE_LOGGING`** | tokmint | unset (do not enable in production) |
| **`TOKMINT_JSONL_FMT_FLUSH_MS`** | jsonl-fmt | `1000` |

Keyring init is separate: `source /path/to/util/keyring/init.bash` (passphrase;
not stored in `env.bash`).

## Quick start

```bash
git clone …/util.git
cd util
./install/install.sh install
```

Then:

```bash
. "${SECCONFIG_DIR}/env.bash"
source /path/to/util/keyring/init.bash
tokmint/.venv/bin/python -m tokmint
```

## Commands

| Command | Purpose |
|---------|---------|
| `check` | Ubuntu/Debian apt packages, `python3.12`, `pip`, binaries (`sops`, `age`, …) |
| `venv` | Create `tokmint/.venv` and `pip install -e secconfig -e 'tokmint/[dev]'` |
| `configure` | Prompt for `SECCONFIG_DIR`, create `tokmint/`, merge `.sops.yaml`, write `env.bash` |
| `install` | `check` → `venv` → `configure` |

`configure` requires the venv (run `venv` first, or use `install`).

## Layout created

- **`$SECCONFIG_DIR/`** — mode `700`; holds `.sops.yaml` and `env.bash` (`600`)
- **`$SECCONFIG_DIR/tokmint/`** — mode `700`; encrypted profiles (`*.enc.yaml`)

## `.sops.yaml` merge

`merge_sops_yaml.py` (run via the venv):

- **New file:** tokmint `creation_rules` from `tokmint/examples/sops.example.dot-sops.yaml`, then the secconfig catch-all from `secconfig/examples/SECCONFIG_DIR.sops.yaml.example`.
- **Existing file:** inserts missing tokmint rules (matched by `path_regex`) **before** the first global catch-all (`.*\.yaml$` / `.*\.ya?ml$`). Backs up to `.sops.yaml.bak.<timestamp>`. Invalid YAML aborts.
- Re-run is idempotent when tokmint rules are already present.

If the keyring DEK is available, `configure` may replace `age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY` using `keyring/get-age-public-key.sh`.

PyYAML round-trip may drop YAML comments in `.sops.yaml`; edit manually if needed.

## Tests

```bash
./install/install.sh venv
tokmint/.venv/bin/python -m pytest install/tests/ -q
```

## Permissions

The installer enforces **700** on `SECCONFIG_DIR` and `tokmint/` and **600** on files it writes. An existing config directory with looser permissions must be fixed before `configure` will proceed.
