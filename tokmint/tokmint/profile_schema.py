"""
Load and apply JSON Schema for tokmint profile YAML (parsed as dict).

Requires optional dependency: jsonschema (see tokmint[dev]).
"""

from __future__ import annotations

import json
from importlib import resources
from typing import Any, Mapping

_PROFILE_SCHEMA_REL = "profile.schema.json"


def load_profile_schema() -> Mapping[str, Any]:
    """Return the profile JSON Schema as a dict."""
    pkg = resources.files("tokmint.schemas")
    raw = pkg.joinpath(_PROFILE_SCHEMA_REL).read_text(encoding="utf-8")
    return json.loads(raw)


def validate_profile_document(data: Any) -> None:
    """
    Validate parsed profile data (e.g. from yaml.safe_load).

    Raises jsonschema.ValidationError on failure; ImportError if jsonschema
    is not installed.
    """
    import jsonschema

    schema = load_profile_schema()
    jsonschema.validate(instance=data, schema=schema)
