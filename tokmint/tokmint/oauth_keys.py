"""
Resolve private key material from profile signing_keys rows.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from tokmint.errors import TokmintError
from tokmint.jwt_sign import (
    PrivateKeyTypes,
    load_private_key_from_jwk,
    load_private_key_from_pem_path,
)


def load_private_key_from_signing_key_row(
    row: dict[str, Any],
    seconfig_base: Path,
) -> PrivateKeyTypes:
    """
    Load cryptography private key from encrypted_pem_path or jwk.
    Relative PEM paths resolve under seconfig_base (SECCONFIG_DIR).
    """
    jwk = row.get("jwk")
    if isinstance(jwk, dict) and len(jwk) > 0:
        return load_private_key_from_jwk(jwk)
    pem_raw = row.get("encrypted_pem_path")
    if isinstance(pem_raw, str) and pem_raw.strip():
        p = Path(pem_raw.strip())
        if not p.is_absolute():
            p = (seconfig_base / p).resolve()
            try:
                p.relative_to(seconfig_base.resolve())
            except ValueError as exc:
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "encrypted_pem_path escapes SECCONFIG_DIR.",
                ) from exc
        return load_private_key_from_pem_path(p)
    raise TokmintError(
        400,
        "PROFILE_INVALID",
        "Invalid profile: signing key row has neither jwk nor "
        "encrypted_pem_path.",
    )
