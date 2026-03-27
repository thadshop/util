"""
Load and validate profile YAML (Phase 1).
"""

from pathlib import Path
from typing import Any, Optional

from secconfig.loader import SecretsConfigError, load_config, resolve_seconfig_dir

from tokmint.canonical import CanonicalBaseUrlError, canonical_base_url
from tokmint.errors import TokmintError


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
    """Validate bases, duplicates; Phase 1 ignores oauth."""
    if "bases" not in data:
        raise TokmintError(
            500,
            "PROFILE_YAML_INVALID",
            "Profile YAML must contain a bases key.",
        )

    bases = data["bases"]
    if not isinstance(bases, list) or len(bases) < 1:
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "bases must be a non-empty list.",
        )

    seen_urls: set[str] = set()
    for idx, row in enumerate(bases):
        if not isinstance(row, dict):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each bases entry must be a mapping.",
            )
        bu = row.get("base_url")
        if not isinstance(bu, str) or not bu.strip():
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each bases entry must have a non-empty base_url.",
            )
        try:
            c = canonical_base_url(bu)
        except CanonicalBaseUrlError as exc:
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Invalid base_url in profile configuration.",
            ) from exc
        if c in seen_urls:
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Duplicate base_url in profile configuration.",
            )
        seen_urls.add(c)
        _validate_tokens_list(row.get("tokens"), idx)


def _validate_tokens_list(tokens: Any, row_index: int) -> None:
    if tokens is None:
        return
    if not isinstance(tokens, list):
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "tokens must be a list when present.",
        )
    seen_ids: set[str] = set()
    for item in tokens:
        if not isinstance(item, dict):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each tokens entry must be a mapping.",
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
                "Duplicate token_id under the same base_url.",
            )
        seen_ids.add(tid_norm)
        tv = item.get("token_value")
        if tv is None or (isinstance(tv, str) and not tv.strip()):
            raise TokmintError(
                500,
                "PROFILE_CONFIG_INVALID",
                "Each token entry must have a token_value.",
            )


def find_token_value(
    data: dict[str, Any],
    request_canonical_base: str,
    token_id: str,
) -> str:
    """Return token_value for the matching row and token_id."""
    bases = data["bases"]
    row: Optional[dict[str, Any]] = None
    for entry in bases:
        assert isinstance(entry, dict)
        bu = entry.get("base_url")
        assert isinstance(bu, str)
        if canonical_base_url(bu) == request_canonical_base:
            row = entry
            break
    if row is None:
        raise TokmintError(
            404,
            "UNKNOWN_BASE",
            "No bases entry matches this base_url for this profile.",
        )

    tokens = row.get("tokens")
    if not isinstance(tokens, list):
        raise TokmintError(
            400,
            "UNKNOWN_TOKEN_ID",
            "No static token is configured for this token_id.",
        )

    for item in tokens:
        if not isinstance(item, dict):
            continue
        tid = item.get("token_id")
        if isinstance(tid, str) and tid.strip() == token_id:
            raw = item.get("token_value")
            return str(raw)
    raise TokmintError(
        400,
        "UNKNOWN_TOKEN_ID",
        "No static token is configured for this token_id.",
    )
