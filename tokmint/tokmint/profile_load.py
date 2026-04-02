"""
Load and validate profile YAML (Phase 1).
"""

from pathlib import Path
from typing import Any, Optional, Tuple

from secconfig.loader import SecretsConfigError, load_config, resolve_seconfig_dir

from tokmint.canonical import CanonicalDomainError, canonical_domain
from tokmint.errors import TokmintError
from tokmint.oauth_common import validate_token_path
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
            "No profile file exists for this profile name.",
        )

    try:
        data = load_config(rel)
    except SecretsConfigError as exc:
        raise TokmintError(
            500,
            "PROFILE_LOAD_FAILED",
            "Profile file could not be loaded.",
        ) from exc

    if not isinstance(data, dict):
        raise TokmintError(
            500,
            "PROFILE_YAML_INVALID",
            "Profile YAML must be a mapping at the top level.",
        )

    _validate_profile_structure(data)
    return data


def _validate_profile_structure(data: dict[str, Any]) -> None:
    """Validate domains, tokens, oauth, and clients."""
    if "domains" not in data:
        raise TokmintError(
            500,
            "PROFILE_YAML_INVALID",
            "Profile YAML must contain a domains key.",
        )

    domains = data["domains"]
    if not isinstance(domains, list) or len(domains) < 1:
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "domains must be a non-empty list.",
        )

    seen_domains: set[str] = set()
    for idx, row in enumerate(domains):
        if not isinstance(row, dict):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each domains entry must be a mapping.",
            )
        dom = row.get("domain")
        if not isinstance(dom, str) or not dom.strip():
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each domains entry must have a non-empty domain.",
            )
        try:
            c = canonical_domain(dom)
        except CanonicalDomainError as exc:
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Invalid domain in profile configuration.",
            ) from exc
        if c in seen_domains:
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Duplicate domain in profile configuration.",
            )
        seen_domains.add(c)
        _validate_tokens(row.get("tokens"), idx)
        _validate_clients_row(row.get("clients"))

    _validate_oauth_if_present(data.get("oauth"))
    if _domains_have_clients(data["domains"]) and data.get("oauth") is None:
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth is required when clients are configured.",
        )


def _domains_have_clients(domains: Any) -> bool:
    if not isinstance(domains, list):
        return False
    for row in domains:
        if not isinstance(row, dict):
            continue
        clients = row.get("clients")
        if isinstance(clients, list) and len(clients) > 0:
            return True
    return False


def _validate_oauth_if_present(oauth: Any) -> None:
    """Validate oauth block when present; no-op if absent."""
    if oauth is None:
        return
    if not isinstance(oauth, dict):
        raise TokmintError(
            500,
            "PROFILE_YAML_INVALID",
            "oauth must be a mapping when present.",
        )
    tp = oauth.get("token_path")
    if tp is None:
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth.token_path is required when oauth is present.",
        )
    validate_token_path(tp)

    cam = oauth.get("client_authentication", "body")
    if cam not in ("body", "basic"):
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth.client_authentication must be 'body' or 'basic'.",
        )

    extra = oauth.get("token_form_extra")
    if extra is not None:
        if not isinstance(extra, dict):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "oauth.token_form_extra must be a mapping of strings.",
            )
        for fk, fv in extra.items():
            if not isinstance(fk, str) or not fk.strip():
                raise TokmintError(
                    500,
                    "PROFILE_CONFIG_INVALID",
                    "oauth.token_form_extra keys must be non-empty strings.",
                )
            if not isinstance(fv, str):
                raise TokmintError(
                    500,
                    "PROFILE_CONFIG_INVALID",
                    "oauth.token_form_extra values must be strings.",
                )

    _validate_oauth_headers(oauth.get("request_headers"))


