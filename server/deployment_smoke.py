"""Isolated Docker deployment checks; no public endpoint, paid service, ACME or model calls.

Run explicitly with Docker available: python3 server/deployment_smoke.py
Only synthetic fixtures are used. The HTTPS upstream is a test-only injected adapter.
"""
import json
import os
import ssl
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
IMAGE = "jarvis-relay:deployment-smoke"
TOKEN = "synthetic-owner-token-0123456789abcdefghijklmnopqrstuvwxyz"
KEY = "synthetic-provider-key-not-a-real-credential"


def docker(*args, check=True):
    return subprocess.run(["docker", *args], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=120, check=check)


class DeploymentSmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        docker("info", "--format", "{{.ServerVersion}}")
        docker("build", "--network", "none", "-t", IMAGE, str(ROOT))

    def setUp(self):
        self.prefix = "jarvis-relay-test-" + uuid.uuid4().hex[:12]
        self.containers = []
        self.volumes = []
        self.networks = []
        self.directory = tempfile.TemporaryDirectory(prefix="jarvis-relay-smoke-")
        self.folder = Path(self.directory.name)
        self.keyfile = self.folder / "provider"; self.keyfile.write_text(KEY)
        self.tokenfile = self.folder / "owner"; self.tokenfile.write_text(TOKEN)
        self.caddyfile = self.folder / "Caddyfile"
        self.caddyfile.write_bytes((ROOT / "deploy/Caddyfile").read_bytes())
        # Non-secret config must be readable with DAC_OVERRIDE removed, even if the
        # source checkout uses a restrictive umask. Secret fixtures are separate.
        self.caddyfile.chmod(0o444)
        # Test fixtures only. Real host Secret files require correct UID10001 ownership +0400.
        self.keyfile.chmod(0o444); self.tokenfile.chmod(0o444)
        self.env = {
            **os.environ, "OPENAI_API_KEY_SECRET_FILE": str(self.keyfile),
            "APP_ACCESS_TOKEN_SECRET_FILE": str(self.tokenfile),
            "APP_ACCESS_TOKEN_EXPIRES_AT": str(int(time.time()) + 600),
            "RELAY_HOSTNAME": "localhost", "ACME_EMAIL": "operator@example.invalid",
        }

    def tearDown(self):
        for container in reversed(self.containers): docker("rm", "-f", container, check=False)
        for volume in reversed(self.volumes): docker("volume", "rm", volume, check=False)
        for network in reversed(self.networks): docker("network", "rm", network, check=False)
        self.directory.cleanup()

    def compose(self):
        result = subprocess.run(["docker", "compose", "-f", str(ROOT / "deploy/compose.yaml"), "config", "--format", "json"],
            env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=True)
        return json.loads(result.stdout)

    def container(self, name, *arguments):
        self.containers.append(name)
        return docker("run", "-d", "--name", name, *arguments).stdout.strip()

    def wait(self, operation, timeout=45):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try: return operation()
            except (OSError, ValueError, subprocess.CalledProcessError, ssl.SSLError) as error:
                last = type(error).__name__; time.sleep(0.25)
        self.fail("Local deployment did not become ready: " + str(last))

    def test_real_entrypoint_private_secrets_health_and_no_key_in_image(self):
        config = self.compose()
        self.assertNotIn("ports", config["services"]["relay"])
        self.assertEqual(config["services"]["relay"]["user"], "10001:10001")
        self.assertTrue(config["services"]["relay"]["read_only"])
        image_config = json.loads(docker("image", "inspect", IMAGE).stdout)[0]["Config"]
        self.assertEqual(image_config["User"], "10001:10001")
        image_env = "\n".join(image_config["Env"])
        self.assertNotIn("OPENAI_API_KEY=", image_env)
        self.assertNotIn("APP_ACCESS_TOKEN=", image_env)
        name = self.prefix + "-entrypoint"
        self.container(name, "--network", "none", "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:size=16m",
            "-v", str(self.keyfile) + ":/run/secrets/openai_api_key:ro",
            "-v", str(self.tokenfile) + ":/run/secrets/app_access_token:ro",
            "-e", "OPENAI_API_KEY_FILE=/run/secrets/openai_api_key",
            "-e", "APP_ACCESS_TOKEN_FILE=/run/secrets/app_access_token",
            "-e", "RELAY_REQUIRE_EXPLICIT_EXPIRY=true",
            "-e", "APP_ACCESS_TOKEN_EXPIRES_AT=" + self.env["APP_ACCESS_TOKEN_EXPIRES_AT"], IMAGE)
        script = "import urllib.request,json; print(json.load(urllib.request.urlopen('http://127.0.0.1:8787/health', timeout=2)))"
        response = self.wait(lambda: docker("exec", name, "python3", "-c", script))
        self.assertIn("True", response.stdout)
        probe = "import urllib.request,urllib.error; r=urllib.request.Request('http://127.0.0.1:8787/v1/chat',data=b'{}',headers={'Content-Type':'application/json'});\ntry: urllib.request.urlopen(r,timeout=2)\nexcept urllib.error.HTTPError as e: print(e.code)"
        self.assertEqual(docker("exec", name, "python3", "-c", probe).stdout.strip(), "401")
        logs = docker("logs", name).stdout + docker("logs", name).stderr
        self.assertNotIn(TOKEN, logs); self.assertNotIn(KEY, logs)
        self.assertNotIn("127.0.0.1", logs)
        self.assertIn('"code":"unauthorized"', logs)

    def test_production_caddy_configuration_over_trusted_local_https(self):
        config = self.compose()
        caddy_image = config["services"]["caddy"]["image"]
        # Validates the actual Caddyfile with networking disabled, without certificate issuance.
        docker("run", "--rm", "--network", "none", "-e", "RELAY_HOSTNAME=localhost",
               "-e", "ACME_EMAIL=operator@example.invalid", "-v", str(self.caddyfile) + ":/etc/caddy/Caddyfile:ro",
               caddy_image, "caddy", "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile")
        network = self.prefix + "-network"; self.networks.append(network)
        docker("network", "create", "--internal", network)
        relay = self.prefix + "-relay"
        # The adapter is only in this test script (not the image). Network isolation also
        # prevents any OpenAI/public API call even if the fixture were accidentally changed.
        fixture = """import time
from relay import RelayService,Settings,create_server
from relay_runtime import SafeEventLogger
def fake(*_):
 return {'status':'completed','output':[{'type':'message','role':'assistant','content':[{'type':'output_text','text':'synthetic HTTPS fixture'}]}]}
s=Settings(api_key='synthetic-provider-key',access_token='%s',access_token_expires_at=time.time()+600,requests_per_minute=1)
create_server(RelayService(s,fake),('0.0.0.0',8787),logger=SafeEventLogger()).serve_forever()
""" % TOKEN
        self.container(relay, "--network", network, "--network-alias", "relay", "--read-only", "--cap-drop", "ALL",
                       "--entrypoint", "python3", IMAGE, "-c", fixture)
        self.wait(lambda: docker("exec", relay, "python3", "-c",
            "import urllib.request; assert urllib.request.urlopen('http://127.0.0.1:8787/health/live',timeout=2).status == 200"))
        volumes = [self.prefix + "-data", self.prefix + "-config"]
        self.volumes.extend(volumes)
        for volume in volumes: docker("volume", "create", volume)
        caddy = self.prefix + "-caddy"
        self.container(caddy, "--network", network, "--read-only", "--cap-drop", "ALL", "--cap-add", "NET_BIND_SERVICE",
                       "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:size=16m",
                       "--network-alias", "edge", "-e", "NO_PROXY=*", "-e", "no_proxy=*", "-e", "RELAY_HOSTNAME=localhost", "-e", "ACME_EMAIL=operator@example.invalid",
                       "-v", str(self.caddyfile) + ":/etc/caddy/Caddyfile:ro",
                       "-v", volumes[0] + ":/data", "-v", volumes[1] + ":/config", caddy_image)
        # Both the HTTPS client and stub backend stay on an internal Docker network;
        # no ports are published and no external route/provider/ACME can be reached.
        root_cert = self.folder / "root.crt"
        self.wait(lambda: docker("cp", caddy + ":/data/caddy/pki/authorities/local/root.crt", str(root_cert)))
        ca_data = root_cert.read_text()
        def request(path, body=None, auth=None):
            method = "POST" if body is not None else "GET"
            headers = {"Host": "localhost", "Content-Type": "application/json", "Connection": "close"}
            if auth: headers["Authorization"] = auth
            if body is not None: headers["Content-Length"] = str(len(body))
            raw = (method + " " + path + " HTTP/1.1\r\n" + "".join(key + ": " + value + "\r\n" for key, value in headers.items()) + "\r\n").encode() + (body or b"")
            script = ("import ssl,socket,http.client,json\n"
                + "tls=ssl.create_default_context(cadata=" + repr(ca_data) + ")\n"
                + "with socket.create_connection(('edge',443),timeout=4) as raw:\n"
                + " with tls.wrap_socket(raw,server_hostname='localhost') as connection:\n"
                + "  connection.sendall(" + repr(raw) + ")\n"
                + "  response=http.client.HTTPResponse(connection); response.begin()\n"
                + "  print(json.dumps([response.status,dict(response.getheaders()),response.read().decode()]))\n")
            result = json.loads(docker("exec", relay, "python3", "-c", script).stdout)
            return result[0], result[1], result[2].encode()
        def live():
            response = request("/health/live")
            if response[0] != 200:
                raise ValueError("Local HTTPS health not ready")
            return response
        ready = self.wait(live)
        self.assertEqual(ready[0], 200)
        self.assertIn("max-age=31536000", ready[1]["Strict-Transport-Security"])
        self.assertEqual(request("/v1/chat", b'{"prompt":"a"}')[0], 401)
        body = b'{"prompt":"synthetic sensitive HTTPS prompt"}'
        status, _, raw = request("/v1/chat", body, "Bearer " + TOKEN)
        self.assertEqual(status, 200); self.assertEqual(json.loads(raw)["text"], "synthetic HTTPS fixture")
        limited = request("/v1/chat", body, "Bearer " + TOKEN)
        self.assertEqual(limited[0], 429); self.assertEqual(limited[1]["Retry-After"], "60")
        self.assertEqual(request("/private-url?secret=value")[0], 404)
        for container in (relay, caddy):
            log = docker("logs", container)
            for forbidden in [TOKEN, KEY, "synthetic sensitive HTTPS prompt", "secret=value"]:
                self.assertNotIn(forbidden, log.stdout + log.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
