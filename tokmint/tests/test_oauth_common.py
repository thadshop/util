"""oauth_common: token URL joining and token_path validation."""

import pytest

from tokmint.errors import TokmintError
from tokmint.oauth_common import build_token_url, validate_token_path


def test_validate_token_path_trims_and_rejects_query() -> None:
    assert validate_token_path("  /oauth2/token  ") == "/oauth2/token"
    with pytest.raises(TokmintError) as ei:
        validate_token_path("/path?x=1")
    assert ei.value.code == "PROFILE_CONFIG_INVALID"


def test_build_token_url_join() -> None:
    u = build_token_url("tenant.okta.com", "/oauth2/default/v1/token")
    assert u == "https://tenant.okta.com/oauth2/default/v1/token"
