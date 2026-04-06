"""
Load and validate profile YAML (Phase 1).
"""

from pathlib import Path
from typing import Any, Optional, Tuple

from secconfig.loader import SecretsConfigError, load_config, resolve_seconfig_dir

from tokmint.canonical import CanonicalDomainError, canonical_domain
from tokmint.errors import TokmintError
from tokmint.oauth_common import validate_auth_server_path
from tokmint.validators import is_valid_auth_scheme


def require_resolved_seconfig_dir() -> Path:
    """
    Return SECCONFIG_DIR as a resolved Path.

    secconfig raises SecretsConfigError if the path is set but missing or not a
    directory; map that to 503 like an unset or unusable config root.
    """
    try:
        base = resolve_seconfig_dir()
    except SecretsConfigError:
        raise TokmintError(
            503,
            "SERVICE_UNAVAILABLE",
            "SECCONFIG_DIR is missing, not a directory, or not usable.",
        ) from None
    if base is None:
        raise TokmintError(
            503,
            "SERVICE_UNAVAILABLE",
            "SECCONFIG_DIR is not configured.",
        )
    return base


def load_profile(
    profile: str,
    subdir: str,
) -> dict[str, Any]:
    """
    Load `{subdir}/{profile}.enc.yaml` under SECCONFIG_DIR (SOPS or plain).

    Raises TokmintError for predictable failures.
    """
    base = require_resolved_seconfig_dir()

    rel = f"{subdir}/{profile}.enc.yaml"
    resolved = (base / subdir / f"{profile}.enc.yaml").resolve()
    try:
        base_resolved = base.resolve()
        resolved.relative_to(base_resolved)
    except ValueError as exc:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Invalid profile path.",
        ) from exc

    if not resolved.exists():
        raise TokmintError(
            404,
            "UNKNOWN_PROFILE",
            "Profile not found: no encrypted profile file for this name.",
        )

    try:
        data = load_config(rel)
    except SecretsConfigError as exc:
        raise TokmintError(
            500,
            "PROFILE_LOAD_FAILED",
            "Profile file exists but could not be read or decrypted "
            "(check permissions, SOPS/AGE keys, and file integrity).",
        ) from exc

    if not isinstance(data, dict):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "This profile file exists but is not valid: top-level YAML "
            "must be a mapping.",
        )

    _validate_profile_structure(data)
    return data


def _validate_profile_structure(data: dict[str, Any]) -> None:
    """Validate domains, tokens, and auth_servers."""
    if "domains" not in data:
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "This profile file exists but is not valid: missing "
            "top-level domains key.",
        )

    domains = data["domains"]
    if not isinstance(domains, list) or len(domains) < 1:
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "domains must be a non-empty list.",
        )

    seen_domains: set[str] = set()
    for idx, row in enumerate(domains):
        if not isinstance(row, dict):
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each domains entry must be a mapping.",
            )
        dom = row.get("domain")
        if not isinstance(dom, str) or not dom.strip():
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each domains entry must have a non-empty domain.",
            )
        try:
            c = canonical_domain(dom)
        except CanonicalDomainError as exc:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Invalid domain in profile configuration.",
            ) from exc
        if c in seen_domains:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Duplicate domain in profile configuration.",
            )
        seen_domains.add(c)
        allowed_keys = {"domain", "tokens", "auth_servers"}
        for yaml_key in row:
            if yaml_key not in allowed_keys:
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    f"Unknown key in domains row: {yaml_key!r}.",
                )
        _validate_tokens(row.get("tokens"), idx)
        _validate_auth_servers_row(row.get("auth_servers"), idx)


def _validate_auth_servers_row(auth_servers: Any, row_index: int) -> None:
    if auth_servers is None:
        return
    if not isinstance(auth_servers, list):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "auth_servers must be a list when present.",
        )
    seen_client_ids: set[str] = set()
    for s_idx, server in enumerate(auth_servers):
        if not isinstance(server, dict):
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each auth_servers entry must be a mapping.",
            )
        raw_path = server.get("path")
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each auth server must have a non-empty path.",
            )
        validate_auth_server_path(raw_path)

        _validate_request_headers(
            server.get("request_headers"),
            "auth server",
        )

        fe = server.get("form_extra")
        if fe is not None:
            if not isinstance(fe, dict):
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "form_extra must be a mapping of strings when present.",
                )
            for fk, fv in fe.items():
                if not isinstance(fk, str) or not fk.strip():
                    raise TokmintError(
                        400,
                        "PROFILE_INVALID",
                        "form_extra keys must be non-empty strings.",
                    )
                if not isinstance(fv, str):
                    raise TokmintError(
                        400,
                        "PROFILE_INVALID",
                        "form_extra values must be strings.",
                    )

        clients = server.get("clients")
        if not isinstance(clients, list) or len(clients) < 1:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each auth server must have a non-empty clients list.",
            )
        for client in clients:
            if not isinstance(client, dict):
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Each client must be a mapping.",
                )
            cid = client.get("client_id")
            if not isinstance(cid, str) or not cid.strip():
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Each client must have a non-empty client_id.",
                )
            cnorm = cid.strip()
            if cnorm in seen_client_ids:
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Duplicate client_id under the same domain.",
                )
            seen_client_ids.add(cnorm)
            _validate_oauth_client_profile(client)


