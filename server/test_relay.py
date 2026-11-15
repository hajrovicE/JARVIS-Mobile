import contextlib
import io
import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

from relay import (
    MAX_BODY_BYTES, RejectRedirects, RelayService, Settings, UpstreamUnavailable,
    call_openai, create_server, extract_text, validate_request,
)

TOKEN = "synthetic-client-bearer-0123456789abcdef"
SETTINGS = Settings(api_key="synthetic-provider-key", access_token=TOKEN, access_token_expires_at=2_000_000_000)
AUTH = "Bearer " + TOKEN


def completed(text="Merhaba", **extra):
    return {"status": "completed", "model": "gpt-4.1-mini", "output": [
        {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}], **extra}


class RelayTests(unittest.TestCase):
    def test_auth_configuration_expiry_and_no_provider_call(self):
        def unexpected(*_):
            self.fail("Unauthorized request must not call provider")
        service = RelayService(SETTINGS, unexpected)
        self.assertEqual(service.reply({"prompt": "a"}, None, now=1)[0], 401)
        self.assertEqual(service.reply({"prompt": "a"}, "Bearer yanlış", now=1)[0], 401)
        self.assertEqual(service.reply({"prompt": "a"}, AUTH, now=2_000_000_000)[1], {"error": "session_expired"})
        self.assertEqual(RelayService(Settings(), unexpected).reply({"prompt": "a"}, AUTH)[0], 503)
        self.assertNotIn(SETTINGS.api_key, repr(SETTINGS))
        self.assertNotIn(SETTINGS.access_token, repr(SETTINGS))

    def test_real_response_contract_preserves_turkish_context_without_fake_citations(self):
        received = []
        def upstream(settings, value):
            received.append(value)
            return completed("Önce kahveni hazırla, sonra iki adımı tamamla.")
        service = RelayService(SETTINGS, upstream)
        request = {"prompt": "İki adımlı plan yap.", "context": [{"id": "tercih-1", "text": "Türk kahvesi severim"}]}
        status, value = service.reply(request, AUTH, now=1)
        self.assertEqual(status, 200)
        self.assertEqual(received, [request])
        self.assertEqual(value["freshness"], "unverified")
        self.assertEqual(value["sources"], [])
        self.assertIsNone(value["expiresAt"])
        self.assertTrue(value["generatedAt"].endswith("Z"))
        self.assertEqual(value["provider"], "openai")

    def test_bad_requests_and_limits(self):
        invalid = [None, {}, {"prompt": " "}, {"prompt": "a" * 8001},
                   {"prompt": "a", "model": "user-selected"}, {"prompt": "a", "context": {}},
                   {"prompt": "a", "context": [{"id": "a", "text": "b", "sensitive": False}]},
                   {"prompt": "a", "context": [{"id": "a", "text": "b"}] * 21},
                   {"prompt": "a", "context": [{"id": "a", "text": "b" * 2001}]}]
        for value in invalid:
            with self.subTest(value_type=type(value).__name__):
                with self.assertRaises(ValueError):
                    validate_request(value)

    def test_upstream_errors_are_sanitized_and_do_not_make_fake_answer(self):
        def unavailable(*_):
            raise UpstreamUnavailable("must-not-leak-provider-details")
        status, result = RelayService(SETTINGS, unavailable).reply({"prompt": "a"}, AUTH, now=1)
        self.assertEqual((status, result), (502, {"error": "provider_unavailable"}))
        for response in [{}, completed(""), completed(status="incomplete"), {"status": "completed", "output": "bad"}]:
            self.assertEqual(RelayService(SETTINGS, lambda *_: response).reply({"prompt": "a"}, AUTH, now=1)[0], 502)

    def test_redirects_are_rejected(self):
        with self.assertRaises(UpstreamUnavailable):
            RejectRedirects().redirect_request(None, None, 302, "redirect", {}, "https://attacker.invalid")

    def test_openai_request_uses_fixed_destination_store_false_and_no_tools(self):
        captured = []
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self, *_): return json.dumps(completed()).encode()
        class Opener:
            def open(self, request, timeout):
                captured.append((request, timeout))
                return Response()
        with patch("urllib.request.build_opener", return_value=Opener()):
            self.assertEqual(extract_text(call_openai(SETTINGS, {"prompt": "Merhaba", "context": []})), "Merhaba")
        request, timeout = captured[0]
        self.assertEqual(request.full_url, "https://api.openai.com/v1/responses")
        self.assertEqual(timeout, 30)
        body = json.loads(request.data)
        self.assertFalse(body["store"])
        self.assertNotIn("tools", body)
        self.assertEqual(body["model"], SETTINGS.model)
        self.assertIn("Türkçe", body["instructions"])

    def test_upstream_network_failure_is_sanitized(self):
        class Opener:
            def open(self, *_args, **_kwargs):
                raise urllib.error.URLError("private-provider-details")
        with patch("urllib.request.build_opener", return_value=Opener()):
            with self.assertRaisesRegex(UpstreamUnavailable, "^provider_failure$"):
                call_openai(SETTINGS, {"prompt": "a", "context": []})

    def test_http_server_auth_json_limits_and_no_sensitive_logs(self):
        server = create_server(RelayService(SETTINGS, lambda *_: completed()), ("127.0.0.1", 0))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:" + str(server.server_address[1])
        logs = io.StringIO()
        def request(data, auth=AUTH, path="/v1/chat", content_type="application/json"):
            headers = {"Content-Type": content_type}
            if auth:
                headers["Authorization"] = auth
            req = urllib.request.Request(base + path, data=data, headers=headers, method="POST")
            try:
                response = urllib.request.urlopen(req, timeout=3)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                return response.status, json.load(response)
        try:
            with contextlib.redirect_stderr(logs):
                self.assertEqual(request(b'{"prompt":"synthetic private prompt"}')[0], 200)
                self.assertEqual(request(b'{"prompt":"a"}', auth=None)[0], 401)
                self.assertEqual(request(b'broken')[0], 400)
                self.assertEqual(request(b'x' * (MAX_BODY_BYTES + 1))[0], 413)
                self.assertEqual(request(b'{}', content_type="text/plain")[0], 415)
                self.assertEqual(request(b'{}', path="/unknown")[0], 404)
            self.assertEqual(logs.getvalue(), "")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
