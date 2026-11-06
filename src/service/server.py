#!/usr/bin/env python3
"""A private, read-only dashboard. Standard library only; no credentials are read.

Codex account data uses the documented account/rateLimits/read RPC through the
installed Codex app-server. It never starts a model turn or spends reset credits.
"""
from __future__ import annotations

import argparse
import copy
import ctypes
import datetime as dt
import json
import math
import mimetypes
import os
from pathlib import Path
import re
import select
import signal
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from codex_speed import SpeedMonitor

ROOT = Path(__file__).resolve().parent
ACCOUNT_INTERVAL = 300
SYSTEM_INTERVAL = 10
RPC_PROCESSES = set()
RPC_LOCK = threading.Lock()
STOPPING = threading.Event()


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def number(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return value
    return None


def window_label(minutes):
    if minutes == 10080:
        return "每周额度"
    if minutes == 300:
        return "5 小时额度"
    if minutes is None:
        return "额度窗口"
    if minutes >= 1440 and minutes % 1440 == 0:
        return f"{minutes // 1440:g} 天额度"
    if minutes >= 60 and minutes % 60 == 0:
        return f"{minutes // 60:g} 小时额度"
    return f"{minutes:g} 分钟额度"


def normalize_account(raw):
    """Keep missing values missing, and never confuse used with remaining."""
    buckets = raw.get("rateLimitsByLimitId")
    if not isinstance(buckets, dict) or not buckets:
        legacy = raw.get("rateLimits")
        buckets = {legacy.get("limitId") or "codex": legacy} if isinstance(legacy, dict) else {}
    windows, plans = [], []
    for bucket_id, bucket in buckets.items():
        if not isinstance(bucket, dict):
            continue
        if isinstance(bucket.get("planType"), str):
            plans.append(bucket["planType"])
        for key in ("primary", "secondary"):
            window = bucket.get(key)
            if not isinstance(window, dict):
                continue
            used = number(window.get("usedPercent"))
            duration = number(window.get("windowDurationMins"))
            label = window_label(duration)
            bucket_name = bucket.get("limitName") or bucket_id
            if bucket_id != "codex":
                label = f"{bucket_name} · {label}"
            windows.append({
                "key": f"{bucket_id}:{key}", "label": label,
                "usedPercent": used,
                "remainingPercent": max(0, min(100, 100 - used)) if used is not None else None,
                "windowDurationMins": duration,
                "resetsAt": number(window.get("resetsAt")),
            })
    reset = raw.get("rateLimitResetCredits")
    reset = reset if isinstance(reset, dict) else {}
    credits = []
    for item in reset.get("credits") or []:
        if isinstance(item, dict):
            credits.append({
                "expiresAt": number(item.get("expiresAt")),
                "status": item.get("status") if isinstance(item.get("status"), str) else None,
                "title": item.get("title") if isinstance(item.get("title"), str) else None,
            })
    return {
        "status": "live", "updatedAt": utc_now(),
        "planType": plans[0] if plans else None, "windows": windows,
        "resetCredits": {"availableCount": number(reset.get("availableCount")), "credits": credits},
        "error": None,
    }


def find_codex():
    # The desktop distribution may support newer account fields than global CLI.
    candidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        shutil.which("codex"),
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError("未找到 Codex，请先安装并登录 ChatGPT / Codex 桌面应用。")


def read_account():
    binary = find_codex()
    with RPC_LOCK:
        if STOPPING.is_set():
            raise RuntimeError("看板正在关闭。")
        proc = subprocess.Popen([binary, "app-server"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        RPC_PROCESSES.add(proc)
    buffer = b""

    def send(message):
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()

    def receive(request_id, timeout=35):
        nonlocal buffer
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                if message.get("id") == request_id:
                    if "error" in message:
                        # Do not echo arbitrary upstream diagnostics or personal data.
                        raise RuntimeError("暂时无法读取账号额度，请确认 Codex 已登录且网络可用。")
                    return message.get("result")
            ready, _, _ = select.select([proc.stdout], [], [], min(1, max(0, deadline-time.monotonic())))
            if ready:
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("无法连接 Codex，请确认桌面应用和登录状态正常。")
                buffer += chunk
                if len(buffer) > 8 * 1024 * 1024:
                    raise RuntimeError("Codex 返回了无法解析的数据。")
        raise RuntimeError("额度同步超时，请检查网络；稍后会自动重试。")

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {
            "name": "personal_usage_dashboard", "title": "Personal Usage Dashboard", "version": "1.0.0"}}})
        receive(1, 15)
        send({"method": "initialized"})
        send({"id": 2, "method": "account/rateLimits/read"})
        raw = receive(2)
        if not isinstance(raw, dict):
            raise RuntimeError("Codex 暂未返回可用的账号额度。")
        return normalize_account(raw)
    finally:
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        for stream in (proc.stdin, proc.stdout):
            if stream:
                stream.close()
        with RPC_LOCK:
            RPC_PROCESSES.discard(proc)


