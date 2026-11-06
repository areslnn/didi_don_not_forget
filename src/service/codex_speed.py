"""Local-only, post-response Codex output-rate estimates.

Only whitelisted timestamps and token counts leave this module. It never starts
inference, reads auth, writes a rollout, or estimates tokens from characters.
"""
from __future__ import annotations

import collections
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import stat
import threading
import time
import uuid

MAX_SAFE_INTEGER = (1 << 53) - 1
MAX_LINE_BYTES = 2 * 1024 * 1024
INITIAL_TAIL_BYTES = 2 * 1024 * 1024
MAX_POLL_BYTES = 4 * 1024 * 1024
MAX_SOURCE_FILES = 24
_ROOT_META_LIMIT = 256 * 1024
_NON_REALTIME = "近似值 · 回复完成后更新，非逐秒实时"


def _integer(value):
    return value if type(value) is int and 0 <= value <= MAX_SAFE_INTEGER else None


def _iso(value):
    try:
        return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat(timespec="milliseconds")
    except (ValueError, OverflowError, OSError, TypeError):
        return None


def _uuid(value):
    if not isinstance(value, str):
        return None
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        return None


def _open_regular(path):
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file")
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def _root_id(path):
    """Read only a bounded metadata header; unknown/subagent sources are skipped."""
    try:
        with _open_regular(path) as stream:
            line = stream.readline(_ROOT_META_LIMIT + 1)
        if len(line) > _ROOT_META_LIMIT or not line.endswith(b"\n"):
            return None
        record = json.loads(line)
        data = record.get("payload", {})
        if (record.get("type") != "session_meta" or not isinstance(data, dict)
                or data.get("thread_source") != "user"
                or data.get("source") not in ("vscode", "cli", "exec", "mcp")):
            return None
        return _uuid(data.get("id"))
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def _envelope_type(line):
    # Rollouts write their envelope type before payload. Do not decode unrelated
    # conversation/tool content just to discover its type.
    prefix = line[:4096].split(b'"payload"', 1)[0]
    match = re.search(br'"type"\s*:\s*"([A-Za-z_]+)"', prefix)
    return match.group(1).decode("ascii") if match else None


def _payload_type(line):
    header = line[:4096].split(b'"payload"', 1)
    if len(header) != 2:
        return None
    match = re.search(br'"type"\s*:\s*"([A-Za-z_]+)"', header[1])
    return match.group(1).decode("ascii") if match else None


