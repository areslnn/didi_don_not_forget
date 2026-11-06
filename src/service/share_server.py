#!/usr/bin/env python3
"""Read-only, paired LAN display bridge. No account authentication is accessed."""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import hmac
import http.client
from http.cookies import SimpleCookie, CookieError
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import threading
import time
import uuid
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
SESSION_SECONDS = 30 * 24 * 60 * 60
COOKIE_NAME = "gpt_display_session"
MAX_SAFE_INTEGER = (1 << 53) - 1
MAX_RELAY_ENTRIES = 1000
MAX_RELAY_CACHE_BYTES = 2 * 1024 * 1024
PRIVATE_NETWORKS = tuple(ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def timestamp(value):
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        date = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return date.timestamp() if date.tzinfo else None
    except (ValueError, OverflowError):
        return None


def date_string(value):
    return value if timestamp(value) is not None else None


def number(value, minimum=0, maximum=None):
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        return None
    if value < minimum or (maximum is not None and value > maximum):
        return None
    try:
        if not math.isfinite(value):
            return None
    except OverflowError:
        return None
    return value


def text(value, limit=160):
    if not isinstance(value, str):
        return None
    return "".join(c for c in value[:limit] if c >= " " and c != "\x7f")


def mapping(value):
    return value if isinstance(value, dict) else {}


def boolean(value):
    return value if isinstance(value, bool) else None


def private_ipv4(value, allow_loopback=False):
    try:
        address = ipaddress.IPv4Address(value)
        return any(address in network for network in PRIVATE_NETWORKS) or (allow_loopback and address.is_loopback)
    except ipaddress.AddressValueError:
        return False


def safe_account(value, now=None):
    value = mapping(value)
    now = time.time() if now is None else now
    updated = date_string(value.get("updatedAt"))
    status = value.get("status")
    if status not in ("live", "stale", "unavailable"):
        status = "unavailable"
    if status == "live" and (not updated or not -60 <= now - timestamp(updated) <= 360):
        status = "stale" if updated else "unavailable"
    windows = []
    for row in (value.get("windows") if isinstance(value.get("windows"), list) else [])[:30]:
        row = mapping(row)
        windows.append({
            "key": text(row.get("key")), "label": text(row.get("label")),
            "usedPercent": number(row.get("usedPercent")),
            "remainingPercent": number(row.get("remainingPercent"), maximum=100),
            "windowDurationMins": number(row.get("windowDurationMins")),
            "resetsAt": number(row.get("resetsAt")),
        })
    reset = mapping(value.get("resetCredits"))
    credits = []
    for row in (reset.get("credits") if isinstance(reset.get("credits"), list) else [])[:100]:
        row = mapping(row)
        credits.append({"expiresAt": number(row.get("expiresAt")),
                        "status": text(row.get("status"), 40), "title": text(row.get("title"))})
    return {"status": status, "updatedAt": updated, "planType": text(value.get("planType"), 40),
            "windows": windows, "resetCredits": {"availableCount": number(reset.get("availableCount")), "credits": credits},
            "error": None if status == "live" else "额度暂未同步，请在 Mac 检查连接。"}


def safe_system(value):
    value = mapping(value)
    result = {"updatedAt": date_string(value.get("updatedAt")),
              "uptimeSeconds": number(value.get("uptimeSeconds")),
              "temperatureC": number(value.get("temperatureC"), minimum=-20, maximum=150)}
    for key in ("cpu", "gpu"):
        source = mapping(value.get(key))
        result[key] = {"name": text(source.get("name")), "cores": number(source.get("cores")),
                       "usagePercent": number(source.get("usagePercent"), maximum=100)}
    for key in ("memory", "disk"):
        source = mapping(value.get(key))
        result[key] = {"usedBytes": number(source.get("usedBytes")), "totalBytes": number(source.get("totalBytes"))}
    memory = mapping(value.get("memory"))
    result["memory"].update(pressure=text(memory.get("pressure"), 40), estimated=boolean(memory.get("estimated")))
    battery = mapping(value.get("battery"))
    result["battery"] = {"percent": number(battery.get("percent"), maximum=100),
                         "present": boolean(battery.get("present")), "charging": boolean(battery.get("charging")),
                         "onAC": boolean(battery.get("onAC"))}
    return result


def read_json(path, limit=256_000):
    try:
        with Path(path).open("rb") as stream:
            raw = stream.read(limit + 1)
        return mapping(json.loads(raw)) if len(raw) <= limit else {}
    except (OSError, ValueError, UnicodeError):
        return {}


def safe_integer(value):
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= MAX_SAFE_INTEGER:
        return value
    return None


def connection_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value):
        return None
    return str(uuid.UUID(value))


