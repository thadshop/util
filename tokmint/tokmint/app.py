"""
FastAPI application: POST /v1/token (Mode A static; Mode B client credentials).
"""

import logging
from typing import Any, Optional, Union

from fastapi import FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from tokmint.canonical import CanonicalDomainError, canonical_domain
from tokmint.dpop import build_dpop_proof_jwt
from tokmint.errors import TokmintError, error_json_response
from tokmint.oauth_client_assertion import build_client_assertion_jwt
from tokmint.oauth_common import build_token_url
from tokmint.oauth_keys import load_private_key_from_signing_key_row
from tokmint.oauth_upstream import fetch_client_credentials_token
from tokmint.profile_load import (
    find_auth_server_and_client,
    find_signing_key_row,
    find_static_token,
    load_profile,
    require_resolved_seconfig_dir,
)
from tokmint.settings import get_secconfig_subdir
from tokmint.validators import is_safe_config_segment

logger = logging.getLogger(__name__)


def _tokmint_error_log_event(
    request: Request,
    exc: TokmintError,
) -> dict[str, Any]:
    # One JSON line per error for grep/journald; omit client_id (sensitivity).
    q = request.query_params
    event: dict[str, Any] = {
        "event": "tokmint_error",
        "code": exc.code,
        "http_status": exc.status_code,
        "detail": exc.detail,
        "method": request.method,
        "path": request.url.path,
    }
    if q.get("profile") is not None:
        event["profile"] = q.get("profile")
    if q.get("domain") is not None:
        event["domain"] = q.get("domain")
    return event


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


def _dpop_enabled(client_row: dict) -> bool:
    dpop = client_row.get("dpop")
    return isinstance(dpop, dict) and dpop.get("enabled") is True


def _dpop_allowlist(client_row: dict) -> Optional[list[str]]:
    dpop = client_row.get("dpop")
    if not isinstance(dpop, dict):
        return None
    allow = dpop.get("signing_keys")
    if not isinstance(allow, list) or len(allow) < 1:
        return None
    out = []
    for x in allow:
        if isinstance(x, str) and x.strip():
            out.append(x.strip())
    return out if out else None


def _ensure_dpop_key_allowed(
    client_row: dict,
    effective_kid: str,
) -> None:
    allow = _dpop_allowlist(client_row)
    if allow is not None and effective_kid not in allow:
        raise TokmintError(
            400,
            "INVALID_DPOP_KEY",
            "DPoP key_id is not in the client dpop.signing_keys allowlist.",
        )


def _resolve_dpop_key_id(
    client_row: dict,
    method: str,
    key_id_param: Optional[str],
    dpop_key_id_param: Optional[str],
) -> str:
    if dpop_key_id_param is not None:
        kid = dpop_key_id_param.strip()
        if not kid:
            raise TokmintError(
                400,
                "INVALID_PARAMETER",
                "dpop_key_id must be non-empty when provided.",
            )
        _ensure_dpop_key_allowed(client_row, kid)
        return kid
    if method == "private_key_jwt":
        if not key_id_param or not key_id_param.strip():
            raise TokmintError(
                400,
                "MISSING_PARAMETER",
                "key_id is required for private_key_jwt.",
            )
        kid = key_id_param.strip()
        _ensure_dpop_key_allowed(client_row, kid)
        return kid
    raise TokmintError(
        400,
        "MISSING_PARAMETER",
        "dpop_key_id is required when using client secret authentication "
        "with DPoP.",
    )


app = FastAPI(title="tokmint", version="0.1.0")


@app.exception_handler(TokmintError)
async def tokmint_error_handler(
    request: Request,
    exc: TokmintError,
) -> JSONResponse:
    event = _tokmint_error_log_event(request, exc)
    if exc.status_code >= 500:
        logger.error("", extra=event)
    else:
        logger.warning("", extra=event)
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