class _ResponseParser:
    def __init__(self, thread_id):
        self.thread_id = thread_id
        self.seen = collections.OrderedDict()
        self.sample = None
        self.reset(False)

    def reset(self, synchronized=False):
        self.synchronized = synchronized
        self.messages = {}
        self.reasoning = {}
        self.blocked = False

    def feed(self, line, now):
        kind = _envelope_type(line)
        if kind == "response_item":
            subtype = _payload_type(line)
            # A model response can contain both a message and a tool invocation.
            # Its usage cannot then be attributed to the message alone.
            if subtype not in ("message", "reasoning", "function_call_output", "custom_tool_call_output",
                               "agent_message", "additional_tools"):
                self.blocked = True
            return  # Never decode/store conversation text or tool arguments.
        if kind == "compacted":
            self.reset(False)
            return
        if kind not in ("event_msg", "token_usage_record"):
            return
        if kind == "event_msg":
            subtype = _payload_type(line)
            if subtype not in ("task_started", "task_complete", "turn_aborted", "item_completed"):
                return
            if subtype == "item_completed":
                header = line[:4096].split(b'"item"', 1)
                if len(header) != 2 or not re.search(br'"type"\s*:\s*"(?:AgentMessage|Reasoning)"', header[1]):
                    return
        try:
            record = json.loads(line)
            data = record.get("payload")
            if not isinstance(data, dict):
                self.reset(False)
                return
        except (ValueError, TypeError, AttributeError):
            self.reset(False)
            return
        if kind == "token_usage_record":
            self._usage(data, now)
            self.reset(True)  # An explicit usage record is the next response boundary.
            return
        subtype = data.get("type")
        if subtype == "task_started":
            self.reset(True)
        elif subtype in ("task_complete", "turn_aborted"):
            self.reset(False)
        elif subtype == "item_completed":
            item = data.get("item")
            if not isinstance(item, dict):
                self.blocked = True
                return
            target = self.messages if item.get("type") == "AgentMessage" else self.reasoning
            item_id = item.get("id")
            interval = (_integer(data.get("started_at_ms")), _integer(data.get("completed_at_ms")), data.get("turn_id"))
            if (not isinstance(item_id, str) or not item_id or len(item_id) > 256
                    or None in interval[:2] or interval[1] <= interval[0]
                    or not isinstance(interval[2], str)):
                self.blocked = True
                return
            if item_id in target and target[item_id] != interval:
                self.blocked = True
            target[item_id] = interval
            if len(self.messages) + len(self.reasoning) > 128:
                self.blocked = True

    def _usage(self, data, now):
        response_id = data.get("response_id")
        if not isinstance(response_id, str) or not response_id or len(response_id) > 256:
            return
        if response_id in self.seen:
            return
        self.seen[response_id] = True
        if len(self.seen) > 2048:
            self.seen.popitem(last=False)
        if (not self.synchronized or self.blocked or len(self.messages) != 1
                or data.get("thread_id") != self.thread_id):
            return
        usage = data.get("usage")
        if not isinstance(usage, dict):
            return
        output = _integer(usage.get("output_tokens"))
        reasoning = _integer(usage.get("reasoning_output_tokens"))
        if output is None or reasoning is None or reasoning > output:
            return
        intervals = sorted(self.messages.values())
        reasoning_intervals = list(self.reasoning.values())
        turn_id = data.get("turn_id")
        if not isinstance(turn_id, str) or any(x[2] != turn_id for x in intervals + reasoning_intervals):
            return
        # Overlap, future timestamps, and reversed intervals cannot establish a
        # useful generation duration. Never substitute whole-turn/tool time.
        if any(right[0] < left[1] for left, right in zip(intervals, intervals[1:])):
            return
        if any(b[1] > intervals[0][0] for b in reasoning_intervals):
            # Reasoning after a message can be the next response when a usage
            # record was lost. There is no response ID on message timing events,
            # so this ambiguous ordering is deliberately not measured.
            return
        duration = sum(end - start for start, end, _ in intervals)
        latest = max(end for _, end, _ in intervals) / 1000.0
        earliest = min(start for start, _, _ in intervals) / 1000.0
        if duration <= 0 or latest > now + 2 or earliest < 0 or latest - earliest > 86400:
            return
        non_reasoning = output - reasoning
        # No non-reasoning output cannot provide a text generation speed. Keep
        # the preceding valid sample rather than inventing an idle 0 Token/s.
        if non_reasoning <= 0:
            return
        # The count can include response formatting, hence the permanent estimate
        # label.
        speed = non_reasoning / (duration / 1000.0)
        if not math.isfinite(speed) or speed < 0:
            return
        if self.sample is not None and latest <= self.sample["epoch"]:
            return
        self.sample = {"epoch": latest, "tokensPerSecond": round(speed, 2),
                       "outputTokens": non_reasoning, "outputDurationMs": duration,
                       "updatedAt": _iso(latest)}


