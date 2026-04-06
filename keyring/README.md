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
- `age` (`age-keygen`): `apt install age`
- `openssl`: usually pre-installed; `apt install openssl` if needed
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
- `edit-encrypted-common.bash` — Shared prompts (sourced; not run alone) for the
  two edit workflows below.
- `edit-encrypted.sh` — Interactive **new** / **edit** for **`encrypt.sh`**
  / **`decrypt.sh`** (OpenSSL + KEK): cleartext only under **`/dev/shm`**,
  validate decrypt to **`/dev/null`**, backup prompts on **edit**. For
  **sops** profiles, use **`secconfig/scripts/edit-encrypted-config.sh`**.
  See **`EDIT_ENCRYPT_WORKFLOW.md`** in this directory.
- `rotate-kek.sh` — Rotate KEK and re-encrypt DEK. Creates DEK if missing.
- `encrypt.sh` / `decrypt.sh` — OpenSSL AES helpers using the KEK; **`-i`**
  **FILE** is required (**`-`** or **`/dev/stdin`** for stdin); **`-o`** defaults
  to **`/dev/null`** for both (no accidental cleartext on the terminal for
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

When `keyring-test.enc` exists (created by `rotate-kek.sh`), init verifies your
passphrase can decrypt it before storing the KEK. `keyring-test.enc` uses the same
sops/age path as typical config encryption, so a successful decrypt confirms
your DEK and sops workflow match what [secconfig](../secconfig/README.md)
expects.

## Test files in this directory

**Not for production secrets:**

- `keyring-test.txt` — committed cleartext used only to build
`keyring-test.enc` for init passphrase checks. Dummy message only.
- `keyring-test.enc` — generated by `rotate-kek.sh` (usually gitignored).
- `dek.encrypted` — your DEK, encrypted with the KEK (gitignored).

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

**Migration from older builds:** The kernel key name was `util_secrets_kek`;
new installs use `util_keyring_kek`. After updating, run
`source /path/to/util/keyring/init.bash` again (or re-add the KEK) so a key exists
under the new name. If you still have `secrets-test.enc`, rename it to
`keyring-test.enc` (or run **`rotate-kek.sh`** to regenerate it).

## DEK (Data Encryption Key)

The DEK is an **age private key** used by sops for file encryption. It is
stored **encrypted** at `dek.encrypted` (OpenSSL AES-256-CBC + PBKDF2, keyed by
the KEK). Run `rotate-kek.sh` to create it (when missing) or to rotate the KEK
and re-encrypt. Requires: age-keygen, openssl.