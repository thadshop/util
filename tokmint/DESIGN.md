# tokmint — design notes (work in progress)

Internal notes capturing what we agreed so far. Not end-user documentation.
PyPI publication is **not** planned (private / repo-only).

## Motivation

- Need a **valid bearer token** for tools like **Postman** when calling APIs
(e.g. Okta management APIs with **OAuth 2.0 client credentials** and
**private key JWT** client authentication).
- Postman pre-request scripts became too heavy; **Postman should call a small
local service** and use the response as the bearer token.
- **tokmint** does the heavy work (JWT assertion, token exchange, decryption);
Postman stays simple.

## Foundations

- **secconfig** — load provider YAML from `SECCONFIG_DIR`; support **sops**
encryption for secrets in config (client secrets, static token values, etc.).
- **keyring** — PEM material on disk stored as **ciphertext** produced by
`keyring/encrypt.sh`; decrypted at runtime with `keyring/decrypt.sh` only
into memory (or short-lived temp under `/dev/shm`), not long-lived cleartext
next to the file.
- **Runtime assumptions** — Linux, same machine as keyring + secconfig
(aligned with existing stack).

## Name

- **tokmint** — local utility for minting tokens / credentials for Postman and
similar clients.

## Local HTTP service

- **uvicorn** (e.g. behind FastAPI or similar).
- **Bind `127.0.0.1` only** — client is only the operator on the same
workstation (no LAN exposure by default). *(Host could become configurable
later; v1 intent is loopback-only.)*
- **Listen port** — from **tokmint’s own settings** (see below), not hardcoded.
- **On-demand only** — no persistent caching of access tokens on disk;
in-memory for the duration of a request is fine.

## Tokmint service configuration

Tokmint keeps **runtime settings separate** from provider YAML under
`SECCONFIG_DIR` (no secrets in this layer beyond what the process already has).

**Intent (v1):** load from **environment variables** with documented defaults.
Env names below; default port **`9876`** is fixed for Phase 1 unless changed
here later.


| Setting | Role |
|---------|------|
| **Listen port** | TCP port for uvicorn (**`TOKMINT_PORT`**; default **`9876`**). |
| **Secconfig subdirectory** | Single name under **`SECCONFIG_DIR`** for profile YAML (**`TOKMINT_SECCONFIG_SUBDIR`**, default **`tokmint`**). No `/` or `..`; validate like **`profile`**. |


**Path:** `{SECCONFIG_DIR}/{TOKMINT_SECCONFIG_SUBDIR}/{profile}.enc.yaml`
(`SECCONFIG_DIR` continues to come from the existing secconfig convention.)

Optional later: a small **tokmint config file** (e.g. under `XDG_CONFIG_HOME`)
if env-only becomes awkward — **out of scope** until needed.

## Config layout (on disk)

- Under `**SECCONFIG_DIR`**, a subdirectory whose **name is configurable**
(default `**tokmint/`**; see **Tokmint service configuration**).
- **Profile** selects the file: `**{subdirectory}/{profile}.enc.yaml`**
Examples: `profile=okta` → `okta.enc.yaml`, `sailpoint`, `azure`, etc.

## Profile YAML schema

Loaded with **secconfig** `load_config()` relative to `**SECCONFIG_DIR`** (path
`{subdirectory}/{profile}.enc.yaml`). File may be **wholly or partly
sops-encrypted** like any other secconfig YAML.

### Top level


| Key         | Phase 1                   | Purpose                                                                               |
| ----------- | ------------------------- | ------------------------------------------------------------------------------------- |
| `**domains`** | required (non-empty list) | One object per tenant / domain (hostname).                                             |
| `**oauth**` | optional object           | Mode B: `**token_path**` + optional `**request_headers**`. Ignored in Phase 1 / Mode A. |


### `oauth` (optional)

All OAuth **token-endpoint** settings for this profile live under one key.


| Child key             | Mode B                 | Purpose                                            |
| --------------------- | ---------------------- | -------------------------------------------------- |
| `**token_path`**      | required for token URL | Path-absolute; appended to `https://` + **`domain`**; see **Token URL joining (Mode B)**. |
| `**request_headers`** | optional list          | Extra HTTP headers on that token request.          |


If `**oauth**` is **absent**, Mode B cannot be used for this profile until it
is added (Phase 1 static-only files may omit `**oauth`** entirely). If
`**oauth**` is present but `**token_path**` is missing when Mode B runs,
`**400**` / config error at load — pick at implementation.

`**oauth.request_headers`:** each list item is an object with:

- `**key`** (string) — HTTP header **name** (e.g. `Accept`, `Content-Type`).
Compare **case-insensitively** when detecting duplicates.
- `**value`** (string) — HTTP header **value**; may be **sops-encrypted** like
`**credential`** if it carries a secret (e.g. vendor-specific API key).

**Semantics (Mode B, when implemented):** these headers are sent on the OAuth
token POST (or the HTTP method we end up using for that profile). **tokmint**
may add **defaults** for a normal token request (e.g. form body
`**Content-Type`**); profile entries **override** a default when the name
matches (case-insensitive). **Duplicate `key`** in the list → invalid config,
reject at **load**. Do **not** log header `**value`** strings.

**Per profile:** the whole `**oauth`** block is per profile file (Okta vs
Azure vs SailPoint, etc.). YAML anchors can deduplicate across files if needed.

**Forward compatibility:** unknown **top-level** keys and unknown keys **under
`oauth`** should be **ignored** by tokmint (TBD at implementation; prefer
ignore).

### Each `domains[]` entry


| Key           | Phase 1            | Purpose                                                  |
| ------------- | ------------------ | -------------------------------------------------------- |
| `**domain`**  | required           | Row identity: ASCII hostname, no scheme (see below).    |
| `**tokens**`  | optional mapping   | Mode A: auth_scheme → list of `{ token_id, credential }` (see below). |
| `**clients**` | ignored in Phase 1 | Phase 2+: Mode B OAuth clients (shape TBD).              |


