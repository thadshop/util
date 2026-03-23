#!/usr/bin/env python3
"""
Test script for secconfig: load YAML config (plain or encrypted).
"""

import sys
from pathlib import Path

# Ensure secconfig is in the Python path
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent.parent))

# Debug: Print Python path to troubleshoot import issues
print("Python Path:", sys.path)

# Debug: Inspect secconfig module __path__
try:
    import secconfig
    print("secconfig __path__:", getattr(secconfig, '__path__', None))
except ImportError as e:
    print("Failed to import secconfig:", e)
    sys.exit(1)

# Debug: Inspect secconfig module contents
print("secconfig contents:", dir(secconfig))

from secconfig import load_config, test_decryption

SCRIPT_DIR = Path(__file__).resolve().parent
_EXAMPLES = SCRIPT_DIR.parent / "examples"


def main() -> None:
    """
    Run tests for plain and encrypted YAML configs.
    """
    # Test 1: plain YAML
    plain_path = _EXAMPLES / "example-config.yaml"
    if plain_path.exists():
        config = load_config(plain_path)
        print(f"Loaded plain config: {config}")
    else:
        print(f"Plain config not found: {plain_path}")

    # Test 2: sops-encrypted YAML (if present)
    enc_path = _EXAMPLES / "example-config.enc.yaml"
    if enc_path.exists():
        if not test_decryption():
            sys.exit(1)
        config = load_config(enc_path)
        print(f"Loaded encrypted config: {config}")
    else:
        print(f"Encrypted config not found: {enc_path}")
        print("To create: see secconfig/README.md (examples/)")


if __name__ == "__main__":
    main()
