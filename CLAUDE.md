# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Three complementary Linux-only tools for managing API credentials and secrets securely:

- **`keyring/`** — Bash library/scripts wrapping the Linux kernel keyring to store a KEK (Key Encryption Key) and encrypted DEK (age private key)
- **`secconfig/`** — Python package that loads sops-encrypted YAML configs, delegating decryption to the keyring scripts
- **`tokmint/`** — FastAPI service (localhost:9876) that mints API tokens for Postman by reading token profiles via secconfig

Targets Ubuntu server, workstation, and WSL2 exclusively.

## Commands

### tokmint

```bash
cd tokmint

# Create/activate venv (first time)
python3 -m venv .venv
.venv/bin/pip install -e ../secconfig -e ".[dev]"

# Run tests
.venv/bin/python -m pytest tests/ -q

# Run a single test file
.venv/bin/python -m pytest tests/test_mode_b.py -q

# Run a single test
.venv/bin/python -m pytest tests/test_phase1.py::test_name -q

# Lint
.venv/bin/ruff check .
.venv/bin/ruff format --check .

# Start service
.venv/bin/python -m tokmint

# Start service with VERBOSE logging, pretty array output per request
TOKMINT_LOG_LEVEL=VERBOSE .venv/bin/python -m tokmint 2>&1 | .venv/bin/jsonl-fmt -a
```

### secconfig

```bash
cd secconfig

# Install (editable)
pip install -e .

# Run tests (requires SECCONFIG_DIR set and keyring initialized)
python -m pytest tests/ -q
```

### keyring

```bash
# Initialize (one-time per machine — prompts for passphrase)
bash keyring/init.bash

# Refresh keyring expiry (suitable for crontab)
bash keyring/refresh-expiry.sh

# Rotate KEK
bash keyring/rotate-kek.sh

# Edit an encrypted file interactively
bash keyring/edit-encrypted.sh <file.enc>
```

## Architecture

### Security model

- **No cleartext secrets on disk** — DEK stored as `keyring/dek.encrypted` (age key encrypted with KEK)
- **KEK lives only in the kernel keyring** — survives session but not reboot; initialized from passphrase hash
- **Cleartext only under `/dev/shm`** (tmpfs) — all edit workflows write cleartext here temporarily
- **Python never sees the DEK** — `keyring/with-sops-dek.sh` sets `SOPS_AGE_KEY_FILE` to a tmpfs path and runs the command as a subprocess; secconfig calls this script rather than reading the key directly

### Data flow

1. `keyring/init.bash` — prompts passphrase → hashes → stores KEK in kernel keyring; encrypts DEK with KEK
2. `secconfig.load_config(path)` — shells out to `keyring/with-sops-dek.sh sops --decrypt ...` → returns Python dict
3. `tokmint` — receives `POST /v1/token?profile=<name>`, loads `$SECCONFIG_DIR/tokmint/<name>.enc.yaml` via secconfig, returns token

### tokmint token profiles (two modes)

- **Mode A** — static token stored directly in profile YAML
- **Mode B** — OAuth 2.0 client credentials; profile contains endpoint, client ID, and private key reference; service fetches token from upstream; supports DPoP

Profile YAML schema is validated against `tokmint/schemas/profile.schema.json` (JSON Schema Draft 2020-12). See `tokmint/examples/tokmint.example.profile.yaml` for annotated reference.

### File naming conventions (keyring/ and secconfig/scripts/)

- `.bash` suffix — source-only library files (not directly executable)
- `.sh` suffix — executable scripts

### Environment variables

| Variable | Component | Purpose |
|---|---|---|
| `SECCONFIG_DIR` | secconfig, tokmint | Root dir for encrypted configs and `.sops.yaml` |
| `TOKMINT_SECCONFIG_SUBDIR` | tokmint | Subdir under `SECCONFIG_DIR` for profiles (default: `tokmint`) |
| `TOKMINT_PORT` | tokmint | uvicorn port (default: 9876) |
| `TOKMINT_LOG_LEVEL` | tokmint | Log verbosity: `DEBUG`, `VERBOSE`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` (default: `INFO`) |
| `TOKMINT_JSONL_FMT_FLUSH_MS` | jsonl-fmt | Burst flush timeout in ms for `-a` mode (default: 1000) |
| `SOPS_AGE_KEY_FILE` | set by `with-sops-dek.sh` | Temp path to cleartext DEK under `/dev/shm` |

## Formatting

Both Bash and Python use **80-character line limit, 4-space indentation**.

**Bash** (from `.cursor/rules/bash-formatting.mdc`):
- Always quote variables as `"${var}"`, not `$var`
- Use `printf` instead of `echo`
- Comments inside functions go on their own line above the relevant code

**Python** (from `.cursor/rules/python-formatting.mdc`):
- PEP 8 style enforced via `ruff`
- Use `PyYAML` (`import yaml`) for all YAML parsing
- Docstrings wrap at 72 characters
