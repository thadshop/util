"""JSON Schema validation for profile YAML shape."""

from pathlib import Path

import pytest
import yaml

from tokmint.profile_schema import load_profile_schema, validate_profile_document


def test_schema_loads() -> None:
    schema = load_profile_schema()
    assert schema.get("title") == "tokmint profile"
    assert "bases" in schema.get("required", [])


def test_reference_example_validates() -> None:
    ref = Path(__file__).resolve().parent.parent / "examples" / "profile.reference.yaml"
    data = yaml.safe_load(ref.read_text(encoding="utf-8"))
    validate_profile_document(data)


def test_minimal_phase1_validates() -> None:
    data = {
        "bases": [
            {
                "base_url": "https://tenant.example.com",
                "tokens": [
                    {"token_id": "default", "token_value": "secret"},
                ],
            }
        ]
    }
    validate_profile_document(data)


def test_reject_unknown_top_level_key() -> None:
    import jsonschema

    data = {
        "bases": [
            {
                "base_url": "https://tenant.example.com",
                "tokens": [{"token_id": "x", "token_value": "y"}],
            }
        ],
        "extra": True,
    }
    with pytest.raises(jsonschema.ValidationError):
        validate_profile_document(data)


def test_reject_oauth_endpoint_without_leading_slash() -> None:
    import jsonschema

    data = {
        "oauth": {"endpoint": "oauth2/v1/token"},
        "bases": [
            {
                "base_url": "https://tenant.example.com",
                "tokens": [{"token_id": "x", "token_value": "y"}],
            }
        ],
    }
    with pytest.raises(jsonschema.ValidationError):
        validate_profile_document(data)
