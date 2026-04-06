"""
OAuth 2.0 client authentication JWT (private_key_jwt), RFC 7523.
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
    merge_jose_headers,
)

CLIENT_ASSERTION_TYPE = (
    "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
)


def build_client_assertion_jwt(
    *,
    issuer: str,
    subject: str,
    audience: str,
    private_key: PrivateKeyTypes,
    ttl_seconds: int,
    profile_jwt_headers: Any,
) -> str:
    """
    Create signed client assertion JWT for token-endpoint client
    authentication.
    """
    if ttl_seconds < 1 or ttl_seconds > 3600:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "assertion_ttl_seconds out of allowed range.",
        )
    now = int(time.time())
    exp = now + int(ttl_seconds)
    jti = secrets.token_urlsafe(32)
    claims = {
        "iss": issuer,
        "sub": subject,
        "aud": audience,
        "iat": now,
        "exp": exp,
        "jti": jti,
    }
    alg = algorithm_for_key(private_key)
    jose_base: Dict[str, Any] = {"alg": alg}
    headers = merge_jose_headers(jose_base, profile_jwt_headers)
    try:
        return jwt.encode(claims, private_key, algorithm=alg, headers=headers)
    except Exception as exc:
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Could not sign client assertion.",
        ) from exc


def client_assertion_form_fields(assertion_jwt: str) -> Dict[str, str]:
    """Form fields for application/x-www-form-urlencoded token POST."""
    return {
        "client_assertion_type": CLIENT_ASSERTION_TYPE,
        "client_assertion": assertion_jwt,
    }
