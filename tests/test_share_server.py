"""Synthetic-only LAN bridge tests. All test listeners bind 127.0.0.1."""
import copy
import datetime as dt
import html
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

SERVICE = Path(__file__).resolve().parents[1] / "src/service"
sys.path.insert(0, str(SERVICE))
import share_server as bridge

CONFIG = {"accessCode": "31415926", "sessionSecret": "ab" * 32}
CONNECTION_ID = "11111111-2222-4333-8444-555555555555"
OTHER_CONNECTION_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
RELAY_CONFIG = {"connectionID": CONNECTION_ID}


def iso(seconds):
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat(timespec="seconds")


def cache(now=1_800_000_000, name="Example team"):
    return {"connectionID": CONNECTION_ID, "status": "live", "capturedAt": iso(now),
            "sourceLabel": "Example relay", "periodLabel": "最近30天",
            "entries": [{"name": name, "calls": 12, "amountUSD": 4.5, "sharePercent": 100.0}]}


def diagnostic(now=1_800_000_000, phase="live", connection=CONNECTION_ID):
    return {"connectionID": connection, "phase": phase, "updatedAt": iso(now)}


def sample():
    now = time.time()
    return {"fetchedAt": iso(now),
            "account": bridge.safe_account({"status": "live", "updatedAt": iso(now), "planType": "example",
                "windows": [{"key": "codex:primary", "label": "每周额度", "usedPercent": 20,
                             "remainingPercent": 80, "windowDurationMins": 10080, "resetsAt": now + 1000}],
                "resetCredits": {"availableCount": 1, "credits": [{"status": "available", "title": "Example credit", "expiresAt": now + 3600}]}}),
            "system": bridge.safe_system({"updatedAt": iso(now), "cpu": {"name": "Example CPU", "usagePercent": 10, "cores": 8},
                "memory": {"usedBytes": 4_000_000_000, "totalBytes": 16_000_000_000}}),
            "relay": bridge.safe_relay(cache(now), diagnostic(now), RELAY_CONFIG)}


class FakeData:
    def snapshot(self):
        return sample()


