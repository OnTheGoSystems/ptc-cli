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
    POST guide/sessions, GET guide/next, POST guide/submit, GET guide/status,
    POST guide/skip, POST guide/action_runs -> agent-guide protocol (ptc-cli 1.1.0)
         submit verdict = evidence["mock_verdict"] (default "accepted")
    POST guide/check {session_id, commit_sha} -> (ptc-cli 1.3.0) G8 gate: gs_pass / gs_fail / gs_norun (409) / 404
    POST guide/wait {task_id, timeout_s}   -> (ptc-cli 1.2.0) long-poll; by task id:
         gt_wait  "waiting" for PTC_MOCK_WAIT_ROUNDS calls (default 1), then accepted
         gt_never always "waiting"      gt_flaky  503 once, then accepted
         gt_rej   rejected              anything else: accepted at once
    action_runs answers {received, provenance, provenance_reason}: ci_id_token decoded (HS256 signature
         checked when PTC_MOCK_LAB_SECRET is set), claims repository|project_path and sha vs the body.

Knobs (env):
    PTC_MOCK_PORT     default 8787
    PTC_MOCK_LOCALES  comma-separated target locales, default "de,fr"
    PTC_MOCK_PENDING  how many status polls answer "in_progress" before
                      "completed" (per file). Default 0.
    PTC_MOCK_LOG      path to append a one-line-per-request journal.
    PTC_MOCK_PUSHES   1: guide answers carry `subscribe`, and `suggestion` when X-PTC-Pushes: shown (L11)
    PTC_MOCK_BODY_DIR directory where every guide request is saved as
                      <route>.json ({"headers":…, "body":…}) for assertions.
