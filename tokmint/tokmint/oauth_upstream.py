"""
HTTP client credentials grant to the IdP token endpoint (Mode B, Phase 2a).
"""

from __future__ import annotations

import base64
import json
import logging
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple, Union
from urllib.parse import urlencode

import httpx

from tokmint.dpop import build_dpop_proof_jwt
from tokmint.errors import TokmintError
from tokmint.jwt_sign import PrivateKeyTypes
from tokmint.oauth_client_assertion import client_assertion_form_fields

logger = logging.getLogger(__name__)


def _header_map_from_profile(
    profile_headers: Any,
    default_pairs: List[Tuple[str, str]],
) -> Dict[str, str]:
    """
    Case-insensitive merge: defaults first, then profile entries (last wins).
    """
    by_lower: Dict[str, Tuple[str, str]] = {}
    for key, val in default_pairs:
        ks = key.strip()
        by_lower[ks.lower()] = (ks, val)
    if profile_headers:
        for item in profile_headers:
            if not isinstance(item, dict):
                continue
            raw_k = item.get("key")
            raw_v = item.get("value")
            if not isinstance(raw_k, str) or not raw_k.strip():
                continue
            if raw_v is None:
                continue
            ks = raw_k.strip()
            by_lower[ks.lower()] = (ks, str(raw_v))
    return {canon: val for canon, val in by_lower.values()}


def _form_encode(data: Mapping[str, str]) -> str:
    """application/x-www-form-urlencoded body."""
    return urlencode(data)


def _upstream_error_fields(response: httpx.Response) -> Dict[str, str]:
    """
    Extract ``error`` and ``error_description`` from an IdP error body.

    Returns an empty dict on any parse failure.  Never raises.
    """
    try:
        body = response.json()
        if not isinstance(body, dict):
            return {}
        out: Dict[str, str] = {}
        if isinstance(body.get("error"), str):
            out["error"] = body["error"]
        if isinstance(body.get("error_description"), str):
            out["error_description"] = body["error_description"]
        return out
    except Exception:
        return {}


def _upstream_error_code(response: httpx.Response) -> Optional[str]:
    """Return the ``error`` string from an IdP error body, or None."""
    return _upstream_error_fields(response).get("error")


async def _post_once(
    client: httpx.AsyncClient,
    url: str,
    headers: Dict[str, str],
    body: str,
) -> httpx.Response:
    """POST to ``url`` and return the response.  Wraps network errors."""
    try:
        return await client.post(url, headers=headers, content=body)
    except httpx.RequestError:
        raise TokmintError(
            502,
            "UPSTREAM_ERROR",
            "Token request failed (network or TLS).",
        ) from None


