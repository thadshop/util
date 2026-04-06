---
description: Bash script formatting style for this project
globs: "**/*.{sh,bash}"
alwaysApply: true
---

# Bash Formatting Style

**Naming:** **`*.bash`** — source only; **`*.sh`** — executable entrypoints
(see **keyring/README.md**).

When editing Bash scripts in this project, follow these conventions:

## Line Length
- Maximum 80 characters per line

## Indentation
- 4 spaces for indentation (not 2)

## Comments
- Place function comments inside the function body, directly under the function name
- For long comments: continue on the next line (do not exceed 80 chars)

## Line Continuation
- Use backslash (`\`) to continue long commands
- Indent continuation lines 2 spaces from the first line
- All continuation lines use the same indent (do not add more indent for each subsequent line)

## Variables
- Wrap all variable references in `${}` (e.g. `${var}`, not `$var`)

## Output
- Use `printf` instead of `echo`
- Always use `printf '%s'` or `printf '%s\n'` with content as the argument
  (never inline variables in the format string):
  - Literals: `printf '%s\n' 'message'`
  - With variables: `printf '%s\n' "message ${var} suffix"`
  - Raw output (piping): `printf '%s' "${var}"`
  Safe when var contains `%` or `\` because the value is a separate argument.

## Example

```bash
keyring_kek_exists() {
    # Return 0 if KEK exists in keyring, 1 otherwise
    local keyring_id
    keyring_id=$(keyring_get_keyring)
    [[ -n "${keyring_id}" ]] && \
      keyctl search "${keyring_id}" user \
      "${KEYRING_KEK_KEY_NAME}" >/dev/null 2>&1
}
```