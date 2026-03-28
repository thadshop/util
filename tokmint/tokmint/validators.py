"""
Validate profile name and secconfig subdirectory segment (no path escape).
"""

import re

_SEGMENT_RE = re.compile(r"^[a-zA-Z0-9_-]+$")
_AUTH_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]{0,127}$")


def is_safe_config_segment(name: str) -> bool:
    """True if name is a single path segment (alphanumeric, _, -)."""
    return bool(name) and _SEGMENT_RE.match(name) is not None


def is_valid_auth_scheme(name: str) -> bool:
    """
    True if name is a plausible HTTP Authorization scheme (Bearer, SSWS, …).

    First character must be a letter; rest letters, digits, +, ., - only.
    """
    return bool(name) and _AUTH_SCHEME_RE.match(name) is not None