async def fetch_client_credentials_token(
    token_url: str,
    client_id: str,
    client_secret: Optional[str],
    scopes: Optional[str],
    profile_headers: Any,
    client_authn: str,
    token_form_extra: Optional[Mapping[str, str]],
    client_assertion_factory: Optional[Callable[[], str]] = None,
    dpop_private_key: Optional[PrivateKeyTypes] = None,
    http_client: Optional[httpx.AsyncClient] = None,
) -> Dict[str, Union[str, int]]:
    """
    POST client_credentials to token_url. Return access_token, token_type,
    and expires_in when present.

    client_authn: 'body' | 'basic' | 'private_key_jwt'

    client_assertion_factory is called fresh for each attempt so that each
    POST carries a unique jti (prevents replay rejection on nonce retry).

    When dpop_private_key is provided, a DPoP proof is built and attached.
    A single nonce-retry is performed automatically if the server requires
    one (RFC 9449 §8).
    """
    if client_authn not in ("body", "basic", "private_key_jwt"):
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Invalid client authentication mode.",
        )

    # Base form fields shared across all attempts (no assertion yet).
    base_form: Dict[str, str] = {"grant_type": "client_credentials"}
    if scopes is not None:
        s = scopes.strip()
        if s:
            base_form["scope"] = s
    if token_form_extra:
        for fk, fv in token_form_extra.items():
            if fk and str(fv):
                base_form[str(fk)] = str(fv)

    # Base headers (no DPoP yet; Authorization added below for basic).
    default_header_pairs: List[Tuple[str, str]] = [
        ("Content-Type", "application/x-www-form-urlencoded"),
    ]
    base_hdrs = _header_map_from_profile(profile_headers, default_header_pairs)

    if client_authn == "basic":
        if not client_secret or not client_secret.strip():
            raise TokmintError(
                500,
                "INTERNAL_ERROR",
                "client_secret is required for basic client authentication.",
            )
        raw = f"{client_id}:{client_secret}".encode("utf-8")
        basic = base64.b64encode(raw).decode("ascii")
        base_hdrs["Authorization"] = f"Basic {basic}"
    elif client_authn == "body":
        if not client_secret or not client_secret.strip():
            raise TokmintError(
                500,
                "INTERNAL_ERROR",
                "client_secret is required for body client authentication.",
            )
        base_form["client_id"] = client_id
        base_form["client_secret"] = client_secret
    else:
        # private_key_jwt: client_id goes in the form; assertion added per
        # attempt so each POST has a fresh jti.
        if client_assertion_factory is None:
            raise TokmintError(
                500,
                "INTERNAL_ERROR",
                "client_assertion_factory is required for private_key_jwt.",
            )
        base_form["client_id"] = client_id.strip()

    def _build_attempt(
        nonce: Optional[str],
    ) -> Tuple[Dict[str, str], str]:
        """Return (headers, body) for one POST attempt."""
        form = dict(base_form)
        if client_authn == "private_key_jwt":
            assert client_assertion_factory is not None
            assertion = client_assertion_factory()
            form.update(client_assertion_form_fields(assertion.strip()))
        hdrs = dict(base_hdrs)
        if dpop_private_key is not None:
            hdrs["DPoP"] = build_dpop_proof_jwt(
                private_key=dpop_private_key,
                http_method="POST",
                http_url=token_url,
                nonce=nonce,
            ).strip()
        return hdrs, _form_encode(form)

    logger.debug("", extra={
        "event": "upstream_request",
        "url": token_url,
        "client_authn": client_authn,
    })

    async def _run(client: httpx.AsyncClient) -> httpx.Response:
        hdrs, body = _build_attempt(None)
        response = await _post_once(client, token_url, hdrs, body)

        if (
            dpop_private_key is not None
            and response.status_code in (400, 401)
            and _upstream_error_code(response) == "use_dpop_nonce"
        ):
            server_nonce = response.headers.get("DPoP-Nonce")
            if server_nonce:
                logger.debug("", extra={
                    "event": "dpop_nonce_retry",
                    "status": response.status_code,
                })
                hdrs, body = _build_attempt(server_nonce)
                response = await _post_once(client, token_url, hdrs, body)

        return response

    owns_client = http_client is None
    if owns_client:
        async with httpx.AsyncClient(
            verify=True,
            timeout=httpx.Timeout(30.0),
        ) as owned:
            response = await _run(owned)
    else:
        assert http_client is not None
        response = await _run(http_client)

    if response.status_code < 200 or response.status_code >= 300:
        logger.debug("", extra={
            "event": "upstream_error",
            "status": response.status_code,
            **_upstream_error_fields(response),
        })
        raise TokmintError(
            502,
            "UPSTREAM_ERROR",
            "Token endpoint returned an error.",
        )

    try:
        payload: Any = response.json()
    except json.JSONDecodeError:
        raise TokmintError(
            502,
            "UPSTREAM_ERROR",
            "Token response was not valid JSON.",
        ) from None

    if not isinstance(payload, dict):
        raise TokmintError(
            502,
            "UPSTREAM_ERROR",
            "Token response JSON was not an object.",
        )

    access = payload.get("access_token")
    ttype = payload.get("token_type")
    if not isinstance(access, str) or not access:
        raise TokmintError(
            502,
            "UPSTREAM_ERROR",
            "Token response missing access_token.",
        )
    if not isinstance(ttype, str) or not ttype:
        raise TokmintError(
            502,
            "UPSTREAM_ERROR",
            "Token response missing token_type.",
        )

    out: Dict[str, Union[str, int]] = {
        "access_token": access,
        "token_type": ttype.strip(),
    }
    exp = payload.get("expires_in")
    if isinstance(exp, (int, float)) and exp >= 0:
        out["expires_in"] = int(exp)
    return out
