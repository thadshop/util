#!/usr/bin/env python3
"""Test if decryption will work with secconfig.

Exit 0 if OK, 1 otherwise.
"""

import sys

from secconfig.loader import test_decryption


def main() -> int:
    """Run test and exit with appropriate code."""
    return 0 if test_decryption() else 1


if __name__ == "__main__":
    sys.exit(main())
