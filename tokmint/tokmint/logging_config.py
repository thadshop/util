"""
Logging configuration for tokmint.

Provides a compact JSON formatter and a setup function that wires the
``tokmint`` logger hierarchy to a single StreamHandler.  All log records
are emitted as one JSON object per line (no trailing newline from the
formatter itself — StreamHandler adds one).

Usage::

    from tokmint.logging_config import configure_logging
    configure_logging("VERBOSE")

Callers log structured data via ``extra``::

    logger.info("", extra={"event": "token_minted", "profile": "okta"})

The ``event`` key (or the formatted message when ``event`` is absent) is
always present in the output.  Secrets must not appear in ``extra`` unless
``TOKMINT_UNSAFE_LOGGING`` is ``true`` case-insensitively (see
``get_unsafe_logging``).

Log levels (most to least verbose):
    DEBUG   (10) — JWT internals, key algorithm selection, DPoP proof fields
    VERBOSE (15) — HTTP request/response detail (redacted unless unsafe)
    INFO    (20) — Normal operation events (startup, token_minted, errors)
"""

import datetime
import json
import logging
from typing import Any

# Custom level between DEBUG and INFO for HTTP request/response tracing.
VERBOSE = 15
logging.addLevelName(VERBOSE, "VERBOSE")

# LogRecord attributes that are part of stdlib's internal bookkeeping.
# These are filtered out so they don't appear as extra JSON fields.
_STDLIB_ATTRS: frozenset[str] = frozenset(
    {
        "args",
        "created",
        "exc_info",
        "exc_text",
        "filename",
        "funcName",
        "levelname",
        "levelno",
        "lineno",
        "message",
        "module",
        "msecs",
        "msg",
        "name",
        "pathname",
        "process",
        "processName",
        "relativeCreated",
        "stack_info",
        "taskName",
        "thread",
        "threadName",
    }
)


class JsonFormatter(logging.Formatter):
    """
    Format each LogRecord as a single compact JSON line.

    Fixed fields emitted first: ``ts``, ``level``, ``logger``.
    All ``extra`` keys follow in insertion order.  If no ``event``
    key is present in extras, the formatted log message is used.
    """

    def format(self, record: logging.LogRecord) -> str:
        ts = datetime.datetime.fromtimestamp(
            record.created,
            tz=datetime.timezone.utc,
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

        obj: dict[str, Any] = {
            "ts": ts,
            "level": record.levelname,
            "logger": record.name,
        }

        # Collect extra fields injected by callers via extra={}.
        for key, val in record.__dict__.items():
            if key not in _STDLIB_ATTRS:
                obj[key] = val

        # Fallback: if caller passed a plain string message and no
        # event key, use the formatted message as the event.
        if "event" not in obj:
            obj["event"] = record.getMessage()

        return json.dumps(obj, ensure_ascii=True, separators=(",", ":"))


def configure_logging(log_level: str) -> None:
    """
    Wire the ``tokmint`` logger to a StreamHandler with JsonFormatter.

    Should be called once at process startup, before uvicorn is started.
    ``log_level`` must be a valid Python logging level name
    (DEBUG, VERBOSE, INFO, WARNING, ERROR, CRITICAL).
    """
    level = logging.getLevelName(log_level.upper())
    if not isinstance(level, int):
        level = logging.INFO
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger("tokmint")
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level)
    # Do not propagate to the root logger; uvicorn owns that.
    root.propagate = False