`**tokens**` **mapping (Phase 1):** keys are **HTTP Authorization schemes**
(e.g. **`SSWS`**, **`Bearer`**). Each key maps to a **non-empty list** of
objects; each object has:

- `**token_id`** (string) — matches the request query parameter of the same
  name; same character rules as safe config identifiers (alphanumeric, `_`,
  `-` — exact regex at implementation).
- `**credential**` (string) — the secret; typically **sops-encrypted** in the
  file (or plain for local-only files). Becomes **`access_token`** in the JSON
  response.

Scheme keys use the same character rules as schemes (letter first, then
letters, digits, **`+`**, **`.`**, **`-`**).

For **Phase 1 / Mode A**, the matching `**domains[]`** row must exist and **some
list entry under some scheme key** must have **`token_id`** equal to the request
(after the same trim rules as query params). **`token_id`** must be **unique
within that domain row across all scheme keys** — duplicates invalid config,
reject at **load**.

**Rationale:** grouping by scheme avoids repeating **`SSWS`** (or **`Bearer`**)
on every token when most rows share one scheme.

**Duplicate canonical `domain`:** invalid config — reject at **load** (or
first request) with a clear error; do not pick a random row.

### `domain` matching

Request query `**domain`** and each YAML `**domain`** use the **same**
**canonicalization** function before comparison (string equality on the
result).

#### Canonical `domain` algorithm (v1)

**Input:** a single string (after query-parameter trim rules for the request).

1. **Trim** leading and trailing **ASCII whitespace** only.
2. **Reject (`400` invalid `domain`)** when empty after trim.
3. **ASCII only:** reject any code point outside **ASCII** (no IDN / punycode
   in v1).
4. **Lowercase** the entire string (DNS hostname comparison is case-insensitive
   for ASCII labels).
5. Repeatedly strip a **trailing DNS root dot** if present (e.g.
   `tenant.example.com.` → `tenant.example.com`).
6. **Reject** if `**..**` appears or the string is empty after the steps above.
7. **Labels:** split on **`.`**. Each label must be **1–63** characters; each
   character must be **ASCII** alphanumeric or **`-`**; a label must not start
   or end with **`-`**.
8. The **canonical comparison string** is the result (hostname only: no
   scheme, no port, no path).

**Examples (conceptual):**


| Input                     | Canonical string      |
| ------------------------- | --------------------- |
| `Tenant.Okta.Com`         | `tenant.okta.com`     |
| `tenant.example.com.`     | `tenant.example.com` |


**Matching:** a `**domains[]`** row matches when its YAML **`domain`**
canonicalizes to the **same** string as the request **`domain`**.

**Duplicate canonical `domain`** in one profile file: invalid config — reject
at **load** (already stated above).

**No row matches:** `**404`** (unknown domain for this profile).

**No matching `token_id` under that row’s `tokens` mapping:** `**400`**
(unknown token for that domain).

### Token URL joining (Mode B)

The **OAuth token request URL** is built from:

1. `**B`** — `**https://` +** the **canonical `domain`** string from the
  request (same algorithm as **`domain` matching**). HTTPS is **assumed** for
  the IdP host; `**domain`** does not carry a scheme.
2. `**E`** — `**oauth.token_path**` from the profile, after trim and validation
  below.

#### Validating `**oauth.token_path**`

After **ASCII trim**:

- **Reject** (`**400`** on Mode B request, or at **profile load** — pick at
implementation) if empty, if `**scheme://`** appears (must not be an absolute
URL — v1 uses a path only), or if `**?**` / `**#**` is present.
- `**E**` must be **path-absolute**: the first character must be `**/`**
(e.g. `**/oauth2/default/v1/token**`).
- **Normalize:** strip a **trailing** `**/`** unless `**E**` is exactly `**/**`
(token paths almost never end with `**/**`).

#### Join

`**token_url**` = `**urllib.parse.urljoin(B, E)**` (or equivalent RFC 3986
reference resolution).

**Semantics:** a path-absolute `**E`** replaces the **path** (and clears query
on the base) relative to `**B`’s scheme and authority** — i.e. it is resolved
from the **host root**.

**Operator note:** Issuers like **Okta** use a **host-only** `**domain**` (e.g.
`**dev-123.okta.com**`) and a `**token_path**` under the host root (e.g.
`**/oauth2/default/v1/token**`). If the token path does not start at
the host root, encode the **full path from the host root** in `**token_path**`
(e.g. `**/identity/oauth2/v1/token**`).

**Examples** (conceptual):


| `**B**` (join base)            | `**E**`                    | `**token_url**`                                   |
| ------------------------------ | -------------------------- | ------------------------------------------------- |
| `https://tenant.okta.com`      | `/oauth2/default/v1/token` | `https://tenant.okta.com/oauth2/default/v1/token` |
| `https://corp.example.com`     | `/identity/oauth2/v1/token` | `https://corp.example.com/identity/oauth2/v1/token` |


**HTTPS:** Mode B uses **HTTPS** for `**B`**; there is no per-row **http** vs
**https** toggle in v1 (`**domain`** has no scheme).

### Example (Phase 1)

```yaml
# Optional; used when Mode B calls the token endpoint (ignored in Phase 1).
oauth:
  token_path: /oauth2/default/v1/token
  request_headers:
    - key: Accept
      value: application/json

domains:
  - domain: dev-12345.okta.com
    tokens:
      SSWS:
        - token_id: management_read
          credential: ENC[AGE-REDACTED]
        - token_id: automation
          credential: ENC[AGE-REDACTED]
  - domain: partner.example.com
    tokens:
      Bearer:
        - token_id: default
          credential: ENC[AGE-REDACTED]
```

Plain values (no sops) are allowed for local-only files; **secconfig** still
loads the YAML normally.

## HTTP contract (v1)


