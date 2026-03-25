#!/usr/bin/env python3
"""
Test script for secconfig: load YAML config (plain or encrypted).

Does not print config values (avoids leaking secrets from examples).
"""

import sys
from pathlib import Path

# Package lives at secconfig/secconfig/; add the parent of that (secconfig/).
# Inserting the repo root would load util/secconfig/ as "secconfig" (wrong).
SCRIPT_DIR = Path(__file__).resolve().parent
_PKG_ROOT = SCRIPT_DIR.parent
if str(_PKG_ROOT) not in sys.path:
    sys.path.insert(0, str(_PKG_ROOT))

from secconfig import load_config, test_decryption

_EXAMPLES = SCRIPT_DIR.parent / "examples"


def main() -> None:
    """
    Run tests for plain and encrypted YAML configs.
    """
    # Test 1: plain YAML
    plain_path = _EXAMPLES / "example-config.yaml"
    if plain_path.exists():
        config = load_config(plain_path)
        _keys = list(config.keys()) if isinstance(config, dict) else "?"
        print(f"Loaded plain config OK (top-level keys: {_keys})")
    else:
        print(f"Plain config not found: {plain_path}")

    # Test 2: sops-encrypted YAML (if present)
    enc_path = _EXAMPLES / "example-config.enc.yaml"
    if enc_path.exists():
        if not test_decryption():
            sys.exit(1)
        config = load_config(enc_path)
        _keys = list(config.keys()) if isinstance(config, dict) else "?"
        print(f"Loaded encrypted config OK (top-level keys: {_keys})")
    else:
        print(f"Encrypted config not found: {enc_path}")
        print("To create: see secconfig/README.md (examples/)")


if __name__ == "__main__":
    main()
