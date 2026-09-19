#!/usr/bin/env python3
"""Exercise a running, isolated Desktop through its real hooks and bundled MCP.

The caller starts Desktop with HOME=<fixture-home>, notifications and usage
enabled, and creates <fixture-home>/.petdex-integration-test-home containing
`petdex-integration-pipeline-v1\n`. No app is launched or stopped here.

Usage files and the notification killswitch are restored, including on failure.
Only fixed `petdex-integration-test-*` conversations are sent; their transient
cards finish idle and disappear when the caller closes the fixture Desktop.
Never point this at a real user home. Only marker-bearing temporary homes work.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path


BASE_URL = "http://127.0.0.1:7777"
MARKER = ".petdex-integration-test-home"
MARKER_CONTENT = "petdex-integration-pipeline-v1\n"
POLL_SECONDS = 2.0
SESSION = "petdex-integration-test-shared"
NATIVE_SESSION = "petdex-integration-test-native"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise AssertionError("the local fixture server must not redirect")


class Pipeline:
    def __init__(self, binary: Path, home: Path, node: str):
        self.binary = binary.resolve(strict=True)
        self.home = home.resolve(strict=True)
        temporary_roots = {Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()}
        require(
            any(root in self.home.parents for root in temporary_roots),
            "fixture HOME must be a directory below a temporary root",
        )
        require(self.home != Path.home().resolve(), "real/current user HOME is prohibited")
        require((self.home / MARKER).read_text() == MARKER_CONTENT, "fixture marker is missing or invalid")
        require(not (self.home / MARKER).is_symlink(), "fixture marker must not be a symlink")
        self.runtime = self.home / ".petdex/runtime"
        require(self.runtime.resolve().is_relative_to(self.home), "runtime directory escapes fixture HOME")
        token_path = self.runtime / "update-token"
        require(not token_path.is_symlink(), "fixture token must not be a symlink")
        self.token = token_path.read_text().strip()
        require(bool(self.token), "fixture app has not created an authentication token")
        self.node = node
        self.asset = Path(__file__).resolve().parents[1] / "src/assets/petdex-mcp-server.mjs"
        require(self.asset.is_file(), "bundled MCP asset is missing")
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(("PETDEX_", "CLAUDE_", "CODEX_", "GEMINI_", "GROK_", "COPILOT_", "JUNIE_", "QODER", "KIMI_", "HERMES_", "DSH_", "WARP_")):
                self.env.pop(key)
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "APPDATA": str(self.home / "AppData/Roaming"),
            "PETDEX_MCP_AGENT": "amp", "GEMINI_FORCE_FILE_STORAGE": "true",
        })
        self.completed: list[str] = []
        self.touched_sessions: set[tuple[str, str]] = set()

    def request(self, route: str, body=None, *, authenticated=True, timeout=1.0):
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["X-Petdex-Update-Token"] = self.token
        request = urllib.request.Request(
            BASE_URL + route,
            data=None if body is None else json.dumps(body).encode(),
            headers=headers,
        )
        try:
            with self.http.open(request, timeout=timeout) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def snapshot(self, timeout=1.0):
        status, body = self.request("/integrations", timeout=timeout)
        require(status == 200 and body.get("ok") is True, "fixture diagnostics are unavailable")
        return body

    def poll(self, description, predicate):
        started = time.monotonic()
        while True:
            remaining = POLL_SECONDS - (time.monotonic() - started)
            require(remaining > 0, description + " did not reach diagnostics within 2 seconds")
            snapshot = self.snapshot(timeout=min(1.0, remaining))
            if predicate(snapshot):
                require(time.monotonic() - started <= POLL_SECONDS, description + " exceeded 2 seconds")
                return snapshot
            time.sleep(min(0.1, max(0, remaining / 2)))

    def mcp(self, name, arguments):
        if name in ("petdex_set_state", "petdex_show_bubble"):
            self.touched_sessions.add((arguments["agent"], arguments["session_id"]))
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "petdex-integration-test", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": arguments}},
        ]
        child = subprocess.run(
            [self.node, str(self.asset)],
            input="\n".join(json.dumps(message) for message in messages),
            text=True, capture_output=True, timeout=6, env=self.env, cwd=self.home,
        )
        require(child.returncode == 0, "bundled Node MCP failed to exit successfully")
        replies = [json.loads(line) for line in child.stdout.splitlines() if line.strip()]
        results = [reply for reply in replies if reply.get("id") == 2]
        require(len(results) == 1 and "error" not in results[0], name + " returned a protocol error")
        result = results[0]["result"]
        require(not result.get("isError", False), name + " returned a tool failure")
        return result

    def native(self, phase, payload):
        self.touched_sessions.add(("amp", payload["session_id"]))
        child = subprocess.run(
            [str(self.binary), "bubble", phase, "amp"],
            input=json.dumps(payload), text=True, capture_output=True,
            timeout=4, env=self.env, cwd=self.home,
        )
        require(child.returncode == 0, "native hook runner failed")

    @staticmethod
    def usage(snapshot, agent):
        return next((row for row in snapshot.get("usage", []) if row.get("agent") == agent), {})

    @staticmethod
    def session(snapshot, agent, title):
        return next((row for row in snapshot["sessions"] if row.get("agent") == agent and row.get("title") == title), {})

    def passed(self, description):
        self.completed.append(description)
        print("PASS " + description, flush=True)

    def run(self):
        initial = self.snapshot()
        require(initial.get("usage_enabled") is True, "fixture Desktop must have Usage limits enabled")
        require(initial.get("notifications_enabled") is True, "fixture Desktop must initially enable notifications")
        status, _ = self.request("/usage/refresh", {}, authenticated=False)
        require(status == 401, "usage refresh accepted an unauthenticated request")
        self.passed("usage refresh requires the fixture token")

        resets_at = int(time.time()) + 3600
        result = self.mcp("petdex_report_usage", {"agent": "amp", "windows": [[37, resets_at, 300]]})
        require(result.get("structuredContent", {}).get("refresh_requested") is True, "MCP did not queue Desktop refresh")
        observed = self.poll("MCP usage", lambda data: self.usage(data, "amp").get("percent") == 37)
        row = self.usage(observed, "amp")
        require(row["windows"][0]["resets_at"] == resets_at and row["windows"][0]["minutes"] == 300, "usage reset/window metadata changed")
        require(abs(row["observed_at"] - time.time()) < 10, "usage observation timestamp was not fresh")
        status_result = self.mcp("petdex_status", {}).get("structuredContent", {})
        require(self.usage(status_result, "amp").get("percent") == 37, "MCP status did not expose Desktop usage")
        self.passed("bundled Node MCP usage reaches native diagnostics within 2 seconds")

        killswitch = self.runtime / "hooks-disabled"
        killswitch.write_text("1\n")
        try:
            self.mcp("petdex_report_usage", {"agent": "amp", "windows": [[41, resets_at, 300]]})
            self.poll("usage with notifications disabled", lambda data: data.get("notifications_enabled") is False and self.usage(data, "amp").get("percent") == 41)
        finally:
            killswitch.unlink(missing_ok=True)
        self.passed("usage remains independent of the notification killswitch")

        # No public MCP tool invents absolute credits; feed the same documented
        # observation file that native adapters write, then use the refresh API.
        credits_file = self.runtime / "usage/droid.json"
        temporary = credits_file.with_suffix(".pipeline.tmp")
        temporary.write_text(json.dumps({"observed_at": int(time.time()), "credits_used": 42.125, "credits_resets_at": resets_at, "windows": []}))
        temporary.replace(credits_file)
        status, refresh = self.request("/usage/refresh", {})
        require(status == 200 and refresh.get("queued") is True, "credits refresh failed")
        observed = self.poll("absolute credits", lambda data: self.usage(data, "droid").get("credits_used") == 42.125)
        row = self.usage(observed, "droid")
        require(row["percent"] is None and row["credits_resets_at"] == resets_at and row["windows"] == [], "absolute credits were misrepresented as a percentage")
        self.passed("absolute credits retain null percentage and their reset time")

        first = "petdex-integration-test-amp"
        second = "petdex-integration-test-droid"
        self.mcp("petdex_show_bubble", {"agent": "amp", "session_id": SESSION, "title": first, "text": "petdex-integration-test-working", "agent_state": "running", "busy": True, "model": "petdex-integration-test-model", "source_cwd": str(self.home)})
        self.mcp("petdex_show_bubble", {"agent": "droid", "session_id": SESSION, "title": second, "text": "petdex-integration-test-other", "busy": True})
        data = self.poll("isolated working cards", lambda snap: self.session(snap, "amp", first).get("busy") is True and self.session(snap, "droid", second).get("busy") is True)
        amp_key = self.session(data, "amp", first)["session_key"]
        require(amp_key != self.session(data, "droid", second)["session_key"], "equal host IDs collided across agents")
        self.mcp("petdex_set_state", {"agent": "amp", "session_id": SESSION, "state": "waiting"})
        data = self.poll("waiting card", lambda snap: self.session(snap, "amp", first).get("state") == "waiting" and self.session(snap, "amp", first).get("busy") is False)
        require(self.session(data, "amp", first)["session_key"] == amp_key, "state update created a second conversation")
        require(self.session(data, "amp", first)["model"] == "petdex-integration-test-model", "MCP state update erased host metadata")
        require(self.session(data, "droid", second)["busy"] is True, "waiting update changed another agent's card")
        self.mcp("petdex_show_bubble", {"agent": "amp", "session_id": SESSION, "text": "petdex-integration-test-complete", "busy": False})
        self.poll("completed card", lambda snap: self.session(snap, "amp", first).get("state") == "idle" and self.session(snap, "amp", first).get("busy") is False)
        self.passed("MCP working, waiting and completed cards preserve conversation isolation")

        native_title = "petdex-integration-test-native-title"
        self.native("pre", {"session_id": NATIVE_SESSION, "petdex_session_title": native_title, "tool_name": "Read", "tool_input": {"file_path": "fixture.txt"}, "cwd": str(self.home)})
        native = self.poll("native hook card", lambda snap: self.session(snap, "amp", native_title).get("state") == "review" and self.session(snap, "amp", native_title).get("busy") is True)
        require(self.session(native, "amp", native_title)["session_key"] != amp_key, "native and MCP conversations collided")
        require(self.session(native, "amp", native_title)["cwd"] == str(self.home), "native cwd metadata was lost")
        self.passed("native bubble CLI stdin reaches the same Desktop session diagnostics")

    def finish_sessions(self):
        for agent, session in sorted(self.touched_sessions):
            try:
                self.mcp("petdex_set_state", {"agent": agent, "session_id": session, "state": "idle"})
            except (AssertionError, OSError, subprocess.TimeoutExpired):
                # The fixture app may have exited on failure; files still restore.
                pass


@contextmanager
def preserve_files(paths):
    saved = {}
    for path in paths:
        require(not path.is_symlink(), "a fixture file must not be a symlink")
        saved[path] = (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None
    try:
        yield
    finally:
        for path, original in saved.items():
            if original is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(original[0])
                path.chmod(original[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="built native hook executable")
    parser.add_argument("--fixture-home", type=Path, required=True, help="marked temporary HOME of the already running fixture Desktop")
    parser.add_argument("--node", default="node", help="Node 20+ executable")
    args = parser.parse_args()
    node = shutil.which(args.node)
    require(node is not None, "Node is unavailable")
    pipeline = Pipeline(args.binary, args.fixture_home, node)
    usage_dir = pipeline.runtime / "usage"
    require(usage_dir.resolve().is_relative_to(pipeline.home), "usage directory escapes fixture HOME")
    usage_dir.mkdir(exist_ok=True)
    paths = [usage_dir / "amp.json", usage_dir / "droid.json", pipeline.runtime / "hooks-disabled", usage_dir / "droid.pipeline.tmp"]
    try:
        with preserve_files(paths):
            try:
                pipeline.run()
            finally:
                pipeline.finish_sessions()
    finally:
        try:
            pipeline.request("/usage/refresh", {})
        except OSError:
            pass
    print(f"PASS {len(pipeline.completed)} live integration checks; fixture files restored")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL {error}", file=sys.stderr)
        raise SystemExit(1)