| Item       | Choice          | Rationale                                                                   |
| ---------- | --------------- | --------------------------------------------------------------------------- |
| **Method** | `**POST`**      | Secret body; avoids `**GET**` caching. v1 uses query string only (Postman). |
| **Path**   | `**/v1/token`** | Short, versioned, distinct from IdP `**.../token**` paths.                  |


**Full URL (illustrative):**

`http://127.0.0.1:{TOKMINT_PORT}/v1/token?profile=...&domain=...&token_id=...`
(Phase 1; omit or empty `**client_id`** / `**key_id**` as already specified.)

**Why not `GET`?** Easier in some clients, but `**GET`** + query string is more
often **logged or cached** along the path; `**POST`** is the safer default for
“return a bearer token” even on loopback.

## Query parameters (v1 intent)

### Presence vs “no value” (Postman / clients)

There are **no magic strings** for “unused” (no `null`, `__none__`, etc.). An
optional or conditional parameter has **no value set** when either:

1. The parameter **key is omitted** from the query string, or
2. The parameter **is present** but the value is **empty after trim** (leading
  / trailing ASCII whitespace stripped), e.g. `client_id=`.

**Omission and empty-after-trim are equivalent** — same mode and validation.

**HTTP / URL validity:** A URL like `?client_id=&token_id=some%20value` is
**syntactically fine**. Typical parsers expose `client_id` as present with an
**empty string**; space in `token_id` should be **percent-encoded** (`%20`) in
real requests. Any **non-empty** string after trim is a real value (including
the literal text `null` if a provider ever issued that as an id).

`**profile`** and `**domain**` are **required**: each key **must** appear with
a **non-empty** value after trim.

**Implementation note:** optional/conditional: missing key → no value. If key
is present, trim; if result is empty → no value; else use the string as the
identifier. `**profile`** / `**domain**`: required; `**400**` if missing or
empty after trim.

The rest of this doc uses **unset** to mean **no value set** as above (omit or
empty after trim).


| Parameter   | Required        | Notes                                                                                                                                                                                     |
| ----------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `profile`   | yes (non-empty) | Maps to `{profile}.enc.yaml` under the secconfig subdirectory (query param has no suffix).                                                                                                     |
| `domain`    | yes (non-empty) | ASCII hostname for the tenant/IdP (no scheme); combined with **`https://`** + canonical `**domain**` and `**oauth.token_path`** for Mode B token URL.                                       |
| `client_id` | conditional     | **Mode B** when set and non-empty. **Mode A** when unset.                                                                                                                                 |
| `token_id`  | conditional     | **Required** (non-empty) in Mode A. Unset in Mode B.                                                                                                                                      |
| `key_id`    | optional        | Only in Mode B when `client_id` is set. If set and non-empty: **encrypted PEM** (keyring) for private-key JWT. If unset: **client_secret** for that `client_id` (sops-encrypted in YAML). |


**Mutual exclusion (after unset normalization):** exactly one of Mode A and Mode
B applies — `client_id` set vs unset selects the mode; `token_id` must be
non-empty iff Mode A; `token_id` must be unset in Mode B. **Invalid:** both
`client_id` and `token_id` set and non-empty, or Mode A with unset `token_id`,
or non-empty `key_id` when not in Mode B.

## Mode A — static API token

- **When:** `client_id` unset; `token_id` non-empty.
- **Config:** `**domains[]`** row matching request `**domain**`; find the list
  entry under some **`tokens`** scheme key whose **`token_id`** matches the
  request; use that key as **`token_type`** and **`credential`** as
  **`access_token`**.
- **Behavior:** decrypt from config (via secconfig); **no** call to provider
token endpoint for issuance.
- **Response:** same JSON shape as Mode B (see below).

## Mode B — OAuth (client credentials)

- **When:** `client_id` set and non-empty (after unset normalization).
- **Token URL:** **Token URL joining (Mode B)** — `**https://` +** canonical
request `**domain**` + profile `**oauth.token_path**` via `**urljoin**`.
- **HTTP headers:** profile `**oauth.request_headers`** merged into the token
request as above (Phase 2+); defaults for standard form posts TBD in
implementation.
- **Client auth:**
  - `**key_id` non-empty** — YAML points to **PEM file encrypted with
  `encrypt.sh`**; decrypt with `**decrypt.sh**`, build **JWT client
  assertion** (RFC 7523-style); Okta is the first target.
  - `**key_id` unset** — `**client_secret`** in YAML for that `client_id`,
  **sops-encrypted**; use standard client authentication for the token
  request (exact method: body vs Basic TBD).
- **Scopes:** fixed in config / target system — **not** user-requestable via
query for now.
- **General JWT feature:** support **arbitrary JWT signing** as a building
block; Okta flow **reuses** that.

## Success response (both modes, v1)

- `**200 OK`**, `Content-Type: application/json`.
- Body (reuse OAuth-ish field names for Postman simplicity):

```json
{
  "access_token": "<string>",
  "token_type": "<scheme>"
}
```

**Mode A:** **`token_type`** is the **`tokens`** **mapping key** (scheme) for
the list that contained the matched **`token_id`**. Clients typically form
**`Authorization`** as **`token_type`**, a single space, then
**`access_token`**.

- `**expires_in`:** include when the **OAuth provider** returns it (Mode B);
**omit** for static tokens (Mode A). Postman can branch if needed.
- Alternatives (raw body, different JSON keys) **explicitly out of scope for
v1**.

## Errors and error handling (v1)

### Principles

- Every error response uses `**Content-Type: application/json`** and the **v1
error body shape** below (same as success: JSON only).
- Responses must **never** echo secrets: no raw **`credential`** value, **PEM**,
  **`client_secret`**, **assertion JWT**, raw **IdP** error payloads, or
  **`Authorization`** material in **`detail`** or any field.
