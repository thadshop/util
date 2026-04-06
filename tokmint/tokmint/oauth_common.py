"""
OAuth token URL construction (Mode B): https://domain + auth server path.
"""

from urllib.parse import urljoin

from tokmint.errors import TokmintError


def validate_auth_server_path(path: str) -> str:
    """
    Validate auth server path (path-absolute) after ASCII trim.

    Returns normalized path. Raises TokmintError PROFILE_INVALID.
    """
    if not isinstance(path, str):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Invalid profile: auth server path must be a string.",
        )
    trimmed = path.strip(" \t\n\r\x0b\x0c")
    if not trimmed:
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Invalid profile: auth server path must be non-empty.",
        )
    low = trimmed.lower()
    if "://" in low:
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Invalid profile: auth server path must be a path only, "
            "not a full URL.",
        )
    if "?" in trimmed or "#" in trimmed:
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Invalid profile: auth server path must not contain ? or #.",
        )
    if not trimmed.startswith("/"):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Invalid profile: auth server path must be path-absolute "
            "(start with /).",
        )
    if trimmed != "/" and trimmed.endswith("/"):
        trimmed = trimmed.rstrip("/")
    return trimmed


def validate_token_path(token_path: str) -> str:
    """Backward-compatible name for validate_auth_server_path."""
    return validate_auth_server_path(token_path)


def build_token_url(canonical_domain: str, auth_path: str) -> str:
    """
    Join https:// + canonical_domain + validated path via urljoin.
    """
    norm = validate_auth_server_path(auth_path)
    return urljoin(f"https://{canonical_domain}", norm)