class _FileTracker:
    def __init__(self, path, thread_id, initial_tail_bytes):
        self.path = path
        self.thread_id = thread_id
        self.parser = _ResponseParser(thread_id)
        self.initial_tail_bytes = initial_tail_bytes
        self.identity = None
        self.offset = 0
        self.buffer = b""
        self.drop_fragment = False

    def poll(self, now):
        with _open_regular(self.path) as stream:
            info = os.fstat(stream.fileno())
            identity = (info.st_dev, info.st_ino)
            if identity != self.identity or info.st_size < self.offset:
                if _root_id(self.path) != self.thread_id:
                    raise OSError("source identity changed")
                self.identity = identity
                self.offset = max(0, info.st_size - self.initial_tail_bytes)
                self.buffer = b""
                self.drop_fragment = self.offset > 0
                self.parser.reset(False)
            if info.st_size - self.offset > MAX_POLL_BYTES:
                # A large backlog is a gap, not a stream of measurements. Resume
                # from a bounded tail and require another response boundary.
                self.offset = max(0, info.st_size - self.initial_tail_bytes)
                self.buffer = b""
                self.drop_fragment = self.offset > 0
                self.parser.reset(False)
            stream.seek(self.offset)
            remaining = min(MAX_POLL_BYTES, max(0, info.st_size - self.offset))
            while remaining:
                chunk = stream.read(min(65536, remaining))
                if not chunk:
                    break
                self.offset += len(chunk)
                remaining -= len(chunk)
                self._consume(chunk, now)
        return True

    def _consume(self, chunk, now):
        data = self.buffer + chunk
        self.buffer = b""
        if self.drop_fragment:
            boundary = data.find(b"\n")
            if boundary < 0:
                return
            data = data[boundary + 1:]
            self.drop_fragment = False
        lines = data.split(b"\n")
        self.buffer = lines.pop()
        for line in lines:
            if not line:
                continue
            if len(line) > MAX_LINE_BYTES:
                self.parser.reset(False)
                continue
            self.parser.feed(line, now)
        if len(self.buffer) > MAX_LINE_BYTES:
            self.buffer = b""
            self.drop_fragment = True
            self.parser.reset(False)


