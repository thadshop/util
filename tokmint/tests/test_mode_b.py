"""
Mode B: OAuth client_credentials (client secret) tests.
"""

from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from starlette.testclient import TestClient

from tokmint.app import app

MODE_B_YAML = """oauth:
  token_path: /oauth2/v1/token
domains:
  - domain: idp.example.com
    clients:
      - client_id: myapp
        client_secret: plain-secret
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


def test_mode_b_key_id_not_implemented(
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
    assert r.json()["code"] == "NOT_IMPLEMENTED"


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


def test_mode_b_jwt_only_client_rejects_secret_flow(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = """oauth:
  token_path: /oauth2/v1/token
domains:
  - domain: idp.example.com
    clients:
      - client_id: jwt_only
        signing_keys:
          - key_id: k
            encrypted_pem_path: dummy.pem.enc
"""
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "oauthp", y)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "oauthp",
            "domain": "idp.example.com",
            "client_id": "jwt_only",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "CLIENT_CONFIG_INVALID"


def test_profile_clients_without_oauth_invalid(
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
    assert r.status_code == 500
    assert r.json()["code"] == "PROFILE_CONFIG_INVALID"


def test_mode_b_missing_oauth_token_path_when_oauth_present(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = """oauth: {}
domains:
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
    assert r.status_code == 500
    assert r.json()["code"] == "PROFILE_CONFIG_INVALID"
