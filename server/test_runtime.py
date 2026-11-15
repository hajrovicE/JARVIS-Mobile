"""Deployment boundary tests: synthetic credentials, fake upstream, local sockets only."""
import contextlib
import io
import json
import os
import socket
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from relay import RelayService, Settings, create_server
from relay_runtime import RequestBudget, SafeEventLogger
from test_relay import AUTH, SETTINGS, TOKEN, completed


class RuntimeTests(unittest.TestCase):
    def test_secret_files_and_explicit_expiry(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory, "provider"); key.write_text("synthetic-key\n")
            token = Path(directory, "owner"); token.write_text(TOKEN + "\r\n")
            env = {"OPENAI_API_KEY_FILE": str(key), "APP_ACCESS_TOKEN_FILE": str(token),
                   "APP_ACCESS_TOKEN_EXPIRES_AT": "2000000000", "RELAY_REQUIRE_EXPLICIT_EXPIRY": "true"}
            with patch.dict(os.environ, env, clear=True):
                settings = Settings.from_environment(now=1)
            self.assertTrue(settings.configured())
            self.assertEqual(settings.api_key, "synthetic-key")
            self.assertEqual(settings.access_token, TOKEN)
            self.assertNotIn(TOKEN, repr(settings))
            self.assertNotIn("synthetic-key", repr(settings))

    def test_ambiguous_unreadable_oversized_or_control_secrets_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory, "secret")
            valid = {"OPENAI_API_KEY": "synthetic-key", "APP_ACCESS_TOKEN": TOKEN,
                     "APP_ACCESS_TOKEN_EXPIRES_AT": "2000000000"}
            file.write_text("file-key")
            cases = [{**valid, "OPENAI_API_KEY_FILE": str(file)},
                     {**valid, "OPENAI_API_KEY": "", "OPENAI_API_KEY_FILE": str(file) + "-missing"},
                     {**valid, "APP_ACCESS_TOKEN": "x\n" + TOKEN},
                     {**valid, "OPENAI_API_KEY": "synthetic\r\nkey"}]
            for env in cases:
                with self.subTest(case=list(env)):
                    with patch.dict(os.environ, env, clear=True):
                        self.assertFalse(Settings.from_environment().configured())
            for data in [b"x" * 8193, b"synthetic\x00key", b"synthetic-key\n\n", b"\xff"]:
                file.write_bytes(data)
                with patch.dict(os.environ, {**valid, "OPENAI_API_KEY": "", "OPENAI_API_KEY_FILE": str(file)}, clear=True):
                    self.assertFalse(Settings.from_environment().configured())

    def test_production_expiry_and_limit_config_fail_closed(self):
        base = {"OPENAI_API_KEY": "synthetic-key", "APP_ACCESS_TOKEN": TOKEN}
        for extra in [{"RELAY_REQUIRE_EXPLICIT_EXPIRY": "true"},
                      {"RELAY_REQUIRE_EXPLICIT_EXPIRY": "unknown"},
                      {"APP_ACCESS_TOKEN_EXPIRES_AT": "NaN"},
                      {"RELAY_REQUESTS_PER_MINUTE": "0"},
                      {"RELAY_REQUESTS_PER_DAY": "10001"},
                      {"RELAY_MAX_CONCURRENT": "5"},
                      {"RELAY_REQUESTS_PER_MINUTE": "not-an-integer"}]:
            with patch.dict(os.environ, {**base, **extra}, clear=True):
                self.assertFalse(Settings.from_environment(now=1).configured())
        # Local development compatibility is retained; production disables this default.
        with patch.dict(os.environ, base, clear=True):
            self.assertEqual(Settings.from_environment(now=1).access_token_expires_at, 28801)

    def test_minute_and_day_windows_exact_boundaries(self):
        clock = [0.0]
        budget = RequestBudget(2, 3, lambda: clock[0])
        self.assertTrue(budget.admit()); self.assertTrue(budget.admit()); self.assertFalse(budget.admit())
        clock[0] = 59.999; self.assertFalse(budget.admit())
        clock[0] = 60; self.assertTrue(budget.admit()); self.assertFalse(budget.admit())
        clock[0] = 86399.999; self.assertFalse(budget.admit())
        clock[0] = 86400; self.assertTrue(budget.admit()); self.assertTrue(budget.admit())
        clock[0] = 0; self.assertFalse(budget.admit(), "Clock rollback must not reset the window")

    def test_budget_is_atomic_across_threads(self):
        budget = RequestBudget(3, 3, lambda: 1)
        accepted = []; lock = threading.Lock()
        def attempt():
            result = budget.admit()
            with lock: accepted.append(result)
        threads = [threading.Thread(target=attempt) for _ in range(30)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=2)
        self.assertEqual(sum(accepted), 3)

    def test_failed_attempts_count_but_unauthorized_and_invalid_do_not(self):
        calls = []
        def failure(*_):
            calls.append(1); raise RuntimeError("private-provider-detail")
        settings = replace(SETTINGS, requests_per_minute=1)
        service = RelayService(settings, failure, clock=lambda: 1)
        self.assertEqual(service.reply({"prompt": "a"}, None, now=1)[0], 401)
        self.assertEqual(service.reply({}, AUTH, now=1)[0], 400)
        self.assertEqual(service.reply({"prompt": "a"}, AUTH, now=1), (502, {"error": "provider_unavailable"}))
        self.assertEqual(service.reply({"prompt": "a"}, AUTH, now=1), (429, {"error": "rate_limited"}))
        self.assertEqual(len(calls), 1)

    def test_concurrency_limit_and_recovery(self):
        entered = threading.Event(); release = threading.Event()
        def slow(*_):
            entered.set(); release.wait(timeout=3); return completed()
        service = RelayService(replace(SETTINGS, max_concurrent=1), slow)
        results = []
        first = threading.Thread(target=lambda: results.append(service.reply({"prompt": "a"}, AUTH, now=1)))
        first.start()
        try:
            self.assertTrue(entered.wait(timeout=2))
            self.assertEqual(service.reply({"prompt": "b"}, AUTH, now=1), (429, {"error": "busy"}))
        finally:
            release.set(); first.join(timeout=3)
        self.assertEqual(results[0][0], 200)
        self.assertEqual(service.reply({"prompt": "b"}, AUTH, now=1)[0], 200)

    def test_safe_logger_accepts_only_allowlisted_fields(self):
        output = io.StringIO(); logger = SafeEventLogger(output)
        logger.record("private-prompt", code=TOKEN, status=502, request_id="client-controlled-private-id")
        value = json.loads(output.getvalue())
        self.assertEqual(value["event"], "request_error")
        self.assertEqual(value["code"], "internal_error")
        self.assertNotIn("request_id", value)
        self.assertNotIn(TOKEN, output.getvalue())
        self.assertNotIn("private", output.getvalue())

    @contextlib.contextmanager
    def running_server(self, settings=SETTINGS, upstream=lambda *_: completed(), logger=None):
        server = create_server(RelayService(settings, upstream), ("127.0.0.1", 0), logger=logger)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            yield server
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=3)

    def http(self, server, path="/v1/chat", data=b'{"prompt":"synthetic"}', headers=None):
        request = urllib.request.Request("http://127.0.0.1:" + str(server.server_port) + path,
            data=data, headers=headers if headers is not None else {"Authorization": AUTH, "Content-Type": "application/json"})
        try: response = urllib.request.urlopen(request, timeout=3)
        except urllib.error.HTTPError as error: response = error
        with response:
            return response.status, response.headers, json.load(response)

    def test_liveness_and_readiness_never_probe_provider(self):
        def forbidden(*_): self.fail("Health must not call a provider")
        for settings, ready in [(SETTINGS, True), (Settings(), False), (replace(SETTINGS, access_token_expires_at=1), False)]:
            with self.running_server(settings, forbidden) as server:
                self.assertEqual(self.http(server, "/health/live", data=None)[2], {"alive": True})
                for path in ["/health", "/health/ready"]:
                    status, _, body = self.http(server, path, data=None)
                    self.assertEqual(status, 200 if ready else 503)
                    self.assertEqual(body, {"ready": ready})
                    self.assertNotIn(TOKEN, json.dumps(body))

    def test_forwarded_addresses_cannot_bypass_global_owner_budget(self):
        with self.running_server(replace(SETTINGS, requests_per_minute=1)) as server:
            for index, expected in [(1, 200), (2, 429)]:
                status, headers, _ = self.http(server, headers={"Authorization": AUTH, "Content-Type": "application/json",
                    "X-Forwarded-For": "192.0.2." + str(index)})
                self.assertEqual(status, expected)
                if status == 429: self.assertEqual(headers["Retry-After"], "60")

    def test_duplicate_framing_and_auth_headers_fail_before_upstream(self):
        def forbidden(*_): self.fail("Ambiguous headers must not call provider")
        with self.running_server(upstream=forbidden) as server:
            for extra in ["Authorization: Bearer other\r\n", "Content-Length: 2\r\n", "Content-Type: text/plain\r\n", "Host: other\r\n"]:
                raw = ("POST /v1/chat HTTP/1.1\r\nHost: localhost\r\nAuthorization: " + AUTH + "\r\nContent-Type: application/json\r\nContent-Length: 2\r\n" + extra + "\r\n{}").encode()
                with socket.create_connection(server.server_address, timeout=3) as connection:
                    connection.sendall(raw); response = connection.recv(4096)
                self.assertIn(b"400", response.split(b"\r\n", 1)[0])
            for length in ["+2", "2  ", "-1", "1000000"]:
                raw = ("POST /v1/chat HTTP/1.1\r\nHost: localhost\r\nAuthorization: " + AUTH + "\r\nContent-Type: application/json\r\nContent-Length: " + length + "\r\n\r\n{}").encode()
                with socket.create_connection(server.server_address, timeout=3) as connection:
                    connection.sendall(raw); response = connection.recv(4096)
                self.assertIn(b"413", response.split(b"\r\n", 1)[0])
            # Send framing headers directly: Python 3.15 urllib can hit BrokenPipe
            # when the server rejects chunked transfer before writing a body.
            raw = ("POST /v1/chat HTTP/1.1\r\nHost: localhost\r\nAuthorization: " + AUTH +
                   "\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n").encode()
            with socket.create_connection(server.server_address, timeout=3) as connection:
                connection.sendall(raw)
                response = connection.recv(4096)
            self.assertIn(b"411", response.split(b"\r\n", 1)[0])

    def test_production_logs_omit_input_headers_ip_and_exception_messages(self):
        output = io.StringIO(); logger = SafeEventLogger(output)
        def failure(*_): raise RuntimeError("private-provider-body" + TOKEN)
        with self.running_server(upstream=failure, logger=logger) as server:
            self.assertEqual(self.http(server, data=b'{"prompt":"private-prompt"}')[0], 502)
            self.assertEqual(self.http(server, "/private-url?secret=value", data=None)[0], 404)
            with contextlib.redirect_stderr(output):
                with socket.create_connection(server.server_address, timeout=3) as connection:
                    connection.sendall(b"private-malformed-request\r\n\r\n"); connection.recv(4096)
            # Default server error tracebacks must also be suppressed.
            with contextlib.redirect_stderr(output):
                try: raise RuntimeError("private-internal-detail")
                except RuntimeError: server.handle_error(None, ("private-client-ip", 123))
        text = output.getvalue()
        for secret in ["private-prompt", "private-url", "secret=value", TOKEN, "private-provider-body", "private-internal-detail", "private-client-ip", "Traceback"]:
            self.assertNotIn(secret, text)
        events = [json.loads(line) for line in text.splitlines()]
        self.assertTrue(any(e["code"] == "provider_unavailable" for e in events))
        self.assertTrue(any(e["code"] == "internal_error" for e in events))
        self.assertTrue(all(set(e) <= {"time", "event", "code", "status", "duration_ms", "request_id"} for e in events))


if __name__ == "__main__":
    unittest.main()