- `**detail**` is for humans (operators); `**code**` is for scripts and
Postman tests. `**detail**` may name a parameter (e.g. “`domain` is
invalid”) but must not repeat untrusted input at length (cap length in
implementation).
- **Log** status code + `**code`** + request correlation if any; avoid logging
full query strings if they could contain sensitive `**token_id**` labels in
sensitive environments — at minimum never log resolved tokens.

### Error response body

All non-2xx responses use:

```json
{
  "code": "UPPER_SNAKE_CASE",
  "detail": "Short, stable English description."
}
```

Both fields are **required**. No other top-level keys in v1 (extend later only
with a doc update).

**Examples:**

```json
{
  "code": "INVALID_DOMAIN",
  "detail": "domain failed canonicalization."
}
```

```json
{
  "code": "UNKNOWN_DOMAIN",
  "detail": "No domains entry matches this domain for this profile."
}
```

### HTTP status codes (when to use which)


| Status    | Meaning                                                                                                                                                         | Typical `code` values                                                            |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `**400**` | Client mistake: bad or inconsistent query, invalid URL shape, wrong mode mix, missing required param for chosen mode, invalid `**oauth.token_path**`.             | See registry below.                                                              |
| `**404**` | Known route but **unknown resource** in tokmint’s config space: no profile file, or no matching `**domain`** row.                                              | `**UNKNOWN_PROFILE**`, `**UNKNOWN_DOMAIN**`.                                       |
| `**405**` | Wrong HTTP method (only `**POST /v1/token**` is defined for minting in v1).                                                                                     | `**METHOD_NOT_ALLOWED**`.                                                        |
| `**500**` | Server / operator misconfiguration: profile file unreadable, decrypt failure, internal bug. **Invalid profile content** (shape, duplicates, auth server paths) returns **400** `**PROFILE_INVALID**`.                          | `**PROFILE_LOAD_FAILED**`, `**INTERNAL_ERROR**`, … |
| `**502**` | Mode B: token request reached the IdP transport but failed, or IdP returned an error **after** a successful HTTP round-trip.                                    | `**UPSTREAM_ERROR`**.                                                            |
| `**503**` | Transient dependency unavailable (optional; e.g. secconfig keyring not ready). Use sparingly so operators can retry.                                            | `**SERVICE_UNAVAILABLE**`.                                                       |


`**422`:** not used in v1 — fold validation into `**400`** so clients have one
family of “fix the request” outcomes.

### Error code registry

Stable `**code**` values (implement exactly; add new codes only with a doc
update).


| `code`                         | HTTP              | When                                                                                                                                                                                                                                         |
| ------------------------------ | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `**METHOD_NOT_ALLOWED**`       | **405**           | Not `**POST`** on `**/v1/token**`.                                                                                                                                                                                                           |
| `**MISSING_PARAMETER**`        | **400**           | Required query parameter missing or empty after trim (`**profile`**, `**domain**`, or mode-specific required fields).                                                                                                                       |
| `**UNSUPPORTED_PROFILE_NAME**` | **400**           | The **`profile`** query value is not a single safe path segment: only **`[a-zA-Z0-9_-]+`** is allowed so it can be used as part of a filename under **`SECCONFIG_DIR`** without **`..`**, slashes, or spaces. Not about missing file (**`UNKNOWN_PROFILE`**) or invalid YAML (**`PROFILE_INVALID`**). |
| `**INVALID_DOMAIN**`          | **400**           | `**domain`** fails **Canonical `domain` algorithm** (non-ASCII, empty labels, `**..**`, bad label chars, etc.).                                                                                                                             |
| `**INVALID_MODE_COMBINATION**` | **400**           | After unset normalization: e.g. `**client_id`** and `**token_id**` both set; Mode A with unset `**token_id**`; `**key_id**` set when not in Mode B; Mode B with unset `**client_id**`; other impossible combinations.                        |
| `**UNKNOWN_PROFILE**`          | **404**           | No profile **file** for `**{subdirectory}/{profile}.enc.yaml`** under `**SECCONFIG_DIR**` — profile name does not exist on disk. Contrast **`PROFILE_INVALID`** (file exists but structure/content is wrong).                                  |
| `**UNKNOWN_DOMAIN**`             | **404**           | Profile loaded, canonical `**domain`** matches **no** `**domains[]`** row.                                                                                                                                                                    |
| `**UNKNOWN_TOKEN_ID**`         | **400**           | Mode A: row matches but no `**tokens`** item has this `**token_id**`.                                                                                                                                                                        |
| `**OAUTH_CONFIG_MISSING**`     | **400**           | Mode B: `**oauth`** missing, `**oauth.token_path**` missing, or `**oauth**` unusable for token URL.                                                                                                                                            |
| `**INVALID_OAUTH_TOKEN_PATH**`   | **400**           | `**oauth.token_path`** fails **Token URL joining (Mode B)** validation.                                                                                                                                                                        |
| `**UNKNOWN_CLIENT_ID`**        | **400**           | Mode B (Phase 2+): no `**clients`** entry for this `**client_id**` on the matched row.                                                                                                                                                       |
| `**PROFILE_INVALID**`          | **400**           | Profile **file was found and decrypted/loaded**, but content fails tokmint validation: bad `**domains**` shape, duplicate `**domain**` / `**token_id**`, bad `**auth_servers**`, bad client/signing-key blocks, bad JWK/PEM, etc. Contrast **`UNKNOWN_PROFILE`** (no file). |
| `**KEY_ID_NOT_ALLOWED`**       | **400**           | `**key_id`** set when `**client_id**` is unset (Mode A), or other mutual-exclusion violations involving `**key_id**`.                                                                                                                        |
| `**PROFILE_LOAD_FAILED**`      | **500**           | `**secconfig.load_config`** failed after the file was found: I/O, permission, **SOPS decrypt** (wrong/missing key), or corrupt ciphertext. Usually **operator** fix. `**detail`** stays generic (no path leakage). |
| `**INTERNAL_ERROR`**           | **500**           | Unhandled exception; generic `**detail`** (“internal error”).                                                                                                                                                                                |
| `**UPSTREAM_ERROR**`           | **502**           | Mode B: network failure talking to token URL, TLS error, or IdP HTTP **4xx/5xx** / non-JSON where JSON expected. `**detail`** stays generic; do **not** forward IdP body verbatim.                                                           |
| `**SERVICE_UNAVAILABLE`**      | **503**           | Optional: decryption/keyring temporarily unavailable.                                                                                                                                                                                        |
| `**NOT_FOUND`**                | **404**           | Request path does not match any defined route.                                                                                                                                                                                               |


