"""JSON Schema validation for profile YAML shape."""

from pathlib import Path

import pytest
import yaml

from tokmint.profile_schema import load_profile_schema, validate_profile_document

_TOK_BEARER = {
    "Bearer": [
        {"token_id": "default", "credential": "secret"},
    ],
}


def test_schema_loads() -> None:
    schema = load_profile_schema()
    assert schema.get("title") == "tokmint profile"
    assert "domains" in schema.get("required", [])


def test_reference_example_validates() -> None:
    ref = Path(__file__).resolve().parent.parent / "examples" / "profile.reference.yaml"
    data = yaml.safe_load(ref.read_text(encoding="utf-8"))
    validate_profile_document(data)


def test_minimal_phase1_validates() -> None:
    data = {
        "domains": [
            {
                "domain": "tenant.example.com",
                "tokens": _TOK_BEARER,
            }
        ]
    }
    validate_profile_document(data)


def test_tokens_multiple_schemes_validates() -> None:
    data = {
        "domains": [
            {
                "domain": "tenant.example.com",
                "tokens": {
                    "SSWS": [
                        {"token_id": "okta", "credential": "a"},
                    ],
                    "Bearer": [
                        {"token_id": "other", "credential": "b"},
                    ],
                },
            }
        ]
    }
    validate_profile_document(data)


def test_reject_unknown_top_level_key() -> None:
    import jsonschema

    data = {
        "domains": [
            {
                "domain": "tenant.example.com",
                "tokens": _TOK_BEARER,
            }
        ],
        "extra": True,
    }
    with pytest.raises(jsonschema.ValidationError):
        validate_profile_document(data)


def test_reject_tokens_as_list() -> None:
    import jsonschema

    data = {
        "domains": [
            {
                "domain": "tenant.example.com",
                "tokens": [
                    {"token_id": "x", "credential": "y"},
                ],
            }
        ],
    }
    with pytest.raises(jsonschema.ValidationError):
        validate_profile_document(data)


def test_reject_invalid_scheme_as_key() -> None:
    import jsonschema

    data = {
        "domains": [
            {
                "domain": "tenant.example.com",
                "tokens": {
                    "9bad": [
                        {"token_id": "x", "credential": "y"},
                    ],
                },
            }
        ],
    }
    with pytest.raises(jsonschema.ValidationError):
        validate_profile_document(data)


def test_reject_oauth_token_path_without_leading_slash() -> None:
    import jsonschema

    data = {
        "oauth": {"token_path": "oauth2/v1/token"},
        "domains": [
            {
                "domain": "tenant.example.com",
                "tokens": _TOK_BEARER,
            }
        ],
    }
    with pytest.raises(jsonschema.ValidationError):
        validate_profile_document(data)