def command(args, timeout=5):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
        return result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def sysctl(key):
    return command(["/usr/sbin/sysctl", "-n", key])


def parse_memory(text, total):
    page_match = re.search(r"page size of (\d+) bytes", text)
    if not page_match or total is None:
        return None
    pages = {name.strip('"'): int(count) for name, count in re.findall(r"^([^:\n]+):\s+(\d+)\.", text, re.M)}
    required = ("Anonymous pages", "Pages wired down", "Pages occupied by compressor", "Pages purgeable")
    if not all(key in pages for key in required):
        return None
    # Same components as memory in use; reclaimable file cache is excluded.
    used = (pages[required[0]] + pages[required[1]] + pages[required[2]] - pages[required[3]]) * int(page_match[1])
    return max(0, min(total, used))


class SystemSampler:
    def __init__(self):
        self.cpu_name = sysctl("machdep.cpu.brand_string") or "Mac 处理器"
        self.cores = os.cpu_count()
        raw_total = sysctl("hw.memsize")
        self.total_memory = int(raw_total) if raw_total.isdigit() else None
        self.boot_time = None
        boot_match = re.search(r"sec\s*=\s*(\d+)", sysctl("kern.boottime"))
        if boot_match:
            self.boot_time = int(boot_match[1])
        self.gpu = {"name": None, "cores": None, "usagePercent": None}
        try:
            data = json.loads(command(["/usr/sbin/system_profiler", "SPDisplaysDataType", "-json"], 12))
            displays = data.get("SPDisplaysDataType", [])
            if displays:
                self.gpu["name"] = displays[0].get("sppci_model") or displays[0].get("_name")
                raw_cores = str(displays[0].get("sppci_cores", ""))
                self.gpu["cores"] = int(raw_cores) if raw_cores.isdigit() else None
        except (ValueError, TypeError, IndexError):
            pass
        self.last_cpu = None
        self.lib = None
        self.host = None
        try:
            self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            self.lib.mach_host_self.restype = ctypes.c_uint
            self.lib.host_statistics.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint)]
            self.lib.host_statistics.restype = ctypes.c_int
            self.host = self.lib.mach_host_self()
        except OSError:
            pass

    def cpu_usage(self):
        if self.lib is None:
            return None
        counters = (ctypes.c_int * 4)()
        count = ctypes.c_uint(4)
        if self.lib.host_statistics(self.host, 3, counters, ctypes.byref(count)) != 0:
            return None
        current = tuple(value & 0xffffffff for value in counters)
        previous, self.last_cpu = self.last_cpu, current
        if previous is None:
            return None
        deltas = [(a-b) & 0xffffffff for a, b in zip(current, previous)]
        total = sum(deltas)
        return round(100 * (total-deltas[2]) / total, 1) if total else None

    def sample(self):
        used = parse_memory(command(["/usr/bin/vm_stat"]), self.total_memory)
        disk = {"usedBytes": None, "totalBytes": None}
        try:
            disk_info = shutil.disk_usage("/")
            disk = {"usedBytes": disk_info.total-disk_info.free, "totalBytes": disk_info.total}
        except OSError:
            pass
        battery = {"percent": None, "charging": None, "present": False, "onAC": None}
        battery_text = command(["/usr/bin/pmset", "-g", "batt"])
        match = re.search(r"(\d+)%;", battery_text)
        if match:
            battery = {"percent": int(match[1]), "charging": "; charging;" in battery_text,
                       "present": True, "onAC": "'AC Power'" in battery_text}
        elif not battery_text:
            battery["present"] = None
        return {
            "updatedAt": utc_now(),
            "cpu": {"name": self.cpu_name, "usagePercent": self.cpu_usage(), "cores": self.cores},
            "memory": {"usedBytes": used, "totalBytes": self.total_memory, "pressure": None, "estimated": True},
            "disk": disk, "battery": battery,
            "uptimeSeconds": max(0, int(time.time()-self.boot_time)) if self.boot_time else None,
            "gpu": self.gpu.copy(), "temperatureC": None,
        }


