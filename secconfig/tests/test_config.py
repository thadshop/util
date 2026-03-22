#!/usr/bin/env python3
"""Test script for secconfig: load YAML config (plain or encrypted)."""

import sys
from pathlib import Path

from secconfig import load_config, test_decryption

SCRIPT_DIR = Path(__file__).resolve().parent
_EXAMPLES = SCRIPT_DIR.parent / "examples"


def main() -> None:
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
