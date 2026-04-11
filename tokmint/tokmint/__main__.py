"""
Run tokmint with: python -m tokmint
"""

import logging

import uvicorn

from tokmint.logging_config import configure_logging
from tokmint.settings import get_settings_summary


def main() -> None:
    """Configure logging, emit startup settings, then start uvicorn."""
    settings = get_settings_summary()
    log_level: str = str(settings["log_level"])
    configure_logging(log_level)

    logger = logging.getLogger("tokmint")
    logger.info("", extra={"event": "startup", **settings})

    uvicorn.run(
        "tokmint.app:app",
        host="127.0.0.1",
        port=int(settings["port"]),
        log_level=log_level.lower(),
        factory=False,
    )


if __name__ == "__main__":
    main()
