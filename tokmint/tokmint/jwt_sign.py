"""
Load private keys (PEM file or JWK dict) and choose JWT signing algorithms.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Tuple, Union

import jwt
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric.ec import (
    EllipticCurvePrivateKey,
)
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPrivateKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from jwt.algorithms import ECAlgorithm, RSAAlgorithm

from tokmint.errors import TokmintError

PrivateKeyTypes = Union[EllipticCurvePrivateKey, RSAPrivateKey]


def load_private_key_from_jwk(jwk: Any) -> PrivateKeyTypes:
    """
    Build a private key from a JWK mapping (RFC 7517 strict subset).

    Supports EC (P-256, P-384, P-521) and RSA. Rejects unknown kty/extra keys
    beyond a small allowlist for security (validate before use).
    """
    if not isinstance(jwk, dict):
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "JWK must be a mapping.",
        )
    kty = jwk.get("kty")
    if kty == "EC":
        return _load_ec_jwk_private(jwk)
    if kty == "RSA":
        return _load_rsa_jwk_private(jwk)
    raise TokmintError(
        400,
        "PROFILE_INVALID",
        "Unsupported or missing jwk.kty (expected EC or RSA).",
    )


def _load_ec_jwk_private(jwk: dict[str, Any]) -> EllipticCurvePrivateKey:
    allowed = {"kty", "crv", "x", "y", "d", "kid", "use", "alg"}
    extra = set(jwk.keys()) - allowed
    if extra:
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "JWK contains unsupported keys.",
        )
    crv = jwk.get("crv")
    if crv not in ("P-256", "P-384", "P-521"):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "EC JWK crv must be P-256, P-384, or P-521.",
        )
    for key in ("x", "y", "d"):
        if not isinstance(jwk.get(key), str) or not jwk[key].strip():
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "EC JWK must include x, y, and d as strings.",
            )
    return ECAlgorithm.from_jwk(json.dumps(jwk))  # type: ignore[return-value]


def _load_rsa_jwk_private(jwk: dict[str, Any]) -> RSAPrivateKey:
    allowed = {
        "kty",
        "n",
        "e",
        "d",
        "p",
        "q",
        "dp",
        "dq",
        "qi",
        "kid",
        "use",
        "alg",
    }
    extra = set(jwk.keys()) - allowed
    if extra:
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "RSA JWK contains unsupported keys.",
        )
    raw = json.dumps(jwk)
    key = RSAAlgorithm.from_jwk(raw)
    if not isinstance(key, RSAPrivateKey):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "RSA JWK did not yield a private key.",
        )
    return key


def load_private_key_from_pem_bytes(pem: bytes) -> PrivateKeyTypes:
    """
    Load a PEM-encoded private key (PKCS#8 or traditional).
    """
    try:
        loaded = load_pem_private_key(pem, password=None, backend=default_backend())
    except ValueError as exc:
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Private key PEM could not be loaded.",
        ) from exc
    if not isinstance(loaded, (EllipticCurvePrivateKey, RSAPrivateKey)):
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "PEM key must be EC or RSA.",
        )
    return loaded


def load_private_key_from_pem_path(path: Path) -> PrivateKeyTypes:
    """
    Read PEM from path and load. File must contain decrypted PEM bytes.
    """
    if not path.is_file():
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "encrypted_pem_path does not exist or is not a file.",
        )
    try:
        pem = path.read_bytes()
    except OSError as exc:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Could not read private key file.",
        ) from exc
    return load_private_key_from_pem_bytes(pem)


def algorithm_for_key(key: PrivateKeyTypes) -> str:
    """Return PyJWT algorithm name for signing."""
    if isinstance(key, EllipticCurvePrivateKey):
        name = key.curve.name
        if name == "secp256r1":
            return "ES256"
        if name == "secp384r1":
            return "ES384"
        if name == "secp521r1":
            return "ES512"
        raise TokmintError(
            400,
            "PROFILE_INVALID",
            "Unsupported elliptic curve for JWT signing.",
        )
    if isinstance(key, RSAPrivateKey):
        return "RS256"
    raise TokmintError(
        500,
        "INTERNAL_ERROR",
        "Unsupported private key type.",
    )


def public_jwk_for_header(key: PrivateKeyTypes) -> Dict[str, Any]:
    """
    Public JWK fields for DPoP proof JWT header (no private material).
    """
    if isinstance(key, EllipticCurvePrivateKey):
        jwk = ECAlgorithm.to_jwk(key.public_key(), as_dict=True)
    elif isinstance(key, RSAPrivateKey):
        jwk = RSAAlgorithm.to_jwk(key.public_key(), as_dict=True)
    else:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Unsupported key for JWK header.",
        )
    jwk.pop("d", None)
    return jwk


def merge_jose_headers(
    base: Dict[str, Any],
    profile_headers: Any,
) -> Dict[str, Any]:
    """
    Merge allowlisted JOSE headers from profile (e.g. kid). Profile value wins.
    """
    out = dict(base)
    if not isinstance(profile_headers, dict):
        return out
    for name in ("kid", "typ", "jku", "x5u", "x5c"):
        if name in profile_headers and profile_headers[name] is not None:
            val = profile_headers[name]
            if isinstance(val, (str, int, float, list, dict)):
                out[str(name)] = val
    return out
