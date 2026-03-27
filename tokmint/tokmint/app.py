"""
FastAPI application: POST /v1/token (Phase 1, Mode A).
"""

from typing import Optional

from fastapi import FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from tokmint.canonical import CanonicalBaseUrlError, canonical_base_url
from tokmint.errors import TokmintError, error_json_response
from tokmint.profile_load import (
    find_token_value,
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
    base_url: Optional[str] = Query(None),
    token_id: Optional[str] = Query(None),
    client_id: Optional[str] = Query(None),
    key_id: Optional[str] = Query(None),
) -> dict[str, str]:
    """
    Phase 1: Mode A static token only.
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

    bu_raw = _query_value(base_url)
    if bu_raw is None:
        raise TokmintError(
            400,
            "MISSING_PARAMETER",
            "Query parameter base_url is required.",
        )

    try:
        canon_req = canonical_base_url(bu_raw)
    except CanonicalBaseUrlError:
        raise TokmintError(
            400,
            "INVALID_BASE_URL",
            "base_url failed canonicalization.",
        ) from None

    if not _query_unset(client_id):
        raise TokmintError(
            400,
            "INVALID_MODE_COMBINATION",
            "client_id must be unset for static token mode.",
        )

    if not _query_unset(key_id):
        raise TokmintError(
            400,
            "KEY_ID_NOT_ALLOWED",
            "key_id must be unset for static token mode.",
        )

    tid = _query_value(token_id)
    if tid is None:
        raise TokmintError(
            400,
            "MISSING_PARAMETER",
            "Query parameter token_id is required.",
        )

    pdata = load_profile(prof, subdir)
    secret = find_token_value(pdata, canon_req, tid)
    return {
        "access_token": secret,
        "token_type": "Bearer",
    }
