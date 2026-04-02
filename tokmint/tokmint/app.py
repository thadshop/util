"""
FastAPI application: POST /v1/token (Mode A static; Mode B client credentials).
"""

from typing import Optional, Union

from fastapi import FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from tokmint.canonical import CanonicalDomainError, canonical_domain
from tokmint.errors import TokmintError, error_json_response
from tokmint.oauth_common import build_token_url
from tokmint.oauth_upstream import fetch_client_credentials_token
from tokmint.profile_load import (
    find_oauth_client,
    find_static_token,
    load_profile,
    require_resolved_seconfig_dir,
)
from tokmint.settings import get_seconfig_subdir
from tokmint.validators import is_safe_config_segment


def _query_unset(raw: Optional[str]) -> bool:
    """True if parameter is omitted or empty after ASCII trim."""
    if raw is None:
        return True
    return raw.strip(" \t\n\r\x0b\x0c") == ""


def _query_value(raw: Optional[str]) -> Optional[str]:
    """None if unset; else stripped non-empty string."""
    if raw is None:
        return None
    s = raw.strip(" \t\n\r\x0b\x0c")
    return None if s == "" else s


app = FastAPI(title="tokmint", version="0.1.0")


@app.exception_handler(TokmintError)
async def tokmint_error_handler(
    request: Request,
    exc: TokmintError,
) -> JSONResponse:
    return error_json_response(exc.status_code, exc.code, exc.detail)


@app.exception_handler(RequestValidationError)
async def validation_handler(
    request: Request,
    exc: RequestValidationError,
) -> JSONResponse:
    return error_json_response(
        400,
        "MISSING_PARAMETER",
        "Invalid request parameters.",
    )


@app.exception_handler(StarletteHTTPException)
async def starlette_http_handler(
    request: Request,
    exc: StarletteHTTPException,
) -> JSONResponse:
    if exc.status_code == 404:
        return error_json_response(
            404,
            "NOT_FOUND",
            "Not found.",
        )
    if exc.status_code == 405:
        return error_json_response(
            405,
            "METHOD_NOT_ALLOWED",
            "Method not allowed.",
        )
    detail = str(exc.detail) if exc.detail else "Request error."
    return error_json_response(
        exc.status_code,
        "INTERNAL_ERROR",
        detail,
    )


@app.post("/v1/token")
async def mint_token(
    profile: Optional[str] = Query(None),
    domain: Optional[str] = Query(None),
    token_id: Optional[str] = Query(None),
    client_id: Optional[str] = Query(None),
    key_id: Optional[str] = Query(None),
) -> dict[str, Union[str, int]]:
    """
    Mode A: static token. Mode B: OAuth client_credentials (client secret).
    """
    require_resolved_seconfig_dir()

    prof = _query_value(profile)
    if prof is None:
        raise TokmintError(
            400,
            "MISSING_PARAMETER",
            "Query parameter profile is required.",
        )
    if not is_safe_config_segment(prof):
        raise TokmintError(
            400,
            "INVALID_PROFILE_NAME",
            "Profile name contains invalid characters.",
        )

    subdir = get_seconfig_subdir()
    if not is_safe_config_segment(subdir):
        raise TokmintError(
            500,
            "INTERNAL_ERROR",
            "TOKMINT_SECCONFIG_SUBDIR is invalid.",
        )

    dom_raw = _query_value(domain)
    if dom_raw is None:
        raise TokmintError(
            400,
            "MISSING_PARAMETER",
            "Query parameter domain is required.",
        )

    try:
        canon_req = canonical_domain(dom_raw)
    except CanonicalDomainError:
        raise TokmintError(
            400,
            "INVALID_DOMAIN",
            "domain failed canonicalization.",
        ) from None

    cid = _query_value(client_id)
    tid = _query_value(token_id)
    kid = _query_value(key_id)

    if cid is not None and tid is not None:
        raise TokmintError(
            400,
            "INVALID_MODE_COMBINATION",
            "token_id must be unset when client_id is set.",
        )

    if cid is not None:
        if kid is not None:
            raise TokmintError(
                400,
                "NOT_IMPLEMENTED",
                "private_key_jwt (key_id) is not implemented yet.",
            )

        pdata = load_profile(prof, subdir)
        oauth = pdata.get("oauth")
        if not isinstance(oauth, dict):
            raise TokmintError(
                400,
                "OAUTH_CONFIG_MISSING",
                "Profile has no oauth configuration for token requests.",
            )
        if oauth.get("token_path") is None:
            raise TokmintError(
                400,
                "OAUTH_CONFIG_MISSING",
                "oauth.token_path is missing.",
            )

        client_row = find_oauth_client(pdata, canon_req, cid)
        secret_raw = client_row.get("client_secret")
        if not isinstance(secret_raw, str) or not secret_raw.strip():
            raise TokmintError(
                400,
                "CLIENT_CONFIG_INVALID",
                "client_secret is required for this client (Phase 2a).",
            )

        scopes_opt = client_row.get("scopes")
        scopes_str = (
            scopes_opt.strip()
            if isinstance(scopes_opt, str) and scopes_opt.strip()
            else None
        )

        tp = oauth.get("token_path")
        assert isinstance(tp, str)
        token_url = build_token_url(canon_req, tp)

        cam = oauth.get("client_authentication", "body")
        if cam not in ("body", "basic"):
            cam = "body"

        extra = oauth.get("token_form_extra")
        extra_map: Optional[dict[str, str]] = None
        if isinstance(extra, dict):
            extra_map = {str(k): str(v) for k, v in extra.items()}

        result = await fetch_client_credentials_token(
            token_url,
            cid.strip(),
            secret_raw.strip(),
            scopes_str,
            oauth.get("request_headers"),
            str(cam),
            extra_map,
        )

        out: dict[str, Union[str, int]] = {
            "access_token": str(result["access_token"]),
            "token_type": str(result["token_type"]),
        }
        if "expires_in" in result:
            out["expires_in"] = int(result["expires_in"])
        return out

    # Mode A
    if not _query_unset(key_id):
        raise TokmintError(
            400,
            "KEY_ID_NOT_ALLOWED",
            "key_id must be unset for static token mode.",
        )

    if tid is None:
        raise TokmintError(
            400,
            "MISSING_PARAMETER",
            "Query parameter token_id is required.",
        )

    pdata = load_profile(prof, subdir)
    auth_scheme, secret = find_static_token(pdata, canon_req, tid)
    return {
        "access_token": secret,
        "token_type": auth_scheme,
    }
