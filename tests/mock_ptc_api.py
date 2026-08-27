#!/usr/bin/env python3
"""Minimal stand-in for the PTC API, enough to drive ptc-cli.sh 1.0.4 end to end.

Endpoints (all under /api/v1/):
    GET  languages                        -> preflight #1 (+ balance headers)
    GET  balance                          -> preflight #2 (plan/active/status)
    POST source_files                     -> upload            (201)
    PUT  source_files/process             -> start processing  (200)
    GET  source_files/translation_status  -> poll              (200 completed)
    GET  source_files/download_translations -> zip of translations
    POST detect_config                    -> `ptc init` layout detection

Knobs (env):
    PTC_MOCK_PORT     default 8787
    PTC_MOCK_LOCALES  comma-separated target locales, default "de,fr"
    PTC_MOCK_PENDING  how many status polls answer "in_progress" before
                      "completed" (per file). Default 0.
    PTC_MOCK_LOG      path to append a one-line-per-request journal.
"""
import io
import json
import os
import sys
import zipfile
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PTC_MOCK_PORT", "8787"))
# Loopback by default: binding 0.0.0.0 on a hosted macOS runner is refused by
# the firewall, and the suite then skipped itself while the job stayed green.
# Everything that talks to this mock is on the same host - under act the job
# container shares the VM's network namespace, so 127.0.0.1 reaches it there
# too. Override with PTC_MOCK_BIND if something ever needs the wider bind.
BIND = os.environ.get("PTC_MOCK_BIND", "127.0.0.1")
LOCALES = [x for x in os.environ.get("PTC_MOCK_LOCALES", "de,fr").split(",") if x]
PENDING = int(os.environ.get("PTC_MOCK_PENDING", "0"))
LOGFILE = os.environ.get("PTC_MOCK_LOG", "")

# One process, one port per scenario, so a workflow picks a failure mode purely
# by the api-url it passes — no restart, no shared mutable state.
#   +0  happy      everything works
#   +1  bad_token  every authenticated call answers 401 -> preflight must abort
#   +2  failed     translation_status answers the terminal "failed" status
#   +3  no_detect  detect_config answers kind:"any" with no files
#   +4  soft_fail  upload answers 201 but with "success": false
SCENARIOS = ["happy", "bad_token", "failed", "no_detect", "soft_fail"]

poll_counts = defaultdict(int)


def journal(line):
    sys.stderr.write(line + "\n")
    sys.stderr.flush()
    if LOGFILE:
        with open(LOGFILE, "a") as fh:
            fh.write(line + "\n")


