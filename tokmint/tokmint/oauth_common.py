"""
OAuth token URL construction (Mode B) per DESIGN.md.
"""

from urllib.parse import urljoin

from tokmint.errors import TokmintError


def validate_token_path(token_path: str) -> str:
    """
    Validate oauth.token_path after ASCII trim.

    Returns normalized path (trailing slash stripped unless path is "/").
    Raises TokmintError PROFILE_CONFIG_INVALID on failure.
    """
    if not isinstance(token_path, str):
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth.token_path must be a string.",
        )
    path = token_path.strip(" \t\n\r\x0b\x0c")
    if not path:
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth.token_path must be non-empty.",
        )
    low = path.lower()
    if "://" in path:
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth.token_path must be a path only, not a full URL.",
        )
    if "?" in path or "#" in path:
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth.token_path must not contain ? or #.",
        )
    if not path.startswith("/"):
        raise TokmintError(
            500,
            "PROFILE_CONFIG_INVALID",
            "oauth.token_path must be path-absolute (start with /).",
        )
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/")
    return path


def build_token_url(canonical_domain: str, token_path: str) -> str:
    """
    Join https:// + canonical_domain + validated token_path via urljoin.
    """
    norm = validate_token_path(token_path)
    return urljoin(f"https://{canonical_domain}", norm)

