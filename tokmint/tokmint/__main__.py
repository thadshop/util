"""
Run tokmint with: python -m tokmint
"""

import uvicorn

from tokmint.settings import get_listen_port


def main() -> None:
    """Start uvicorn on 127.0.0.1 (Phase 1)."""
    uvicorn.run(
        "tokmint.app:app",
        host="127.0.0.1",
        port=get_listen_port(),
        factory=False,
    )


if __name__ == "__main__":
    main()
