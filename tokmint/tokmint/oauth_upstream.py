"""
HTTP client credentials grant to the IdP token endpoint (Mode B, Phase 2a).
"""

from __future__ import annotations

import base64
import json
from typing import Any, Dict, List, Mapping, Optional, Tuple, Union
from urllib.parse import urlencode

import httpx

from tokmint.errors import TokmintError


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


async def fetch_client_credentials_token(
    token_url: str,
    client_id: str,
    client_secret: str,
    scopes: Optional[str],
    profile_headers: Any,
    client_authentication: str,
    token_form_extra: Optional[Mapping[str, str]],
    http_client: Optional[httpx.AsyncClient] = None,
) -> Dict[str, Union[str, int]]:
    """
    POST client_credentials to token_url. Return access_token, token_type,
    and expires_in when present.

    client_authentication: 'body' | 'basic'
    """
    if client_authentication not in ("body", "basic"):
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "Invalid client_authentication mode.",
        )

    form: Dict[str, str] = {"grant_type": "client_credentials"}
    if scopes is not None:
        s = scopes.strip()
        if s:
            form["scope"] = s
    if token_form_extra:
        for fk, fv in token_form_extra.items():
            if fk and str(fv):
                form[str(fk)] = str(fv)

    default_header_pairs: List[Tuple[str, str]] = [
        ("Content-Type", "application/x-www-form-urlencoded"),
    ]
    if client_authentication == "body":
        form["client_id"] = client_id
        form["client_secret"] = client_secret

    hdrs = _header_map_from_profile(profile_headers, default_header_pairs)

    if client_authentication == "basic":
        raw = f"{client_id}:{client_secret}".encode("utf-8")
        basic = base64.b64encode(raw).decode("ascii")
        hdrs["Authorization"] = f"Basic {basic}"

    body = _form_encode(form)
    owns_client = http_client is None
    try:
        if owns_client:
            async with httpx.AsyncClient(
                verify=True,
                timeout=httpx.Timeout(30.0),
            ) as client:
                response = await client.post(
                    token_url,
                    headers=hdrs,
                    content=body,
                )
        else:
            assert http_client is not None
            response = await http_client.post(
                token_url,
                headers=hdrs,
                content=body,
            )
    except httpx.RequestError:
        raise TokmintError(
            502,
            "UPSTREAM_ERROR",
            "Token request failed (network or TLS).",
        ) from None

    if response.status_code < 200 or response.status_code >= 300:
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