class SpeedMonitor:
    """Observe a specific root conversation, or recent root conversations.

    thread_id=None follows the newest valid completed output among at most 24
    root logs selected by file modification time, including resumed old logs. `path` is a bounded
    explicit source for tests or a caller-selected local log; it never causes a
    scan outside that file. No paths or conversation identifiers enter snapshot().
    """
    def __init__(self, thread_id=None, sessions_root=None, path=None, clock=None,
                 poll_interval=1.0, initial_tail_bytes=INITIAL_TAIL_BYTES):
        self.thread_id = _uuid(thread_id)
        self.invalid_id = thread_id is not None and self.thread_id is None
        self.root = Path(sessions_root) if sessions_root is not None else Path.home() / ".codex" / "sessions"
        self.explicit_path = Path(path) if path is not None else None
        self.clock = clock or time.time
        self.poll_interval = max(0.05, float(poll_interval))
        self.initial_tail_bytes = max(64, min(int(initial_tail_bytes), MAX_POLL_BYTES))
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._thread = None
        self._trackers = {}
        self._next_discovery = 0.0
        self._sample = None
        self._sample_source = None
        self._last_now = None
        self._last_checked = None
        self._source_available = False
        self._healthy = False
        self._checked = False
        self._clock_fault = False

    def start(self):
        with self._lock:
            if self._thread and self._thread.is_alive():
                return
            self._stop.clear()
            self._thread = threading.Thread(target=self._run, name="codex-speed-local", daemon=True)
            self._thread.start()

    def stop(self):
        self._stop.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2)

    def _run(self):
        while not self._stop.is_set():
            try:
                self.poll()
            except Exception:
                # Never log an exception containing a local path or source data.
                with self._lock:
                    self._healthy = False
                    self._checked = True
            self._stop.wait(self.poll_interval)

    def _discover(self, now):
        if self.invalid_id:
            return {}
        if self.explicit_path is not None:
            paths = [self.explicit_path]
        elif self.thread_id:
            paths = list(self.root.glob("*/*/*/rollout-*-" + self.thread_id + ".jsonl"))[:4]
        else:
            # Only file metadata is enumerated across dates. A conversation can
            # resume months after creation while continuing to append to its old
            # date directory. Only bounded selected headers/tails are then read.
            paths = self.root.glob("*/*/*/rollout-*.jsonl")
        candidates = []
        for path in paths:
            try:
                info = path.lstat()
                if stat.S_ISREG(info.st_mode):
                    candidates.append((info.st_mtime_ns, path))
            except OSError:
                pass
        selected = {}
        for _, path in sorted(candidates, reverse=True)[:MAX_SOURCE_FILES * 4]:
            root_id = _root_id(path)
            if root_id is None or (self.thread_id is not None and root_id != self.thread_id):
                continue
            # File name and metadata must agree; explicit fixtures may use an
            # arbitrary filename but still need affirmative root metadata.
            if self.explicit_path is None and not path.name.endswith("-" + root_id + ".jsonl"):
                continue
            selected[path] = root_id
            if len(selected) == MAX_SOURCE_FILES:
                break
        return selected

    def poll(self):
        with self._lock:
            now = self.clock()
            if not isinstance(now, (int, float)) or isinstance(now, bool) or not math.isfinite(now) or _iso(now) is None:
                self._healthy = False
                self._checked = True
                return
            if self._last_now is not None and now < self._last_now - 1:
                self._clock_fault = True
                self._next_discovery = 0
                for tracker in self._trackers.values():
                    tracker.parser.reset(False)
                    tracker.parser.sample = None
            self._last_now = now
            self._last_checked = _iso(now)
            self._checked = True
            if now >= self._next_discovery or not self._trackers:
                selected = self._discover(now)
                self._trackers = {path: self._trackers.get(path) or _FileTracker(path, ident, self.initial_tail_bytes)
                                  for path, ident in selected.items()}
                self._next_discovery = now + 5
            successful = set()
            newest = None
            newest_source = None
            for path, tracker in self._trackers.items():
                try:
                    tracker.poll(now)
                    successful.add(path)
                    candidate = tracker.parser.sample
                    if candidate and (newest is None or candidate["epoch"] > newest["epoch"]):
                        newest = candidate
                        newest_source = path
                except (OSError, ValueError, TypeError):
                    continue
            if newest is not None and (self._sample is None or newest["epoch"] > self._sample["epoch"] or self._clock_fault):
                self._sample = dict(newest)
                self._sample_source = newest_source
                self._clock_fault = False
            self._source_available = self._sample_source in successful if self._sample else bool(successful)
            self._healthy = self._source_available and not self._clock_fault

    def snapshot(self):
        with self._lock:
            sample = self._sample or {}
            if not self._checked:
                status, detail = "waiting", "正在读取本机 Codex 记录 · " + _NON_REALTIME
            elif not self._healthy:
                status = "unavailable"
                reason = "本机时间有变化，等待新的有效记录" if self._clock_fault else "本机 Codex 记录暂不可读"
                detail = reason + ("；保留最近读数 · " if sample else " · ") + _NON_REALTIME
            elif sample:
                status, detail = "ready", _NON_REALTIME
                if self._last_now is not None and self._last_now - sample["epoch"] >= 60:
                    detail = "保留最近一次可测回复 · " + detail
            else:
                status, detail = "waiting", "等待可测的 Codex 文字回复 · " + _NON_REALTIME
            return {"status": status, "tokensPerSecond": sample.get("tokensPerSecond"),
                    "outputTokens": sample.get("outputTokens"), "outputDurationMs": sample.get("outputDurationMs"),
                    "updatedAt": sample.get("updatedAt"), "label": "最近回复均速", "detail": detail,
                    "scopeLabel": "当前对话" if self.thread_id is not None else "最近活跃对话",
                    "sourceAvailable": self._source_available, "monitorHealthy": self._healthy,
                    "lastCheckedAt": self._last_checked}