**Mode B IdP OAuth JSON errors** (e.g. `{"error":"invalid_client"}`): do **not**
pass through as the tokmint body in v1; map to `**UPSTREAM_ERROR`** with a
fixed `**detail**` (operators use IdP logs). Later iteration may add a **safe**
opaque `**upstream_code`** field.

### Mode A (static token)


| Situation                                                                  | HTTP    | `code`                                                     |
| -------------------------------------------------------------------------- | ------- | ---------------------------------------------------------- |
| Missing / empty `**profile**` or `**domain**`                              | **400** | `**MISSING_PARAMETER`**                                    |
| `**profile**` query not a safe segment                                    | **400** | `**UNSUPPORTED_PROFILE_NAME`**                              |
| Invalid `**domain**`                                                       | **400** | `**INVALID_DOMAIN`**                                       |
| `**client_id**` or `**token_id**` or `**key_id**` inconsistent with Mode A | **400** | `**INVALID_MODE_COMBINATION`** or `**KEY_ID_NOT_ALLOWED**` |
| `**token_id**` missing or empty                                            | **400** | `**MISSING_PARAMETER`** or `**INVALID_MODE_COMBINATION**`  |
| Profile file not found                                                     | **404** | `**UNKNOWN_PROFILE`**                                      |
| Load / parse / config shape failure                                        | **500** | `**PROFILE_*`** / `**INTERNAL_ERROR**`                     |
| No `**domains[]**` match                                                     | **404** | `**UNKNOWN_DOMAIN`**                                         |
| No matching `**token_id**` in row                                          | **400** | `**UNKNOWN_TOKEN_ID`**                                     |


### Mode B (OAuth — Phase 2+)


| Situation                                                                    | HTTP                        | `code`                                                  |
| ---------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------- |
| Same shared validation failures as Mode A for `**profile**` / `**domain**`   | **400** / **404** / **500** | as above                                                |
| `**client_id`** unset or Mode A-only combination                             | **400**                     | `**INVALID_MODE_COMBINATION`**                          |
| `**token_id**` set (must be unset)                                           | **400**                     | `**INVALID_MODE_COMBINATION`**                          |
| `**oauth**` / `**token_path**` missing or unusable                           | **400**                     | `**OAUTH_CONFIG_MISSING`**                              |
| `**oauth.token_path**` invalid                                                 | **400**                     | `**INVALID_OAUTH_TOKEN_PATH`**                            |
| Token URL join produces invalid URL                                          | **400**                     | `**INVALID_OAUTH_TOKEN_PATH`** or `**INVALID_DOMAIN**`    |
| Unknown `**client_id**` on matched row                                       | **400**                     | `**UNKNOWN_CLIENT_ID`**                                 |
| IdP transport or error response                                              | **502**                     | `**UPSTREAM_ERROR`**                                    |
| PEM / JWT build / decrypt failures (Phase 3)                                 | **500**                     | `**INTERNAL_ERROR`** or a dedicated code when specified |


### Shared (any mode)


| Situation                      | HTTP    | `code`                   |
| ------------------------------ | ------- | ------------------------ |
| Wrong method                   | **405** | `**METHOD_NOT_ALLOWED`** |
| Wrong path (no matching route) | **404** | `**NOT_FOUND`**          |


`**NOT_FOUND`:** use for unknown paths (e.g. `**GET /v1/token`** is **405**, but
`**/v1/other`** is **404** `**NOT_FOUND`**). `**detail**` generic (“not found”).

### Profile load vs request validation

- **Per-request** validation: query params, mode resolution, **`domain`**
canonical match, Mode A **`token_id`** lookup, Mode B **`oauth`** /
**`token_path`** / **`client_id`** (when implemented).
- **Profile load** (on first use or at startup): YAML parse, **`domains`**
structure, duplicates, **`oauth.request_headers`** **`key`** duplicates.
Failures use `**500**` + `**PROFILE_***` so operators fix files, not
Postman query strings.

## Security notes (intent)

- Validate `**profile**` and the **secconfig subdirectory** name (safe single
segment; no path escape from `{SECCONFIG_DIR}/{subdirectory}/`).
- Validate `**domain`** per **Canonical `domain` algorithm**; Mode B assumes
**HTTPS** when building the IdP token URL.
- **Do not log** tokens, PEM, full `Authorization` header values, or
`**oauth.request_headers`** values.  The `VERBOSE` log level redacts
`client_secret`, the `Authorization` header, and the `client_assertion`
JWT signature; the header and payload of `client_assertion` are logged
as they contain only public identifiers (issuer, audience, expiry).
- Reject `**key` / `value**` pairs that allow **header injection** (e.g.
embedded CR/LF) at load or request time.

## Roadmap providers

- First concrete: **Okta** (management APIs, private key JWT client auth).
- Later: **SailPoint**, **Azure**, **AWS** — design for **pluggable** URL
resolution + client auth + token request shape.

## Implementation phases (build order)

Deliver incrementally so Postman integration stays simple end-to-end before
adding OAuth complexity.