def safe_relay(cache, diagnostic, config, now=None):
    """Publish optional metrics only for the currently configured connection."""
    now = time.time() if now is None else now
    cache, diagnostic, config = mapping(cache), mapping(diagnostic), mapping(config)
    empty = {"status": "unconnected", "updatedAt": None, "periodLabel": "用量统计",
             "sourceLabel": "中转站", "entries": [], "error": "请在 Mac 组件配置中转站。"}
    expected_id = connection_id(config.get("connectionID"))
    if expected_id is None or connection_id(cache.get("connectionID")) != expected_id:
        return empty
    captured = timestamp(cache.get("capturedAt"))
    cache_status = cache.get("status")
    if captured is None or captured > now + 60 or cache_status not in ("live", "stale", "snapshot"):
        return empty
    raw_entries = cache.get("entries")
    if not isinstance(raw_entries, list) or len(raw_entries) > MAX_RELAY_ENTRIES:
        return empty
    if not raw_entries and cache_status != "live":
        return empty  # Only a successful complete snapshot establishes no usage.
    entries = []
    for row in raw_entries:
        row = mapping(row)
        name = text(row.get("name"), 200)
        if not name or not name.strip():
            return empty
        input_tokens = safe_integer(row.get("inputTokens"))
        output_tokens = safe_integer(row.get("outputTokens"))
        total_tokens = safe_integer(row.get("totalTokens"))
        if total_tokens is None and input_tokens is not None and output_tokens is not None:
            total_tokens = safe_integer(input_tokens + output_tokens)
        amount = number(row.get("amountUSD"), maximum=1e12)
        entries.append({"name": name, "calls": safe_integer(row.get("calls")),
                        "inputTokens": input_tokens, "outputTokens": output_tokens, "totalTokens": total_tokens,
                        "amountUSD": amount, "sharePercent": None})
    if entries and all(row["amountUSD"] is not None for row in entries):
        total = sum(row["amountUSD"] for row in entries)
        if math.isfinite(total) and total > 0:
            for row in entries:
                row["sharePercent"] = row["amountUSD"] / total * 100
    phase = diagnostic.get("phase")
    observed = timestamp(diagnostic.get("updatedAt"))
    # Status written separately can be newer than the last successful data file.
    # Never promote old values because the bridge itself has just refreshed.
    current_diagnostic = (connection_id(diagnostic.get("connectionID")) == expected_id
                          and observed is not None and captured - 1 <= observed <= now + 60)
    live = cache_status == "live" and now - captured <= 360 and current_diagnostic and phase == "live"
    error = None
    if not live:
        if current_diagnostic and phase == "unconnected":
            error = "中转站连接已失效，请在 Mac 组件检查设置或重新登录。"
        elif cache_status == "snapshot":
            error = "单次读取；请在 Mac 组件连接自动更新。"
        elif current_diagnostic and phase in ("loading", "reading", "preparing", "verifying_graph", "waiting_for_graph", "document_ready", "location_ready", "routing_to_usage"):
            error = "正在同步，保留最近读数；平台统计可能延迟。"
        else:
            error = "中转站同步暂缓，保留最近读数；请在 Mac 检查连接。"
    return {"status": "live" if live else "stale", "updatedAt": cache["capturedAt"],
            "periodLabel": text(cache.get("periodLabel"), 80) or "用量统计",
            "sourceLabel": text(cache.get("sourceLabel"), 80) or "中转站", "entries": entries, "error": error}


