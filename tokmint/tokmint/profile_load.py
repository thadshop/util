"""
Load and validate profile YAML (Phase 1).
"""

from pathlib import Path
from typing import Any, Optional, Tuple

from secconfig.loader import SecretsConfigError, load_config, resolve_seconfig_dir

from tokmint.canonical import CanonicalDomainError, canonical_domain
from tokmint.errors import TokmintError
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
    """Validate domains, duplicates; Phase 1 ignores oauth."""
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