"""
import io
import json
import os
import re
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
# E20 knobs (comma-separated file_path lists): process answers 422 / translation_status answers "draft" or "rejected".
REJECT_PROCESS = {x for x in os.environ.get("PTC_MOCK_REJECT_PROCESS", "").split(",") if x}
DRAFT = {x for x in os.environ.get("PTC_MOCK_DRAFT", "").split(",") if x}
REJECTED = {x for x in os.environ.get("PTC_MOCK_REJECTED", "").split(",") if x}
# S2-R10 knobs (file_path lists): translation_status answers the over-limit approval states.
AWAITING_APPROVAL = {x for x in os.environ.get("PTC_MOCK_AWAITING_APPROVAL", "").split(",") if x}
APPROVAL_EXPIRED = {x for x in os.environ.get("PTC_MOCK_APPROVAL_EXPIRED", "").split(",") if x}
# S2-R28-3: files PTC paused out-of-credit (the status door's terminal out_of_credit, API-16).
OUT_OF_CREDIT = {x for x in os.environ.get("PTC_MOCK_OUT_OF_CREDIT", "").split(",") if x}
# S2-R3B F-2 knob (file_path list): translation_status answers "in_progress" forever (a first translation that outlives
# the CI job's monitor bound).
STILL_TRANSLATING = {x for x in os.environ.get("PTC_MOCK_STILL_TRANSLATING", "").split(",") if x}
# S2-R12 knobs (file_path lists): process answers a proxy-shaped 503 (an ngrok error page, no PTC JSON) -
# always, or only on the first call for that file.
PROCESS_503 = {x for x in os.environ.get("PTC_MOCK_PROCESS_503", "").split(",") if x}
PROCESS_503_ONCE = {x for x in os.environ.get("PTC_MOCK_PROCESS_503_ONCE", "").split(",") if x}
PROCESS_503_SEEN = set()
# S2-R19-1 knobs (file_path lists): translation_status answers a tunnel's 404 page (not PTC: an HTML body, no JSON) -
# on every poll (PTC could not be asked), or only on the first poll for that file (one transient failure).
STATUS_404 = {x for x in os.environ.get("PTC_MOCK_STATUS_404", "").split(",") if x}
STATUS_404_ONCE = {x for x in os.environ.get("PTC_MOCK_STATUS_404_ONCE", "").split(",") if x}
STATUS_404_SEEN = set()
# S2-R29-1 (API-13): files whose FIRST download answers 202 + Retry-After while the server builds the archive in the
# background (the per-file door never builds it inline); the next download answers the zip.
DOWNLOAD_BUILDING_ONCE = {x for x in os.environ.get("PTC_MOCK_DOWNLOAD_BUILDING_ONCE", "").split(",") if x}
DOWNLOAD_BUILDING_SEEN = set()
LOGFILE = os.environ.get("PTC_MOCK_LOG", "")

# One process, one port per scenario, so a workflow picks a failure mode purely
# by the api-url it passes — no restart, no shared mutable state.
#   +0  happy      everything works
#   +1  bad_token  every authenticated call answers 401 -> preflight must abort
#   +2  failed     translation_status answers the terminal "failed" status
#   +3  no_detect  detect_config answers kind:"any" with no files
#   +4  soft_fail  upload answers 201 but with "success": false
#   +5  old_cli    guide responses demand cli.min_version 99.0.0
SCENARIOS = ["happy", "bad_token", "failed", "no_detect", "soft_fail", "old_cli"]
BODY_DIR = os.environ.get("PTC_MOCK_BODY_DIR", "")
API_DONE = ("Setup is done; the delivery channel is the API: run `ptc sync` in the project directory to upload, translate and "
            "write the translations (and again after every change); no CI file and no push are needed.")
WAIT_ROUNDS = int(os.environ.get("PTC_MOCK_WAIT_ROUNDS", "1"))
WAIT_CALLS = defaultdict(int)
LAB_SECRET = os.environ.get("PTC_MOCK_LAB_SECRET", "")
# (L11, SF-31) the conversion pushes on guide answers (see _json).
PUSHES = os.environ.get("PTC_MOCK_PUSHES", "") == "1"
# (L11, SF-32) PTC_MOCK_REFUSE_PROCESS=1: every PUT source_files/process answers the trial cap's 402.
REFUSE_PROCESS = os.environ.get("PTC_MOCK_REFUSE_PROCESS", "") == "1"
PUSH_ROUTES = {"guide/next", "guide/wait", "guide/submit", "guide/skip", "guide/action_runs", "guide/delivery_commits"}


def provenance(body):
    """Mirror of PTC's P1 provenance decision, enough to exercise the CLI (no issuer key fetching)."""
    import base64, hashlib, hmac
    tok = body.get("ci_id_token")
    if not tok:
        return "unverified", "no CI identity token"
    try:
        h, c, sig = tok.split(".")
        pad = lambda x: x + "=" * (-len(x) % 4)
        header = json.loads(base64.urlsafe_b64decode(pad(h)))
        claims = json.loads(base64.urlsafe_b64decode(pad(c)))
    except Exception:
        return "unverified", "identity token is not a JWT"
    if LAB_SECRET:
        want = base64.urlsafe_b64encode(hmac.new(LAB_SECRET.encode(), f"{h}.{c}".encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
        if header.get("alg") != "HS256" or not hmac.compare_digest(want, sig):
            return "unverified", "identity token signature does not verify"
    if claims.get("aud") != "ptc":
        return "unverified", "identity token audience is not ptc"
    if claims.get("sha") != body.get("commit_sha"):
        return "unverified", "identity token sha does not match commit_sha"
    return "ci_verified", claims.get("repository") or claims.get("project_path")
TASK = {"id": "gt_1", "type": "repo_census", "stage": 0, "title": "Census the repository",
        "why": "PTC needs to know where the strings live.",
        "instructions": "Run the scan and submit its output.",
        "allowed_scope": ["**/*.yml"], "evidence_schema": {"type": "object"},
        "cli_commands": ["ptc scan --json > .ptc/scan.json", "ptc guide submit gt_1 --file .ptc/scan.json"],
        "ask_human": None}

poll_counts = defaultdict(int)
RUN_IDS = []  # (L3-1) action runs recorded, for run_id
# E23: file_path -> output_file_path as the upload sent it. The real API names each archive entry
# Translation#translated_filename: the output pattern with {{lang}} substituted, directories included.
OUTPUTS = {}


def record_upload(body):
    """Pull file_path/output_file_path out of an upload (multipart form or JSON body)."""
    text = body.decode("utf-8", "replace")
    fields = dict(re.findall(r'name="(file_path|output_file_path)"\r\n\r\n([^\r]*)\r\n', text))
    if not fields:
        try:
            doc = json.loads(text)
            fields = {k: doc.get(k, "") for k in ("file_path", "output_file_path")}
        except Exception:
            return
    if fields.get("file_path") and fields.get("output_file_path"):
        OUTPUTS[fields["file_path"]] = fields["output_file_path"]
        journal(f"     upload {fields['file_path']} -> output {fields['output_file_path']}")


# (L14, SF-41) a task whose ask carries PTC's draft (Guide::Tasks::ProjectDescription after the generator ran).
DESC_DRAFT = ("AI translation platform by OnTheGoSystems for developers who ship software in many languages.\n"
         "Readers: product managers and engineers.")
DRAFT_TASK = {"id": "gt_120", "type": "project_description", "stage": 3, "title": "Describe the product for translators",
              "why": "w", "instructions": "PTC wrote the description in ask_human.default. Show the human the draft verbatim.",
              "allowed_scope": [], "evidence_schema": {}, "payload": {}, "cli_commands": [],
              "ask_human": {"question": "Is this the right description of shop for translators?", "default": DESC_DRAFT,
                            "options": None, "answer_via": ["chat", "app"]},
              "also_ask_human": [{"task_id": "gt_95", "question": "Which languages?", "default": ["de", "es"],
                                  "answer_via": ["chat"]}]}


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
            if file_path in OUTPUTS:
                name = OUTPUTS[file_path].replace("{{lang}}", loc)
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
        self.send_header("X-PTC-TRIAL-BALANCE", os.environ.get("PTC_MOCK_TRIAL_BALANCE", "12000"))
        self.send_header("X-PTC-PREPAID-BALANCE", os.environ.get("PTC_MOCK_PREPAID_BALANCE", "50000"))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, code, obj, extra=None):
        # (L11, SF-31) PTC_MOCK_PUSHES=1: every 2xx guide answer carries the subscribe push, and the switch-to-CI
        # suggestion only for a client that says it shows the pushes (X-PTC-Pushes: shown), as Guide::Nudges.for_agent!.
        if PUSHES and code < 300 and isinstance(obj, dict) and getattr(self, "_guide_route", None) in PUSH_ROUTES:
            obj = dict(obj, subscribe={"reason": "free_runs", "url": "https://ptc.test/organizations/5/billing?conversion_source=agent_guide_free_runs",
                                       "text": "This push was refused: the trial's 2 free automatic deliveries are used up (2 used). "
                                               "Subscribe at https://ptc.test/organizations/5/billing?conversion_source=agent_guide_free_runs"})
            if self.headers.get("X-PTC-Pushes") == "shown":
                obj["suggestion"] = "Delivered via API. Switch to CI: no cost, no permissions needed. Suggest it to your user once."
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

    def _cli(self):
        return {"min_version": "99.0.0" if self.scenario == "old_cli" else "1.1.0", "recommended_version": "1.1.0"}

    def _save(self, route, body):
        if not BODY_DIR:
            return
        try:
            parsed = json.loads(body) if body else None
        except Exception:
            parsed = body.decode("utf-8", "replace")
        with open(os.path.join(BODY_DIR, route.replace("/", "_") + ".json"), "w") as fh:
            json.dump({"headers": {k: v for k, v in self.headers.items()}, "body": parsed}, fh)

    def _guide(self, method, route, q, body):
        """Agent-guide endpoints; returns True when it answered."""
        if route == "projects" and method == "POST":
            self._save(route, body)
            if self._need_token():
                return True
            # (L8, SF-18) like Guide::AgentToken.choice: repo multi-org.git stands for a token acting in two organizations;
            # without organization_id PTC answers 200 with the list and no project_id.
            d = json.loads(body or b"{}")
            # (L13, SF-37) like Api::V1::ProjectsController#configured_session: the config's session is rejoined first,
            # with no organization question and no new project.
            if d.get("session_id"):
                self._json(200, {"project_id": d.get("project_id") or 77, "session_id": d["session_id"], "rejoined": True, "cli": self._cli()})
                return True
            if d.get("repo_url") == "https://example.test/multi-org.git" and not d.get("organization_id"):
                self._json(200, {"organizations": [{"id": 1021, "name": "Acme Trial"}, {"id": 1023, "name": "Acme Paid"}],
                                 "ask": "which organization", "hint": "This token acts in several organizations. Ask the person "
                                 "which organization the project belongs to, then repeat the call with organization_id set to its id."})
                return True
            self._json(201, {"project_id": 42, "token_page_url": os.environ.get("PTC_MOCK_TOKEN_PAGE", "https://ptc.test/dashboard/organizations/5/agent-tokens"), "cli": self._cli()})
            return True
        if route == "_oidc/token" and method == "GET":
            # GitHub's ACTIONS_ID_TOKEN_REQUEST_URL stand-in: a JWT whose aud is the requested audience.
            self._save(route, body)
            import base64
            enc = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
            claims = {"iss": "https://token.actions.githubusercontent.com", "aud": q.get("audience", [""])[0],
                      "repository": "acme/app", "sha": q.get("sha", [""])[0]}
            self._json(200, {"value": enc({"alg": "RS256"}) + "." + enc(claims) + ".sig"})
            return True
        if not route.startswith("guide/"):
            return False
        self._guide_route = route
        self._save(route, body)
        journal(f"     guide {route} cli={self.headers.get('X-PTC-CLI-Version', '-')} ua={self.headers.get('User-Agent', '-')}")
        if self._need_token():
            return True
        cli = self._cli()
        if route == "guide/sessions" and method == "GET":
            if q.get("repo_url", [""])[0] == "https://example.test/known.git":
                self._json(200, {"session_id": "gs_found", "project_id": 77, "stage": 1, "readiness": 0.25, "cli": cli})
            else:
                self._json(404, {"error": "no open guide session for that repo_url", "cli": cli})
        elif route == "guide/sessions" and method == "POST":
            self._json(201, {"session_id": "gs_mock", "stage": 0, "readiness": 0.0, "cli": cli})
        elif route == "guide/next":
            sid = q.get("session_id", [""])[0]
            if sid == "gs_done":
                self._json(200, {"task": None, "done": True, "cli": cli})
            elif sid == "gs_done_api":
                # (L13, SF-36) an API-channel session's done names `ptc sync` (Guide::Tasks::DeliveryChannel::API_DONE_MESSAGE).
                self._json(200, {"task": None, "done": True, "message": API_DONE, "cli": cli})
            elif sid in ("9", "10"):
                # (L13, SF-37) which session the CLI asked for, by task id: gt_s9 / gt_s10.
                self._json(200, {"task": dict(TASK, id="gt_s" + sid), "cli": cli})
            elif sid == "gs_chat_only":
                # (L13, SF-38) an ask whose only door is the chat (the guide page is not visible to this member).
                self._json(200, {"task": dict(TASK, id="gt_95", type="target_languages", ask_human={
                    "question": "Which languages?", "options": None, "answer_via": ["chat"]}), "cli": cli})
            elif sid == "gs_page_too":
                self._json(200, {"task": dict(TASK, id="gt_96", type="target_languages", ask_human={
                    "question": "Which languages?", "options": None, "answer_via": ["chat", "app"]}), "cli": cli})
            elif sid == "gs_waiting":
                # Guide::Engine#next_task before the first report (T9): no task, not done, the step PTC waits on.
                self._json(200, {"task": None, "done": False, "cli": cli, "waiting":
                                 "PTC picks the strings to describe from a report of the repository. Before the CI workflow is "
                                 "committed, report your working tree: run `ptc guide action-run --project-id 7` in the "
                                 "repository root, then run `ptc guide next` again."})
            elif sid == "gs_suite":
                self._json(200, {"task": None, "done": False, "suite": True, "cli": cli, "products": [
                    {"dir": "pa", "session_id": "gs_pa", "project_id": 81, "state": "done", "readiness": 1.0},
                    {"dir": "pb", "session_id": "gs_pb", "project_id": 82, "state": "open", "readiness": 0.5}]})
            elif sid == "gs_named":
                # (L8, SF-22/SF-24) a source_fixes task naming code files, and an ask_human whose options are objects.
                self._json(200, {"task": dict(TASK, id="gt_54", type="source_fixes", payload={
                    "proposals": [{"id": "p1", "path": "app/files_import.js", "line": 2, "before": "a", "after": "b"}],
                    "readiness_manual": [{"id": "m1", "path": "app/trace.js"}]},
                    ask_human={"question": "Which channel?", "options": [
                        {"id": "ci", "label": "Add CI", "available": False, "reason": "no git host"},
                        {"id": "api", "label": "Deliver over the API", "available": True}]}), "cli": cli})
            elif sid == "gs_upload":
                # (L12, SF-33) the source_upload task: every census source path with the sha256 of PTC's stored upload
                # (PTC_MOCK_HELD_SHA for admin/en.json, none for locales/en.json).
                self._json(200, {"task": dict(TASK, id="gt_up", type="source_upload", cli_commands=["ptc guide upload-sources gt_up"],
                                              payload={"files": [{"path": "locales/en.json", "held_sha256": None},
                                                                 {"path": "admin/en.json", "held_sha256": os.environ.get("PTC_MOCK_HELD_SHA")}]}),
                                 "cli": cli})
            elif sid == "gs_draft":
                # (L14, SF-41) PTC's generated description draft in ask_human.default, and an also-ask with a default list.
                self._json(200, {"task": DRAFT_TASK, "cli": cli})
            elif sid == "gs_pb":
                self._json(200, {"task": dict(TASK, id="gt_9", type="commit_config"), "cli": cli})
            else:
                self._json(200, {"task": TASK, "cli": cli})
        elif route == "guide/status":
            self._json(200, {"stage": 0, "readiness": 0.25, "cli": cli,
                             "tasks": [{"id": "gt_1", "type": "repo_census", "state": "done", "verdict": "accepted"}],
                             "pending_ask_human": []})
        elif route in ("guide/submit", "guide/skip") and method == "POST":
            try:
                d = json.loads(body or b"{}")
            except Exception:
                return self._json(422, {"error": "body is not JSON"}) or True
            # (S2-F2 C-2) transient answers the CLI retries, by task id: gt_flaky 503 once; gt_down always 503;
            # gt_429ra 429 + Retry-After once; gt_429 a 429 with no Retry-After (final, not retried).
            tid = d.get("task_id")
            WAIT_CALLS[route + ":" + str(tid)] += 1
            n = WAIT_CALLS[route + ":" + str(tid)]
            if tid == "gt_down" or (tid == "gt_flaky" and n == 1):
                return self._json(503, {"error": "upstream timeout"}) or True
            if tid == "gt_429ra" and n == 1:
                return self._json(429, {"error": "rate limited"}, {"Retry-After": "1"}) or True
            if tid == "gt_429":
                return self._json(429, {"error": "rate limited"}) or True
            verdict = "skipped" if route == "guide/skip" else (d.get("evidence") or {}).get("mock_verdict", "accepted")
            reasons = [] if verdict in ("accepted", "skipped") else ["evidence does not match the census"]
            if d.get("task_id") == "gt_last":
                # (L13, SF-36) the answer that closed the last setup task on an API session: no next task, PTC's done message.
                return self._json(200, {"verdict": verdict, "reasons": reasons, "next": None, "done": True, "message": API_DONE, "cli": cli}) or True
            if d.get("task_id") == "gt_desc":
                # (L14, SF-41) the submit that made PTC write the draft: needs_more, the next task carries the draft.
                return self._json(200, {"verdict": "needs_more", "reasons": ["PTC wrote the description; ask the human to confirm it"],
                                        "next": DRAFT_TASK, "cli": cli}) or True
            if d.get("task_id") == "gt_accepted":
                # (P4E-4) a closed task: skip is answered like submit, rejected.
                verdict, reasons = "rejected", ["gt_accepted is already accepted"]
            self._json(200, {"verdict": verdict, "reasons": reasons, "next": TASK, "cli": cli})
        elif route == "guide/action_runs" and method == "POST":
            try:
                d = json.loads(body or b"{}")
            except Exception:
                d = {}
            # (S2-R3B C-1) like the server (authenticate_org_run!: params.require(:project_id)): an organization token
            # without a project is a 400; a project token needs none.
            if self._auth() == "Bearer org-token" and not d.get("project_id") and not self.headers.get("X-PTC-Project-Id"):
                return self._json(400, {"error": "param is missing or the value is empty: project_id"}) or True
            # (S2-F2 C-2) branch ptc-flaky-once: 503 on the first report, then 201.
            WAIT_CALLS["action_runs:" + str(d.get("branch"))] += 1
            if d.get("branch") == "ptc-flaky-once" and WAIT_CALLS["action_runs:ptc-flaky-once"] == 1:
                return self._json(503, {"error": "upstream timeout"}) or True
            prov, why = provenance(d)
            # (L3-1) like the door: an agent-local run without an identity token is recorded agent_local (the mock's
            # sessions are API sessions); the answer names the run and its key (commit sha, else "fp:<fingerprint>").
            if d.get("provenance_request") == "agent_local" and not d.get("ci_id_token"):
                prov, why = "agent_local", None
            RUN_IDS.append(len(RUN_IDS) + 1)
            key = d.get("commit_sha") or ("fp:" + str(d.get("workspace_fingerprint")))
            self._json(201, {"received": True, "run_id": RUN_IDS[-1], "run_key": key, "provenance": prov, "provenance_reason": why})
        elif route == "guide/delivery_commits" and method == "POST":
            # (ptc-cli 1.4.0, P4 T14) the translations-branch commit report: answers how many files it got.
            d = json.loads(body or b"{}")
            # (S2-F2 C-2) branch ptc/flaky: 503 on the first report, then 200; ptc/down: always 503.
            WAIT_CALLS["delivery_commits:" + str(d.get("branch"))] += 1
            if d.get("branch") == "ptc/down" or (d.get("branch") == "ptc/flaky" and WAIT_CALLS["delivery_commits:ptc/flaky"] == 1):
                return self._json(503, {"error": "upstream timeout"}) or True
            files = d.get("delivered_files_sha") or {}
            # (S2-R3B F-2) a run that stopped at its monitor bound reports the stop, with or without a commit.
            if d.get("stopped_reason") and not d.get("commit_sha"):
                return self._json(200, {"received": True, "stopped_reason": d["stopped_reason"], "cli": cli,
                                        "delivery_proof": {"effect": "none", "why": "the CI run stopped at its monitor bound while PTC was still translating; the delivery arrives from a later run"}}) or True
            out = {"received": True, "delivery_commit_id": 1, "matched": len(files), "reported": len(files), "cli": cli}
            if d.get("stopped_reason"):
                out["stopped_reason"] = d["stopped_reason"]
            # (S2-R14) a trusted report of PTC's delivery on the translations branch closes the proof; an older CLI's
            # `validate` is ignored (Guide::Tasks::DeliveryProof.on_delivery_report!).
            out["delivery_proof"] = {"effect": "closed", "task_id": "gt_mock_proof", "branch": d.get("branch"), "files": len(files)}
            if d.get("branch") == "ptc/untrusted":
                out["delivery_proof"] = {"effect": "none", "why": "an untrusted report (provenance unverified) never closes the delivery proof"}
            out["check"] = {"verdict": "pass", "reasons": [], "notes": [],
                            "comment": {"enabled": True, "marker": "<!-- ptc-agent-guide-findings -->",
                                        "body": "<!-- ptc-agent-guide-findings -->\n### PTC agent guide"}}
            self._json(200, out)
        elif route == "guide/check" and method == "POST":
            # (ptc-cli 1.3.0, G8) the gate verdict by session id: gs_pass / gs_fail / gs_norun (409) / else 404.
            d = json.loads(body or b"{}")
            sid = d.get("session_id")
            if sid in ("gs_pass", "gs_prod"):
                self._json(200, {"verdict": "pass", "reasons": [], "reasons_total": 0, "round": 1, "cli": cli})
            elif sid == "gs_fail":
                self._json(200, {"verdict": "fail", "reasons_total": 1, "round": 2, "cli": cli, "reasons": [
                    {"code": "under_specified_string", "file": "config/locales/en.yml", "key": "users.save", "path": "app/views/users/edit.html.erb",
                     "line": 7, "message": "app/views/users/edit.html.erb:7: new string `users.save` has no description or translator comment (short)"}]})
            elif sid == "gs_norun":
                self._json(409, {"verdict": "error", "error": {"code": "run_missing", "message": "no ptc-action run for dddddddddddd reached PTC yet: run the action first"}, "cli": cli})
            else:
                self._json(404, {"verdict": "error", "error": {"code": "no_session", "message": "no guide session with that session_id in this organization"}, "cli": cli})
        elif route == "guide/wait" and method == "POST":
            import time
            d = json.loads(body or b"{}")
            tid = d.get("task_id")
            WAIT_CALLS[tid] += 1
            n = WAIT_CALLS[tid]
            waiting = {"status": "waiting", "task_id": tid, "waited_s": 0, "cli": cli}
            if tid == "gt_never" or (tid == "gt_wait" and n <= WAIT_ROUNDS):
                time.sleep(min(float(d.get("timeout_s") or 0), 0.3))
                self._json(200, waiting)
            elif tid == "gt_flaky" and n == 1:
                self._json(503, {"error": "upstream timeout"})
            elif tid == "gt_desc":
                self._json(200, {"status": "changed", "verdict": "needs_more", "reasons": [], "next": DRAFT_TASK, "cli": cli})
            elif tid == "gt_rej":
                self._json(200, {"status": "changed", "verdict": "rejected", "reasons": ["the CI run's config differs from the one PTC generated"], "next": None, "cli": cli})
            else:
                self._json(200, {"status": "changed", "verdict": "accepted", "reasons": [], "next": TASK, "cli": cli})
        else:
            self._json(404, {"error": "no route"})
        return True

    # ---------- verbs ----------
    def do_GET(self):
        route, q = self._path()
        journal(f"GET  /{route}  q={ {k: v[0] for k, v in q.items()} }  auth={'yes' if self._auth() else 'no'}")
        if not route.startswith("guide/"):
            self._save("api_" + route, b"")
        if self._guide("GET", route, q, b""):
            return

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
            # PTC_MOCK_PREPAID_BALANCE: a prepaid-gated organization (status active, the wallets gate) with that balance.
            if os.environ.get("PTC_MOCK_PREPAID_BALANCE"):
                prepaid = int(os.environ["PTC_MOCK_PREPAID_BALANCE"])
                return self._json(200, {"plan": "prepaid", "active": True, "status": "active", "prepaid_gated": True,
                                        "trial_balance": 0, "prepaid_balance": prepaid, "balance_words": prepaid, "word_cost": 4})
            return self._json(200, {"plan": "pro", "active": True, "status": "unlimited",
                                    "trial_balance": 12000, "prepaid_balance": 50000,
                                    "word_cost": 4})

        if route == "source_files/translation_status":
            if self._need_token():
                return
            fp = q.get("file_path", [""])[0]
            if self.scenario == "failed":
                return self._json(200, {"translation_status": {
                    "status": "failed", "completeness": 0}})
            if fp in DRAFT:
                return self._json(200, {"translation_status": {"status": "draft", "completeness": 0}})
            if fp in REJECTED:
                return self._json(200, {"translation_status": {"status": "rejected", "completeness": 0}})
            if fp in AWAITING_APPROVAL:
                return self._json(200, {"translation_status": {"status": "awaiting_approval", "completeness": 0,
                                                               "terminal": False, "failure_reason": None}})
            if fp in APPROVAL_EXPIRED:
                return self._json(200, {"translation_status": {"status": "approval_expired", "completeness": 0,
                                                               "terminal": True, "failure_reason": "approval_expired"}})
            if fp in OUT_OF_CREDIT:
                return self._json(200, {"translation_status": {"status": "out_of_credit", "completeness": 0,
                                                               "terminal": True, "failure_reason": "out_of_credit"}})
            if fp in STATUS_404 or (fp in STATUS_404_ONCE and fp not in STATUS_404_SEEN):
                STATUS_404_SEEN.add(fp)
                return self._send(404, "<html><body>Tunnel 127.0.0.1 not found (ERR_NGROK_3200)</body></html>",
                                  "text/html", {"ngrok-error-code": "ERR_NGROK_3200"})
            poll_counts[(self.scenario, fp)] += 1
            if fp in STILL_TRANSLATING or poll_counts[(self.scenario, fp)] <= PENDING:
                return self._json(200, {"translation_status": {
                    "status": "in_progress", "completeness": 40}})

            return self._json(200, {"translation_status": {
                "status": "completed", "completeness": 100}})

        if route == "source_files/download_translations":
            if self._need_token():
                return
            fp = q.get("file_path", [""])[0]
            if fp in DOWNLOAD_BUILDING_ONCE and fp not in DOWNLOAD_BUILDING_SEEN:
                DOWNLOAD_BUILDING_SEEN.add(fp)
                journal(f"     -> 202 archive building for {fp}")
                body = json.dumps({"status": "processing", "retry_after": 1,
                                   "message": "The translations archive is being built. Please retry after the specified delay."})
                return self._send(202, body, "application/json", {"Retry-After": "1"})
            blob = make_zip(fp)
            journal(f"     -> zip {len(blob)} bytes for {fp} ({','.join(LOCALES)})")
            return self._send(200, blob, "application/zip")

        return self._json(404, {"success": False, "message": f"no route {route}", "errors": [404]})

    def do_POST(self):
        route, q = self._path()
        body = self._body()
        journal(f"POST /{route}  {len(body)}B  auth={'yes' if self._auth() else 'no'}")
        if not route.startswith("guide/") and route != "projects":
            self._save("api_" + route, b"")
        if self._guide("POST", route, q, body):
            return

        if route == "source_files":
            if self._need_token():
                return
            record_upload(body)
            if self.scenario == "soft_fail":
                # A 201 that still carries "success": false is a
                # rejected upload dressed as a created one.
                return self._json(201, {"success": False, "message": "content rejected",
                                        "errors": [4201]})
            return self._json(201, {"success": True, "id": 1, "message": "created"})

        if route == "source_files/estimate":
            # ci18-7252 dry-run quote (S2-R3 item 3), shaped as InsufficientCreditsResponse.from_quote answers it and
            # as spec/requests/api/v1/source_files_estimate_spec.rb pins it (test-estimate.sh checks the shape against
            # that spec). PTC_MOCK_ESTIMATE_WORDS source words per language (default 7) for every file, languages de, fr.
            if self._need_token():
                return
            import re as _re
            m = _re.search(rb'name="file_path"\r\n\r\n(.*?)\r\n', body)
            journal(f"estimate file_path={m.group(1).decode() if m else ''}")
            words = float(os.environ.get("PTC_MOCK_ESTIMATE_WORDS", "7"))
            per_lang = {"de": words, "fr": words}
            total = sum(per_lang.values())
            wallet = {"words_to_use": total, "credits_to_use": total * 4, "balance_sufficient": True}
            return self._json(200, {
                "allowed": True, "words_required": total, "credits_cost": total * 4,
                "trial": dict(wallet), "prepaid": dict(wallet, words_to_use=0, credits_to_use=0),
                "payg_bypass": False, "deficiency_details": {},
                "usage_estimate": {"words_required": total, "credits_cost": total * 4,
                                   "per_language_breakdown": per_lang, "metadata": {}},
            })

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
        self._save("api_" + route, b"")

        if route == "source_files/process":
            if self._need_token():
                return
            import re as _re
            m = _re.search(rb'name="file_path"\r\n\r\n(.*?)\r\n', body)
            fp = m.group(1).decode() if m else ""
            # (L12, SF-33) a store-only process (translate=false: stored, nothing translated) is journaled as such.
            t = _re.search(rb'name="translate"\r\n\r\n(.*?)\r\n', body)
            journal(f"     process {fp} translate={t.group(1).decode() if t else 'default'}")
            if fp in PROCESS_503 or (fp in PROCESS_503_ONCE and fp not in PROCESS_503_SEEN):
                PROCESS_503_SEEN.add(fp)
                return self._send(503, "<html><body>ERR_NGROK_3004: the upstream closed the connection</body></html>",
                                  "text/html", {"ngrok-error-code": "ERR_NGROK_3004"})
            if m and m.group(1).decode() in REJECT_PROCESS:
                return self._json(422, {"success": False, "message": "YAML aliases are not allowed", "errors": [422]})
            if REFUSE_PROCESS:
                # (L11, SF-32) TrialApiTranslationCap: the trial's free automatic deliveries are used up.
                url = "https://ptc.test/#/dashboard/organizations/5/billing?conversion_source=api_translation_cap"
                return self._json(402, {"success": False, "error": "Trial API translation limit reached", "error_code": 9024,
                                        "code": "TRIAL_API_TRANSLATIONS_EXHAUSTED", "limit": 2, "used": 2, "upgrade_url": url,
                                        "message": "Nothing was translated. Your trial's 2 free automatic deliveries are used up. "
                                                   "Upgrade to Pro at " + url + " to keep translating automatically."})
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