class AuthAndDataTests(unittest.TestCase):
    def test_sessions_persist_expire_and_resist_tampering(self):
        auth = bridge.PairingAuth(CONFIG)
        token = auth.issue(now=1000)
        self.assertTrue(bridge.PairingAuth(CONFIG).valid(token, now=1001))
        self.assertFalse(auth.valid(token, now=999))
        self.assertFalse(auth.valid(token, now=1000 + bridge.SESSION_SECONDS))
        self.assertFalse(auth.valid(token[:-1] + ("0" if token[-1] != "0" else "1"), now=1001))
        self.assertFalse(bridge.PairingAuth({**CONFIG, "sessionSecret": "cd" * 32}).valid(token, now=1001))

    def test_config_rejects_insecure_file_or_invalid_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(CONFIG))
            path.chmod(0o644)
            with self.assertRaises(ValueError): bridge.PairingAuth.from_path(path)
            path.chmod(0o600)
            self.assertIsInstance(bridge.PairingAuth.from_path(path), bridge.PairingAuth)
            link = Path(directory) / "link.json"
            link.symlink_to(path)
            with self.assertRaises(ValueError): bridge.PairingAuth.from_path(link)
        for invalid in ({}, {**CONFIG, "accessCode": 31415926}, {**CONFIG, "sessionSecret": "short"}):
            with self.assertRaises(ValueError): bridge.PairingAuth(invalid)

    def test_pair_rate_limit_is_per_ip_and_ages_out(self):
        auth = bridge.PairingAuth(CONFIG)
        for index in range(5): self.assertEqual(auth.pair("192.168.1.2", "00000000", now=index), "invalid")
        self.assertEqual(auth.pair("192.168.1.2", CONFIG["accessCode"], now=5), "limited")
        self.assertEqual(auth.pair("192.168.1.3", CONFIG["accessCode"], now=5), "ok")
        self.assertEqual(auth.pair("192.168.1.2", CONFIG["accessCode"], now=65), "ok")

    def test_private_addresses_and_local_source_only(self):
        for address in ("10.0.0.2", "172.16.0.2", "172.31.255.2", "192.168.5.2"):
            self.assertTrue(bridge.private_ipv4(address))
        for address in ("0.0.0.0", "127.0.0.1", "169.254.1.1", "172.32.0.2", "8.8.8.8", "::1", "example.com"):
            self.assertFalse(bridge.private_ipv4(address))
        self.assertEqual(bridge.local_endpoint("http://localhost:18768"), ("127.0.0.1", 18768))
        for url in ("https://127.0.0.1:8768", "http://192.168.1.3:8768", "http://u:p@127.0.0.1", "http://127.0.0.1?secret=x", "http://127.0.0.1/api"):
            with self.assertRaises(ValueError): bridge.local_endpoint(url)

    def test_account_and_system_whitelist_and_freshness(self):
        now = 1_800_000_000
        raw = {"status": "live", "updatedAt": iso(now - 361), "email": "nobody@example.invalid",
               "token": "PRIVATE", "windows": [{"key": "primary", "usedPercent": 23, "remainingPercent": 77, "token": "PRIVATE"}]}
        result = bridge.safe_account(raw, now=now)
        self.assertEqual(result["status"], "stale")
        self.assertEqual(result["windows"][0]["remainingPercent"], 77)
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertNotIn("email", result)
        self.assertIsNone(bridge.safe_system({"cpu": {"usagePercent": float("nan"), "token": "PRIVATE"}})["cpu"]["usagePercent"])

    def test_relay_never_promotes_old_or_disconnected_snapshots(self):
        now = 1_800_000_000
        current = diagnostic(now)
        fresh = bridge.safe_relay(cache(now), current, RELAY_CONFIG, now)
        self.assertEqual(fresh["status"], "live")
        old = bridge.safe_relay(cache(now - 361), current, RELAY_CONFIG, now)
        self.assertEqual(old["status"], "stale")
        expired = bridge.safe_relay(cache(now), diagnostic(now + 1, "unconnected"), RELAY_CONFIG, now)
        self.assertEqual(expired["status"], "stale")
        self.assertIn("重新登录", expired["error"])
        self.assertEqual(expired["updatedAt"], iso(now))
        self.assertEqual(expired["entries"][0]["calls"], 12)
        self.assertEqual(bridge.safe_relay(cache(now), {}, RELAY_CONFIG, now)["status"], "stale")
        seeded = bridge.safe_relay({**cache(now), "status": "snapshot"}, current, RELAY_CONFIG, now)
        self.assertEqual(seeded["status"], "stale")
        self.assertIn("单次", seeded["error"])

    def test_relay_metrics_distinguish_missing_and_real_zero(self):
        raw = cache()
        raw["entries"] = [{"name": "Unknown"}, {"name": "No usage", "calls": 0, "inputTokens": 0,
                                                "outputTokens": 0, "amountUSD": 0}]
        result = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)
        self.assertEqual(result["status"], "live")
        missing, zero = result["entries"]
        for field in ("calls", "inputTokens", "outputTokens", "totalTokens", "amountUSD", "sharePercent"):
            self.assertIsNone(missing[field], field)
        for field in ("calls", "inputTokens", "outputTokens", "totalTokens", "amountUSD"):
            self.assertEqual(zero[field], 0, field)
        self.assertIsNone(zero["sharePercent"])

    def test_relay_tokens_reject_invalid_values_and_unsafe_sums(self):
        invalid = [True, False, -1, 1.5, 1.0, "100", float("nan"), float("inf"), bridge.MAX_SAFE_INTEGER + 1, 10 ** 1000]
        for value in invalid:
            with self.subTest(value=repr(value)[:30]):
                raw = cache()
                raw["entries"][0].update(calls=value, inputTokens=value, outputTokens=value, totalTokens=value)
                row = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)["entries"][0]
                for field in ("calls", "inputTokens", "outputTokens", "totalTokens"):
                    self.assertIsNone(row[field])
        raw["entries"][0].update(inputTokens=bridge.MAX_SAFE_INTEGER, outputTokens=1, totalTokens=None)
        row = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)["entries"][0]
        self.assertEqual(row["inputTokens"], bridge.MAX_SAFE_INTEGER)
        self.assertIsNone(row["totalTokens"])

    def test_relay_total_uses_direct_value_or_both_components_only(self):
        raw = cache()
        raw["entries"] = [
            {"name": "Direct", "totalTokens": 99, "inputTokens": 2, "outputTokens": 3},
            {"name": "Computed", "inputTokens": 2, "outputTokens": 3},
            {"name": "Partial", "inputTokens": 2, "amountUSD": 10},
            {"name": "Direct zero", "totalTokens": 0},
            {"name": "Invalid direct", "totalTokens": -1, "inputTokens": 7, "outputTokens": 8},
        ]
        rows = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)["entries"]
        self.assertEqual([r["totalTokens"] for r in rows], [99, 5, None, 0, 15])
        self.assertTrue(all(r["calls"] is None for r in rows))
        self.assertTrue(all(r["sharePercent"] is None for r in rows))

    def test_relay_spend_share_requires_all_amounts_and_never_uses_tokens(self):
        raw = cache()
        raw["entries"] = [
            {"name": "A", "amountUSD": 1, "totalTokens": 900, "sharePercent": 90},
            {"name": "B", "amountUSD": 3, "totalTokens": 100, "sharePercent": 10},
        ]
        rows = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)["entries"]
        self.assertEqual([r["sharePercent"] for r in rows], [25, 75])
        for invalid in (None, -1, True, "3", float("nan"), float("inf"), 10 ** 1000):
            raw["entries"][1]["amountUSD"] = invalid
            rows = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)["entries"]
            self.assertIsNone(rows[1]["amountUSD"])
            self.assertEqual([r["sharePercent"] for r in rows], [None, None])
        for entry in raw["entries"]:
            entry["amountUSD"] = 0
        rows = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)["entries"]
        self.assertEqual([r["amountUSD"] for r in rows], [0, 0])
        self.assertEqual([r["sharePercent"] for r in rows], [None, None])

    def test_relay_connection_id_isolates_sites_and_diagnostic_state(self):
        raw = cache()
        for config in ({}, {"connectionID": "not-a-uuid"}, {"connectionID": OTHER_CONNECTION_ID}):
            result = bridge.safe_relay(raw, diagnostic(), config, 1_800_000_000)
            self.assertEqual(result["status"], "unconnected")
            self.assertEqual(result["entries"], [])
            self.assertIsNone(result["updatedAt"])
            self.assertEqual(result["sourceLabel"], "中转站")
        for previous_state in (diagnostic(connection=OTHER_CONNECTION_ID), diagnostic(1_800_000_061)):
            result = bridge.safe_relay(raw, previous_state, RELAY_CONFIG, 1_800_000_000)
            self.assertEqual(result["status"], "stale")
            self.assertEqual(result["entries"][0]["calls"], 12)

    def test_relay_output_is_a_summary_without_configuration_or_secrets(self):
        raw = cache()
        raw.update(usageURL="https://PRIVATE.invalid/?token=PRIVATE", apiKey="PRIVATE", cookies="PRIVATE", connectionSecret="PRIVATE")
        raw["entries"][0].update(apiKey="PRIVATE", token="PRIVATE", userEmail="PRIVATE", url="PRIVATE")
        state = {**diagnostic(), "reason": "PRIVATE", "locationPath": "PRIVATE", "headers": {"Authorization": "PRIVATE"}}
        config = {**RELAY_CONFIG, "usageURL": "PRIVATE", "password": "PRIVATE", "headers": {"Authorization": "PRIVATE"}}
        result = bridge.safe_relay(raw, state, config, 1_800_000_000)
        self.assertEqual(set(result), {"status", "updatedAt", "periodLabel", "sourceLabel", "entries", "error"})
        self.assertEqual(set(result["entries"][0]), {"name", "calls", "inputTokens", "outputTokens", "totalTokens", "amountUSD", "sharePercent"})
        serialized = json.dumps(result)
        self.assertNotIn("PRIVATE", serialized)
        self.assertNotIn(CONNECTION_ID, serialized)
        self.assertEqual(result["sourceLabel"], "Example relay")

    def test_empty_relay_requires_a_successful_snapshot(self):
        raw = {**cache(), "entries": []}
        result = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)
        self.assertEqual(result["status"], "live")
        self.assertEqual(result["entries"], [])
        for status in ("loading", "unconnected", "unavailable", "stale", "snapshot"):
            result = bridge.safe_relay({**raw, "status": status}, diagnostic(), RELAY_CONFIG, 1_800_000_000)
            self.assertEqual(result["status"], "unconnected")

    def test_relay_entry_limit_supports_large_valid_lists_without_partial_output(self):
        for count in (101, 1000, 1001):
            with self.subTest(count=count):
                raw = cache()
                raw["entries"] = [{"name": "Example " + str(i), "totalTokens": i, "amountUSD": 1}
                                  for i in range(count)]
                result = bridge.safe_relay(raw, diagnostic(), RELAY_CONFIG, 1_800_000_000)
                if count <= 1000:
                    self.assertEqual(result["status"], "live")
                    self.assertEqual(len(result["entries"]), count)
                    self.assertAlmostEqual(sum(row["sharePercent"] for row in result["entries"]), 100)
                else:
                    self.assertEqual(result["status"], "unconnected")
                    self.assertEqual(result["entries"], [])

    def test_only_relay_snapshot_receives_the_two_mib_read_limit(self):
        now = time.time()
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory)
            raw = {**cache(now), "unpublishedPadding": "x" * 300_000}
            (support / "relay-config.json").write_text(json.dumps(RELAY_CONFIG))
            (support / "relay-connection-state.json").write_text(json.dumps(diagnostic(now)))
            snapshot_path = support / "relay-snapshot.json"
            snapshot_path.write_text(json.dumps(raw))
            result = bridge.DisplayData(support).read_relay()
            self.assertEqual(result["status"], "live")
            self.assertNotIn("unpublishedPadding", result)
            raw["unpublishedPadding"] = "x" * bridge.MAX_RELAY_CACHE_BYTES
            snapshot_path.write_text(json.dumps(raw))
            self.assertEqual(bridge.DisplayData(support).read_relay()["status"], "unconnected")
            snapshot_path.write_text(json.dumps(cache(now)))
            (support / "relay-config.json").write_text(json.dumps({**RELAY_CONFIG, "unpublishedPadding": "x" * 300_000}))
            self.assertEqual(bridge.DisplayData(support).read_relay()["status"], "unconnected")

    def test_cached_mac_response_rechecks_configuration_and_ignores_old_brand_files(self):
        now = time.time()
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory)
            for filename, content in (("relay-config.json", RELAY_CONFIG), ("relay-snapshot.json", cache(now)),
                                      ("relay-connection-state.json", diagnostic(now)),
                                      ("starsg-snapshot.json", cache(now)), ("starsg-connection-state.json", diagnostic(now))):
                (support / filename).write_text(json.dumps(content))
            data = bridge.DisplayData(support)
            with patch.object(data, "read_local", return_value=sample()) as read_local:
                first = data.snapshot()
                self.assertEqual(first["relay"]["status"], "live")
                (support / "relay-config.json").write_text(json.dumps({"connectionID": OTHER_CONNECTION_ID}))
                second = data.snapshot()
                self.assertEqual(second["relay"]["status"], "unconnected")
                self.assertEqual(second["relay"]["entries"], [])
                self.assertEqual(read_local.call_count, 1)
                (support / "relay-config.json").unlink()
                third = data.snapshot()
                self.assertEqual(third["relay"]["status"], "unconnected")
                self.assertNotIn("starsg", third)

    def test_local_failure_preserves_last_timestamp_and_marks_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            data = bridge.DisplayData(directory)
            previous = sample()
            with patch.object(data, "read_local", return_value=previous):
                first = data.snapshot()
            data.next_read = 0
            with patch.object(data, "read_local", side_effect=OSError("PRIVATE upstream error")):
                second = data.snapshot()
            self.assertEqual(second["account"]["updatedAt"], first["account"]["updatedAt"])
            self.assertEqual(second["account"]["status"], "stale")
            self.assertNotIn("PRIVATE", json.dumps(second))


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.auth = bridge.PairingAuth(CONFIG)
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        (root / "shared").mkdir()
        (root / "shared/display.css").write_text("body{color:black}")
        (root / "shared/display.js").write_text("/* example */")
        self.server = bridge.DisplayServer(("127.0.0.1", 0), self.auth, FakeData(),
            renderer=lambda data, mode: "<html>" + html.escape(data["relay"]["entries"][0]["name"]) + mode + "</html>", resource_root=root)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        self.port = self.server.server_port
        self.host = f"127.0.0.1:{self.port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.directory.cleanup()

    def request(self, method="GET", path="/", headers=None, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request(method, path, body=body, headers={"Host": self.host, **(headers or {})})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read().decode("utf-8")
        finally:
            connection.close()

    def pair(self):
        status, headers, _ = self.request("POST", "/pair", {"Content-Type": "application/x-www-form-urlencoded"}, "code=" + CONFIG["accessCode"])
        self.assertEqual(status, 303)
        return headers["Set-Cookie"].split(";", 1)[0], headers

    def test_unauthenticated_surface_reveals_no_account_data(self):
        for path in ("/", "/display", "/kindle"):
            status, headers, body = self.request(path=path)
            self.assertEqual(status, 200)
            self.assertIn("连接码", body)
            self.assertNotIn("Example team", body)
            self.assertNotIn("usedPercent", body)
        self.assertEqual(self.request(path="/api/display")[0], 401)
        self.assertEqual(self.request(path="/display.js")[0], 401)
        self.assertEqual(json.loads(self.request(path="/health")[2]), {"service": "gpt-lan-display"})

    def test_pairing_cookie_security_headers_and_authenticated_routes(self):
        cookie, paired_headers = self.pair()
        for flag in ("HttpOnly", "SameSite=Strict", "Max-Age=2592000", "Path=/"):
            self.assertIn(flag, paired_headers["Set-Cookie"])
        for path in ("/display", "/kindle", "/api/display", "/display.css", "/display.js"):
            status, headers, body = self.request(path=path, headers={"Cookie": cookie})
            self.assertEqual(status, 200)
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertEqual(headers["Referrer-Policy"], "no-referrer")
            self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
            self.assertNotIn("Access-Control-Allow-Origin", headers)
        self.assertEqual(self.request(path="/", headers={"Cookie": cookie})[0], 303)

    def test_host_origin_cross_site_and_traversal_are_blocked(self):
        cookie, _ = self.pair()
        for headers in ({"Host": "attacker.invalid:" + str(self.port)}, {"Origin": "https://attacker.invalid"},
                        {"Origin": "null"}, {"Sec-Fetch-Site": "cross-site"}, {"Host": "localhost:" + str(self.port)}):
            self.assertEqual(self.request(path="/api/display", headers={"Cookie": cookie, **headers})[0], 403)
        self.assertEqual(self.request(path="/api/display", headers={"Cookie": cookie, "Origin": "http://" + self.host})[0], 200)
        for path in ("/../share_server.py", "/%2e%2e/share_server.py", "/shared/../../config.json", "/api/display?code=31415926", "http://attacker.invalid/health"):
            self.assertEqual(self.request(path=path, headers={"Cookie": cookie})[0], 404)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.putrequest("GET", "/health", skip_host=True)
            connection.putheader("Host", self.host)
            connection.putheader("Host", "attacker.invalid")
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 403)
            response.read()
        finally:
            connection.close()

    def test_http_rate_limit_and_logout(self):
        for _ in range(5):
            self.assertEqual(self.request("POST", "/pair", {"Content-Type": "application/x-www-form-urlencoded"}, "code=00000000")[0], 403)
        self.assertEqual(self.request("POST", "/pair", {"Content-Type": "application/x-www-form-urlencoded"}, "code=00000000")[0], 429)
        self.auth.failures.clear()
        cookie, _ = self.pair()
        status, headers, _ = self.request("POST", "/logout", {"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"}, "")
        self.assertEqual(status, 303)
        self.assertIn("Max-Age=0", headers["Set-Cookie"])

    def test_kindle_pairing_keeps_lightweight_view_and_cannot_redirect_elsewhere(self):
        self.assertIn('name="view" value="kindle"', self.request(path="/kindle")[2])
        status, headers, _ = self.request("POST", "/pair", {"Content-Type": "application/x-www-form-urlencoded"},
                                          "code=" + CONFIG["accessCode"] + "&view=kindle")
        self.assertEqual(status, 303)
        self.assertEqual(headers["Location"], "/kindle")
        self.assertEqual(self.request("POST", "/pair", {"Content-Type": "application/x-www-form-urlencoded"},
                                      "code=" + CONFIG["accessCode"] + "&view=https%3A%2F%2Fexample.invalid")[0], 403)