def _validate_oauth_client_profile(client: dict[str, Any]) -> None:
    method = client.get("client_authn_method")
    if method not in (
        "client_secret_post",
        "client_secret_basic",
        "private_key_jwt",
    ):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Invalid client authentication method in profile "
            "(client_authn_method).",
        )

    sec = client.get("client_secret")
    has_secret = isinstance(sec, str) and bool(sec.strip())
    if method in ("client_secret_post", "client_secret_basic"):
        if not has_secret:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "client_secret is required for secret-based client "
                "authentication.",
            )

    if method == "private_key_jwt":
        pk = client.get("private_key_jwt")
        if not isinstance(pk, dict):
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "private_key_jwt block is required for private_key_jwt.",
            )
        iss = pk.get("assertion_iss")
        if not isinstance(iss, str) or not iss.strip():
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "private_key_jwt.assertion_iss is required.",
            )
        ttl = pk.get("assertion_ttl_seconds", 300)
        if not isinstance(ttl, int) or ttl < 1 or ttl > 3600:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "assertion_ttl_seconds must be an integer 1–3600.",
            )

    keys = client.get("signing_keys")
    if method == "private_key_jwt":
        if not isinstance(keys, list) or len(keys) < 1:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "signing_keys required for private_key_jwt.",
            )
    dpop = client.get("dpop")
    if isinstance(dpop, dict) and dpop.get("enabled") is True:
        if not isinstance(keys, list) or len(keys) < 1:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "signing_keys required when dpop.enabled is true.",
            )

    if isinstance(keys, list):
        _validate_signing_keys_list(keys)


def _validate_signing_keys_list(keys: list[Any]) -> None:
    seen: set[str] = set()
    for entry in keys:
        if not isinstance(entry, dict):
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each signing_keys entry must be a mapping.",
            )
        kid = entry.get("key_id")
        if not isinstance(kid, str) or not kid.strip():
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each signing key needs a non-empty key_id.",
            )
        kn = kid.strip()
        if kn in seen:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Duplicate signing key_id on the same client.",
            )
        seen.add(kn)
        has_pem = isinstance(
            entry.get("encrypted_pem_path"),
            str,
        ) and bool(str(entry.get("encrypted_pem_path")).strip())
        raw_jwk = entry.get("jwk")
        has_jwk = isinstance(raw_jwk, dict) and len(raw_jwk) > 0
        if has_pem == has_jwk:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each signing key needs exactly one of "
                "encrypted_pem_path or jwk.",
            )


def _validate_request_headers(headers: Any, ctx: str) -> None:
    if headers is None:
        return
    if not isinstance(headers, list):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            f"{ctx} request_headers must be a list when present.",
        )
    seen_lower: set[str] = set()
    for item in headers:
        if not isinstance(item, dict):
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each request_headers entry must be a mapping.",
            )
        key = item.get("key")
        if not isinstance(key, str) or not key.strip():
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each request header must have a non-empty key.",
            )
        lk = key.strip().lower()
        if lk in seen_lower:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Duplicate request header name (case-insensitive).",
            )
        seen_lower.add(lk)


