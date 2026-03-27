"""
Validate profile name and secconfig subdirectory segment (no path escape).
"""

import re

_SEGMENT_RE = re.compile(r"^[a-zA-Z0-9_-]+$")


def is_safe_config_segment(name: str) -> bool:
    """True if name is a single path segment (alphanumeric, _, -)."""
    return bool(name) and _SEGMENT_RE.match(name) is not None