def local_endpoint(value):
    """Use an explicit loopback HTTP source, without redirects or proxies."""
    try:
        url = urlsplit(value)
        port = url.port or 8768
        if url.scheme != "http" or url.hostname not in ("127.0.0.1", "localhost") or url.username or url.password or url.query or url.fragment or url.path not in ("", "/"):
            raise ValueError("Invalid local summary source")
        if not 1 <= port <= 65535:
            raise ValueError("Invalid local summary port")
        return "127.0.0.1", port
    except (ValueError, TypeError):
        raise ValueError("A loopback HTTP summary source is required") from None


class DisplayData:
    """Pull only the local summary service and app-owned aggregate files."""
    def __init__(self, support, local_url="http://127.0.0.1:8768"):
        self.support = Path(support)
        self.local_host, self.local_port = local_endpoint(local_url)
        self.lock = threading.Lock()
        self.next_read = 0
        self.last_dashboard = {}
        self.cached = None

    def read_local(self):
        connection = http.client.HTTPConnection(self.local_host, self.local_port, timeout=2)
        try:
            connection.request("GET", "/api/dashboard", headers={"Host": f"{self.local_host}:{self.local_port}"})
            response = connection.getresponse()
            if response.status != 200 or response.getheader("X-Dashboard") != "gpt-mac-local":
                raise ValueError("Unexpected local service")
            raw = response.read(512_001)
            if len(raw) > 512_000:
                raise ValueError("Oversized local summary")
            result = json.loads(raw)
            if not isinstance(result, dict):
                raise ValueError("Invalid local summary")
            return {"account": safe_account(result.get("account")), "system": safe_system(result.get("system"))}
        finally:
            connection.close()

    def snapshot(self):
        with self.lock:
            if self.cached is not None and time.monotonic() < self.next_read:
                result = copy.deepcopy(self.cached)
                result["fetchedAt"] = utc_now()
                result["account"] = safe_account(result["account"])
                result["relay"] = self.read_relay()
                return result
            failed = False
            try:
                self.last_dashboard = self.read_local()
            except (OSError, ValueError, UnicodeError, http.client.HTTPException):
                failed = True
            account = safe_account(self.last_dashboard.get("account"))
            if failed:
                account["status"] = "stale" if account["updatedAt"] else "unavailable"
                account["error"] = "Mac 额度服务暂未连接，保留最近读数。"
            self.cached = {"fetchedAt": utc_now(), "account": account,
                           "system": safe_system(self.last_dashboard.get("system"))}
            self.next_read = time.monotonic() + 10
            result = copy.deepcopy(self.cached)
            result["relay"] = self.read_relay()
            return result

    def read_relay(self):
        # Read the configuration last and recheck on every response, including
        # cached Mac samples, so switching sites cannot publish the former site.
        cache = read_json(self.support / "relay-snapshot.json", MAX_RELAY_CACHE_BYTES)
        diagnostic = read_json(self.support / "relay-connection-state.json")
        config = read_json(self.support / "relay-config.json")
        return safe_relay(cache, diagnostic, config)


class PairingAuth:
    def __init__(self, config):
        if not isinstance(config, dict) or not re.fullmatch(r"[0-9]{8}", str(config.get("accessCode", ""))) or not isinstance(config.get("accessCode"), str):
            raise ValueError("Invalid pairing configuration")
        if not isinstance(config.get("sessionSecret"), str) or not re.fullmatch(r"[0-9a-fA-F]{64}", config["sessionSecret"]):
            raise ValueError("Invalid pairing configuration")
        self.code = config["accessCode"]
        self.secret = bytes.fromhex(config["sessionSecret"])
        self.failures = {}
        self.lock = threading.Lock()

    @classmethod
    def from_path(cls, path):
        path = Path(path)
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("Pairing configuration must be a user-owned 0600 file")
        return cls(read_json(path, 4096))

    def issue(self, now=None):
        now = int(time.time() if now is None else now)
        payload = f"v1.{now}.{secrets.token_hex(12)}"
        signature = hmac.new(self.secret, payload.encode("ascii"), hashlib.sha256).hexdigest()
        return payload + "." + signature

    def valid(self, token, now=None):
        if not isinstance(token, str) or len(token) > 160:
            return False
        match = re.fullmatch(r"v1\.([0-9]{1,12})\.([0-9a-f]{24})\.([0-9a-f]{64})", token)
        if not match:
            return False
        now = int(time.time() if now is None else now)
        issued = int(match.group(1))
        if not 0 <= now - issued < SESSION_SECONDS:
            return False
        payload, signature = token.rsplit(".", 1)
        expected = hmac.new(self.secret, payload.encode("ascii"), hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, signature)

    def pair(self, client, code, now=None):
        now = time.monotonic() if now is None else now
        with self.lock:
            self.failures = {ip: [t for t in attempts if now - t < 60]
                             for ip, attempts in self.failures.items() if any(now - t < 60 for t in attempts)}
            failures = self.failures.get(client, [])
            if len(failures) >= 5:
                return "limited"
            if re.fullmatch(r"[0-9]{8}", code) and hmac.compare_digest(code, self.code):
                self.failures.pop(client, None)
                return "ok"
            self.failures[client] = failures + [now]
            return "invalid"