def _upstream_client_authn(method: str) -> str:
    if method == "client_secret_post":
        return "body"
    if method == "client_secret_basic":
        return "basic"
    if method == "private_key_jwt":
        return "private_key_jwt"
    raise TokmintError(
        500,
        "INTERNAL_ERROR",
        "Unknown client authentication method.",
    )


@app.post("/v1/token")
async def mint_token(
    profile: Optional[str] = Query(None),
    domain: Optional[str] = Query(None),
    token_id: Optional[str] = Query(None),
    client_id: Optional[str] = Query(None),
    key_id: Optional[str] = Query(None),
    dpop_key_id: Optional[str] = Query(None),
    dpop_htm: Optional[str] = Query(None),
    dpop_htu: Optional[str] = Query(None),
) -> dict[str, Union[str, int]]:
    """
    Mode A: static token. Mode B: OAuth client_credentials.

    dpop_htm / dpop_htu: when provided and the upstream token_type is DPoP,
    a fresh DPoP proof for the caller's actual API request is built and
    returned as ``dpop_proof`` in the response body.  The Postman pre-request
    script passes these automatically.
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
            "UNSUPPORTED_PROFILE_NAME",
            "profile query value must be one filename-safe segment: "
            "ASCII letters, digits, underscore, and hyphen only.",
        )

    subdir = get_secconfig_subdir()
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
    dkid = _query_value(dpop_key_id)

    if cid is not None and tid is not None:
        raise TokmintError(
            400,
            "INVALID_MODE_COMBINATION",
            "token_id must be unset when client_id is set.",
        )

    if cid is not None:
        pdata = load_profile(prof, subdir)
        auth_server, client_row = find_auth_server_and_client(
            pdata,
            canon_req,
            cid,
        )

        if dkid is not None and not _dpop_enabled(client_row):
            raise TokmintError(
                400,
                "DPOP_DISABLED",
                "DPoP is disabled for this client in the profile.",
            )

        method_raw = client_row.get("client_authn_method")
        if not isinstance(method_raw, str):
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Invalid profile: client authentication method is missing "
                "or not a string (client_authn_method).",
            )
        method = method_raw.strip()

        path_raw = auth_server.get("path")
        if not isinstance(path_raw, str):
            raise TokmintError(
                400,
                "PROFILE_INVALID",
                "Invalid profile: auth server path missing.",
            )
        token_url = build_token_url(canon_req, path_raw)

        extra = auth_server.get("form_extra")
        extra_map: Optional[dict[str, str]] = None
        if isinstance(extra, dict):
            extra_map = {str(k): str(v) for k, v in extra.items()}

        scopes_opt = client_row.get("scopes")
        scopes_str = (
            scopes_opt.strip()
            if isinstance(scopes_opt, str) and scopes_opt.strip()
            else None
        )

        seconfig_base = require_resolved_seconfig_dir()
        assertion_factory: Optional[object] = None
        secret_str: Optional[str] = None
        dpop_priv = None

        if method == "private_key_jwt":
            if kid is None:
                raise TokmintError(
                    400,
                    "MISSING_PARAMETER",
                    "key_id is required for private_key_jwt.",
                )
            sk_row = find_signing_key_row(client_row, kid)
            pk_cfg = client_row.get("private_key_jwt")
            if not isinstance(pk_cfg, dict):
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Invalid profile: private_key_jwt block missing.",
                )
            iss = pk_cfg.get("assertion_iss")
            if not isinstance(iss, str) or not iss.strip():
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Invalid profile: private_key_jwt.assertion_iss invalid.",
                )
            subject = pk_cfg.get("assertion_sub")
            if isinstance(subject, str) and subject.strip():
                sub_s = subject.strip()
            else:
                sub_s = cid.strip()
            aud_raw = pk_cfg.get("assertion_aud")
            audience = (
                aud_raw.strip()
                if isinstance(aud_raw, str) and aud_raw.strip()
                else token_url
            )
            ttl = pk_cfg.get("assertion_ttl_seconds", 300)
            ttl_i = ttl if isinstance(ttl, int) else 300
            priv = load_private_key_from_signing_key_row(sk_row, seconfig_base)
            jwt_hdr = sk_row.get("jwt_header")
            _iss = iss.strip()
            _sub = sub_s
            _aud = audience
            _priv = priv
            _ttl = ttl_i
            _hdr = jwt_hdr

            def assertion_factory(
                _i=_iss,
                _s=_sub,
                _a=_aud,
                _p=_priv,
                _t=_ttl,
                _h=_hdr,
            ) -> str:
                return build_client_assertion_jwt(
                    issuer=_i,
                    subject=_s,
                    audience=_a,
                    private_key=_p,
                    ttl_seconds=_t,
                    profile_jwt_headers=_h,
                )

            sec_for_upstream: Optional[str] = None
        else:
            if kid is not None:
                raise TokmintError(
                    400,
                    "INVALID_PARAMETER",
                    "key_id must be unset for client secret authentication.",
                )
            raw_sec = client_row.get("client_secret")
            if not isinstance(raw_sec, str) or not raw_sec.strip():
                raise TokmintError(
                    400,
                    "PROFILE_INVALID",
                    "Invalid profile: client_secret missing.",
                )
            secret_str = raw_sec.strip()
            sec_for_upstream = secret_str

        if _dpop_enabled(client_row):
            eff_dkid = _resolve_dpop_key_id(client_row, method, kid, dkid)
            sk_dpop = find_signing_key_row(client_row, eff_dkid)
            dpop_priv = load_private_key_from_signing_key_row(
                sk_dpop,
                seconfig_base,
            )

        upstream_authn = _upstream_client_authn(method)
        result = await fetch_client_credentials_token(
            token_url,
            cid.strip(),
            sec_for_upstream,
            scopes_str,
            auth_server.get("request_headers"),
            upstream_authn,
            extra_map,
            client_assertion_factory=assertion_factory,
            dpop_private_key=dpop_priv,
        )

        out: dict[str, Union[str, int]] = {
            "access_token": str(result["access_token"]),
            "token_type": str(result["token_type"]),
        }
        if "expires_in" in result:
            out["expires_in"] = int(result["expires_in"])

        # When the caller supplied dpop_htm/dpop_htu and the upstream issued
        # a DPoP-bound token, build a proof for their actual API request so
        # Postman can attach it as the DPoP header without extra round-trips.
        api_htm = _query_value(dpop_htm)
        api_htu = _query_value(dpop_htu)
        if (
            dpop_priv is not None
            and str(out["token_type"]).lower() == "dpop"
            and api_htm is not None
            and api_htu is not None
        ):
            out["dpop_proof"] = build_dpop_proof_jwt(
                private_key=dpop_priv,
                http_method=api_htm,
                http_url=api_htu,
                access_token=str(out["access_token"]),
            )

        log_extra: dict = {
            "event": "token_minted",
            "mode": "B",
            "profile": prof,
            "domain": canon_req,
            "token_type": out["token_type"],
            "dpop_proof_included": "dpop_proof" in out,
        }
        if "expires_in" in out:
            log_extra["expires_in"] = out["expires_in"]
        logger.info("", extra=log_extra)
        return out

    # Mode A
    if not _query_unset(key_id):
        raise TokmintError(
            400,
            "KEY_ID_NOT_ALLOWED",
            "key_id must be unset for static token mode.",
        )
    if dkid is not None:
        raise TokmintError(
            400,
            "INVALID_PARAMETER",
            "dpop_key_id must be unset for static token mode.",
        )

    if tid is None:
        raise TokmintError(
            400,
            "MISSING_PARAMETER",
            "Query parameter token_id is required.",
        )

    pdata = load_profile(prof, subdir)
    auth_scheme, secret = find_static_token(pdata, canon_req, tid)
    logger.info("", extra={
        "event": "token_minted",
        "mode": "A",
        "profile": prof,
        "domain": canon_req,
        "token_type": auth_scheme,
    })
    return {
        "access_token": secret,
        "token_type": auth_scheme,
    }
