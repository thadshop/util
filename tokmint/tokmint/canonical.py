"""
ASCII domain canonicalization for domains[].domain matching.

Case-insensitive: canonical form is lowercase. Non-ASCII labels are rejected.
"""


class CanonicalDomainError(ValueError):
    """domain cannot be canonicalized (client or config error)."""


def canonical_domain(raw: str) -> str:
    """
    Return the canonical comparison string for domain matching.

    Strip ASCII whitespace, lowercase, strip a trailing DNS root dot, then
    validate LDH labels (letters, digits, hyphen; hyphen not at label ends).

    Raises CanonicalDomainError when the input is not a valid domain.
    """
    s = raw.strip(" \t\n\r\x0b\x0c")
    if not s:
        raise CanonicalDomainError("empty")
    try:
        s.encode("ascii")
    except UnicodeEncodeError as exc:
        raise CanonicalDomainError("non-ascii") from exc

    s = s.lower()
    while s.endswith("."):
        s = s[:-1]

    if not s or ".." in s:
        raise CanonicalDomainError("invalid domain")

    labels = s.split(".")
    for label in labels:
        if not label or len(label) > 63:
            raise CanonicalDomainError("invalid domain")
        if label[0] == "-" or label[-1] == "-":
            raise CanonicalDomainError("invalid domain")
        for c in label:
            if not (c.isascii() and (c.isalnum() or c == "-")):
                raise CanonicalDomainError("invalid domain")

    return s
