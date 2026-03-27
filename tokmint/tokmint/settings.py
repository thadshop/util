"""
Runtime settings from environment variables.
"""

import os

DEFAULT_PORT = 9876
DEFAULT_SECCONFIG_SUBDIR = "tokmint"


def get_listen_port() -> int:
    """TCP port for uvicorn (default 9876)."""
    raw = os.environ.get("TOKMINT_PORT", "").strip()
    if not raw:
        return DEFAULT_PORT
    return int(raw)


def get_seconfig_subdir() -> str:
    """Directory name under SECCONFIG_DIR for profile YAML."""
    raw = os.environ.get("TOKMINT_SECCONFIG_SUBDIR", "").strip()
    return raw if raw else DEFAULT_SECCONFIG_SUBDIR
