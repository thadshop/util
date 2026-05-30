#!/usr/bin/env python3
"""
Merge util tokmint creation_rules into $SECCONFIG_DIR/.sops.yaml.

See install/README.md for behavior. Requires PyYAML (tokmint venv).
"""

from __future__ import annotations

import argparse
import copy
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

PLACEHOLDER_AGE = "age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY"

TOKMINT_PATH_REGEXES: tuple[str, ...] = (
    r"(^|/)tokmint/.*\.plain\.ya?ml$",
    r"(^|/)tokmint/.*\.enc\.ya?ml$",
    r".*\.ya?ml$",
)

CATCHALL_PATH_REGEXES: frozenset[str] = frozenset(
    {
        r".*\.yaml$",
        r".*\.ya?ml$",
    }
)


def _load_yaml(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    data = yaml.safe_load(text)
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be a mapping")
    return data


def _rules_list(doc: dict[str, Any]) -> list[dict[str, Any]]:
    rules = doc.get("creation_rules")
    if rules is None:
        return []
    if not isinstance(rules, list):
        raise ValueError("creation_rules must be a list")
    out: list[dict[str, Any]] = []
    for i, item in enumerate(rules):
        if not isinstance(item, dict):
            raise ValueError(f"creation_rules[{i}] must be a mapping")
        out.append(item)
    return out


def _path_regex(rule: dict[str, Any]) -> str | None:
    val = rule.get("path_regex")
    if val is None:
        return None
    if not isinstance(val, str):
        raise ValueError("path_regex must be a string")
    return val


def _is_tokmint_specific(path_regex: str) -> bool:
    return "tokmint/" in path_regex or path_regex.startswith(r"(^|/)tokmint/")


def _is_global_catchall(rule: dict[str, Any]) -> bool:
    path_regex = _path_regex(rule)
    if path_regex is None or path_regex not in CATCHALL_PATH_REGEXES:
        return False
    if _is_tokmint_specific(path_regex):
        return False
    return True


def _find_catchall_index(rules: list[dict[str, Any]]) -> int | None:
    for i, rule in enumerate(rules):
        if _is_global_catchall(rule):
            return i
    return None


def _age_from_rules(rules: list[dict[str, Any]]) -> str | None:
    for rule in rules:
        age = rule.get("age")
        if isinstance(age, str) and age and age != PLACEHOLDER_AGE:
            return age
    return None


def _tokmint_template_rules(util_root: Path) -> list[dict[str, Any]]:
    path = util_root / "tokmint/examples/sops.example.dot-sops.yaml"
    doc = _load_yaml(path)
    return _rules_list(doc)


def _secconfig_template_rules(util_root: Path) -> list[dict[str, Any]]:
    path = util_root / "secconfig/examples/SECCONFIG_DIR.sops.yaml.example"
    doc = _load_yaml(path)
    return _rules_list(doc)


def _apply_age(rules: list[dict[str, Any]], age: str | None) -> None:
    if not age:
        return
    for rule in rules:
        if "age" in rule:
            rule["age"] = age


def _missing_tokmint_rules(
    existing: list[dict[str, Any]], template: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    present = {_path_regex(r) for r in existing if _path_regex(r)}
    missing: list[dict[str, Any]] = []
    for rule in template:
        pr = _path_regex(rule)
        if pr is None:
            continue
        if pr in TOKMINT_PATH_REGEXES and pr not in present:
            missing.append(copy.deepcopy(rule))
    return missing


def _build_fresh_rules(
    util_root: Path, age: str | None
) -> list[dict[str, Any]]:
    tokmint = _tokmint_template_rules(util_root)
    secconfig = _secconfig_template_rules(util_root)
    rules = copy.deepcopy(tokmint) + copy.deepcopy(secconfig)
    _apply_age(rules, age)
    return rules


def merge_sops_yaml(
    secconfig_dir: Path,
    util_root: Path,
    *,
    backup: bool = True,
) -> tuple[bool, str]:
    """
    Merge tokmint rules into .sops.yaml.

    Returns (changed, message).
    """
    target = secconfig_dir / ".sops.yaml"
    tokmint_tpl = _tokmint_template_rules(util_root)

    if target.is_file():
        try:
            doc = _load_yaml(target)
        except yaml.YAMLError as exc:
            raise ValueError(f"invalid YAML in {target}: {exc}") from exc
        rules = _rules_list(doc)
        age = _age_from_rules(rules)
        missing = _missing_tokmint_rules(rules, tokmint_tpl)
        if not missing:
            return False, "creation_rules already include tokmint rules"
        _apply_age(missing, age)
        insert_at = _find_catchall_index(rules)
        if insert_at is None:
            insert_at = len(rules)
            msg = (
                "no global catch-all rule found; appended tokmint rules "
                "(review order in .sops.yaml)"
            )
        else:
            msg = "inserted tokmint rules before global catch-all"
        new_rules = rules[:insert_at] + missing + rules[insert_at:]
        doc["creation_rules"] = new_rules
        if backup:
            ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
            backup_path = target.with_name(f".sops.yaml.bak.{ts}")
            backup_path.write_text(
                target.read_text(encoding="utf-8"), encoding="utf-8"
            )
            backup_path.chmod(0o600)
        out_text = yaml.dump(doc, default_flow_style=False, sort_keys=False)
        target.write_text(out_text, encoding="utf-8")
        target.chmod(0o600)
        return True, msg

    secconfig_dir.mkdir(parents=True, exist_ok=True)
    secconfig_dir.chmod(0o700)
    age = None
    rules = _build_fresh_rules(util_root, age)
    doc: dict[str, Any] = {"creation_rules": rules}
    header = (
        "# Created by util install/install.sh — replace age: placeholders\n"
        "# configure after keyring init (get-age-public-key.sh).\n"
    )
    out_text = header + yaml.dump(
        doc, default_flow_style=False, sort_keys=False
    )
    target.write_text(out_text, encoding="utf-8")
    target.chmod(0o600)
    return True, "created new .sops.yaml from util templates"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Merge tokmint sops rules into SECCONFIG_DIR/.sops.yaml",
    )
    parser.add_argument(
        "--secconfig-dir",
        type=Path,
        required=True,
        help="SECCONFIG_DIR (contains or will contain .sops.yaml)",
    )
    parser.add_argument(
        "--util-root",
        type=Path,
        required=True,
        help="Path to util repository root",
    )
    parser.add_argument(
        "--no-backup",
        action="store_true",
        help="Do not write .sops.yaml.bak.* before updating",
    )
    args = parser.parse_args()
    secconfig_dir = args.secconfig_dir.resolve()
    util_root = args.util_root.resolve()
    if not util_root.is_dir():
        print(f"util-root not a directory: {util_root}", file=sys.stderr)
        return 1
    try:
        changed, msg = merge_sops_yaml(
            secconfig_dir,
            util_root,
            backup=not args.no_backup,
        )
    except ValueError as exc:
        print(f"merge_sops_yaml: {exc}", file=sys.stderr)
        return 1
    print(msg)
    if changed:
        print(f"updated: {secconfig_dir / '.sops.yaml'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