def _validate_oauth_headers(headers: Any) -> None:
    if headers is None:
        return
    if not isinstance(headers, list):
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth.request_headers must be a list when present.",
        )
    seen_lower: set[str] = set()
    for item in headers:
        if not isinstance(item, dict):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each oauth.request_headers entry must be a mapping.",
            )
        key = item.get("key")
        if not isinstance(key, str) or not key.strip():
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each oauth header must have a non-empty key.",
            )
        lk = key.strip().lower()
        if lk in seen_lower:
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Duplicate oauth request header name (case-insensitive).",
            )
        seen_lower.add(lk)


def _validate_clients_row(clients: Any) -> None:
    if clients is None:
        return
    if not isinstance(clients, list):
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "clients must be a list when present.",
        )
    seen_id: set[str] = set()
    for c in clients:
        if not isinstance(c, dict):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each clients entry must be a mapping.",
            )
        cid = c.get("client_id")
        if not isinstance(cid, str) or not cid.strip():
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each client must have a non-empty client_id.",
            )
        cnorm = cid.strip()
        if cnorm in seen_id:
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Duplicate client_id under the same domain.",
            )
        seen_id.add(cnorm)

        sec = c.get("client_secret")
        has_secret = isinstance(sec, str) and bool(sec.strip())
        keys = c.get("signing_keys")
        has_keys = isinstance(keys, list) and len(keys) > 0
        if not has_secret and not has_keys:
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each client must have client_secret and/or signing_keys.",
            )

        scopes = c.get("scopes")
        if scopes is not None and (
            not isinstance(scopes, str) or not scopes.strip()
        ):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "client scopes must be a non-empty string when present.",
            )


def _validate_tokens(tokens: Any, row_index: int) -> None:
    """Validate tokens mapping: auth_scheme -> [ { token_id, credential }, ... ]."""
    if tokens is None:
        return
    if not isinstance(tokens, dict):
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "tokens must be a mapping (auth_scheme to list) when present.",
        )
    seen_ids: set[str] = set()
    for scheme_key, bucket in tokens.items():
        if not isinstance(scheme_key, str) or not scheme_key.strip():
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each tokens key must be a non-empty auth_scheme string.",
            )
        auth_scheme = scheme_key.strip()
        if not is_valid_auth_scheme(auth_scheme):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Invalid auth_scheme as tokens key in profile configuration.",
            )
        if not isinstance(bucket, list) or len(bucket) < 1:
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each auth_scheme under tokens must map to a non-empty list.",
            )
        for item in bucket:
            if not isinstance(item, dict):
                raise TokmintError(
                    500,
                    "PROFILE_CONFIG_INVALID",
                    "Each tokens list entry must be a mapping.",
                )
            tid = item.get("token_id")
            if not isinstance(tid, str) or not tid.strip():
                raise TokmintError(
                    500,
                    "PROFILE_CONFIG_INVALID",
                    "Each token entry must have a non-empty token_id.",
                )
            tid_norm = tid.strip()
            if tid_norm in seen_ids:
                raise TokmintError(
                    500,
                    "PROFILE_CONFIG_INVALID",
                    "Duplicate token_id under the same domain.",
                )
            seen_ids.add(tid_norm)
            cr = item.get("credential")
            if cr is None or (isinstance(cr, str) and not cr.strip()):
                raise TokmintError(
                    500,
                    "PROFILE_CONFIG_INVALID",
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


def find_oauth_client(
    data: dict[str, Any],
    request_canonical_domain: str,
    client_id: str,
) -> dict[str, Any]:
    """
    Return the clients[] mapping matching client_id on the domain row.
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

    clients = row.get("clients")
    if not isinstance(clients, list):
        raise TokmintError(
            400,
            "UNKNOWN_CLIENT_ID",
            "No OAuth client is configured for this client_id.",
        )

    sought = client_id.strip()
    for c in clients:
        if not isinstance(c, dict):
            continue
        cid = c.get("client_id")
        if isinstance(cid, str) and cid.strip() == sought:
            return c

    raise TokmintError(
        400,
        "UNKNOWN_CLIENT_ID",
        "No OAuth client is configured for this client_id.",
    )
