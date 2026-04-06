"""
Phase 1 acceptance tests (P1-01–P1-20 from DESIGN.md).
"""

from pathlib import Path

import pytest
from starlette.testclient import TestClient

from tokmint.app import app

MINIMAL_YAML = """domains:
  - domain: tenant.example.com
    tokens:
      Bearer:
        - token_id: default
          credential: plain-test-secret
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


def test_p1_01_02_happy_path_and_json_shape(
    tmp_path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 200
    data = r.json()
    assert data["access_token"] == "plain-test-secret"
    assert data["token_type"] == "Bearer"


def test_p1_03_missing_profile(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "MISSING_PARAMETER"


def test_p1_04_missing_domain(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={"profile": "test", "token_id": "default"},
    )
    assert r.status_code == 400
    assert r.json()["code"] == "MISSING_PARAMETER"


def test_p1_05_empty_domain(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "",
            "token_id": "default",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "MISSING_PARAMETER"


def test_p1_06_invalid_domain(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "https://tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "INVALID_DOMAIN"


def test_p1_07_secconfig_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("SECCONFIG_DIR", raising=False)
    client = TestClient(app)
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 503
    assert r.json()["code"] == "SERVICE_UNAVAILABLE"


def test_p1_07b_secconfig_dir_path_missing(
    tmp_path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    missing = tmp_path / "does-not-exist"
    monkeypatch.setenv("SECCONFIG_DIR", str(missing))
    monkeypatch.setenv("TOKMINT_SECCONFIG_SUBDIR", "tokmint")
    client = TestClient(app)
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 503
    assert r.json()["code"] == "SERVICE_UNAVAILABLE"


def test_p1_08_unknown_profile(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "nope",
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 404
    assert r.json()["code"] == "UNKNOWN_PROFILE"


def test_p1_09_unknown_domain(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "other.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 404
    assert r.json()["code"] == "UNKNOWN_DOMAIN"


def test_p1_10_unknown_token_id(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "missing",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "UNKNOWN_TOKEN_ID"


def test_p1_11_client_id_set(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
            "client_id": "x",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "INVALID_MODE_COMBINATION"


def test_p1_12_key_id_set(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
            "key_id": "kid",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "KEY_ID_NOT_ALLOWED"


def test_p1_13_token_id_unset(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "MISSING_PARAMETER"


def test_p1_14_wrong_method(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", MINIMAL_YAML)
    client = _client(monkeypatch, str(sec))
    r = client.get(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 405
    assert r.json()["code"] == "METHOD_NOT_ALLOWED"


def test_p1_15_unknown_path(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    client = _client(monkeypatch, str(sec))
    r = client.post("/v1/nope")
    assert r.status_code == 404
    assert r.json()["code"] == "NOT_FOUND"


def test_p1_16_error_body_shape(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={"profile": "test"},
    )
    assert r.status_code == 400
    body = r.json()
    assert set(body.keys()) == {"code", "detail"}
    assert isinstance(body["code"], str)
    assert isinstance(body["detail"], str)


def test_p1_17_duplicate_domain(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    bad = """domains:
  - domain: x.example.com
    tokens:
      Bearer:
        - token_id: a
          credential: "1"
  - domain: X.example.com
    tokens:
      Bearer:
        - token_id: b
          credential: "2"
"""
    _write_profile(str(sec), "test", bad)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "x.example.com",
            "token_id": "a",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "PROFILE_INVALID"


def test_p1_18_duplicate_token_id(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    bad = """domains:
  - domain: tenant.example.com
    tokens:
      Bearer:
        - token_id: dup
          credential: "1"
        - token_id: dup
          credential: "2"
"""
    _write_profile(str(sec), "test", bad)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "dup",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "PROFILE_INVALID"


def test_duplicate_token_id_across_auth_schemes(
    tmp_path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    bad = """domains:
  - domain: tenant.example.com
    tokens:
      SSWS:
        - token_id: same
          credential: "1"
      Bearer:
        - token_id: same
          credential: "2"
"""
    _write_profile(str(sec), "test", bad)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "same",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "PROFILE_INVALID"


def test_p1_19_missing_domains(tmp_path, monkeypatch: pytest.MonkeyPatch) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", "{}")
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 400
    assert r.json()["code"] == "PROFILE_INVALID"


def test_p1_20_case_insensitive_match(
    tmp_path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sec = tmp_path / "sec"
    sec.mkdir()
    y = """domains:
  - domain: TENANT.example.com
    tokens:
      Bearer:
        - token_id: default
          credential: secret
"""
    _write_profile(str(sec), "test", y)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["access_token"] == "secret"
    assert body["token_type"] == "Bearer"


def test_mode_a_auth_scheme_ssws_in_profile(
    tmp_path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    y = """domains:
  - domain: tenant.example.com
    tokens:
      SSWS:
        - token_id: default
          credential: ssws-test-secret
"""
    sec = tmp_path / "sec"
    sec.mkdir()
    _write_profile(str(sec), "test", y)
    client = _client(monkeypatch, str(sec))
    r = client.post(
        "/v1/token",
        params={
            "profile": "test",
            "domain": "tenant.example.com",
            "token_id": "default",
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["access_token"] == "ssws-test-secret"
    assert body["token_type"] == "SSWS"
