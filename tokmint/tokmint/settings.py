"""
Runtime settings from environment variables.
"""

import os

DEFAULT_PORT = 9876
DEFAULT_SECCONFIG_SUBDIR = "tokmint"
DEFAULT_LOG_LEVEL = "INFO"
DEFAULT_JSONL_FMT_FLUSH_MS = 1000

_VALID_LOG_LEVELS = frozenset(
    {
        "DEBUG",
        "VERBOSE",
        "INFO",
        "WARNING",
        "ERROR",
        "CRITICAL",
    }
)


def get_listen_port() -> int:
    """TCP port for uvicorn (default 9876)."""
    raw = os.environ.get("TOKMINT_PORT", "").strip()
    if not raw:
        return DEFAULT_PORT
    else:
        return int(raw)


def get_secconfig_subdir() -> str:
    """Directory name under SECCONFIG_DIR for profile YAML."""
    raw = os.environ.get("TOKMINT_SECCONFIG_SUBDIR", "").strip()
    if raw:
        return raw
    else:
        return DEFAULT_SECCONFIG_SUBDIR


def get_unsafe_logging() -> bool:
    """
    Whether VERBOSE logs may include redacted material verbatim.

    Reads TOKMINT_UNSAFE_LOGGING.  Only the string ``true`` after strip,
    compared case-insensitively, enables unsafe logging.  Any other value
    (including empty) disables it.
    """
    raw = os.environ.get("TOKMINT_UNSAFE_LOGGING", "").strip().lower()
    return raw == "true"


def get_log_level() -> str:
    """
    Log level for the tokmint logger (default INFO).

    Reads TOKMINT_LOG_LEVEL; falls back to INFO for unrecognised values.
    Valid values: DEBUG, VERBOSE, INFO, WARNING, ERROR, CRITICAL.
    """
    raw = os.environ.get("TOKMINT_LOG_LEVEL", "").strip().upper()
    if raw in _VALID_LOG_LEVELS:
        return raw
    else:
        return DEFAULT_LOG_LEVEL


def get_jsonl_fmt_flush_ms() -> int:
    """
    Burst flush timeout for jsonl-fmt -a mode (default 1000 ms).

    Reads TOKMINT_JSONL_FMT_FLUSH_MS; falls back to default for
    missing or non-positive values.
    """
    raw = os.environ.get("TOKMINT_JSONL_FMT_FLUSH_MS", "").strip()
    if raw.isdigit() and int(raw) > 0:
        return int(raw)
    return DEFAULT_JSONL_FMT_FLUSH_MS


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
        "unsafe_logging": get_unsafe_logging(),
        "secconfig_dir": os.environ.get("SECCONFIG_DIR", ""),
    }
