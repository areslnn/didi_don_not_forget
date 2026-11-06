import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/service"))
import importlib.util
from pathlib import Path
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("dashboard", Path(__file__).resolve().parents[1] / "src/service/server.py")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


class BackendContractTests(unittest.TestCase):
    def test_speed_route_does_not_read_full_dashboard(self):
        class Monitor:
            def snapshot(self): return {"status": "ready", "tokensPerSecond": 12.3}
        class State:
            speed_monitor = Monitor()
            def snapshot(self): raise AssertionError("Full dashboard accessed")
        handler = d.DashboardHandler.__new__(d.DashboardHandler)
        handler.path = "/api/codex-speed"
        handler.command = "GET"
        handler.server = types.SimpleNamespace(state=State())
        handler.allowed_request = lambda: True
        result = []
        handler.reply = lambda status, body, mime: result.append((status, body))
        handler.do_GET()
        import json
        self.assertEqual(result[0][0], 200)
        self.assertEqual(json.loads(result[0][1]), {"status": "ready", "tokensPerSecond": 12.3})

    def test_weekly_primary_not_mislabelled_five_hour_and_null_not_zero(self):
        data = d.normalize_account({"rateLimitsByLimitId": {"codex": {
            "primary": {"usedPercent": 16, "windowDurationMins": 10080, "resetsAt": 1794379060},
            "secondary": None, "planType": "prolite"}}, "rateLimitResetCredits": None})
        self.assertEqual(len(data["windows"]), 1)
        self.assertEqual(data["windows"][0]["label"], "每周额度")
        self.assertEqual(data["windows"][0]["remainingPercent"], 84)
        self.assertIsNone(data["resetCredits"]["availableCount"])

    def test_multi_bucket_preferred_no_legacy_double_count_and_clamped(self):
        data = d.normalize_account({"rateLimits": {"primary": {"usedPercent": 5}},
            "rateLimitsByLimitId": {"codex": {"primary": {"usedPercent": 150}},
                "another": {"primary": {"usedPercent": None}, "secondary": {"usedPercent": -2}}}})
        self.assertEqual([x["remainingPercent"] for x in data["windows"]], [0, None, 100])

    def test_raw_personal_identifiers_not_exposed(self):
        data = d.normalize_account({"accountId": "account-secret", "email": "private@example.com",
            "rateLimitResetCredits": {"availableCount": 0, "credits": [{"id": "credit-secret", "title": "Full reset", "expiresAt": None, "status": "available"}]}})
        self.assertEqual(data["resetCredits"]["availableCount"], 0)
        self.assertNotIn("secret", str(data))
        self.assertNotIn("private@example.com", str(data))

    def test_last_success_retained_as_stale_on_failed_refresh(self):
        state = d.DashboardState()
        state.account = d.normalize_account({"rateLimits": {"primary": {"usedPercent": 30}}})
        saved_time = state.account["updatedAt"]
        with patch.object(d, "read_account", side_effect=RuntimeError("network unavailable")):
            with patch.object(state.refresh, "wait", side_effect=StopIteration):
                with self.assertRaises(StopIteration):
                    state.account_loop()
        self.assertEqual(state.account["status"], "stale")
        self.assertEqual(state.account["updatedAt"], saved_time)
        self.assertEqual(state.account["windows"][0]["remainingPercent"], 70)

    def test_memory_cache_exclusion_and_unknown_data(self):
        sample = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Anonymous pages: 100.
Pages wired down: 50.
Pages occupied by compressor: 20.
Pages purgeable: 10.
File-backed pages: 400.
"""
        self.assertEqual(d.parse_memory(sample, 10000000), 160*16384)
        self.assertIsNone(d.parse_memory(sample, None))
        self.assertIsNone(d.parse_memory("", 10000000))

    def test_rebinding_and_cross_origin_blocked(self):
        handler = object.__new__(d.DashboardHandler)
        handler.server = types.SimpleNamespace(server_port=8768)
        for headers, expected in [
            ({"Host": "127.0.0.1:8768"}, True),
            ({"Host": "localhost:8768", "Origin": "http://localhost:8768"}, True),
            ({"Host": "attacker.example:8768"}, False),
            ({"Host": "127.0.0.1:8768", "Origin": "https://attacker.example"}, False),
            ({"Host": "127.0.0.1:8768", "Sec-Fetch-Site": "cross-site"}, False),
        ]:
            handler.headers = headers
            self.assertEqual(handler.allowed_request(), expected)


if __name__ == "__main__":
    unittest.main()