1. **Phase 1 — Static tokens (Mode A only)**
   - One HTTP route: **`POST /v1/token`** (see **HTTP contract (v1)**); query:
     **`profile`**, **`domain`**, **`token_id`** (non-empty); **`client_id`**
     and **`key_id`** **unset** (omit or empty after trim).
   - Load **`{SECCONFIG_DIR}/{subdirectory}/{profile}.enc.yaml`** via **secconfig**;
     resolve the row matching **`domain`** and the static token for
     **`token_id`**; return **`access_token`** + **`token_type`** (scheme key
     under **`tokens`**).
   - **No** token endpoint HTTP call; **no** keyring PEM path yet for this phase.
   - Smallest YAML slice: enough to match **`domain`** and store **sops**
     encrypted static token values.
   - **Profile YAML shape for Phase 1 is agreed** — see **Profile YAML schema**
     (**`domains`** + **`tokens`** list; optional **`oauth`** allowed, ignored until
     Mode B).

2. **Phase 2 — OAuth with client secret**
   - Add **Mode B** with **`client_id`** and **no** **`key_id`**: **`client_secret`**
     in YAML (sops); POST to **token URL** (**Token URL joining (Mode B)**);
     apply **`oauth.request_headers`** from the profile; return provider response
     shape (still **`access_token`** + **`token_type`**, optional **`expires_in`**).
   - Query param rules and mutual exclusion with **`token_id`** as already
     described.

3. **Phase 3 — OAuth with public/private key**
   - Add optional **`key_id`**; YAML points to **encrypt.sh** ciphertext on disk;
     **decrypt.sh** at runtime; JWT client assertion + token exchange (Okta
     first).
   - **General JWT signing** module as a building block for this phase.

Later phases do not change the **success JSON** shape agreed for v1.

## Before implementation — Phase 1 (walkthrough)

Design is **sufficient** to start coding. The topics below are **not** new
product spec — they are **setup and ops** choices. **Decisions** for this repo
are recorded after each walkthrough bullet.

**Status:** the **Decision** blocks in this section are **agreed** for Phase 1
(port **`9876`**, **`SECCONFIG_DIR`** unset → **`503`**, package layout,
**`python -m tokmint`**, no health/CORS v1, pytest scope).

### 1. Default **`TOKMINT_PORT`**

You need a default so `uvicorn` can start without extra env. It should be
**unprivileged** (≥ 1024), **uncommon** among your usual stack (Postgres 5432,
various 8xxx dev servers), and easy to remember.

**Walkthrough:** **`9876`** reads as a “downward” sequence, is rarely used by
major defaults, and stays clear of **8080** / **8000** / **3000**.

**Decision:** default **`TOKMINT_PORT`** = **`9876`** (override via env anytime).

### 2. **`SECCONFIG_DIR`** unset vs load failures

**secconfig** expects **`SECCONFIG_DIR`** for the usual secure layout; without
it, relative profile paths are ambiguous (cwd-dependent), which is wrong for a
security-sensitive loader.

**Walkthrough:**

- **`SECCONFIG_DIR` not set** (or empty after trim): treat as **deployment not
  ready** — operator must export the variable before tokmint can load any
  profile. Use **`503`** + **`SERVICE_UNAVAILABLE`** so monitors and humans read
  “fix the environment,” not “your profile file is wrong.”
- **`SECCONFIG_DIR` set** but profile file missing: **`404`** **`UNKNOWN_PROFILE`**
  (already in the error registry).
- **Set, file exists**, but **sops / decrypt / IO** fails: **`500`**
  **`PROFILE_LOAD_FAILED`** (no path or secret leakage in **`detail`**).

**Decision:** unset **`SECCONFIG_DIR`** → **`503`** **`SERVICE_UNAVAILABLE`**;
other load failures → **`500`** **`PROFILE_LOAD_FAILED`** (and **`UNKNOWN_PROFILE`**
when the file is simply absent).

### 3. Package layout (this monorepo)

**Walkthrough:** Keep **`util/tokmint/`** as the app root: **`pyproject.toml`**
there, Python package **`tokmint`** beside **`DESIGN.md`**. Declare **secconfig**
as a **path** dependency to **`../secconfig`** (editable install for dev).
Avoid putting tokmint-only deps only at the util repo root unless you already
use a workspace pattern for all tools.

**Decision:** **`tokmint/pyproject.toml`** + path dep on **`secconfig`** in this
repo; implementation checklist stays the source of exact dependency names.

### 4. Entrypoint

**Walkthrough:** Two equivalent patterns: (a) **`uvicorn tokmint…:app --host
127.0.0.1 --port …`** in scripts/docs, or (b) **`python -m tokmint`** calling
**`uvicorn.run(..., host="127.0.0.1")`** so one command hides flags. Do **not**
bind **`0.0.0.0`** in Phase 1.

**Decision:** support **`python -m tokmint`** as the documented primary for
operators; implement **`if __name__ == "__main__"`** or **`__main__.py`** with
host **`127.0.0.1`** and port from **`TOKMINT_PORT`**. Document equivalent raw
**`uvicorn`** invocation in **`tokmint/README.md`**.

### 5. Health / readiness

**Walkthrough:** Systemd or k8s sometimes wants **`GET /health`**. Postman-only
on a laptop does not need it.

**Decision:** **omit** health route for Phase 1; add **`GET /health`** later if
you add a unit file or orchestration.

### 6. Tests

**Walkthrough:** One **plain YAML** profile under **`/tmp`** or **`tmp_path`** —
no sops in CI if that pulls in keyring. Cover: **200** happy path, one **400**
(e.g. bad mode), one **404** (**`UNKNOWN_DOMAIN`** or **`UNKNOWN_PROFILE`**).
Keeps regression safety for canonicalization and routing.

**Decision:** **pytest** + **`httpx.AsyncClient`** or **`TestClient`**; implement
the concrete cases in **Phase 1 test plan** (**P1-01**–**P1-20**).

### 7. CORS

**Walkthrough:** Browsers enforce CORS; **Postman** and **curl** do not. Adding
CORS middleware early can accidentally suggest browser use from untrusted pages.

**Decision:** **no CORS** in Phase 1; revisit only if a browser client is in
scope.

