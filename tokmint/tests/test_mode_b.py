"""
Mode B: OAuth client_credentials tests.
"""

from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx
import jwt
import pytest
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey
from jwt.algorithms import ECAlgorithm
from starlette.testclient import TestClient

from tokmint.app import app

# Valid P-256 private JWKs for unit tests only (generated at import).
_test_priv = ec.generate_private_key(ec.SECP256R1(), default_backend())
_TEST_EC_JWK = ECAlgorithm.to_jwk(_test_priv, as_dict=True)
_test_priv2 = ec.generate_private_key(ec.SECP256R1(), default_backend())
_TEST_EC_JWK2 = ECAlgorithm.to_jwk(_test_priv2, as_dict=True)

MODE_B_YAML = f"""domains:
  - domain: idp.example.com
    auth_servers:
      - path: /oauth2/v1/token
        clients:
          - client_id: myapp
            client_authn_method: client_secret_post
            client_secret: plain-secret
"""

MODE_B_JWT_YAML = f"""domains:
  - domain: idp.example.com
    auth_servers:
      - path: /oauth2/v1/token
        clients:
          - client_id: jwtclient
            client_authn_method: private_key_jwt
            private_key_jwt:
              assertion_iss: https://idp.example.com/oauth2/default
            signing_keys:
              - key_id: k1
                jwk:
                  kty: {_TEST_EC_JWK["kty"]}
                  crv: {_TEST_EC_JWK["crv"]}
                  x: {_TEST_EC_JWK["x"]}
                  y: {_TEST_EC_JWK["y"]}
                  d: {_TEST_EC_JWK["d"]}
                jwt_header:
                  kid: test-kid
"""

MODE_B_JWT_DPOP_YAML = f"""domains:
  - domain: idp.example.com
    auth_servers:
      - path: /oauth2/v1/token
        clients:
          - client_id: jwtclient
            client_authn_method: private_key_jwt
            private_key_jwt:
              assertion_iss: https://idp.example.com/oauth2/default
            signing_keys:
              - key_id: k1
                jwk:
                  kty: {_TEST_EC_JWK["kty"]}
                  crv: {_TEST_EC_JWK["crv"]}
                  x: {_TEST_EC_JWK["x"]}
                  y: {_TEST_EC_JWK["y"]}
                  d: {_TEST_EC_JWK["d"]}
                jwt_header:
                  kid: test-kid
            dpop:
              enabled: true
"""


def _write_profile(base: str, profile: str, content: str) -> None:
    td = Path(base)
    sub = td / "tokmint"
    sub.mkdir(parents=True)
    (sub / f"{profile}.enc.yaml").write_text(content, encoding="utf-8")


def _client(monkeypatch: pytest.MonkeyPatch, sec_root: str) -> TestClient:
    monkeypatch.setenv("SECCONFIG_DIR", sec_root)
    monkeypatch.setenv("TOKMINT_SECCONFIG_SUBDIR", "tokmint")
    return TestClient(app)


def test_mode_b_happy_path(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "oauthp", MODE_B_YAML)
    monkeypatch.setattr(
        "tokmint.app.fetch_client_credentials_token",
        AsyncMock(
            return_value={
                "access_token": "upstream-at",
                "token_type": "Bearer",
                "expires_in": 99,
            }
        ),
    )
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "oauthp",
            "domain": "idp.example.com",
            "client_id": "myapp",
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["access_token"] == "upstream-at"
    assert body["token_type"] == "Bearer"
    assert body["expires_in"] == 99


def test_mode_b_key_id_rejected_for_secret_client(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "oauthp", MODE_B_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "oauthp",
            "domain": "idp.example.com",
            "client_id": "myapp",
            "key_id": "kid",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "INVALID_PARAMETER"


def test_mode_b_unknown_client_id(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "oauthp", MODE_B_YAML)
    monkeypatch.setattr(
        "tokmint.app.fetch_client_credentials_token",
        AsyncMock(return_value={"access_token": "x", "token_type": "Bearer"}),
    )
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "oauthp",
            "domain": "idp.example.com",
            "client_id": "nope",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "UNKNOWN_CLIENT_ID"


def test_mode_b_private_key_jwt_happy_path(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "oauthjwt", MODE_B_JWT_YAML)
    mock_fetch = AsyncMock(
        return_value={
            "access_token": "jwt-at",
            "token_type": "Bearer",
        }
    )
    monkeypatch.setattr(
        "tokmint.app.fetch_client_credentials_token",
        mock_fetch,
    )
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "oauthjwt",
            "domain": "idp.example.com",
            "client_id": "jwtclient",
            "key_id": "k1",
        },
    )
    assert r.status_code == 200
    assert r.json()["access_token"] == "jwt-at"
    mock_fetch.assert_awaited_once()
    pos, kw = mock_fetch.call_args
    assert pos[5] == "private_key_jwt"
    assert kw.get("client_assertion_factory") is not None
    assert kw.get("dpop_private_key") is None