class DashboardState:
    def __init__(self):
        self.speed_monitor = SpeedMonitor()
        self.lock = threading.Lock()
        self.refresh = threading.Event()
        self.last_request = 0
        self.account = {
            "status": "unavailable", "updatedAt": None, "planType": None, "windows": [],
            "resetCredits": {"availableCount": None, "credits": []}, "error": "正在连接账号…",
        }
        self.system = {"updatedAt": None, "cpu": {"name": "Mac", "usagePercent": None, "cores": None},
                       "memory": {"usedBytes": None, "totalBytes": None, "pressure": None, "estimated": True},
                       "disk": {"usedBytes": None, "totalBytes": None},
                       "battery": {"percent": None, "charging": None, "present": None, "onAC": None},
                       "uptimeSeconds": None, "gpu": {"name": None, "cores": None, "usagePercent": None}, "temperatureC": None}

    def start(self):
        self.speed_monitor.start()
        threading.Thread(target=self.account_loop, name="account-monitor", daemon=True).start()
        threading.Thread(target=self.system_loop, name="system-monitor", daemon=True).start()

    def account_loop(self):
        while not STOPPING.is_set():
            self.refresh.clear()
            with self.lock:
                self.last_request = time.monotonic()
            try:
                account = read_account()
                with self.lock:
                    self.account = account
            except Exception as exc:
                with self.lock:
                    self.account["status"] = "stale" if self.account["updatedAt"] else "unavailable"
                    self.account["error"] = str(exc) if isinstance(exc, RuntimeError) else "账号同步暂时失败，请检查 Codex 登录和网络。"
            self.refresh.wait(ACCOUNT_INTERVAL)

    def system_loop(self):
        sampler = SystemSampler()
        while not STOPPING.is_set():
            try:
                sample = sampler.sample()
                with self.lock:
                    self.system = sample
            except Exception:
                pass  # Last timestamp remains unchanged, so clients can mark stale.
            time.sleep(SYSTEM_INTERVAL)

    def request_refresh(self):
        with self.lock:
            if time.monotonic()-self.last_request >= 10:
                self.refresh.set()

    def snapshot(self):
        with self.lock:
            value = {"fetchedAt": utc_now(), "account": copy.deepcopy(self.account), "system": copy.deepcopy(self.system)}
        value["codexSpeed"] = self.speed_monitor.snapshot()
        return value


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "LocalDashboard/1.0"
    files = {"/": "index.html", "/index.html": "index.html", "/app.js": "app.js", "/styles.css": "styles.css", "/favicon.svg": "favicon.svg"}

    def log_message(self, *args):
        pass

    def allowed_request(self):
        port = self.server.server_port
        hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        if self.headers.get("Host", "").lower() not in hosts:
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in {"http://" + host for host in hosts}:
            return False
        return self.headers.get("Sec-Fetch-Site", "") != "cross-site"

    def reply(self, status, body, mime):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Dashboard", "gpt-mac-local")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self.allowed_request():
            return self.reply(403, b"Local access only", "text/plain; charset=utf-8")
        parsed = urlsplit(self.path)
        if parsed.path == "/api/health":
            return self.reply(200, b'{"service":"gpt-mac-dashboard"}', "application/json; charset=utf-8")
        if parsed.path == "/api/codex-speed":
            data = json.dumps(self.server.state.speed_monitor.snapshot(), ensure_ascii=False, allow_nan=False).encode()
            return self.reply(200, data, "application/json; charset=utf-8")
        if parsed.path == "/api/dashboard":
            if self.command == "GET" and parse_qs(parsed.query).get("refresh") == ["1"]:
                self.server.state.request_refresh()
            data = json.dumps(self.server.state.snapshot(), ensure_ascii=False, allow_nan=False).encode()
            return self.reply(200, data, "application/json; charset=utf-8")
        name = self.files.get(parsed.path)
        if name and (ROOT / name).is_file():
            mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
            return self.reply(200, (ROOT / name).read_bytes(), mime + "; charset=utf-8")
        return self.reply(404, b"Not found", "text/plain; charset=utf-8")


def close_rpc_processes():
    STOPPING.set()
    with RPC_LOCK:
        processes = list(RPC_PROCESSES)
    for proc in processes:
        if proc.poll() is None:
            proc.terminate()
    for proc in processes:
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


def watch_parent(parent_pid):
    while not STOPPING.wait(2):
        if os.getppid() != parent_pid:
            os.kill(os.getpid(), signal.SIGTERM)
            return


def interrupt_handler(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description="GPT 账号与 Mac 状态看板（仅本机）")
    parser.add_argument("--port", type=int, default=8768)
    parser.add_argument("--check", action="store_true", help="读取一次真实数据并退出")
    parser.add_argument("--parent-pid", type=int, default=None)
    args = parser.parse_args()
    if args.check:
        sampler = SystemSampler()
        sampler.sample()
        time.sleep(0.2)
        print(json.dumps({"account": read_account(), "system": sampler.sample()}, ensure_ascii=False, indent=2))
        return
    state = DashboardState()
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), DashboardHandler)
    except OSError:
        raise SystemExit(f"无法打开本地端口 {args.port}；看板可能已经在运行。")
    server.state = state
    try:
        signal.signal(signal.SIGTERM, interrupt_handler)
        if args.parent_pid:
            threading.Thread(target=watch_parent, args=(args.parent_pid,), daemon=True).start()
        state.start()
        print(f"看板已启动：http://127.0.0.1:{args.port}\n仅此 Mac 可访问。按 Control+C 停止。", flush=True)
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        state.speed_monitor.stop()
        close_rpc_processes()
        server.server_close()


if __name__ == "__main__":
    main()