## Phase 1 implementation checklist

Use this list when implementing **Mode A**; check items off in the PR or
locally as you go.

**Project & runtime**

- [ ] Add **tokmint** Python package layout and **`pyproject.toml`** (or
  equivalent) with **FastAPI**, **uvicorn**, **PyYAML** (if not only via
  secconfig), and editable **secconfig** dependency.
- [ ] Read **`TOKMINT_PORT`** (default **`9876`**) and **`TOKMINT_SECCONFIG_SUBDIR`**
  (default **`tokmint`**); validate subdirectory name like **`profile`**.
- [ ] If **`SECCONFIG_DIR`** unset → **`503`** **`SERVICE_UNAVAILABLE`** (see
  walkthrough above); do not load profiles from an ambiguous cwd.
- [ ] Run uvicorn bound to **`127.0.0.1`** and chosen port only.

**HTTP surface**

- [ ] Implement **`POST /v1/token`** only; return **`405`**
  **`METHOD_NOT_ALLOWED`** for wrong method on that path.
- [ ] Return **`404`** **`NOT_FOUND`** for unknown paths (align **`detail`**
  with **Errors and error handling**).
- [ ] Parse query params **`profile`**, **`domain`**, **`token_id`**,
  **`client_id`**, **`key_id`**; **unset** = omit or empty after ASCII trim.
- [ ] Enforce Mode A only: **`client_id`** and **`key_id`** unset; **`token_id`**
  required and non-empty; reject mixed modes per registry
  (**`INVALID_MODE_COMBINATION`**, etc.).

**Config load & validation**

- [ ] Resolve **`{SECCONFIG_DIR}/{subdirectory}/{profile}.enc.yaml`** and call
  **`secconfig.load_config`** (relative path when **`SECCONFIG_DIR`** set).
- [ ] Missing file → **`404`** **`UNKNOWN_PROFILE`**; decrypt/IO/other load
  failure → **`500`** **`PROFILE_LOAD_FAILED`** (no path leakage in **`detail`**).
- [ ] Validate YAML: top-level **`domains`** non-empty list; duplicate canonical
  **`domain`** or duplicate **`token_id`** in one row → **`400`**
  **`PROFILE_INVALID`** (fail at first load of that profile).
- [ ] Ignore optional top-level **`oauth`** for Phase 1.

**Matching & response**

- [ ] Implement **Canonical `domain` algorithm** for request and each YAML
  row; no match → **`404`** **`UNKNOWN_DOMAIN`**.
- [ ] Find **`tokens`** list entry by **`token_id`**; no match → **`400`**
  **`UNKNOWN_TOKEN_ID`**.
- [ ] Success: **`200`** JSON **`access_token`** (from **`credential`**) +
  **`token_type`** (matching **`tokens`** scheme key).

**Errors**

- [ ] All errors: **`Content-Type: application/json`**, body **`code`** +
  **`detail`** per **Error code registry** (map FastAPI defaults if needed).

**Security & logging**

- [ ] Do not log tokens, full **`credential`**, or full query strings if
  policy requires minimal logging.
- [ ] Validate **`profile`** / subdirectory segment (no **`..`**, no **`/`**).

**Docs & operator UX**

- [ ] **`tokmint/README.md`**: env vars, **`python -m tokmint`**, example
  **curl** / Postman URL for Phase 1.

**Tests**

- [ ] Implement **P1-01**–**P1-20** from **Phase 1 test plan** (below).

## Phase 1 test plan (define before / implement with code)

These cases are **acceptance criteria** for Mode A. Implement as **pytest** with
**`httpx.ASGITransport`** + **`AsyncClient`** or **`starlette.testclient.TestClient`**
against the FastAPI app (no live port required). Use **plain YAML** (no sops) and
**`tmp_path`** for profile files.

### Shared test harness (intent)

- Set **`SECCONFIG_DIR`** to a **`tmp_path`** directory (or monkeypatch **`os.environ`**).
- Create **`{SECCONFIG_DIR}/tokmint/{profile}.enc.yaml`** (or override
  **`TOKMINT_SECCONFIG_SUBDIR`** if testing that name).
- Build the app with the same env the tests set; avoid binding a real TCP port
  unless you add one **integration** test optionally marked.

**Minimal valid profile** (adjust **`domain`** / **`token_id`** per case):

```yaml
domains:
  - domain: tenant.example.com
    tokens:
      Bearer:
        - token_id: default
          credential: plain-test-secret
```

### Test cases