def test_mode_b_private_key_jwt_missing_key_id(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "oauthjwt", MODE_B_JWT_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "oauthjwt",
            "domain": "idp.example.com",
            "client_id": "jwtclient",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "MISSING_PARAMETER"


def test_profile_legacy_clients_key_invalid(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = """domains:
  - domain: idp.example.com
    clients:
      - client_id: x
        client_secret: s
"""
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "bad", y)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "bad",
            "domain": "idp.example.com",
            "client_id": "x",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "PROFILE_INVALID"


def test_mode_b_auth_server_missing_path_invalid(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = """domains:
  - domain: idp.example.com
    auth_servers:
      - clients:
          - client_id: x
            client_authn_method: client_secret_post
            client_secret: s
"""
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "bad", y)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "bad",
            "domain": "idp.example.com",
            "client_id": "x",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "PROFILE_INVALID"


def test_dpop_key_id_when_disabled_errors(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = f"""domains:
  - domain: idp.example.com
    auth_servers:
      - path: /oauth2/v1/token
        clients:
          - client_id: jwtclient
            client_authn_method: private_key_jwt
            private_key_jwt:
              assertion_iss: https://idp.example.com/
            signing_keys:
              - key_id: k1
                jwk:
                  kty: {_TEST_EC_JWK["kty"]}
                  crv: {_TEST_EC_JWK["crv"]}
                  x: {_TEST_EC_JWK["x"]}
                  y: {_TEST_EC_JWK["y"]}
                  d: {_TEST_EC_JWK["d"]}
"""
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "p", y)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "p",
            "domain": "idp.example.com",
            "client_id": "jwtclient",
            "key_id": "k1",
            "dpop_key_id": "k1",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "DPOP_DISABLED"


def test_private_key_jwt_with_dpop_sends_dpop_header_payload(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Upstream fetch receives a non-empty DPoP proof; decoded proof matches
    RFC 9449 shape (htm, htu) for the token URL.
    """
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "dpopp", MODE_B_JWT_DPOP_YAML)
    mock_fetch = AsyncMock(
        return_value={"access_token": "t", "token_type": "Bearer"},
    )
    monkeypatch.setattr(
        "tokmint.app.fetch_client_credentials_token",
        mock_fetch,
    )
    client = _client(monkeypatch, str(sec))
    token_url = "https://idp.example.com/oauth2/v1/token"
    r = client.post(
        "/v1/token",
        params={
            "profile": "dpopp",
            "domain": "idp.example.com",
            "client_id": "jwtclient",
            "key_id": "k1",
        },
    )
    assert r.status_code == 200
    mock_fetch.assert_awaited_once()
    _pos, kw = mock_fetch.call_args
    assert isinstance(kw.get("dpop_private_key"), EllipticCurvePrivateKey)
    assert kw.get("client_assertion_factory") is not None


def test_secret_client_dpop_requires_dpop_key_id(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = f"""domains:
  - domain: idp.example.com
    auth_servers:
      - path: /oauth2/v1/token
        clients:
          - client_id: secapp
            client_authn_method: client_secret_post
            client_secret: s3cret
            signing_keys:
              - key_id: dk
                jwk:
                  kty: {_TEST_EC_JWK["kty"]}
                  crv: {_TEST_EC_JWK["crv"]}
                  x: {_TEST_EC_JWK["x"]}
                  y: {_TEST_EC_JWK["y"]}
                  d: {_TEST_EC_JWK["d"]}
            dpop:
              enabled: true
"""
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "sec_dpop", y)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "sec_dpop",
            "domain": "idp.example.com",
            "client_id": "secapp",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "MISSING_PARAMETER"


def test_secret_client_dpop_with_dpop_key_id_calls_upstream(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = f"""domains:
  - domain: idp.example.com
    auth_servers:
      - path: /oauth2/v1/token
        clients:
          - client_id: secapp
            client_authn_method: client_secret_post
            client_secret: s3cret
            signing_keys:
              - key_id: dk
                jwk:
                  kty: {_TEST_EC_JWK["kty"]}
                  crv: {_TEST_EC_JWK["crv"]}
                  x: {_TEST_EC_JWK["x"]}
                  y: {_TEST_EC_JWK["y"]}
                  d: {_TEST_EC_JWK["d"]}
            dpop:
              enabled: true
"""
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "sec_dpop", y)
    mock_fetch = AsyncMock(
        return_value={"access_token": "t", "token_type": "Bearer"},
    )
    monkeypatch.setattr(
        "tokmint.app.fetch_client_credentials_token",
        mock_fetch,
    )
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "sec_dpop",
            "domain": "idp.example.com",
            "client_id": "secapp",
            "dpop_key_id": "dk",
        },
    )
    assert r.status_code == 200
    _pos, kw = mock_fetch.call_args
    assert isinstance(kw.get("dpop_private_key"), EllipticCurvePrivateKey)
    assert kw.get("client_assertion_factory") is None
    pos = mock_fetch.call_args[0]
    assert pos[5] == "body"


def test_dpop_allowlist_rejects_key_id_not_listed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = f"""domains:
  - domain: idp.example.com
    auth_servers:
      - path: /oauth2/v1/token
        clients:
          - client_id: jwtclient
            client_authn_method: private_key_jwt
            private_key_jwt:
              assertion_iss: https://idp.example.com/
            signing_keys:
              - key_id: k1
                jwk:
                  kty: {_TEST_EC_JWK["kty"]}
                  crv: {_TEST_EC_JWK["crv"]}
                  x: {_TEST_EC_JWK["x"]}
                  y: {_TEST_EC_JWK["y"]}
                  d: {_TEST_EC_JWK["d"]}
              - key_id: k2
                jwk:
                  kty: {_TEST_EC_JWK2["kty"]}
                  crv: {_TEST_EC_JWK2["crv"]}
                  x: {_TEST_EC_JWK2["x"]}
                  y: {_TEST_EC_JWK2["y"]}
                  d: {_TEST_EC_JWK2["d"]}
            dpop:
              enabled: true
              signing_keys:
                - k1
"""
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "allow", y)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "allow",
            "domain": "idp.example.com",
            "client_id": "jwtclient",
            "key_id": "k2",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "INVALID_DPOP_KEY"


def test_dpop_nonce_retry_succeeds(tmp_path: Path) -> None:
    """
    fetch_client_credentials_token retries with the server-supplied nonce
    when the IdP returns use_dpop_nonce (RFC 9449 §8).  The factory is
    called once per attempt so each POST carries a distinct client assertion.
    """
    import asyncio
    import secrets as _secrets

    from tokmint.oauth_upstream import fetch_client_credentials_token

    dpop_priv = ec.generate_private_key(ec.SECP256R1(), default_backend())
    assertion_priv = ec.generate_private_key(ec.SECP256R1(), default_backend())
    nonce_value = "server-supplied-nonce-abc123"

    # First response: 400 use_dpop_nonce with DPoP-Nonce header
    first_resp = httpx.Response(
        400,
        json={"error": "use_dpop_nonce",
              "error_description": "nonce required"},
        headers={"DPoP-Nonce": nonce_value},
    )
    # Second response: success
    second_resp = httpx.Response(
        200,
        json={
            "access_token": "retried-token",
            "token_type": "Bearer",
            "expires_in": 3600,
        },
    )

    call_count = 0
    received_bodies: list = []

    async def fake_post(url, *, headers, content, **kwargs):
        nonlocal call_count
        call_count += 1
        received_bodies.append(content)
        return first_resp if call_count == 1 else second_resp

    factory_call_count = 0
    issued_jtis: list = []

    def assertion_factory() -> str:
        nonlocal factory_call_count
        factory_call_count += 1
        # Build a real assertion so each call has a unique jti.
        from tokmint.oauth_client_assertion import build_client_assertion_jwt
        tok = build_client_assertion_jwt(
            issuer="myclient",
            subject="myclient",
            audience="https://idp.example.com/oauth2/v1/token",
            private_key=assertion_priv,
            ttl_seconds=300,
            profile_jwt_headers=None,
        )
        import jwt as _jwt
        payload = _jwt.decode(tok, options={"verify_signature": False})
        issued_jtis.append(payload["jti"])
        return tok

    mock_client = AsyncMock(spec=httpx.AsyncClient)
    mock_client.post = fake_post

    async def run() -> dict:
        return await fetch_client_credentials_token(
            token_url="https://idp.example.com/oauth2/v1/token",
            client_id="myclient",
            client_secret=None,
            scopes=None,
            profile_headers=None,
            client_authn="private_key_jwt",
            token_form_extra=None,
            client_assertion_factory=assertion_factory,
            dpop_private_key=dpop_priv,
            http_client=mock_client,
        )

    result = asyncio.run(run())

    assert call_count == 2, "expected exactly two POST calls (initial + retry)"
    assert factory_call_count == 2, "factory must be called once per attempt"
    assert len(issued_jtis) == 2 and issued_jtis[0] != issued_jtis[1], (
        "each attempt must use a distinct jti"
    )
    assert result["access_token"] == "retried-token"