def _validate_tokens(tokens: Any, row_index: int) -> None:
    """Validate tokens mapping: auth_scheme -> [ { token_id, credential }, ... ]."""
    if tokens is None:
        return
    if not isinstance(tokens, dict):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "tokens must be a mapping (auth_scheme to list) when present.",
        )
    seen_ids: set[str] = set()
    for scheme_key, bucket in tokens.items():
        if not isinstance(scheme_key, str) or not scheme_key.strip():
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each tokens key must be a non-empty auth_scheme string.",
            )
        auth_scheme = scheme_key.strip()
        if not is_valid_auth_scheme(auth_scheme):
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Invalid auth_scheme as tokens key in profile configuration.",
            )
        if not isinstance(bucket, list) or len(bucket) < 1:
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Each auth_scheme under tokens must map to a non-empty list.",
            )
        for item in bucket:
            if not isinstance(item, dict):
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Each tokens list entry must be a mapping.",
                )
            tid = item.get("token_id")
            if not isinstance(tid, str) or not tid.strip():
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Each token entry must have a non-empty token_id.",
                )
            tid_norm = tid.strip()
            if tid_norm in seen_ids:
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Duplicate token_id under the same domain.",
                )
            seen_ids.add(tid_norm)
            cr = item.get("credential")
            if cr is None or (isinstance(cr, str) and not cr.strip()):
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Each token entry must have a credential.",
                )


def find_static_token(
    data: dict[str, Any],
    request_canonical_domain: str,
    token_id: str,
) -> Tuple[str, str]:
    """
    Return (auth_scheme, credential) for Mode A static token lookup.

    auth_scheme is the YAML dict key under tokens (e.g. Bearer, SSWS).
    """
    domains = data["domains"]
    row: Optional[dict[str, Any]] = None
    for entry in domains:
        assert isinstance(entry, dict)
        dom = entry.get("domain")
        assert isinstance(dom, str)
        if canonical_domain(dom) == request_canonical_domain:
            row = entry
            break
    if row is None:
        raise TokmintError(
            404,
            "UNKNOWN_DOMAIN",
            "No domains entry matches this domain for this profile.",
        )

    tokens = row.get("tokens")
    if not isinstance(tokens, dict):
        raise TokmintError(
            400,
            "UNKNOWN_TOKEN_ID",
            "No static token is configured for this token_id.",
        )

    for auth_scheme_key, bucket in tokens.items():
        if not isinstance(auth_scheme_key, str):
            continue
        if not isinstance(bucket, list):
            continue
        scheme = auth_scheme_key.strip()
        for item in bucket:
            if not isinstance(item, dict):
                continue
            tid = item.get("token_id")
            if isinstance(tid, str) and tid.strip() == token_id:
                raw_cred = item.get("credential")
                return scheme, str(raw_cred)
    raise TokmintError(
        400,
        "UNKNOWN_TOKEN_ID",
        "No static token is configured for this token_id.",
    )


def find_auth_server_and_client(
    data: dict[str, Any],
    request_canonical_domain: str,
    client_id: str,
) -> Tuple[dict[str, Any], dict[str, Any]]:
    """
    Return (auth_server_row, client_row) for client_id under the domain.
    """
    domains = data["domains"]
    row: Optional[dict[str, Any]] = None
    for entry in domains:
        assert isinstance(entry, dict)
        dom = entry.get("domain")
        assert isinstance(dom, str)
        if canonical_domain(dom) == request_canonical_domain:
            row = entry
            break
    if row is None:
        raise TokmintError(
            404,
            "UNKNOWN_DOMAIN",
            "No domains entry matches this domain for this profile.",
        )

    auth_servers = row.get("auth_servers")
    if not isinstance(auth_servers, list):
        raise TokmintError(
            400,
            "UNKNOWN_CLIENT_ID",
            "No auth servers are configured for this domain "
            "(auth_servers missing or not a list).",
        )

    sought = client_id.strip()
    for server in auth_servers:
        if not isinstance(server, dict):
            continue
        clients = server.get("clients")
        if not isinstance(clients, list):
            continue
        for c in clients:
            if not isinstance(c, dict):
                continue
            cid = c.get("client_id")
            if isinstance(cid, str) and cid.strip() == sought:
                return server, c

    raise TokmintError(
        400,
        "UNKNOWN_CLIENT_ID",
        "No OAuth client is configured for this client_id.",
    )


def find_signing_key_row(
    client_row: dict[str, Any],
    key_id: str,
) -> dict[str, Any]:
    """Return signing_keys[] entry matching key_id."""
    keys = client_row.get("signing_keys")
    if not isinstance(keys, list):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Invalid profile: client is missing signing_keys.",
        )
    sought = key_id.strip()
    for entry in keys:
        if not isinstance(entry, dict):
            continue
        kid = entry.get("key_id")
        if isinstance(kid, str) and kid.strip() == sought:
            return entry
    raise TokmintError(
        400,
        "UNKNOWN_KEY_ID",
        "No signing key matches this key_id.",
    )
