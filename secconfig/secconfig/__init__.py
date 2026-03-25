"""
Load YAML config files with sops-encrypted secrets.
"""

from secconfig.loader import (
    SECCONFIG_DIR_ENV,
    check_prereqs,
    load_config,
    resolve_seconfig_dir,
    test_decryption,
)

# Call check_prereqs() before the first load_config() if you want fail-fast
# checks (sops, keyring, SECCONFIG_DIR). Otherwise errors surface when you
# call load_config() or test_decryption().

__all__ = [
    "SECCONFIG_DIR_ENV",
    "check_prereqs",
    "load_config",
    "resolve_seconfig_dir",
    "test_decryption",
]
