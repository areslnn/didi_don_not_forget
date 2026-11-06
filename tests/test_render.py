"""Synthetic data only. No account files, real names, or network access."""
import copy
import importlib.util
from pathlib import Path
import re
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "src/service/shared/render.py"
spec = importlib.util.spec_from_file_location("companion_render", MODULE_PATH)
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)

NOW = 1_800_000_000
STAMP = "2027-01-15T08:00:00+00:00"  # Equals NOW; deliberately synthetic.


def data():
    return {
        "account": {"status": "live", "updatedAt": STAMP, "planType": "demo",
                    "windows": [{"label": "每周额度", "usedPercent": 25, "remainingPercent": 75, "resetsAt": NOW + 86400},
                                {"label": "5 小时额度", "usedPercent": 9, "remainingPercent": 91, "resetsAt": NOW + 3600}],
                    "resetCredits": {"availableCount": 2, "credits": []}},
        "system": {"updatedAt": STAMP, "cpu": {"name": "Example Silicon", "usagePercent": 12, "cores": 8},
                   "memory": {"usedBytes": 8 * 1024**3, "totalBytes": 16 * 1024**3},
                   "disk": {"usedBytes": 100 * 1024**3, "totalBytes": 500 * 1024**3},
                   "battery": {"present": True, "percent": 68, "onAC": False, "charging": False}, "uptimeSeconds": 90000},
        "starsg": {"status": "live", "updatedAt": STAMP, "periodLabel": "最近30天", "entries": [
            {"name": "团队A", "calls": 12, "amountUSD": 0.123456, "sharePercent": 34.48},
            {"name": "个人助手", "calls": 8, "amountUSD": 0.234567, "sharePercent": 65.52}]},
    }


class RenderTests(unittest.TestCase):
    def render(self, value=None, mode="display"):
        with patch.object(render.time, "time", return_value=NOW):
            return render.render_page(data() if value is None else value, mode)

    def test_all_windows_keys_and_decimal_precision(self):
        page = self.render()
        self.assertIn("每周额度 · 剩余", page)
        self.assertIn("5 小时额度 · 剩余", page)
        for name in ("团队A", "个人助手"):
            self.assertIn(name, page)
        self.assertIn("0.123456", page)
        self.assertIn("0.234567", page)
        self.assertIn('class="currency">$</span>0.36', page)
        self.assertIn("34.48%", page)

    def test_external_strings_are_escaped_and_private_fields_ignored(self):
        value = data()
        attack = '<script>alert("x")</script>&'
        value["starsg"]["entries"][0]["name"] = attack
        value["account"]["windows"][0]["label"] = attack
        value["system"]["cpu"]["name"] = attack
        value["starsg"]["error"] = attack
        value["account"]["password"] = "DO_NOT_RENDER_PRIVATE_FIELD"
        value["starsg"]["entries"][0]["apiKey"] = "DO_NOT_RENDER_API_KEY"
        page = self.render(value)
        self.assertNotIn(attack, page)
        self.assertIn("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;&amp;", page)
        self.assertNotIn("DO_NOT_RENDER", page)
        self.assertNotIn("application/json", page)

    def test_kindle_is_complete_without_script(self):
        page = self.render(mode="kindle")
        self.assertNotIn("<script", page)
        self.assertNotIn("display.js", page)
        self.assertIn('<meta http-equiv="refresh" content="300">', page)
        self.assertIn("团队A", page)
        self.assertIn('class="metrics-layout"', page)
        self.assertIn("每周额度", page)
        self.assertNotIn('id="fullscreen"', page)

    def test_modern_refresh_and_no_inline_script(self):
        page = self.render()
        self.assertIn('<meta http-equiv="refresh" content="60">', page)
        self.assertEqual(re.findall(r"<script[^>]*>.*?</script>", page), ['<script src="/display.js" defer></script>'])
        self.assertIn('id="fullscreen" hidden', page)

    def test_expiry_exact_boundary_unknown_and_nonavailable(self):
        value = data()
        value["account"]["resetCredits"]["credits"] = [
            {"status": "available", "expiresAt": NOW + 259200},
            {"status": "available", "expiresAt": NOW + 259201},
            {"status": "available", "expiresAt": NOW},
            {"status": "available", "expiresAt": NOW - 1},
            {"status": "available", "expiresAt": None},
            {"status": "available", "expiresAt": float("nan")},
            {"status": "consumed", "expiresAt": NOW + 30},
        ]
        page = self.render(value)
        self.assertEqual(page.count('class="expiring"'), 3)
        self.assertEqual(page.count("3天内到期"), 1)
        self.assertEqual(page.count("卡片已到期"), 2)
        self.assertEqual(page.count("到期时间未提供"), 2)

    def test_stale_status_does_not_use_page_time(self):
        value = data()
        value["account"]["status"] = "stale"
        value["account"]["updatedAt"] = "2027-01-14T08:00:00+00:00"
        value["starsg"]["status"] = "live"
        value["starsg"]["updatedAt"] = "2027-01-14T08:00:00+00:00"
        page = self.render(value)
        self.assertEqual(page.count("显示上次读数"), 2)
        self.assertIn("01/14 16:00", page)
        self.assertIn("0.123456", page)

    def test_missing_values_are_not_zero_or_battery_claim(self):
        page = self.render({})
        self.assertIn("电源状态未提供", page)
        self.assertNotIn("使用电池供电", page)
        self.assertIn('class="currency">$</span>—', page)
        self.assertNotIn('class="currency">$</span>0.00', page)
        self.assertIn("暂未读取到账号额度", page)

    def test_actual_zero_usage_is_distinct_from_unavailable(self):
        value = data()
        value["starsg"]["entries"] = []
        page = self.render(value)
        self.assertIn('class="currency">$</span>0.00', page)
        self.assertIn("当前周期暂无用量", page)

    def test_demo_banner_requires_boolean_true_and_attribution_present(self):
        value = data()
        self.assertNotIn("示例数据 · 非真实账号", self.render(value))
        value["demo"] = "true"
        self.assertNotIn("示例数据 · 非真实账号", self.render(value))
        value["demo"] = True
        self.assertIn("示例数据 · 非真实账号", self.render(value))
        self.assertIn("https://github.com/areslnn/didi_don_not_forget", self.render(value))


if __name__ == "__main__":
    unittest.main()
