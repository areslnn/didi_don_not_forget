#!/usr/bin/env python3
"""Serve synthetic demo data on loopback; never access an account or a LAN interface."""
from pathlib import Path
import argparse
import datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import sys
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src/service'))
from shared.render import render_page


def demo():
    data = json.loads((ROOT / 'examples/demo.json').read_text(encoding='utf-8'))
    now = time.time()
    stamp = dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat(timespec='seconds')
    data['demo'] = True
    data['fetchedAt'] = stamp
    for name in ('account', 'system', 'starsg'):
        data[name]['updatedAt'] = stamp
    data['account']['windows'][0]['resetsAt'] = now + 4 * 86400
    for i, card in enumerate(data['account']['resetCredits']['credits']):
        card['expiresAt'] = now + (2 + i * 7) * 86400
    return data


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        port = self.server.server_port
        hosts = {f'127.0.0.1:{port}', f'localhost:{port}'}
        host = self.headers.get('Host', '').lower()
        origin = self.headers.get('Origin')
        if host not in hosts or (origin and origin not in {'http://' + h for h in hosts}):
            self.send_error(403); return
        route = urlsplit(self.path).path
        if route in ('/', '/display', '/kindle'):
            body = render_page(demo(), 'kindle' if route == '/kindle' else 'display').encode()
            mime = 'text/html; charset=utf-8'
        elif route in ('/display.css', '/display.js'):
            body = (ROOT / 'src/service/shared' / route[1:]).read_bytes()
            mime = ('text/css' if route.endswith('.css') else 'text/javascript') + '; charset=utf-8'
        else:
            self.send_error(404); return
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8780)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print(f'虚构数据预览：http://127.0.0.1:{args.port}/display', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
