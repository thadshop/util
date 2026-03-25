"""
Secure loader for YAML config files with sops-encrypted secrets.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Optional

# Env var: directory containing encrypted configs, .sops.yaml, and sops
# metadata. If set, relative config paths resolve under this directory.
SECCONFIG_DIR_ENV = "SECCONFIG_DIR"


class SecretsConfigError(Exception):
    """
    Raised when config loading fails or security checks fail.
    """

    pass


def _validate_seconfig_directory(path: Path) -> Path:
    """
    Ensure path is a usable directory for configs and sops metadata.

    Raises SecretsConfigError with path and reason when not usable.
    """
    if not path.exists():
        raise SecretsConfigError(
            f"secconfig: {SECCONFIG_DIR_ENV} points to a path that does "
            f"not exist: {path}"
        )
    if not path.is_dir():
        raise SecretsConfigError(
            f"secconfig: {SECCONFIG_DIR_ENV} must be a directory (not usable):"
            f" {path}"
        )
    if not os.access(path, os.R_OK):
        raise SecretsConfigError(
            f"secconfig: {SECCONFIG_DIR_ENV} directory is not readable: {path}"
        )
    if not os.access(path, os.X_OK):
        raise SecretsConfigError(
            f"secconfig: {SECCONFIG_DIR_ENV} directory is not searchable "
            f"(execute permission required): {path}"
        )
    return path


def resolve_seconfig_dir() -> Optional[Path]:
    """
    If SECONFIG_DIR is set, validate it and return the absolute Path.

    Returns None if unset. Raises SecretsConfigError if set but invalid.
    """
    raw = os.environ.get(SECCONFIG_DIR_ENV, "").strip()
    if not raw:
        return None
    return _validate_seconfig_directory(Path(raw).expanduser().resolve())


def check_prereqs() -> None:
    """
    Verify all prerequisites for secconfig.

    Raises SecretsConfigError listing any missing prerequisites and how to
    fix them.
    """
    missing: list[str] = []

    # Python
    try:
        import yaml  # noqa: F401
    except ImportError:
        missing.append("PyYAML: pip install pyyaml")

    # Linux
    if sys.platform != "linux":
        missing.append(
            "Linux: secconfig requires Linux (kernel keyring, /dev/shm)"
        )

    if not Path("/dev/shm").exists():
        missing.append("/dev/shm: Linux tmpfs required (not available)")

    # sops
    if shutil.which("sops") is None:
        missing.append(
            "sops: https://github.com/getsops/sops/releases or: "
            "go install github.com/getsops/sops/v3/cmd/sops@latest"
        )

    # get-dek.sh (Bash secrets)
    dek_path = _default_get_dek_path()
    if not dek_path.exists():
        missing.append(
            f"get-dek.sh: not found at {dek_path}. "
            "Source keyring/init.sh, run rotate-kek.sh, "
            "ensure repo layout."
        )
    elif not os.access(dek_path, os.X_OK):
        missing.append(f"get-dek.sh: not executable at {dek_path}")

    wsd_path = _with_sops_dek_path()
    if not wsd_path.exists():
        missing.append(
            f"with-sops-dek.sh: not found at {wsd_path}. "
            "Ensure util repo layout (keyring/)."
        )
    elif not os.access(wsd_path, os.X_OK):
        missing.append(
            f"with-sops-dek.sh: not executable at {wsd_path}"
        )

    try:
        resolve_seconfig_dir()
    except SecretsConfigError as e:
        missing.append(str(e).replace("secconfig: ", "", 1))

    if missing:
        msg = "secconfig: missing prerequisites:\n  - " + "\n  - ".join(missing)
        raise SecretsConfigError(msg)


def _check_no_debug() -> None:
    """Refuse if debugger, profiler, or verbose mode could leak."""
    if sys.gettrace() is not None:
        raise SecretsConfigError(
            "secconfig: refused (debugger attached). Detach debugger first."
        )
    if sys.getprofile() is not None:
        raise SecretsConfigError(
            "secconfig: refused (profiler active). Disable profiler first."
        )
    if sys.flags.debug:
        raise SecretsConfigError(
            "secconfig: refused (Python -d debug mode). Run without -d."
        )
    if sys.flags.verbose:
        raise SecretsConfigError(
            "secconfig: refused (Python -v verbose mode). Run without -v."
        )
    try:
        import faulthandler

        if faulthandler.is_enabled():
            raise SecretsConfigError(
                "secconfig: refused (faulthandler enabled). "
                "Disable faulthandler first."
            )
    except ImportError:
        pass


def _util_repo_root() -> Path:
    """Return util repo root (parent of secconfig/ and keyring/)."""
    return Path(__file__).resolve().parent.parent.parent


def _test_decryption_script_path() -> Path:
    """Return path to keyring test-decryption.sh."""
    return _util_repo_root() / "keyring" / "test-decryption.sh"


def test_decryption() -> bool:
    """
    Test that decryption will work (KEK, DEK, sops).

    Runs keyring/test-decryption.sh. Returns True if OK, False
    otherwise. Prints to stderr on failure.
    """
    check_script = _test_decryption_script_path()
    if not check_script.exists() or not check_script.is_file():
        return False
    result = subprocess.run(
        [str(check_script)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        else:
            print("secconfig: decryption test failed", file=sys.stderr)
        return False
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    return True


def _default_get_dek_path() -> Path:
    """Return default path to get-dek.sh (repo root keyring/)."""
    return _util_repo_root() / "keyring" / "get-dek.sh"


def _with_sops_dek_path() -> Path:
    """Return path to keyring/with-sops-dek.sh."""
    return _util_repo_root() / "keyring" / "with-sops-dek.sh"


def _is_sops_encrypted(config_path: Path) -> bool:
    """Check if file is sops-encrypted (has sops metadata)."""
    try:
        with open(config_path, "rb") as f:
            data = f.read(4096)
        return b"sops:" in data or b"ENC[" in data
    except OSError:
        return False


def _decrypt_with_sops(config_path: Path, *, get_dek_path: Path) -> bytes:
    """
    Decrypt config with sops via keyring/with-sops-dek.sh (DEK never in Python).
    """
    wrapper = _with_sops_dek_path()
    if not wrapper.is_file():
        raise SecretsConfigError(
            f"secconfig: with-sops-dek.sh not found at {wrapper}. "
            "Ensure util repo layout (keyring/)."
        )
    if not os.access(wrapper, os.X_OK):
        raise SecretsConfigError(
            f"secconfig: with-sops-dek.sh not executable: {wrapper}"
        )
    if not get_dek_path.exists():
        raise SecretsConfigError(
            f"secconfig: get-dek.sh not found at {get_dek_path}. "
            "Set get_dek_path or ensure util repo layout (keyring/)."
        )
    if not os.access(get_dek_path, os.X_OK):
        raise SecretsConfigError(
            f"secconfig: get-dek.sh not executable: {get_dek_path}"
        )

    cmd: list[str] = [
        str(wrapper),
        "-k",
        str(get_dek_path),
    ]
    sops_root = resolve_seconfig_dir()
    if sops_root is not None:
        sops_cfg = sops_root / ".sops.yaml"
        if sops_cfg.is_file():
            cmd.extend(["-c", str(sops_cfg)])
    cmd.extend(["--", "sops", "--decrypt", str(config_path)])

    result = subprocess.run(
        cmd,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        err = result.stderr.decode("utf-8", errors="replace").strip()
        raise SecretsConfigError(
            f"secconfig: sops decrypt failed: {err or 'unknown error'}"
        )
    return result.stdout


def _load_yaml(data: bytes) -> Any:
    """Parse YAML bytes into Python object."""
    import yaml

    return yaml.safe_load(data)


def load_config(
    config_path: Path | str,
    *,
    get_dek_path: Optional[Path | str] = None,
) -> dict[str, Any]:
    """
    Load YAML config file. Decrypts with sops if encrypted.

    Encrypted files: runs keyring/with-sops-dek.sh (get-dek.sh + sops); the
    age DEK is not read into this Python process.

    Args:
        config_path: Path to YAML config (plain or sops-encrypted). If
            environment variable SECONFIG_DIR is set, relative paths are
            resolved under that directory (must be an existing, readable
            directory).
        get_dek_path: Path to get-dek.sh (passed to with-sops-dek -k).
            Default: keyring/get-dek.sh under util repo root.

    Returns:
        Parsed config as a dict.

    Raises:
        SecretsConfigError: If security checks fail, with-sops-dek/sops
            fails, or the file cannot be read.
    """
    _check_no_debug()

    base = resolve_seconfig_dir()
    cfg = Path(config_path)
    if base is not None and not cfg.is_absolute():
        path = (base / cfg).resolve()
    else:
        path = cfg.resolve()

    if not path.exists():
        raise SecretsConfigError(f"secconfig: config file not found: {path}")

    dek_path = (
        Path(get_dek_path)
        if get_dek_path is not None
        else _default_get_dek_path()
    )

    if _is_sops_encrypted(path):
        decrypted = _decrypt_with_sops(path, get_dek_path=dek_path)
        return _load_yaml(decrypted)
    else:
        with open(path, "rb") as f:
            return _load_yaml(f.read())