def pairing_page(message="", view="display"):
    # Messages are fixed strings supplied by this module, never submitted values.
    return """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>连接桌面看板</title>
<style>body{background:#eee;color:#222;font:18px sans-serif;margin:8% auto;padding:24px;max-width:440px}h1{font-size:30px}input,button{font:inherit;box-sizing:border-box;width:100%;padding:14px;margin:8px 0;border:1px solid #444;border-radius:0}button{color:white;background:#222}small{line-height:1.7;color:#555}</style></head>
<body><h1>连接桌面看板</h1><p>输入 Mac 组件中显示的 8 位连接码。</p><p role="alert">""" + message + """</p>
<form method="post" action="/pair"><input type="hidden" name="view" value=""" + ('"kindle"' if view == "kindle" else '"display"') + """><label for="code">连接码</label><input id="code" name="code" type="text" inputmode="numeric" pattern="[0-9]{8}" maxlength="8" autocomplete="off" required><button type="submit">连接</button></form>
<small>请与 Mac 连接同一 Wi-Fi。连接后仅显示额度、用量汇总与电脑状态；此设备将记住连接 30 天。</small></body></html>"""


class DisplayServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, auth, data, renderer=None, resource_root=ROOT):
        self.auth = auth
        self.data = data
        self.resource_root = Path(resource_root)
        if renderer is None:
            from shared.render import render_page
            renderer = render_page
        self.renderer = renderer
        super().__init__(address, DisplayHandler)
        self.allowed_hosts = {f"{address[0]}:{self.server_port}", f"127.0.0.1:{self.server_port}"}

    def handle_error(self, request, client_address):
        pass  # No request paths, pairing codes, or session values in logs.


class DisplayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.reply(code, "请求无法处理。", "text/plain; charset=utf-8")

    def reply(self, status, body=b"", mime="text/plain; charset=utf-8", headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response_only(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'")
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            self.wfile.write(body)

    def allowed(self):
        if not private_ipv4(self.client_address[0], allow_loopback=True):
            return False
        hosts = self.headers.get_all("Host", [])
        if len(hosts) != 1 or hosts[0] not in self.server.allowed_hosts:
            return False
        origins = self.headers.get_all("Origin", [])
        if len(origins) > 1 or (origins and origins[0] != "http://" + hosts[0]):
            return False
        return self.headers.get("Sec-Fetch-Site", "") != "cross-site"

    def route(self):
        try:
            url = urlsplit(self.path)
            if url.scheme or url.netloc or url.query or url.fragment or not self.path.startswith("/") or self.path.startswith("//"):
                return None
            return url.path
        except ValueError:
            return None

    def authenticated(self):
        raw = self.headers.get("Cookie", "")
        if len(raw) > 4096:
            return False
        try:
            cookies = SimpleCookie()
            cookies.load(raw)
            token = cookies.get(COOKIE_NAME)
            return bool(token and self.server.auth.valid(token.value))
        except CookieError:
            return False

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self.allowed():
            self.reply(403, "仅允许已连接的局域网设备访问。")
            return
        route = self.route()
        if route == "/health":
            self.reply(200, '{"service":"gpt-lan-display"}', "application/json; charset=utf-8")
            return
        routes = {"/", "/display", "/kindle", "/api/display", "/display.css", "/display.js"}
        if route not in routes:
            self.reply(404, "页面不存在。")
            return
        if not self.authenticated():
            if route in ("/", "/display", "/kindle"):
                self.reply(200, pairing_page(view="kindle" if route == "/kindle" else "display"), "text/html; charset=utf-8")
            else:
                self.reply(401, '{"error":"pairing_required"}', "application/json; charset=utf-8")
            return
        if route == "/":
            self.reply(303, headers={"Location": "/display"})
        elif route == "/api/display":
            self.reply(200, json.dumps(self.server.data.snapshot(), ensure_ascii=False, allow_nan=False), "application/json; charset=utf-8")
        elif route in ("/display", "/kindle"):
            body = self.server.renderer(self.server.data.snapshot(), mode="kindle" if route == "/kindle" else "display")
            self.reply(200, body, "text/html; charset=utf-8")
        else:
            path = self.server.resource_root / "shared" / route.lstrip("/")
            try:
                body = path.read_bytes()
            except OSError:
                self.reply(503, "页面资源暂未就绪。")
                return
            self.reply(200, body, "text/css; charset=utf-8" if route.endswith(".css") else "application/javascript; charset=utf-8")

    def do_POST(self):
        if not self.allowed():
            self.reply(403, "此请求来源不受支持。")
            return
        route = self.route()
        if route not in ("/pair", "/logout"):
            self.reply(404, "页面不存在。")
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,3}", lengths[0]) or int(lengths[0]) > 256:
            self.reply(400, "请求格式不正确。")
            return
        if self.headers.get_content_type() != "application/x-www-form-urlencoded":
            self.reply(415, "请求格式不正确。")
            return
        body = self.rfile.read(int(lengths[0]))
        if route == "/logout":
            if not self.authenticated():
                self.reply(401, "尚未连接。")
                return
            self.reply(303, headers={"Location": "/", "Set-Cookie": f"{COOKIE_NAME}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"})
            return
        view = "display"
        try:
            values = parse_qs(body.decode("ascii"), max_num_fields=2, strict_parsing=True)
            codes = values.get("code", [])
            views = values.get("view", ["display"])
            valid_view = len(views) == 1 and views[0] in ("display", "kindle")
            code = codes[0] if len(codes) == 1 and set(values) <= {"code", "view"} and valid_view else ""
            if valid_view:
                view = views[0]
        except (ValueError, UnicodeError):
            code = ""
        result = self.server.auth.pair(self.client_address[0], code)
        if result == "limited":
            self.reply(429, pairing_page("尝试次数较多，请 1 分钟后再试。", view), "text/html; charset=utf-8", {"Retry-After": "60"})
        elif result == "invalid":
            self.reply(403, pairing_page("连接码不正确，请查看 Mac 组件中的连接码。", view), "text/html; charset=utf-8")
        else:
            cookie = f"{COOKIE_NAME}={self.server.auth.issue()}; Path=/; Max-Age={SESSION_SECONDS}; HttpOnly; SameSite=Strict"
            self.reply(303, headers={"Location": "/" + view, "Set-Cookie": cookie})


def parent_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main():
    parser = argparse.ArgumentParser(description="Paired read-only LAN display")
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, default=8769)
    parser.add_argument("--parent-pid", type=int, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--local-url", default="http://127.0.0.1:8768")
    args = parser.parse_args()
    if not private_ipv4(args.bind) or not 1 <= args.port <= 65535 or args.parent_pid <= 1 or os.getppid() != args.parent_pid:
        parser.error("An explicit private IPv4 address and the current parent PID are required")
    try:
        auth = PairingAuth.from_path(args.config)
        data = DisplayData(args.config.parent, args.local_url)
        server = DisplayServer((args.bind, args.port), auth, data)
    except (OSError, ValueError, ImportError):
        parser.exit(1, "无法启动共享看板，请在 Mac 组件检查连接设置。\n")
    stopping = threading.Event()

    def request_stop(*_):
        stopping.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    def watch():
        while not stopping.wait(0.5):
            if os.getppid() != args.parent_pid or not parent_alive(args.parent_pid):
                stopping.set()
        server.shutdown()

    watcher = threading.Thread(target=watch, name="share-parent-watch", daemon=True)
    watcher.start()
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        stopping.set()
        server.server_close()


if __name__ == "__main__":
    main()
