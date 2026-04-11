"""
Format a stream of JSON Lines for display or copy-paste.

Each line that parses as JSON is formatted according to the selected
options.  Lines that are not valid JSON (e.g. uvicorn startup messages,
tracebacks) are passed through to stdout in default mode, or wrapped as
{"raw": "..."} entries in array mode so all output is captured.

Usage::

    # Pretty-print each line individually (default)
    python -m tokmint 2>&1 | jsonl-fmt

    # Pretty array, auto-emitted after each burst of log lines
    python -m tokmint 2>&1 | jsonl-fmt -a

    # Compact array — minimal copy-paste into a JSON beautifier
    python -m tokmint 2>&1 | jsonl-fmt -ac

Array flush timeout
-------------------
In -a mode, the buffer is emitted after a quiet period with no new
input.  The timeout defaults to 200 ms and can be overridden via the
TOKMINT_JSONL_FMT_FLUSH_MS environment variable.

Array format
------------
Each entry in the emitted array is a single-key object:
  {"log": { ...structured log object... }}
  {"raw": "unstructured line"}

A separator line is printed after each array to make the block easy to
identify and copy.
"""
import argparse
import json
import os
import select
import sys
from typing import Any, Dict, List

from tokmint.settings import get_jsonl_fmt_flush_ms


def _dumps(obj: Any, compact: bool) -> str:
    if compact:
        return json.dumps(obj, separators=(",", ":"))
    return json.dumps(obj, indent=2)


def _run_streaming(compact: bool) -> None:
    """Pretty-print or compact each JSON line; pass non-JSON through."""
    try:
        for line in sys.stdin:
            stripped = line.rstrip("\r\n")
            if not stripped:
                continue
            try:
                obj = json.loads(stripped)
                print(_dumps(obj, compact))
                if not compact:
                    print()
            except json.JSONDecodeError:
                print(stripped)
    except KeyboardInterrupt:
        pass


def _flush(objects: List[Dict[str, Any]], compact: bool) -> None:
    """
    Emit buffered entries as an array and clear the list.

    Pretty mode: json.dumps with indent=2 naturally places [ and ] on
    their own lines.  Compact mode: [ and ] on their own lines with one
    compact JSON entry per line.  A blank line follows the ] in both
    modes to visually separate successive bursts.
    """
    if compact:
        print("[")
        last = len(objects) - 1
        for i, obj in enumerate(objects):
            suffix = "," if i < last else ""
            print(json.dumps(obj, separators=(",", ":")) + suffix)
        print("]")
    else:
        print(json.dumps(objects, indent=2))
    print()
    objects.clear()


def _run_array(compact: bool) -> None:
    """
    Collect lines and emit a wrapped array after each burst of input.

    A burst ends when no new data arrives within TOKMINT_JSONL_FMT_FLUSH_MS
    milliseconds.  Each entry is wrapped as {"log": ...} for structured
    JSON lines or {"raw": "..."} for unstructured text, so all output is
    captured in the array.

    Reads from the raw file descriptor to avoid Python's internal stdio
    buffering interfering with select() timeouts.
    """
    flush_s = get_jsonl_fmt_flush_ms() / 1000.0
    fd = sys.stdin.fileno()
    objects: List[Dict[str, Any]] = []
    # Accumulates bytes between newlines across os.read() chunks.
    tail = b""
    try:
        while True:
            # Block indefinitely when idle; use flush timeout mid-burst.
            timeout = flush_s if objects else None
            ready, _, _ = select.select([fd], [], [], timeout)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    # EOF
                    break
                lines = (tail + chunk).split(b"\n")
                # Last element is a partial line (or b"" if chunk ended
                # with \n); carry it forward.
                tail = lines[-1]
                for raw_line in lines[:-1]:
                    stripped = raw_line.rstrip(b"\r").decode(
                        "utf-8", errors="replace"
                    )
                    if not stripped:
                        continue
                    try:
                        objects.append({"log": json.loads(stripped)})
                    except json.JSONDecodeError:
                        objects.append({"raw": stripped})
            else:
                # Timeout expired — burst is over, emit the array.
                if objects:
                    _flush(objects, compact)
    except KeyboardInterrupt:
        pass
    # Flush anything remaining (EOF or interrupt mid-burst).
    if tail.strip():
        stripped = tail.rstrip(b"\r\n").decode("utf-8", errors="replace")
        if stripped:
            try:
                objects.append({"log": json.loads(stripped)})
            except json.JSONDecodeError:
                objects.append({"raw": stripped})
    if objects:
        _flush(objects, compact)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="jsonl-fmt",
        description="Format a JSON Lines stream for display or copy-paste.",
    )
    parser.add_argument(
        "-a", "--array",
        action="store_true",
        help=(
            "emit all lines as a wrapped array after each burst of input; "
            "JSON lines become {\"log\": ...}, others become {\"raw\": ...}; "
            "flush timeout configurable via TOKMINT_JSONL_FMT_FLUSH_MS "
            "(default 200 ms)"
        ),
    )
    parser.add_argument(
        "-c", "--compact",
        action="store_true",
        help="minify JSON output (no indentation)",
    )
    args = parser.parse_args()

    if args.array:
        _run_array(args.compact)
    else:
        _run_streaming(args.compact)


if __name__ == "__main__":
    main()
