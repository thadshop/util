# Keyring (Linux kernel keyring)

**Shell scripts:** **`*.bash`** — source only (`source path/file.bash`); do not
execute. **`*.sh`** — run as programs (`./script.sh` / `bash script.sh`); do not
source. Each file states the same at the top.

Reusable utilities for secrets on Linux using the kernel keyring, with a
foundation for age and sops. **No cleartext secrets on disk.**

Repository overview: [../README.md](../README.md). Python config helper:
[../secconfig/README.md](../secconfig/README.md).

## How it works

- **First login since boot:** You are prompted for a passphrase (input is
  hidden). It is hashed (SHA256) and stored in your kernel keyring (per-user,
  survives logout).
- **Subsequent logins (same user, machine still running):** The KEK is
  already in the keyring. No user interaction—access is automatic. Scripts can
  call `keyring_get_kek` immediately.
- **After reboot or keyring expiry:** Keyring is cleared; next login prompts
  again.

## Platforms

- **Ubuntu server/workstation:** Uses persistent keyring. Expiry configurable
  via `/proc/sys/kernel/keys/persistent_keyring_expiry` (default: 3 days).
  Add `refresh-expiry.sh` to crontab to reset the expiry timer.
- **Ubuntu on WSL2:** Falls back to user keyring (`@u`) when `get_persistent`
  is not supported. User-scoped persistence works; no expiry timer.

## Prerequisites

- Linux with kernel keyring support
- `keyutils` (`keyctl`): `apt install keyutils`
- `sops`: https://github.com/getsops/sops/releases or:
  `go install github.com/getsops/sops/v3/cmd/sops@latest`
- `openssl` for **`dek.encrypted`** wrap (pinned path **`KEYRING_OPENSSL_BIN`**,
  default **`/usr/bin/openssl`**). **`keyring_check_prereqs`** runs a **recipe
  smoke test** (PBKDF2 round-trip) before use.
- Committed **DEK wrap recipes** under **`dek-wrap-recipes/`** (override dir with
  **`KEYRING_DEK_WRAP_RECIPE_DIR`**). See **`dek-wrap-recipes/README`**.
- **`dek-wrap-test-vectors.bash`** (next to **`lib.bash`**) — fixed smoke inputs
  for **`keyring_check_prereqs`**; must stay with the repo copy of **`lib.bash`**.
- `age` (`age` and `age-keygen`): `apt install age` — **`encrypt.sh`** /
  **`decrypt.sh`**, **sops**, and the age DEK key material.
- `/dev/shm` (tmpfs): standard on Linux
- Bash 4+

Init fails with a clear message if any prerequisite is missing.

## Setup

1. Clone this repo and add to your shell profile (e.g. `~/.profile` or
   `~/.bashrc`):

   ```bash
   source /path/to/util/keyring/init.bash
   ```

2. On first interactive login, enter your passphrase when prompted.

Secret data files (`dek.encrypted`, `keyring-test.enc`) live outside the repo
under **`~/.local/share/util/keyring/`** by default. Override with:

```bash
export KEYRING_DATA_DIR="/your/preferred/path"
```

Set this before sourcing `init.bash` (e.g. earlier in the same profile file).
`rotate-kek.sh` creates the directory on first run.

## Usage

After sourcing, the KEK is in your keyring. To retrieve it in scripts:

```bash
# Bash: use helper script (works from any directory)
kek=$(/path/to/util/keyring/get-kek.sh -o /dev/stdout) || exit 1

# Or source the library and call directly
source /path/to/util/keyring/lib.bash
kek=$(keyring_get_kek) || exit 1
```

**Helper scripts** (in this directory):

- `get-kek.sh` — Output KEK; default `-o /dev/null`. Use `-o /dev/stdout` (or
  a file) when you need the material.
- `get-dek.sh` — Output decrypted DEK (for sops/age); same `-o` semantics as
  `get-kek.sh`.
- `get-age-public-key.sh` — Print the **age public** line (`age1…`) for the DEK
  (for **`$SECCONFIG_DIR/.sops.yaml`**); uses **`/dev/shm`** briefly.
- `with-sops-dek.sh` — Run a command with **`SOPS_AGE_KEY_FILE`** set from
  **`get-dek.sh`** (tmp under **`/dev/shm`**), optionally **`SOPS_CONFIG`**
  from **`-c`**. **`secconfig/scripts/decrypt-config.sh`** and future workflows
  should use this so DEK handling stays in **keyring**.
- `.work-encrypted.bash` — Source only (do not run). Shared implementation for
  **`new-encrypted.sh`** and **`edit-encrypted.sh`** (interactive paths,
  encrypt/validate); entry scripts set **`WE_MSG_PREFIX`** then call **`we_new`**
  or **`we_edit`**. Interactive **`we_*`** helpers are in **`lib.bash`**.
