"""
DPoP proof JWT for HTTP requests (RFC 9449).
"""

from __future__ import annotations

import secrets
import time
from typing import Any, Dict

import jwt

from tokmint.errors import TokmintError
from tokmint.jwt_sign import (
    PrivateKeyTypes,
    algorithm_for_key,
    public_jwk_for_header,
)

DPOP_TYP = "dpop+jwt"


def build_dpop_proof_jwt(
    *,
    private_key: PrivateKeyTypes,
    http_method: str,
    http_url: str,
) -> str:
    """
    Build a DPoP proof for one HTTP request (e.g. token POST).

    http_url must match the request URL per RFC 9449 (fragment stripped).
    """
    htm = http_method.strip().upper()
    if htm != http_method.upper() or not htm:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Invalid HTTP method for DPoP.",
        )
    htu = http_url.split("#", 1)[0]
    if not htu:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Invalid htu for DPoP.",
        )
    now = int(time.time())
    claims = {
        "jti": secrets.token_urlsafe(24),
        "htm": htm,
        "htu": htu,
        "iat": now,
    }
    alg = algorithm_for_key(private_key)
    pub_jwk = public_jwk_for_header(private_key)
    headers: Dict[str, Any] = {
        "typ": DPOP_TYP,
        "jwk": pub_jwk,
        "alg": alg,
    }
    try:
        return jwt.encode(claims, private_key, algorithm=alg, headers=headers)
    except Exception as exc:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Could not sign DPoP proof.",
        ) from exc
