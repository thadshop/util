"""
Runtime settings from environment variables.
"""

import os

DEFAULT_PORT = 9876
DEFAULT_SECCONFIG_SUBDIR = "tokmint"
DEFAULT_LOG_LEVEL = "INFO"

_VALID_LOG_LEVELS = frozenset({
    "DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL",
})


def get_listen_port() -> int:
    """TCP port for uvicorn (default 9876)."""
    raw = os.environ.get("TOKMINT_PORT", "").strip()
    if not raw:
        return DEFAULT_PORT
    return int(raw)


def get_secconfig_subdir() -> str:
    """Directory name under SECCONFIG_DIR for profile YAML."""
    raw = os.environ.get("TOKMINT_SECCONFIG_SUBDIR", "").strip()
    return raw if raw else DEFAULT_SECCONFIG_SUBDIR


def get_log_level() -> str:
    """
    Log level for the tokmint logger (default INFO).

    Reads TOKMINT_LOG_LEVEL; falls back to INFO for unrecognised values.
    """
    raw = os.environ.get("TOKMINT_LOG_LEVEL", "").strip().upper()
    if raw in _VALID_LOG_LEVELS:
        return raw
    return DEFAULT_LOG_LEVEL


def get_settings_summary() -> dict[str, object]:
    """
    Return all runtime settings as a plain dict for startup logging.

    Values are the effective (resolved) values, not raw env strings.
    SECCONFIG_DIR is included as a path hint; it is not a secret.
    """
    return {
        "port": get_listen_port(),
        "secconfig_subdir": get_secconfig_subdir(),
        "log_level": get_log_level(),
        "secconfig_dir": os.environ.get("SECCONFIG_DIR", ""),
    }
