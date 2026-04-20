# Design: cleartext-in-shm encrypt / re-encrypt workflow

**Status:** implemented as two entrypoints + shared helpers; refine as needed.

## Purpose

Enable developers and admins to **create or change config that contains
secrets** without leaving **cleartext secrets on normal disk**. Cleartext
exists only under **`/dev/shm`** for short-lived edit sessions. The durable
artifact is always the **encrypted** file.

## Principles

- **Cleartext:** only in **`/dev/shm`**, named and removed by the workflow
  (including on **exit, cancel, or interrupt**).
- **User editing:** outside the script (editor, IDE, etc.); the workflow pauses
  and resumes when the user returns.
- **Validate:** after writing encrypted output, confirm the file **decrypts
  successfully** before treating the step as done.
- **First encrypt:** destination path and filename for the encrypted file may
  be **chosen by the user** (subject to project layout / tooling rules).
- **Re-encrypt:** the encrypted file on disk must end up at the **same path**
  as the file the user chose to edit.

## Entrypoints

| Script | Stack | When to use |
|--------|--------|-------------|
| **`keyring/new-encrypted.sh`** | **`encrypt.sh`** / **`decrypt.sh`** (**age**, DEK recipient) | New standalone ciphertext, **not** sops. |
| **`keyring/edit-encrypted.sh`** | same | Edit an existing **age** ciphertext **in place** (after backup prompts). |
| **`secconfig/scripts/new-encrypted-config.sh`** | **sops** + **`with-sops-dek.sh`** | New ciphertext; **`SECCONFIG_DIR`**, **`.sops.yaml`**. |
| **`secconfig/scripts/edit-encrypted-config.sh`** | same | Edit an existing encrypted file **in place** (after backup prompts). |

**Keyring (age blobs):** **`keyring/.work-encrypted.bash`** (source only);
**`new-encrypted.sh`** / **`edit-encrypted.sh`** set **`WE_MSG_PREFIX`** and
call **`we_new`** or **`we_edit`**. With no file argument,
**`edit-encrypted.sh`** lists ciphertexts under **`SECCONFIG_DIR`** when
possible, otherwise prompts for a path (**`/dev/tty`** if available, else
**stdin**; empty input aborts).

**Secconfig (sops):** **`secconfig/scripts/.work-encrypted-config.bash`**
(source only); entry scripts set **`WE_MSG_PREFIX`** then call **`wek_new`**
or **`wek_edit`**. Same **no-argument** listing / path behavior for
**`edit-encrypted-config.sh`**.

Shared interactive helpers (**`we_*`**: edit instructions, backup prompts,
empty-file loop, **`/dev/shm`** check, etc.) live in **`keyring/lib.bash`**
(both work scripts **`source`** **`lib.bash`** first). The simple
“full path for new encrypted file” prompt is **`we_read_new_encrypted_path_and_mkdir`**
(distinct from **`we_new_prompt_output_path_and_mkdir`** /
**`wek_new_prompt_output_path_and_mkdir`**, which handle **`SECCONFIG_DIR`**
directory picking).

## Use case 1 — New cleartext, first encryption

1. **Start:** Workflow creates an **empty** file under **`/dev/shm`**, prints
   its **full path**, and instructs the user to save and return.
2. **Edit:** User edits and saves **outside** the workflow.
3. **Continue:** User presses Enter; optional **empty-file** **`p` / `e` /
   `a`** loop; user specifies the **new** encrypted path (**`new-encrypted.sh`**
   or **`new-encrypted-config.sh`** with **`SECCONFIG_DIR`**: directory list
   with file hints, then basename, or full path; may confirm **`mkdir`**).
4. **Finish:** Workflow encrypts, **validates**, **`mv`** into place, removes
   shm cleartext.

## Use case 2 — Edit an existing encrypted file

1. User passes the **live** ciphertext path.
2. **Decrypt** to **`/dev/shm`**; same edit / Enter / empty-file behavior as
   use case 1.
3. **Backup** of the previous ciphertext (path prompt, default **`.old`**,
   overwrite and **`mv`** loops).
4. **Re-encrypt** to the **original** path, validate, optional delete-backup
   prompt.

If encrypt/validate fails after the live file was moved to backup, stderr
prints a suggested **`mv -f …`** recovery line (**`%q`**-escaped paths).

## sops-specific (`new-encrypted-config.sh` / `edit-encrypted-config.sh`)

- **`SOPS_CONFIG`:** **`--sops-config` / `-c`**, else **`$SECCONFIG_DIR/.sops.yaml`**
  when present.
- **Staging:** Cleartext is edited under **`/dev/shm`**, then copied to a
  **temporary plaintext path under `dirname(final output)`** named
  **`<stem>.plain.XXXXXX.yaml`** (stem from the ciphertext basename) so
  **`creation_rules`** **`path_regex`** can match **`.*\.plain\.ya?ml`** (or
  similar); ciphertext is not built straight from **`/dev/shm`**.
- **Prereqs:** **`sops`**, **`with-sops-dek.sh`**, **`get-dek.sh`**; **`GET_DEK_PATH`**
  or **`-k`**.

Refuses **`xtrace`** / **`verbose`** (via **`keyring/lib.bash`**).

## age-specific (`new-encrypted.sh` / `edit-encrypted.sh`)

- **`get-dek.sh`** via **`GET_DEK_PATH`** or **`-k` / `--get-dek`** (same
  semantics as secconfig scripts).
- **`encrypt.sh`** resolves the age recipient via **`get-age-public-key.sh`**
  (override with **`-k` / `--get-pub`** on **`encrypt.sh`** if needed).
- Plaintext can be encrypted **directly** from the shm file (no sops
  **`path_regex`** staging).

## Architecture

**`keyring/with-sops-dek.sh`** remains the single place that attaches the age
DEK to **`sops`**. **`load_config()`** and **`decrypt-config.sh`** use that
wrapper; **`new-encrypted-config.sh`** / **`edit-encrypted-config.sh`** compose
it for encrypt/decrypt/validate (via **`.work-encrypted-config.bash`**).

## Non-goals (for this document)

- Automated tests for these scripts (optional later).
- CI or non-Linux environments.

## Related

- **`secconfig/README.md`** — **`SECCONFIG_DIR`**, **`scripts/`**.
- **`keyring/README.md`**, **`keyring/lib.bash`**, **`keyring/with-sops-dek.sh`**,
  **`keyring/.work-encrypted.bash`**, **`keyring/new-encrypted.sh`**,
  **`keyring/edit-encrypted.sh`**, **`keyring/encrypt.sh`**, **`keyring/decrypt.sh`**,
  **`secconfig/scripts/.work-encrypted-config.bash`**,
  **`secconfig/scripts/new-encrypted-config.sh`**, **`secconfig/scripts/edit-encrypted-config.sh`**.
