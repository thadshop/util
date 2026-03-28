"""
HTTP error responses: { "code", "detail" } per DESIGN.md.
"""

from fastapi.responses import JSONResponse


class TokmintError(Exception):
    """Raise for predictable API errors; handled by FastAPI exception handler."""

    def __init__(self, status_code: int, code: str, detail: str) -> None:
        self.status_code = status_code
        self.code = code
        self.detail = detail
        super().__init__(detail)


def error_json_response(status_code: int, code: str, detail: str) -> JSONResponse:
    """Build a JSON error body matching the v1 contract."""
    return JSONResponse(
        status_code=status_code,
        content={"code": code, "detail": detail},
    )
