#!/usr/bin/env python3
"""
Test if decryption will work with secconfig.

Exit 0 if OK, 1 otherwise.
"""

import sys
from pathlib import Path

# Package is secconfig/secconfig/; add project root (parent of tests/).
SCRIPT_DIR = Path(__file__).resolve().parent
_PKG_ROOT = SCRIPT_DIR.parent
if str(_PKG_ROOT) not in sys.path:
    sys.path.insert(0, str(_PKG_ROOT))

from secconfig.loader import test_decryption


def main() -> int:
    """
    Run test and exit with appropriate code.
    """
    return 0 if test_decryption() else 1


if __name__ == "__main__":
    sys.exit(main())
