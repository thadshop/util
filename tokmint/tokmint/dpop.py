"""
DPoP proof JWT for HTTP requests (RFC 9449).
"""

from __future__ import annotations

import base64
import hashlib
import logging
import secrets
import time
from typing import Any, Dict, Optional

import jwt

from tokmint.errors import TokmintError
from tokmint.jwt_sign import (
    PrivateKeyTypes,
    algorithm_for_key,
    public_jwk_for_header,
)

logger = logging.getLogger(__name__)

DPOP_TYP = "dpop+jwt"


def build_dpop_proof_jwt(
    *,
    private_key: PrivateKeyTypes,
    http_method: str,
    http_url: str,
    nonce: Optional[str] = None,
    access_token: Optional[str] = None,
) -> str:
    """
    Build a DPoP proof for one HTTP request.

    http_url is the full request URL; query and fragment are stripped per
    RFC 9449 §4.2 before embedding as the htu claim.
    nonce is included when the server requires it (RFC 9449 §8).
    access_token must be supplied for resource-server proofs: it produces
    the ath claim (base64url SHA-256 of the token) required by RFC 9449
    §4.2. Omit for token-endpoint proofs.
    """
    htm = http_method.strip().upper()
    if htm != http_method.upper() or not htm:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Invalid HTTP method for DPoP.",
        )
    # RFC 9449 §4.2: htu must not include query or fragment components.
    htu = http_url.split("?", 1)[0].split("#", 1)[0]
    if not htu:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Invalid htu for DPoP.",
        )
    now = int(time.time())
    claims: Dict[str, Any] = {
        "jti": secrets.token_urlsafe(24),
        "htm": htm,
        "htu": htu,
        "iat": now,
    }
    if nonce is not None:
        claims["nonce"] = nonce
    if access_token is not None:
        digest = hashlib.sha256(access_token.encode("ascii")).digest()
        claims["ath"] = (
            base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
        )
    alg = algorithm_for_key(private_key)
    _dpop_log: Dict[str, Any] = {
        "event": "dpop_proof_jwt",
        "htm": claims["htm"],
        "htu": claims["htu"],
        "iat": claims["iat"],
        "jti": claims["jti"],
        "alg": alg,
        "has_nonce": nonce is not None,
        "has_ath": access_token is not None,
    }
    logger.debug("", extra=_dpop_log)
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
