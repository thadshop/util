"""
Secure loader for YAML config files with sops-encrypted secrets.
"""

import os
import shutil
import subprocess
import sys
import tempfile
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
    return path


def resolve_seconfig_dir() -> Optional[Path]:
    """
    If SECONFIG_DIR is set, validate it and return the absolute Path.

    Returns None if unset. Raises SecretsConfigError if set but invalid.
    """
    raw = os.environ.get(SECCONFIG_DIR_ENV, "").strip()
    if not raw:
        return None
    return _validate_seconfig_directory(
        Path(raw).expanduser().resolve()
    )


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
            "secconfig: refused (debugger attached). "
            "Detach debugger first."
        )
    if sys.getprofile() is not None:
        raise SecretsConfigError(
            "secconfig: refused (profiler active). "
            "Disable profiler first."
        )
    if sys.flags.debug:
        raise SecretsConfigError(
            "secconfig: refused (Python -d debug mode). "
            "Run without -d."
        )
    if sys.flags.verbose:
        raise SecretsConfigError(
            "secconfig: refused (Python -v verbose mode). "
            "Run without -v."
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


def _test_decryption_script_path() -> Path:
    """Return path to keyring test-decryption.sh."""
    base = Path(__file__).resolve().parent.parent.parent
    return base / "keyring" / "test-decryption.sh"


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
    base = Path(__file__).resolve().parent.parent.parent
    return base / "keyring" / "get-dek.sh"


def _get_dek(get_dek_path: Path) -> bytes:
    """Run get-dek.sh and return the DEK."""
    if not get_dek_path.exists():
        raise SecretsConfigError(
            f"secconfig: get-dek.sh not found at {get_dek_path}. "
            "Set get_dek_path or ensure util repo layout (keyring/)."
        )
    if not os.access(get_dek_path, os.X_OK):
        raise SecretsConfigError(
            f"secconfig: get-dek.sh not executable: {get_dek_path}"
        )
    result = subprocess.run(
        [str(get_dek_path)],
        capture_output=True,
        text=False,
        check=False,
    )
    if result.returncode != 0:
        err = result.stderr.decode("utf-8", errors="replace").strip()
        raise SecretsConfigError(
            f"secconfig: get-dek failed: {err or 'unknown error'}"
        )
    return result.stdout


def _is_sops_encrypted(config_path: Path) -> bool:
    """Check if file is sops-encrypted (has sops metadata)."""
    try:
        with open(config_path, "rb") as f:
            data = f.read(4096)
        return b"sops:" in data or b"ENC[" in data
    except OSError:
        return False


def _decrypt_with_sops(config_path: Path, dek: bytes) -> bytes:
    """Decrypt config file with sops using the given DEK."""
    if shutil.which("sops") is None:
        raise SecretsConfigError(
            "secconfig: sops not found. "
            "Install sops: https://github.com/getsops/sops/releases"
        )
    # Use /dev/shm (tmpfs, RAM) so key never touches disk.
    # sops reads key file multiple times; pipe would only work once.
    if not Path("/dev/shm").exists():
        raise SecretsConfigError(
            "secconfig: /dev/shm not found. Linux with tmpfs required; "
            "cleartext keys are never written to disk."
        )
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            delete=False,
            suffix=".age-key",
            dir="/dev/shm",
        ) as tmp:
            tmp.write(dek)
            tmp_path = tmp.name
        try:
            env = {**os.environ, "SOPS_AGE_KEY_FILE": tmp_path}
            sops_root = resolve_seconfig_dir()
            if sops_root is not None:
                sops_cfg = sops_root / ".sops.yaml"
                if sops_cfg.is_file():
                    env["SOPS_CONFIG"] = str(sops_cfg)
            result = subprocess.run(
                ["sops", "--decrypt", str(config_path)],
                capture_output=True,
                env=env,
                check=False,
            )
            if result.returncode != 0:
                err = result.stderr.decode(
                    "utf-8", errors="replace"
                ).strip()
                raise SecretsConfigError(
                    f"secconfig: sops decrypt failed: "
                    f"{err or 'unknown error'}"
                )
            return result.stdout
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
    except OSError as e:
        raise SecretsConfigError(
            f"secconfig: temp file error: {e}"
        ) from e


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

    Uses get-dek.sh to obtain the age key for sops decryption.
    The decrypted config is returned in memory; no cleartext on disk.

    Args:
        config_path: Path to YAML config (plain or sops-encrypted). If
            environment variable SECONFIG_DIR is set, relative paths are
            resolved under that directory (must be an existing, readable
            directory).
        get_dek_path: Path to get-dek.sh. Default:
            keyring/get-dek.sh (sibling of secconfig/ at repo root).

    Returns:
        Parsed config as a dict.

    Raises:
        SecretsConfigError: If security checks fail, get-dek fails, sops
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
        raise SecretsConfigError(
            f"secconfig: config file not found: {path}"
        )

    dek_path = (
        Path(get_dek_path)
        if get_dek_path is not None
        else _default_get_dek_path()
    )

    if _is_sops_encrypted(path):
        dek = bytearray(_get_dek(dek_path))
        try:
            decrypted = _decrypt_with_sops(path, bytes(dek))
            return _load_yaml(decrypted)
        finally:
            for i in range(len(dek)):
                dek[i] = 0
            del dek
    else:
        with open(path, "rb") as f:
            return _load_yaml(f.read())