| ID | Case | Profile / setup | Request | Exp. HTTP | Exp. `code` |
|----|------|-------------------|---------|-----------|-------------|
| **P1-01** | Happy path | Minimal valid YAML; **`profile=test`**, file **`test.enc.yaml`** | **`POST /v1/token?profile=test&domain=tenant.example.com&token_id=default`** (omit **`client_id`**, **`key_id`**) | **200** | *(success body; no `code`)* |
| **P1-02** | Success JSON shape | Same as P1-01 | Same | **200** | Body has **`access_token`** = YAML value, **`token_type`** **`Bearer`**. |
| **P1-03** | Missing **`profile`** | Any | **`POST /v1/token?domain=tenant.example.com&token_id=default`** | **400** | **`MISSING_PARAMETER`** |
| **P1-04** | Missing **`domain`** | Any | **`POST /v1/token?profile=test&token_id=default`** | **400** | **`MISSING_PARAMETER`** |
| **P1-05** | Empty **`domain`** after trim | Any | **`POST`** with **`domain=`** empty or **`domain=%20`** (space only) | **400** | **`MISSING_PARAMETER`** (trims to empty). |
| **P1-06** | Invalid **`domain`** | Any | Query with non-ASCII, `..`, or URL with `://` per **Canonical `domain` algorithm** | **400** | **`INVALID_DOMAIN`** |
| **P1-07** | **`SECCONFIG_DIR`** unset | Clear env var for that test | Valid query | **503** | **`SERVICE_UNAVAILABLE`** |
| **P1-08** | Unknown profile file | No **`tokmint/nope.enc.yaml`** | **`POST /v1/token?profile=nope&domain=…&token_id=…`** | **404** | **`UNKNOWN_PROFILE`** |
| **P1-09** | Unknown domain | Minimal YAML with **`tenant.example.com`** only | **`domain=other.example.com`** | **404** | **`UNKNOWN_DOMAIN`** |
| **P1-10** | Unknown **`token_id`** | Minimal YAML | **`token_id=missing`** | **400** | **`UNKNOWN_TOKEN_ID`** |
| **P1-11** | Mode B leak | Minimal YAML | **`client_id=any`** non-empty + valid Mode A other params | **400** | **`INVALID_MODE_COMBINATION`** |
| **P1-12** | **`key_id`** set in Mode A | Minimal YAML | **`key_id=kid`** non-empty, **`client_id`** unset | **400** | **`KEY_ID_NOT_ALLOWED`** or **`INVALID_MODE_COMBINATION`** (match registry choice). |
| **P1-13** | Mode A **`token_id`** unset | Minimal YAML | Omit **`token_id`** and leave **`client_id`** unset | **400** | **`MISSING_PARAMETER`** or **`INVALID_MODE_COMBINATION`**. |
| **P1-14** | Wrong method | Any | **`GET /v1/token?…`** | **405** | **`METHOD_NOT_ALLOWED`** |
| **P1-15** | Unknown path | Any | **`POST /v1/nope`** | **404** | **`NOT_FOUND`** |
| **P1-16** | Error body shape | Any failing case | Any **4xx** above | — | JSON exactly **`{ "code", "detail" }`** (both strings). |
| **P1-17** | Duplicate **`domain`** in YAML | Two **`domains[]`** rows canonicalizing to same hostname | Any request that loads profile | **400** | **`PROFILE_INVALID`** |
| **P1-18** | Duplicate **`token_id`** in one row | Two entries with same **`token_id`** under the same scheme list (or across schemes) | Any request that loads profile | **400** | **`PROFILE_INVALID`** |
| **P1-19** | Missing top-level **`domains`** | YAML `{}` or **`domains: []`** | Valid query | **400** | **`PROFILE_INVALID`** |
| **P1-20** | Case-insensitive match | YAML **`TENANT.example.com`**; request uses **`tenant.example.com`** | Match | **200** | Same as P1-01 (proves canonical match). |

**Optional later:** P1-21 **invalid `profile` name** (path segments / **`..`**) → **400**
**`UNSUPPORTED_PROFILE_NAME`**; P1-22 **load_config** raises (permission/decrypt) → **500**
**`PROFILE_LOAD_FAILED`**.

### Checklist linkage

- [ ] Implement all **P1-01**–**P1-20** (or explicitly defer optional rows in a PR
  comment).
- [ ] **`detail`** strings may evolve; **`code`** must match the **Error code
  registry** exactly.

## Deferred / next iteration

- **`clients`** shape under each **`domains[]`** entry (Phase 2+): see
  **`examples/tokmint.example.profile.yaml`** (list of **`client_id`** entries with
  optional **`client_secret`** and **`signing_keys`** for **`key_id`**).
- **OAuth token request** details when using `client_secret` (form fields vs
Basic auth).
- **Separate “sign arbitrary JWT”** HTTP surface vs internal module only TBD.
- **FastAPI** app layout, dependencies (`httpx`, `cryptography`, JWT library),
`uvicorn` entrypoint; wire **env** for port and secconfig subdirectory.

## Changelog (this doc)

- Captures agreements through: name **tokmint**, dual modes A/B, query params,
response shape, config subdirectory under **SECCONFIG_DIR** (default
**tokmint**), PEM via **encrypt.sh** /
**decrypt.sh**, static tokens and client_secret in **sops** YAML.
- **Implementation phases:** static tokens first, then client_secret OAuth,
then private-key JWT.
- **No magic unset strings:** optional/conditional params are **unset** only if
**omitted** or **empty after trim**; `**profile`** / `**domain**` required
and non-empty after trim.
- **Tokmint runtime config:** listen **port** and **secconfig subdirectory**
name (default **tokmint**) via **environment variables** at implementation.
- **Profile YAML:** top-level **`domains`** with **`tokens`** as **scheme →**
  **[{ token_id, credential }, …]**; optional **`oauth`** with **`token_path`**
  and **`request_headers`** (Mode B); **`clients**` deferred to Phase 2.
- **OAuth config nesting:** `**oauth.token_path`** and `**oauth.request_headers**`
replace flat `**oauth_***` top-level keys.
- `**oauth.request_headers`:** each item is `**key`** (header name) and
`**value**` (header value).
- **Phase 1 profile YAML** structure agreed: `**domains`** with **`tokens`**
  mapping; optional `**oauth**` (ignored in Phase 1).
- **HTTP contract (v1):** `**POST /v1/token`**, query string for parameters,
no request body.
- `**domain` canonicalization:** single algorithm for request + YAML (ASCII
LDH labels, lowercase, strip DNS root dot, reject `**..**`).
- **Token URL (Mode B):** `**urljoin`**(`**https://` +** canonical `**domain**`,
path-absolute `**oauth.token_path**`) with documented path-root semantics.
- **Errors (v1):** JSON `**{ code, detail }`**; registry of `**code**` values;
**400** / **404** / **405** / **500** / **502** / **503**; Mode A / Mode B /
profile-load tables; no secret leakage.
- **Phase 1:** **Before implementation** walkthrough (port **`9876`**,
  **`SECCONFIG_DIR`** → **`503`**, package layout, entrypoint, no health/CORS for
  v1) + **implementation checklist** — walkthrough **decisions agreed**.
- **Phase 1 test plan:** table **P1-01**–**P1-20** (pytest harness, minimal YAML
  fixtures, expected HTTP + **`code`**).

