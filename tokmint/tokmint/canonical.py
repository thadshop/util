"""
Canonical base_url per DESIGN.md (v1).
"""

from urllib.parse import urlparse, urlunparse


class CanonicalBaseUrlError(ValueError):
    """base_url cannot be canonicalized (client error)."""


def canonical_base_url(url: str) -> str:
    """
    Return the canonical comparison string for base_url matching.

    Raises CanonicalBaseUrlError when the input is not a valid base URL.
    """
    s = url.strip(" \t\n\r\x0b\x0c")
    if not s:
        raise CanonicalBaseUrlError("empty")

    parsed = urlparse(s)
    if not parsed.scheme or not parsed.netloc:
        raise CanonicalBaseUrlError("missing scheme or authority")

    if parsed.username is not None or parsed.password is not None:
        raise CanonicalBaseUrlError("userinfo not allowed")

    if parsed.query or parsed.fragment:
        raise CanonicalBaseUrlError("query or fragment not allowed")

    scheme = parsed.scheme.lower()
    if scheme not in ("http", "https"):
        raise CanonicalBaseUrlError("scheme must be http or https")

    host = parsed.hostname
    if host is None:
        raise CanonicalBaseUrlError("missing host")

    try:
        host_ascii = host.encode("idna").decode("ascii")
    except (UnicodeError, UnicodeDecodeError) as exc:
        raise CanonicalBaseUrlError("invalid host") from exc

    port = parsed.port
    default_port = 443 if scheme == "https" else 80
    if port is None:
        port = default_port

    path = parsed.path or ""
    if path in ("", "/"):
        canon_path = ""
    else:
        if not path.startswith("/"):
            raise CanonicalBaseUrlError("path must be absolute")
        trimmed = path.rstrip("/")
        segments = [x for x in trimmed.split("/") if x]
        if ".." in segments:
            raise CanonicalBaseUrlError("path must not contain ..")
        canon_path = trimmed

    netloc = _format_netloc(host_ascii, port, default_port)
    return urlunparse((scheme, netloc, canon_path, "", "", ""))


def _format_netloc(host: str, port: int, default_port: int) -> str:
    """Build netloc with optional non-default port; bracket IPv6."""
    is_ipv6 = ":" in host and "." not in host
    if is_ipv6:
        host_disp = f"[{host}]"
    else:
        host_disp = host
    if port != default_port:
        return f"{host_disp}:{port}"
    return host_disp
