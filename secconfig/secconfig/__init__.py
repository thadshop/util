"""Load YAML config files with sops-encrypted secrets."""

from secconfig.loader import (
    SECCONFIG_DIR_ENV,
    check_prereqs,
    load_config,
    resolve_seconfig_dir,
    test_decryption,
)

check_prereqs()

__all__ = [
    "SECCONFIG_DIR_ENV",
    "check_prereqs",
    "load_config",
    "resolve_seconfig_dir",
    "test_decryption",
]
