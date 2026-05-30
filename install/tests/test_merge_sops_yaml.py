"""Tests for install.merge_sops_yaml (run from tokmint venv)."""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from merge_sops_yaml import (
    TOKMINT_PATH_REGEXES,
    merge_sops_yaml,
)


@pytest.fixture
def util_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def test_fresh_merge_creates_ordered_rules(
    tmp_path: Path, util_root: Path
) -> None:
    sec = tmp_path / "secconfig"
    changed, _ = merge_sops_yaml(sec, util_root, backup=False)
    assert changed
    doc = yaml.safe_load((sec / ".sops.yaml").read_text(encoding="utf-8"))
    rules = doc["creation_rules"]
    regexes = [r["path_regex"] for r in rules]
    assert regexes[0] == TOKMINT_PATH_REGEXES[0]
    assert regexes[-1] == r".*\.yaml$"
    assert (sec / ".sops.yaml").stat().st_mode & 0o777 == 0o600


def test_merge_idempotent(tmp_path: Path, util_root: Path) -> None:
    sec = tmp_path / "secconfig"
    merge_sops_yaml(sec, util_root, backup=False)
    changed, msg = merge_sops_yaml(sec, util_root, backup=False)
    assert not changed
    assert "already include" in msg


def test_merge_into_secconfig_only(tmp_path: Path, util_root: Path) -> None:
    sec = tmp_path / "secconfig"
    sec.mkdir()
    only = {
        "creation_rules": [
            {
                "path_regex": r".*\.yaml$",
                "encrypted_suffix": "_secrypt",
                "age": "age1testkeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            },
        ],
    }
    (sec / ".sops.yaml").write_text(
        yaml.dump(only, sort_keys=False), encoding="utf-8"
    )
    changed, _ = merge_sops_yaml(sec, util_root, backup=False)
    assert changed
    doc = yaml.safe_load((sec / ".sops.yaml").read_text(encoding="utf-8"))
    regexes = [r["path_regex"] for r in doc["creation_rules"]]
    assert regexes[0] == TOKMINT_PATH_REGEXES[0]
    assert regexes[-1] == r".*\.yaml$"
    assert doc["creation_rules"][0]["age"] == "age1testkeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"


def test_invalid_yaml_aborts(tmp_path: Path, util_root: Path) -> None:
    sec = tmp_path / "secconfig"
    sec.mkdir()
    (sec / ".sops.yaml").write_text("not: [valid\n", encoding="utf-8")
    with pytest.raises(ValueError, match="invalid YAML"):
        merge_sops_yaml(sec, util_root, backup=False)