- `new-encrypted.sh` — Create a new encrypted file: edit in **`/dev/shm`**,
  encrypt with **`encrypt.sh`** (age, DEK recipient). With **`$SECCONFIG_DIR`**:
  directory list then basename prompt.
- `edit-encrypted.sh` — Edit an existing encrypted file: decrypt to
  **`/dev/shm`**, edit, re-encrypt (backup prompts). With **`$SECCONFIG_DIR`**:
  file picker. For **sops** profiles use
  **`secconfig/scripts/new-encrypted-config.sh`** /
  **`secconfig/scripts/edit-encrypted-config.sh`**.
- `rotate-kek.sh` — Rotate KEK and re-encrypt DEK. Creates DEK if missing.
- `encrypt.sh` / `decrypt.sh` — age helpers using the DEK; **`-i`** FILE is
  required (**`-`** or **`/dev/stdin`** for stdin); **`-o`** defaults to
  **`/dev/null`** for both (no accidental cleartext on the terminal for
  **`decrypt.sh`** unless you set **`-o`**).
- `test-decryption.sh` — Test decryption will work. Exits 0 if OK, 1 otherwise.

## Keyring key name

The KEK is stored as `util_keyring_kek`. Inspect with:

```bash
# Ubuntu (persistent keyring)
persistent_id=$(keyctl get_persistent @s)
keyctl search "$persistent_id" user util_keyring_kek

# WSL2 (user keyring)
keyctl search @u user util_keyring_kek

keyctl pipe <key_id>
```

## Preventing expiry (Ubuntu only)

On Ubuntu (persistent keyring), the keyring expires after inactivity (default:
3 days). Add `refresh-expiry.sh` to your crontab to reset the timer. On
WSL2, this script is a no-op.

```bash
# Daily at 2am
0 2 * * * /path/to/util/keyring/refresh-expiry.sh

# Or every 12 hours
0 */12 * * * /path/to/util/keyring/refresh-expiry.sh
```

Use `crontab -e` to edit your user crontab. The script runs silently on success;
it only prints to stderr on failure.

## Keyring fallback

On Ubuntu server/workstation, the persistent keyring is used. On WSL2 (where
`get_persistent` is not supported), the library falls back to the user
keyring (`@u`). Both provide user-scoped persistence across sessions.

## Passphrase validation

When `keyring-test.enc` exists (created by `rotate-kek.sh` under
`$KEYRING_DATA_DIR`), init verifies your passphrase can decrypt it before
storing the KEK. `keyring-test.enc` uses the same sops/age path as typical
config encryption, so a successful decrypt confirms your DEK and sops workflow
match what [secconfig](../secconfig/README.md) expects.

## Data files (outside the repo)

`rotate-kek.sh` writes secret data files to `$KEYRING_DATA_DIR`
(default `~/.local/share/util/keyring/`):

- `dek.encrypted` — your DEK, encrypted with the KEK (**util header** +
  **openssl enc**; see **`dek-wrap-recipes/`**).
- `dek.encrypted.meta` — autogenerated OpenSSL/recipe metadata (human-oriented).
- `keyring-test.enc` — sops-encrypted test blob for passphrase validation.

These files never enter the repo. `keyring-test.txt` (the committed cleartext
template `rotate-kek.sh` reads to build `keyring-test.enc`) stays here in
`keyring/`.

Do not commit real secrets here. Sample YAML for the Python package lives
under `../secconfig/examples/`.

## Security: leak prevention

The library refuses to run when `set -x` (xtrace) or `set -v` (verbose) is
enabled, since both can echo the passphrase. Disable with `set +x` and
`set +v` before calling `keyring_init` or `keyring_get_kek`.

Other considerations: avoid running with `bash -x` or `bash -v`; be cautious
with command logging or audit systems that may capture expanded command lines;
consider `HISTCONTROL=ignorespace` if you type secrets-related commands
manually.

## DEK (Data Encryption Key)

The DEK is an **age private key** used by **sops** and by **`encrypt.sh`** /
**`decrypt.sh`** for arbitrary ciphertext. On disk it lives in **`dek.encrypted`**
as:

1. A **16-byte binary header**: 8-byte ASCII magic (`UTILDEK1` in recipe 01),
   header format major/minor (not OpenSSL’s version), **recipe id** uint16
   big-endian (selects **`dek-wrap-recipe-NN.conf`**), then **payload length**
   uint32 big-endian.
2. Raw **`openssl enc`** output for that recipe (e.g. AES-256-CBC, **PBKDF2**,
   salt, iteration count, digest — all defined in the recipe file).

The KEK material passed to **`openssl -pass file:`** is the SHA-256 **hex**
string of your login passphrase. **`rotate-kek.sh`** is **interactive only**
(stdin/stdout must be a TTY); it runs **`keyring_check_prereqs`** (including the
openssl smoke test) before changing keys.

Regression check: **`testdata/verify-dek-wrap-golden.sh`** (committed sample
ciphertext). Requires: **openssl**, **age**, **age-keygen**, recipe files.