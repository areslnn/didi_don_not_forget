import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/service"))
"""Synthetic fixtures only: never read account data or actual conversations."""
import datetime as dt
import json
import math
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from codex_speed import SpeedMonitor, _ResponseParser, MAX_SOURCE_FILES

THREAD = "11111111-2222-4333-8444-555555555555"
OTHER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
NOW = 1_800_000_000.0
TURN = "fixture-turn"


def record(kind, payload):
    return (json.dumps({"timestamp": "2027-01-15T08:00:00.000Z", "type": kind, "payload": payload}) + "\n").encode()


def metadata(thread=THREAD, root=True):
    return record("session_meta", {"id": thread, "source": "vscode", "thread_source": "user" if root else "subagent"})


def start():
    return record("event_msg", {"type": "task_started", "turn_id": TURN})


def item(ident="message", start_ms=None, end_ms=None, kind="AgentMessage", turn=TURN):
    return record("event_msg", {"type": "item_completed", "turn_id": turn,
        "item": {"type": kind, "id": ident, "content": "PRIVATE BODY NOT FOR DISPLAY", "phase": "final_answer"},
        "started_at_ms": int((NOW - 3) * 1000) if start_ms is None else start_ms,
        "completed_at_ms": int((NOW - 1) * 1000) if end_ms is None else end_ms})


def usage(ident="response", output=100, reasoning=20, thread=THREAD, turn=TURN):
    return record("token_usage_record", {"thread_id": thread, "turn_id": turn, "response_id": ident,
        "usage": {"output_tokens": output, "reasoning_output_tokens": reasoning, "input_tokens": 100000}})


class SpeedTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.path = self.root / "fixture.jsonl"
        self.clock = [NOW]
        self.monitors = []

    def tearDown(self):
        for monitor in self.monitors:
            monitor.stop()
        self.directory.cleanup()

    def monitor(self, **kwargs):
        defaults = dict(thread_id=THREAD, path=self.path, sessions_root=self.root, clock=lambda: self.clock[0])
        defaults.update(kwargs)
        result = SpeedMonitor(**defaults)
        self.monitors.append(result)
        return result

    def write(self, *parts):
        self.path.write_bytes(metadata() + b"".join(parts))

    def append(self, *parts):
        with self.path.open("ab") as stream:
            stream.write(b"".join(parts))

    def assert_waiting(self, monitor):
        monitor.poll()
        self.assertEqual(monitor.snapshot()["status"], "waiting")
        self.assertIsNone(monitor.snapshot()["tokensPerSecond"])

    def test_whitelisted_estimate_excludes_reasoning_and_preserves_original_time(self):
        self.write(start(), item(), usage())
        monitor = self.monitor(); monitor.poll(); value = monitor.snapshot()
        self.assertEqual(value["tokensPerSecond"], 40)
        self.assertEqual(value["outputTokens"], 80)
        self.assertEqual(value["outputDurationMs"], 2000)
        self.assertEqual(value["status"], "ready")
        self.assertIn("非逐秒实时", value["detail"])
        self.assertNotIn("PRIVATE", json.dumps(value))
        self.assertNotIn(THREAD, json.dumps(value))
        self.assertNotIn(str(self.root), json.dumps(value))
        self.clock[0] += 3600; monitor.poll()
        self.assertEqual(monitor.snapshot()["updatedAt"], value["updatedAt"])
        self.assertIn("保留最近", monitor.snapshot()["detail"])

    def test_partial_final_line_waits_for_newline_and_incremental_tail(self):
        raw = usage(); self.write(start(), item(), raw[:30])
        monitor = self.monitor(); self.assert_waiting(monitor)
        self.append(raw[30:-1]); self.assert_waiting(monitor)
        self.append(b"\n"); monitor.poll()
        self.assertEqual(monitor.snapshot()["tokensPerSecond"], 40)

    def test_tail_requires_a_complete_response_boundary(self):
        padding = record("response_item", {"type": "message", "role": "user", "content": "x" * 10000})
        self.write(padding, item(), usage())
        monitor = self.monitor(initial_tail_bytes=2000); self.assert_waiting(monitor)
        self.append(item(ident="next"), usage(ident="next")); monitor.poll()
        self.assertEqual(monitor.snapshot()["tokensPerSecond"], 40)

    def test_initial_cut_fragment_is_discarded(self):
        self.write(start(), item(), usage())
        monitor = self.monitor(initial_tail_bytes=64); self.assert_waiting(monitor)
        self.append(start(), item(), usage(ident="new")); monitor.poll()
        self.assertEqual(monitor.snapshot()["status"], "ready")

    def test_missing_usage_does_not_merge_separate_messages(self):
        self.write(start(), item(), item(ident="other", start_ms=int((NOW - .8)*1000), end_ms=int((NOW - .5)*1000)), usage())
        self.assert_waiting(self.monitor())

    def test_tool_response_is_not_a_text_speed_sample(self):
        for kind in ("function_call", "custom_tool_call", "web_search_call", "future_unknown_generated_item"):
            with self.subTest(kind=kind):
                self.write(start(), item(), record("response_item", {"type": kind, "arguments": "SECRET"}), usage())
                self.assert_waiting(self.monitor())

    def test_response_item_body_is_not_json_decoded(self):
        parser = _ResponseParser(THREAD)
        with patch("codex_speed.json.loads", side_effect=AssertionError("decoded body")):
            parser.feed(b'{"type":"response_item","payload":{"type":"message","content":"not even complete', NOW)
            parser.feed(b'{"type":"response_item","payload":{"type":"custom_tool_call","input":"private', NOW)
        self.assertTrue(parser.blocked)

    def test_tool_output_input_is_not_counted_as_generation(self):
        self.write(start(), record("response_item", {"type": "function_call_output", "output": "PRIVATE"}), item(), usage())
        monitor = self.monitor(); monitor.poll()
        self.assertEqual(monitor.snapshot()["tokensPerSecond"], 40)

    def test_invalid_counts_are_unknown_never_zero(self):
        for count in (None, -1, True, "100", 1.5, float("nan"), float("inf"), 1 << 54):
            with self.subTest(count=count):
                self.write(start(), item(), usage(output=count))
                self.assert_waiting(self.monitor())
        self.write(start(), item(), usage(output=10, reasoning=20))
        self.assert_waiting(self.monitor())

    def test_missing_reasoning_or_no_text_output_cannot_measure_speed(self):
        self.write(start(), item(), usage(reasoning=None)); self.assert_waiting(self.monitor())
        self.write(start(), item(), usage(output=0, reasoning=0))
        self.assert_waiting(self.monitor())

    def test_duplicate_response_id_cannot_replace_previous_sample(self):
        self.write(start(), item(), usage())
        monitor = self.monitor(); monitor.poll(); before = monitor.snapshot()
        self.append(start(), item(start_ms=int((NOW-.8)*1000),end_ms=int((NOW-.4)*1000)),usage(output=1000))
        monitor.poll()
        self.assertEqual(monitor.snapshot()["tokensPerSecond"], before["tokensPerSecond"])
        self.assertEqual(monitor.snapshot()["updatedAt"], before["updatedAt"])

    def test_timing_must_be_positive_current_and_nonoverlapping(self):
        for begin,end in [(0,0),(200,100),(True,200),(int(NOW*1000),int((NOW+10)*1000))]:
            with self.subTest(begin=begin,end=end):
                self.write(start(),item(start_ms=begin,end_ms=end),usage());self.assert_waiting(self.monitor())
        self.write(start(),item(),item(ident="reasoning",kind="Reasoning"),usage())
        self.assert_waiting(self.monitor())
        self.write(start(),item(),item(ident="second"),usage())
        self.assert_waiting(self.monitor())

    def test_separate_reasoning_interval_is_allowed_but_not_in_duration(self):
        self.write(start(),item(ident="r",kind="Reasoning",start_ms=int((NOW-10)*1000),end_ms=int((NOW-4)*1000)),item(),usage())
        monitor=self.monitor();monitor.poll();self.assertEqual(monitor.snapshot()["outputDurationMs"],2000)

    def test_reasoning_after_message_cannot_reuse_missing_usage_boundary(self):
        self.write(start(),item(),item(ident="next-response-thinking",kind="Reasoning",start_ms=int((NOW-.9)*1000),end_ms=int((NOW-.5)*1000)),usage())
        self.assert_waiting(self.monitor())

    def test_zero_new_output_keeps_last_valid_speed(self):
        self.write(start(),item(),usage());monitor=self.monitor();monitor.poll();before=monitor.snapshot()
        self.append(start(),item(start_ms=int((NOW-.8)*1000),end_ms=int((NOW-.4)*1000)),usage(ident="no-text",output=0,reasoning=0))
        monitor.poll();self.assertEqual(monitor.snapshot()["updatedAt"],before["updatedAt"])

    def test_turn_and_thread_must_match(self):
        self.write(start(),item(turn="other-turn"),usage());self.assert_waiting(self.monitor())
        self.write(start(),item(),usage(thread=OTHER));self.assert_waiting(self.monitor())

    def test_truncation_rotation_and_deleted_source_preserve_or_update_correctly(self):
        self.write(start(),item(),usage())
        monitor=self.monitor();monitor.poll();before=monitor.snapshot()
        self.path.unlink(); monitor.poll()
        self.assertEqual(monitor.snapshot()["status"],"unavailable")
        self.assertEqual(monitor.snapshot()["updatedAt"],before["updatedAt"])
        self.write(start(),item(start_ms=int((NOW-.8)*1000),end_ms=int((NOW-.4)*1000)),usage(ident="rotated"))
        monitor.poll();self.assertEqual(monitor.snapshot()["tokensPerSecond"],200)
        self.path.write_bytes(metadata());monitor.poll()
        self.append(start(),item(start_ms=int((NOW-.3)*1000),end_ms=int((NOW-.1)*1000)),usage(ident="truncated"))
        monitor.poll();self.assertEqual(monitor.snapshot()["tokensPerSecond"],400)

    def test_backward_clock_does_not_relabel_old_data_as_current(self):
        self.write(start(),item(),usage());monitor=self.monitor();monitor.poll();before=monitor.snapshot()
        self.clock[0]-=60;monitor.poll()
        self.assertFalse(monitor.snapshot()["monitorHealthy"])
        self.assertEqual(monitor.snapshot()["updatedAt"],before["updatedAt"])
        self.append(start(),item(start_ms=int((NOW-63)*1000),end_ms=int((NOW-61)*1000)),usage(ident="after-clock"))
        monitor.poll();self.assertEqual(monitor.snapshot()["status"],"ready")
        self.assertNotEqual(monitor.snapshot()["updatedAt"],before["updatedAt"])

    def test_nonfinite_clock_is_unavailable(self):
        self.write(start(),item(),usage());monitor=self.monitor();self.clock[0]=float("nan");monitor.poll()
        self.assertEqual(monitor.snapshot()["status"],"unavailable")

    def test_malformed_or_compacted_gap_requires_new_boundary(self):
        for gap in (b'{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage"}\n',record("compacted",{})):
            self.write(start(),gap,item(),usage());self.assert_waiting(self.monitor())

    def test_unknown_root_subagent_and_symlink_are_not_read(self):
        for meta in (metadata(root=False),record("session_meta",{"id":THREAD,"source":"vscode"})):
            self.path.write_bytes(meta+start()+item()+usage());monitor=self.monitor();monitor.poll()
            self.assertEqual(monitor.snapshot()["status"],"unavailable")
        self.path.unlink();target=self.root/'target';target.write_bytes(metadata()+start()+item()+usage());self.path.symlink_to(target)
        monitor=self.monitor();monitor.poll();self.assertFalse(monitor.snapshot()["sourceAvailable"])

    def create_log(self, thread, when, *, root=True, directory="2020/01/01", sample=True):
        path=self.root/directory/("rollout-2020-01-01T00-00-00-"+thread+".jsonl");path.parent.mkdir(parents=True,exist_ok=True)
        body=metadata(thread,root)+start()
        if sample:body+=item(start_ms=int((when-3)*1000),end_ms=int((when-1)*1000))+usage(ident=thread,thread=thread)
        path.write_bytes(body);os.utime(path,(when,when));return path

    def test_auto_follows_recent_output_even_in_old_directory(self):
        self.create_log(THREAD,NOW-10)
        self.create_log(OTHER,NOW)
        monitor=self.monitor(thread_id=None,path=None);monitor.poll()
        self.assertEqual(monitor.snapshot()["updatedAt"],dt.datetime.fromtimestamp(NOW-1,dt.timezone.utc).isoformat(timespec="milliseconds"))
        self.assertEqual(monitor.snapshot()["scopeLabel"],"最近活跃对话")

    def test_auto_excludes_subagent_and_bounds_source_files(self):
        for index in range(30):
            ident=f"11111111-2222-4333-8444-{index:012d}";self.create_log(ident,NOW-index)
        self.create_log(OTHER,NOW,root=False)
        monitor=self.monitor(thread_id=None,path=None);monitor.poll()
        self.assertEqual(len(monitor._trackers),MAX_SOURCE_FILES)
        self.assertTrue(all(t.thread_id!=OTHER for t in monitor._trackers.values()))

    def test_fixed_thread_does_not_follow_another_source(self):
        self.create_log(THREAD,NOW-10);self.create_log(OTHER,NOW)
        monitor=self.monitor(path=None);monitor.poll()
        self.assertEqual(len(monitor._trackers),1)
        self.assertEqual(monitor.snapshot()["scopeLabel"],"当前对话")

    def test_missing_sample_source_is_not_hidden_by_another_readable_file(self):
        path=self.create_log(THREAD,NOW);self.create_log(OTHER,NOW-5,sample=False)
        monitor=self.monitor(thread_id=None,path=None);monitor.poll();before=monitor.snapshot()
        path.unlink();monitor.poll()
        self.assertEqual(monitor.snapshot()["status"],"unavailable")
        self.assertEqual(monitor.snapshot()["updatedAt"],before["updatedAt"])

    def test_background_lifecycle_is_reversible_and_stops(self):
        self.write(start(),item(),usage());monitor=self.monitor(poll_interval=.05);monitor.start()
        deadline=time.monotonic()+2
        while monitor.snapshot()["status"]!="ready" and time.monotonic()<deadline:time.sleep(.01)
        self.assertEqual(monitor.snapshot()["status"],"ready");monitor.stop()
        self.assertFalse(monitor._thread.is_alive());monitor.start();monitor.stop();self.assertFalse(monitor._thread.is_alive())


if __name__ == "__main__":
    unittest.main()