class RenderIntegrationTests(unittest.TestCase):
    def test_real_renderer_escapes_key_names_and_kindle_has_no_js_dependency(self):
        from shared.render import render_page
        data = sample()
        dangerous = '</script><img src=x onerror="alert(1)">'
        data["relay"]["entries"][0]["name"] = dangerous
        for mode in ("display", "kindle"):
            body = render_page(copy.deepcopy(data), mode=mode)
            self.assertNotIn(dangerous, body)
            self.assertIn("&lt;", body)
            self.assertIn("4.50", body)
            if mode == "kindle":
                self.assertNotIn("<script", body.lower())
                self.assertRegex(body.lower(), r'<meta[^>]*http-equiv=[\"\']refresh[\"\'][^>]*content=[\"\']300')


class LifecycleTests(unittest.TestCase):
    # Run the production lifecycle with only a test-only loopback bind override
    # and a synthetic renderer. Never contact the real dashboard or user data.
    CHILD = """import sys
sys.path.insert(0, sys.argv.pop(1))
import share_server as bridge
original_server = bridge.DisplayServer
bridge.DisplayServer = lambda *args: original_server(*args, renderer=lambda data, mode: '<html>example</html>')
bridge.private_ipv4 = lambda value, allow_loopback=False: value == '127.0.0.1'
bridge.main()
"""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.config = Path(self.directory.name) / "config.json"
        self.config.write_text(json.dumps(CONFIG))
        self.config.chmod(0o600)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        self.children = []

    def tearDown(self):
        for process in self.children:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
            if process.stdout:
                process.stdout.close()
        self.directory.cleanup()

    def args(self, parent):
        return [sys.executable, "-c", self.CHILD, str(SERVICE), "--bind", "127.0.0.1", "--port", str(self.port),
                "--parent-pid", str(parent), "--config", str(self.config)]

    def listening(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=0.3)
        try:
            connection.request("GET", "/health")
            result = connection.getresponse()
            return result.status == 200 and json.loads(result.read()) == {"service": "gpt-lan-display"}
        except (OSError, http.client.HTTPException, ValueError):
            return False
        finally:
            connection.close()

    def await_state(self, expected):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.listening() == expected:
                return
            time.sleep(0.05)
        self.fail("Bridge listener did not reach expected lifecycle state")

    def test_sigterm_closes_bridge(self):
        child = subprocess.Popen(self.args(os.getpid()), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(child)
        self.await_state(True)
        child.terminate()
        self.assertEqual(child.wait(timeout=5), 0)
        self.await_state(False)

    def test_parent_exit_closes_bridge(self):
        parent_code = """import json, os, subprocess, sys, time
args = json.loads(sys.argv[1])
args[args.index('--parent-pid') + 1] = str(os.getpid())
child = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(child.pid, flush=True)
while True: time.sleep(1)
"""
        parent = subprocess.Popen([sys.executable, "-c", parent_code, json.dumps(self.args(2))],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.children.append(parent)
        child_pid = int(parent.stdout.readline().strip())
        try:
            self.await_state(True)
            parent.terminate()
            parent.wait(timeout=3)
            self.await_state(False)
        finally:
            try:
                os.kill(child_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


if __name__ == "__main__":
    unittest.main()
