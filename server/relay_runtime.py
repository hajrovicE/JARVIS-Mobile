"""Small deployment guards; never serialize credentials, request text, addresses or exceptions."""
from __future__ import annotations

import json
import math
import os
import re
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path


class ConfigurationError(ValueError):
    pass


def read_secret(name: str, environ) -> str:
    value = environ.get(name, "")
    filename = environ.get(name + "_FILE", "")
    if value and filename:
        raise ConfigurationError("ambiguous_secret")
    if filename:
        try:
            with Path(filename).open("rb") as source:
                data = source.read(8193)
            if len(data) > 8192:
                raise ConfigurationError("invalid_secret")
            value = data.decode("ascii")
            # Secret files commonly end with one newline. Embedded/control data is rejected.
            if value.endswith("\n"):
                value = value[:-1]
                if value.endswith("\r"):
                    value = value[:-1]
        except (OSError, UnicodeError):
            raise ConfigurationError("unreadable_secret") from None
    if value and (len(value) > 8192 or any(ord(c) < 33 or ord(c) > 126 for c in value)):
        raise ConfigurationError("invalid_secret")
    return value


def positive_limit(environ, name: str, default: int, maximum: int, *, allow_zero: bool = False) -> int:
    try:
        value = int(environ.get(name, str(default)))
    except (TypeError, ValueError):
        raise ConfigurationError("invalid_limit") from None
    if not (0 if allow_zero else 1) <= value <= maximum:
        raise ConfigurationError("invalid_limit")
    return value


class RequestBudget:
    """Single-process, single-owner sliding limits; not an account billing cap.

    Deliberately not keyed by a caller-provided address or forwarding header.
    """
    def __init__(self, per_minute: int, per_day: int, clock=time.monotonic):
        self.per_minute, self.per_day, self.clock = per_minute, per_day, clock
        self._minute, self._day = deque(), deque()
        self._lock = threading.Lock()
        self._last = 0.0

    def admit(self) -> bool:
        with self._lock:
            current = float(self.clock())
            if not math.isfinite(current):
                return False
            current = max(self._last, current)
            self._last = current
            for history, seconds in ((self._minute, 60), (self._day, 86400)):
                while history and current - history[0] >= seconds:
                    history.popleft()
            if (self.per_minute and len(self._minute) >= self.per_minute) or (self.per_day and len(self._day) >= self.per_day):
                return False
            # Zero disables an optional quota; avoid storing history when disabled.
            if self.per_minute:
                self._minute.append(current)
            if self.per_day:
                self._day.append(current)
            return True


_SAFE_CODES = frozenset({
    "ok", "not_found", "service_unconfigured", "session_expired", "unauthorized",
    "ambiguous_headers", "content_length_required", "json_required", "invalid_body_size",
    "invalid_json", "invalid_request", "busy", "rate_limited", "provider_unavailable",
    "internal_error", "client_disconnected", "configuration_invalid", "started", "stopped",
})
_SAFE_EVENTS = frozenset({"http_response", "request_error", "server_lifecycle"})


class SafeEventLogger:
    """An allowlist, not best-effort string redaction. No arbitrary messages are accepted."""
    def __init__(self, stream=None):
        self.stream = stream if stream is not None else sys.stderr
        self._lock = threading.Lock()

    def record(self, event: str, *, code: str, status: int = 0,
               request_id: str = "", duration_ms: int = 0):
        fields = {
            "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "event": event if event in _SAFE_EVENTS else "request_error",
            "code": code if code in _SAFE_CODES else "internal_error",
            "status": status if isinstance(status, int) and 0 <= status <= 599 else 0,
            "duration_ms": max(0, min(duration_ms, 86_400_000)) if isinstance(duration_ms, int) else 0,
        }
        if re.fullmatch(r"[a-f0-9]{32}", request_id):
            fields["request_id"] = request_id
        try:
            with self._lock:
                self.stream.write(json.dumps(fields, separators=(",", ":")) + "\n")
                self.stream.flush()
        except (OSError, ValueError):
            # Logging failure cannot expose a traceback containing request state.
            pass
