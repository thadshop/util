"""
Run tokmint with: python -m tokmint
"""

import logging

import uvicorn

from tokmint.logging_config import configure_logging
from tokmint.settings import get_settings_summary, get_unsafe_logging


def main() -> None:
    """Configure logging, emit startup settings, then start uvicorn."""
    settings = get_settings_summary()
    log_level: str = str(settings["log_level"])
    configure_logging(log_level)

    logger = logging.getLogger("tokmint")
    logger.info("", extra={"event": "startup", **settings})

    if get_unsafe_logging():
        logger.warning(
            "",
            extra={
                "event": "unsafe_logging_enabled",
                "notice": (
                    "TOKMINT_UNSAFE_LOGGING=true; log output may contain "
                    "secrets and replayable credentials."
                ),
            },
        )

    _UVICORN_LEVELS = frozenset(
        {
            "critical",
            "error",
            "warning",
            "info",
            "debug",
            "trace",
        }
    )
    uvicorn_level = log_level.lower()
    if uvicorn_level not in _UVICORN_LEVELS:
        uvicorn_level = "info"
    uvicorn.run(
        "tokmint.app:app",
        host="127.0.0.1",
        port=int(settings["port"]),
        log_level=uvicorn_level,
        factory=False,
    )


if __name__ == "__main__":
    main()
