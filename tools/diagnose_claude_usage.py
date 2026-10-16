#!/usr/bin/env python3
"""Read-only diagnosis of Token Monitor's Claude quota query.

Runs the official Claude CLI the way the app's probe does (initialize and
get_usage control messages only; no prompt, conversation or model request) and
prints a privacy-safe timeline: which CLI and version, the control responses,
the payload shape, the diagnostic lines the app classifies, and the message the
app shows for that answer. Paths under your home folder, e-mail addresses,
UUIDs and token-like strings are redacted before printing.
"""
import json
import os
import plistlib
import re
import select
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
APP = "/Applications/Token Monitor.app"
# After the usage payload the app waits this long for the CLI's diagnostics
# (ClaudeUsageProbe.evidenceGrace), then stops the CLI.
GRACE = 5
MAX_SNAPSHOT_AGE = 300
OK_200 = re.compile(r"fetchUtilization: 200 after [0-9]+ attempt\(s\)")
SNAPSHOT = re.compile(r"Usage read answered from a snapshot ([0-9]{1,7})s old; endpoint not asked")
INTERESTING = re.compile(r"fetchUtilization|Usage read|Usage fetch|usage data|utilization|rate.?limit|"
                         r"\b40[13]\b|\b429\b|oauth/usage|get_usage|usage:|remembered for this bearer", re.I)
MESSAGES = {
    "confirmed": "shows fresh numbers",
    "unavailable": "Claude 暂未返回实时额度 · 请检查网络或现有登录",
    "noSubscriptionLimits": "Claude Code 当前登录不含订阅额度 · 请用 Pro/Max 等订阅账号登录",
    "rateLimited": "Claude 查询频率受限 · 稍后自动重试",
    "serviceRejected": "Claude 用量接口暂时拒绝查询 · 稍后自动重试",
    "signedOut": "Claude Code 登录已失效 · 请重新登录",
    "endpointUnavailable": "Claude 用量接口暂时无响应 · 将自动重试",
    "unconfirmed": "未确认 Claude 服务端更新 · 将自动重试",
}


class Evidence:
    """Mirror of ClaudeUsageEvidence in Sources/TokenMonitor/ClaudeUsageProbe.swift."""

    def __init__(self):
        self.success = False
        self.snapshot_age = None
        self.unusable = False
        self.rate_limited = False
        self.rejected = False
        self.signed_out = False
        self.attempted = False
        self.no_http_answer = False

    def observe(self, line):
        marks = []
        if OK_200.search(line):
            self.success = True
            marks.append("APP-EVIDENCE:200")
        match = SNAPSHOT.search(line)
        if match and int(match.group(1)) <= MAX_SNAPSHOT_AGE:
            self.snapshot_age = int(match.group(1))
            marks.append(f"APP-EVIDENCE:snapshot {match.group(1)}s")
        elif match:
            marks.append(f"STALE-SNAPSHOT {match.group(1)}s")
        lower = line.lower()
        failed_load = "failed to load usage data" in lower
        if "fetchutilization: get " in lower:
            self.attempted = True
            marks.append("REQUEST")
        if "fieldless or non-object body" in lower or failed_load:
            self.unusable = True
            marks.append("UNUSABLE")
        if ("fetchutilization" in lower or failed_load) and "429" in lower:
            self.rate_limited = True
            marks.append("RATE-LIMITED")
        forbidden = ("status code 403" in lower or "answered 403" in lower
                     or ("fetchutilization: 403" in lower and "remembered for this bearer" in lower))
        if "non-object body (in-band error)" in lower or (forbidden and (failed_load or "fetchutilization" in lower)):
            self.rejected = True
            marks.append("REFUSED")
        if failed_load and ("auth error" in lower or "status code 401" in lower or "answered 401" in lower):
            self.signed_out = True
            marks.append("SIGNED-OUT")
        elif failed_load and "429" not in lower and not forbidden:
            self.no_http_answer = True
            marks.append("NO-HTTP-ANSWER")
        return marks

    def verdict(self, payload, complete):
        if payload.get("rate_limits_available") is False:
            return "noSubscriptionLimits"
        if self.rate_limited:
            return "rateLimited"
        if self.rejected:
            return "serviceRejected"
        if (self.success or self.snapshot_age is not None) and not self.unusable:
            return "confirmed" if isinstance(payload.get("rate_limits"), dict) else "unavailable"
        if self.signed_out:
            return "signedOut"
        if self.no_http_answer or (complete and self.attempted and not self.success):
            return "endpointUnavailable"
        return "unconfirmed"


def redact(text):
    text = text.replace(HOME, "~")
    text = re.sub(r"[\w.+-]+@[\w-]+\.[\w.-]+", "<email>", text)
    text = re.sub(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "<uuid>", text)
    text = re.sub(r"(?i)bearer\s+\S+", "Bearer <token>", text)
    text = re.sub(r"sk-ant-[\w-]+", "<token>", text)
    text = re.sub(r"[A-Za-z0-9_\-]{40,}", "<redacted>", text)
    return text[:300]


