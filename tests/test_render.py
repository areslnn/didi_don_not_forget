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
        "relay": {"status": "live", "updatedAt": STAMP, "periodLabel": "最近30天", "sourceLabel": "示例中转站", "entries": [
            {"name": "团队A", "calls": 12, "inputTokens": 80000, "outputTokens": 12000, "totalTokens": 92000, "amountUSD": 0.123456, "sharePercent": 34.48},
            {"name": "个人助手", "calls": 8, "inputTokens": 24000, "outputTokens": 4000, "totalTokens": 28000, "amountUSD": 0.234567, "sharePercent": 65.52}]},
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
        self.assertIn('class="token-total">120,000', page)
        self.assertIn("输入 104,000 · 输出 16,000", page)
        self.assertIn("示例中转站", page)
        self.assertIn("<h1>中转站用量</h1>", page)

    def test_external_strings_are_escaped_and_private_fields_ignored(self):
        value = data()
        attack = '<script>alert("x")</script>&'
        value["relay"]["entries"][0]["name"] = attack
        value["account"]["windows"][0]["label"] = attack
        value["system"]["cpu"]["name"] = attack
        value["relay"]["error"] = attack
        value["relay"]["sourceLabel"] = attack
        value["relay"]["periodLabel"] = attack
        value["account"]["password"] = "DO_NOT_RENDER_PRIVATE_FIELD"
        value["relay"]["entries"][0]["apiKey"] = "DO_NOT_RENDER_API_KEY"
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
        value["relay"]["status"] = "live"
        value["relay"]["updatedAt"] = "2027-01-14T08:00:00+00:00"
        page = self.render(value)
        self.assertEqual(page.count("显示上次读数"), 2)
        self.assertIn("01/14 16:00", page)
        self.assertIn("0.123456", page)

    def test_missing_values_are_not_zero_or_battery_claim(self):
        page = self.render({})
        self.assertIn("电源状态未提供", page)
        self.assertNotIn("使用电池供电", page)
        self.assertIn('class="cost-total">未提供', page)
        self.assertIn('class="token-total missing-value">未提供', page)
        self.assertNotIn('class="currency">$</span>0.00', page)
        self.assertIn("暂未读取到账号额度", page)

    def test_actual_zero_usage_is_distinct_from_unavailable(self):
        value = data()
        value["relay"]["entries"] = []
        page = self.render(value)
        self.assertIn('class="currency">$</span>0.00', page)
        self.assertIn("当前周期暂无用量", page)


    def test_incomplete_token_total_never_shows_partial_sum(self):
        value = data()
        value["relay"]["entries"][1]["totalTokens"] = None
        page = self.render(value)
        self.assertIn('class="token-total missing-value">未提供', page)
        self.assertNotIn('class="token-total">92,000', page)
        self.assertIn("部分 Key 未提供真实 Token", page)
        self.assertIn('class="currency">$</span>0.36', page)

    def test_missing_tokens_are_not_inferred_from_cost_or_input_output(self):
        value = data()
        for entry in value["relay"]["entries"]:
            entry["totalTokens"] = None
        page = self.render(value)
        self.assertIn('class="token-total missing-value">未提供', page)
        self.assertIn('class="currency">$</span>0.36', page)
        self.assertIn("输入 104,000 · 输出 16,000", page)

    def test_each_optional_aggregate_requires_all_entries(self):
        value = data()
        value["relay"]["entries"][0]["calls"] = None
        value["relay"]["entries"][1]["amountUSD"] = None
        page = self.render(value)
        self.assertIn('class="token-total">120,000', page)
        self.assertIn('class="cost-total">未提供', page)
        self.assertIn('调用次数 <strong>未提供', page)
        self.assertIn("0.123456", page)

    def test_token_count_validation_and_actual_zero(self):
        for invalid in (True, "92000", -1, 1.5, float("nan"), float("inf"), 9007199254740992):
            with self.subTest(invalid=invalid):
                value = data()
                value["relay"]["entries"][0]["totalTokens"] = invalid
                self.assertIn('class="token-total missing-value">未提供', self.render(value))
        value = data()
        for entry in value["relay"]["entries"]:
            entry.update(inputTokens=0, outputTokens=0, totalTokens=0, calls=0, amountUSD=0)
        page = self.render(value)
        self.assertIn('class="token-total">0', page)
        self.assertIn('class="currency">$</span>0.00', page)

    def test_amount_per_entry_boundary_does_not_cap_complete_total(self):
        value = data()
        for entry in value["relay"]["entries"]:
            entry["amountUSD"] = 1e12
        page = self.render(value)
        self.assertIn('class="currency">$</span>2,000,000,000,000.00', page)
        value["relay"]["entries"][0]["amountUSD"] = 1e12 + 1
        page = self.render(value)
        self.assertIn('class="cost-total">未提供', page)
        self.assertIn('class="token-total">120,000', page)
        self.assertNotIn('class="currency">$</span>0.00', page)

    def test_unconnected_or_stale_empty_is_not_live_zero(self):
        for status in ("unconnected", "stale"):
            value = data()
            value["relay"].update(status=status, entries=[])
            self.assertIn('class="token-total missing-value">未提供', self.render(value))

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