def make_zip(file_path):
    """A translations archive: one file per target locale, named after the
    source file with the locale substituted, as the real API returns."""
    base = os.path.basename(file_path)          # en.json
    stem, ext = os.path.splitext(base)          # en, .json
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for loc in LOCALES:
            name = f"{loc}{ext}" if stem in ("en", "source") else f"{stem}-{loc}{ext}"
            payload = {
                "greeting": f"[{loc}] Hello",
                "farewell": f"[{loc}] Goodbye",
                "_mock": True,
            }
            z.writestr(name, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mock-ptc/1"
    scenario = "happy"

    def log_message(self, fmt, *args):  # silence the default noisy logger
        pass

    # ---------- helpers ----------
    def _auth(self):
        return self.headers.get("Authorization", "")

    def _send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # The balance headers ride on every /api/v1 response (CLI reads them
        # off the `languages` call during preflight).
        self.send_header("X-PTC-TRIAL-BALANCE", "12000")
        self.send_header("X-PTC-PREPAID-BALANCE", "50000")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, code, obj, extra=None):
        self._send(code, json.dumps(obj), "application/json", extra)

    def _path(self):
        u = urlparse(self.path)
        p = u.path
        for prefix in ("/api/v1/", "/api/v1"):
            if p.startswith(prefix):
                p = p[len(prefix):]
                break
        return p.strip("/"), parse_qs(u.query)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(n) if n else b""

    def _need_token(self):
        if self.scenario == "bad_token":
            self._json(401, {"success": False, "message": "token rejected", "errors": [401]})
            return True
        if not self._auth().startswith("Bearer "):
            self._json(401, {"success": False, "message": "missing token", "errors": [401]})
            return True
        return False

    # ---------- verbs ----------
    def do_GET(self):
        route, q = self._path()
        journal(f"GET  /{route}  q={ {k: v[0] for k, v in q.items()} }  auth={'yes' if self._auth() else 'no'}")

        if route == "languages":
            if self._need_token():
                return
            return self._json(200, {
                "source_language": {"iso": "en", "name": "English"},
                "languages": [{"iso": l, "name": l.upper()} for l in LOCALES],
            })

        if route == "balance":
            if self._need_token():
                return
            return self._json(200, {"plan": "pro", "active": True, "status": "unlimited",
                                    "trial_balance": 12000, "prepaid_balance": 50000})

        if route == "source_files/translation_status":
            if self._need_token():
                return
            fp = q.get("file_path", [""])[0]
            if self.scenario == "failed":
                return self._json(200, {"translation_status": {
                    "status": "failed", "completeness": 0}})
            poll_counts[(self.scenario, fp)] += 1
            if poll_counts[(self.scenario, fp)] <= PENDING:
                return self._json(200, {"translation_status": {
                    "status": "in_progress", "completeness": 40}})

            return self._json(200, {"translation_status": {
                "status": "completed", "completeness": 100}})

        if route == "source_files/download_translations":
            if self._need_token():
                return
            fp = q.get("file_path", [""])[0]
            blob = make_zip(fp)
            journal(f"     -> zip {len(blob)} bytes for {fp} ({','.join(LOCALES)})")
            return self._send(200, blob, "application/zip")

        return self._json(404, {"success": False, "message": f"no route {route}", "errors": [404]})

    def do_POST(self):
        route, q = self._path()
        body = self._body()
        journal(f"POST /{route}  {len(body)}B  auth={'yes' if self._auth() else 'no'}")

        if route == "source_files":
            if self._need_token():
                return
            if self.scenario == "soft_fail":
                # A 201 that still carries "success": false is a
                # rejected upload dressed as a created one.
                return self._json(201, {"success": False, "message": "content rejected",
                                        "errors": [4201]})
            return self._json(201, {"success": True, "id": 1, "message": "created"})

        if route == "detect_config":
            if self.scenario == "no_detect":
                return self._json(200, {"kind": "any", "source_locale": "en", "files": [],
                                        "available_locales": LOCALES})
            # anonymous by design
            try:
                paths = json.loads(body or b"{}").get("file_paths", [])
            except Exception:
                paths = []
            src = next((p for p in paths if p.endswith("/en.json") or p.endswith("en.json")), None)
            if not src:
                return self._json(200, {"kind": "any", "source_locale": "en", "files": [],
                                        "available_locales": LOCALES})
            out = src.replace("en.json", "{{lang}}.json")
            return self._json(200, {
                "kind": "json-locale-files",
                "source_locale": "en",
                "available_locales": LOCALES,
                "files": [{"file": src, "output": out}],
            })

        return self._json(404, {"success": False, "message": f"no route {route}", "errors": [404]})

    def do_PUT(self):
        route, q = self._path()
        body = self._body()
        journal(f"PUT  /{route}  {len(body)}B  auth={'yes' if self._auth() else 'no'}")

        if route == "source_files/process":
            if self._need_token():
                return
            return self._json(200, {"success": True, "message": "processing started"})

        return self._json(404, {"success": False, "message": f"no route {route}", "errors": [404]})


if __name__ == "__main__":
    import threading

    servers = []
    for i, name in enumerate(SCENARIOS):
        cls = type(f"Handler_{name}", (Handler,), {"scenario": name})
        srv = ThreadingHTTPServer((BIND, PORT + i), cls)
        servers.append(srv)
        journal(f"mock PTC API  {BIND}:{PORT + i}  scenario={name}")
    journal(f"locales={LOCALES} pending={PENDING}")
    for srv in servers[1:]:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    servers[0].serve_forever()