def find_cli():
    candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", os.path.join(HOME, ".local/bin/claude")]
    candidates += [os.path.join(p, "claude") for p in os.environ.get("PATH", "").split(":") if p]
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def app_info():
    try:
        with open(os.path.join(APP, "Contents/Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
        with open(os.path.join(APP, "Contents/MacOS/TokenMonitor"), "rb") as handle:
            binary = handle.read()
        snapshot = b"Usage read answered from a snapshot" in binary
        explains = b"fetchutilization: get " in binary
        return (f"{info.get('CFBundleShortVersionString')} (build {info.get('CFBundleVersion')}); "
                f"accepts snapshot answers: {'yes' if snapshot else 'NO - old build installed'}; "
                f"explains failed usage requests: {'yes' if explains else 'NO - older build installed'}")
    except OSError as error:
        return f"not readable ({error.strerror})"


def run_once(cli, label):
    args = [cli, "--safe-mode", "--strict-mcp-config", "--tools", "", "--no-session-persistence",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--print",
            "--debug-to-stderr"]
    env = dict(os.environ, DISABLE_TELEMETRY="1", DO_NOT_TRACK="1", CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false")
    env.pop("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", None)
    start = time.monotonic()
    stamp = lambda: f"{time.monotonic() - start:6.2f}s"
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               cwd=tempfile.gettempdir(), env=env)

    def send(request_id, request):
        message = {"type": "control_request", "request_id": request_id, "request": request}
        process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()

    print(f"\n=== {label}")
    send("tm_init", {"subtype": "initialize"})
    out, err = b"", b""
    open_streams = {process.stdout.fileno(): "out", process.stderr.fileno(): "err"}
    payload, payload_at, stderr_closed_at = None, None, None
    stderr_lines = 0
    app_view, full_view = Evidence(), Evidence()
    deadline = time.monotonic() + 40
    while open_streams and time.monotonic() < deadline:
        if payload_at is not None and time.monotonic() > payload_at + 15:
            break
        ready, _, _ = select.select(list(open_streams), [], [], 0.25)
        for fd in ready:
            chunk = os.read(fd, 65536)
            kind = open_streams[fd]
            if not chunk:
                print(f"  {stamp()} {'stdout' if kind == 'out' else 'stderr'} closed")
                if kind == "err":
                    stderr_closed_at = time.monotonic()
                del open_streams[fd]
                continue
            if kind == "err":
                err += chunk
                while b"\n" in err:
                    raw, err = err.split(b"\n", 1)
                    line = raw.decode("utf-8", "replace")
                    stderr_lines += 1
                    marks = full_view.observe(line)
                    late = payload_at is not None and time.monotonic() > payload_at + GRACE
                    if not late:
                        app_view.observe(line)
                    if marks or INTERESTING.search(line):
                        tag = (" [" + ", ".join(marks) + "]") if marks else ""
                        when = " (after the app's grace)" if late else ""
                        print(f"  {stamp()} stderr{tag}{when}: {redact(line)}")
                continue
            out += chunk
            while b"\n" in out:
                raw, out = out.split(b"\n", 1)
                try:
                    item = json.loads(raw)
                except ValueError:
                    continue
                if item.get("type") != "control_response":
                    continue
                response = item.get("response") or {}
                request_id = response.get("request_id")
                print(f"  {stamp()} control_response {request_id}: {response.get('subtype')}"
                      + (f" error={redact(str(response.get('error')))}" if response.get("error") else ""))
                if request_id == "tm_init" and response.get("subtype") == "success":
                    send("tm_usage", {"subtype": "get_usage", "skip_behaviors": True})
                elif request_id == "tm_usage":
                    payload = response.get("response") or {}
                    limits = payload.get("rate_limits")
                    summary = {"rate_limits_available": payload.get("rate_limits_available"),
                               "subscription_type": payload.get("subscription_type")}
                    if isinstance(limits, dict):
                        for key, value in limits.items():
                            if isinstance(value, dict):
                                summary[key] = value.get("utilization", "?")
                            elif isinstance(value, list):
                                summary[key] = f"list[{len(value)}]"
                            else:
                                summary[key] = value
                    else:
                        summary["rate_limits"] = limits
                    print(f"  {stamp()} usage payload: {json.dumps(summary, ensure_ascii=False)}")
                    payload_at = time.monotonic()
                    # Like the app: close stdin as soon as the payload arrives.
                    process.stdin.close()
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    print(f"  {stamp()} exit status {process.returncode}; {stderr_lines} stderr lines in total")
    if payload is None:
        print(f"  RESULT: no usage payload -> the app shows: {MESSAGES['unavailable']} (or a timeout)")
        return
    complete_for_app = stderr_closed_at is not None and stderr_closed_at <= payload_at + GRACE
    verdict = app_view.verdict(payload, complete_for_app)
    print(f"  RESULT: {verdict} -> the app shows: {MESSAGES[verdict]}")
    later = full_view.verdict(payload, stderr_closed_at is not None)
    if later != verdict:
        print(f"  NOTE: with the lines that arrived after the app's {GRACE} s grace it would be: {later}")


def main():
    cli = find_cli()
    print("Token Monitor app:", app_info())
    if not cli:
        print("Claude CLI not found in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin or PATH")
        return 1
    print("Claude CLI (the first one the app finds):", redact(cli), "->", redact(os.path.realpath(cli)))
    try:
        version = subprocess.run([cli, "--version"], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        version = f"unavailable ({error})"
    print("Claude CLI version:", redact(version))
    run_once(cli, "query 1")
    run_once(cli, "query 2 (immediately after, normally answered from the CLI's 60 s snapshot)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
