"""Tests for TOKMINT_UNSAFE_LOGGING / get_unsafe_logging."""

import pytest

from tokmint.settings import get_unsafe_logging


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("true", True),
        ("True", True),
        ("TRUE", True),
        (" true ", True),
        ("", False),
        ("false", False),
        ("1", False),
        ("yes", False),
    ],
)
def test_get_unsafe_logging_case_insensitive_true(
    monkeypatch: pytest.MonkeyPatch,
    raw: str,
    expected: bool,
) -> None:
    monkeypatch.setenv("TOKMINT_UNSAFE_LOGGING", raw)
    assert get_unsafe_logging() is expected


def test_get_unsafe_logging_unset(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("TOKMINT_UNSAFE_LOGGING", raising=False)
    assert get_unsafe_logging() is False
