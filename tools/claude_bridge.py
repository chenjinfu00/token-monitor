#!/usr/bin/env python3
"""Local, credential-free Claude Code quota bridge for Token Monitor.

Run ``install`` only after the user chooses to connect Claude Code. The script
can also be used directly as a statusLine command with the ``capture`` command.
Only quota percentages, reset timestamps, and allowlisted callback diagnostics
are persisted by capture. No account, session, or conversation data is stored.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterator


SCHEMA_VERSION = 1
WINDOWS = ("five_hour", "seven_day", "spend_limit")
STATE_FILENAME = "install-state.json"
BRIDGE_FILENAME = "bridge.py"
DIAGNOSTICS_FILENAME = "statusline-diagnostics.json"


def home_path() -> Path:
    return Path(os.environ.get("TOKEN_MONITOR_HOME", str(Path.home()))).expanduser()


def data_path() -> Path:
    override = os.environ.get("TOKEN_MONITOR_DATA_DIR")
    if override:
        return Path(override).expanduser()
    return home_path() / "Library" / "Application Support" / "Token Monitor"


def bridge_directory() -> Path:
    return home_path() / ".claude" / "token-monitor"


def settings_path() -> Path:
    return home_path() / ".claude" / "settings.json"


def _make_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)


@contextmanager
def _locked(path: Path) -> Iterator[None]:
    _make_directory(path.parent)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _atomic_bytes(path: Path, content: bytes) -> None:
    """Write a private file in the same directory and then atomically replace."""
    _make_directory(path.parent)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _atomic_json(path: Path, document: Any) -> None:
    content = json.dumps(document, ensure_ascii=False, indent=2, allow_nan=False)
    _atomic_bytes(path, (content + "\n").encode("utf-8"))


def _read_json_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object in {path.name}")
    return value


def _valid_number(value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def sanitize_rate_limits(document: dict[str, Any]) -> dict[str, dict[str, int | float]]:
    limits = document.get("rate_limits")
    if not isinstance(limits, dict):
        return {}
    sanitized: dict[str, dict[str, int | float]] = {}
    for name in WINDOWS:
        raw_window = limits.get(name)
        if not isinstance(raw_window, dict):
            continue
        window: dict[str, int | float] = {}
        for field in ("used_percentage", "resets_at"):
            value = raw_window.get(field)
            if _valid_number(value):
                window[field] = value
        if window:
            sanitized[name] = window
    return sanitized


def _safe_version(value: Any) -> str | None:
    if isinstance(value, str) and len(value) <= 64 and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        return value
    return None


def write_diagnostics(document: dict[str, Any], captured_at: float | None = None) -> bool:
    """Record callback shape only, independently of quota freshness."""
    timestamp = time.time() if captured_at is None else captured_at
    if not _valid_number(timestamp):
        raise ValueError("Invalid capture timestamp")
    context = document.get("context_window")
    envelope = {
        "schemaVersion": SCHEMA_VERSION,
        "capturedAt": timestamp,
        "callbackReceived": True,
        "hasAPIResponse": isinstance(context, dict) and isinstance(context.get("current_usage"), dict),
        "hasRateLimits": isinstance(document.get("rate_limits"), dict),
        "quotaWindows": list(sanitize_rate_limits(document)),
    }
    version = _safe_version(document.get("version"))
    if version is not None:
        envelope["version"] = version
    directory = data_path()
    destination = directory / DIAGNOSTICS_FILENAME
    with _locked(directory / ".statusline-diagnostics.lock"):
        if destination.exists():
            try:
                previous = _read_json_object(destination)
            except (ValueError, UnicodeError):
                previous = {}
            previous_time = previous.get("capturedAt")
            if _valid_number(previous_time) and previous_time > timestamp:
                return False
        _atomic_json(destination, envelope)
    return True


def diagnostics_status() -> dict[str, Any]:
    """Expose a fixed, validated summary rather than arbitrary file contents."""
    summary = {
        "diagnosticsPresent": False,
        "lastCallbackAt": None,
        "hasAPIResponse": False,
        "hasRateLimits": False,
        "windowNames": [],
        "version": None,
    }
    try:
        document = _read_json_object(data_path() / DIAGNOSTICS_FILENAME)
    except (OSError, ValueError, UnicodeError):
        return summary
    if (
        type(document.get("schemaVersion")) is not int
        or document.get("schemaVersion") != SCHEMA_VERSION
        or document.get("callbackReceived") is not True
        or not _valid_number(document.get("capturedAt"))
        or type(document.get("hasAPIResponse")) is not bool
        or type(document.get("hasRateLimits")) is not bool
    ):
        return summary
    raw_names = document.get("quotaWindows")
    names = raw_names if isinstance(raw_names, list) else []
    summary.update({
        "diagnosticsPresent": True,
        "lastCallbackAt": document["capturedAt"],
        "hasAPIResponse": document["hasAPIResponse"],
        "hasRateLimits": document["hasRateLimits"],
        "windowNames": [name for name in WINDOWS if name in names],
        "version": _safe_version(document.get("version")),
    })
    return summary


def write_snapshot(document: dict[str, Any], captured_at: float | None = None) -> bool:
    """Capture a single account's quota without making stale callbacks look new.

    Status line callbacks have no server response timestamp. Within one active
    window, normal quota consumption does not decrease, so a lower percentage
    with the same reset time is conservatively treated as an idle session's old
    data. An exceptional provider correction may therefore wait until the next
    reset before its lower value is shown.

    Return False when there is no new quota information or when a concurrently
    captured newer snapshot already exists. No session identifiers are stored.
    """
    timestamp = time.time() if captured_at is None else captured_at
    if not _valid_number(timestamp):
        raise ValueError("Invalid capture timestamp")
    envelope = {
        "schemaVersion": SCHEMA_VERSION,
        "capturedAt": timestamp,
        "rateLimits": sanitize_rate_limits(document),
    }
    directory = data_path()
    destination = directory / "claude-quota.json"
    with _locked(directory / ".claude-quota.lock"):
        if destination.exists():
            try:
                previous = _read_json_object(destination)
            except (ValueError, UnicodeError):
                previous = {}
            previous_time = previous.get("capturedAt")
            if _valid_number(previous_time) and previous_time > timestamp:
                return False
            previous_limits = sanitize_rate_limits({"rate_limits": previous.get("rateLimits")})
            if document.get("rate_limits") is None and previous_limits:
                # Startup or idle callbacks may omit quota data altogether. Keep
                # the last observation's original age instead of claiming a sync.
                return False
            conservative = False
            for name, incoming in envelope["rateLimits"].items():
                prior_window = previous_limits.get(name, {})
                reset = incoming.get("resets_at")
                prior_percentage = prior_window.get("used_percentage")
                incoming_percentage = incoming.get("used_percentage")
                if (
                    reset is not None
                    and reset == prior_window.get("resets_at")
                    and reset > timestamp
                    and prior_percentage is not None
                    and incoming_percentage is not None
                    and incoming_percentage < prior_percentage
                ):
                    incoming["used_percentage"] = prior_percentage
                    conservative = True
            if envelope["rateLimits"] == previous.get("rateLimits"):
                # Even a newer local callback can carry the exact same old API
                # observation. Do not refresh capturedAt or rewrite that file.
                return False
            if conservative:
                envelope["conservative"] = True
        _atomic_json(destination, envelope)
    return True


def _installed_command(state: dict[str, Any], settings: dict[str, Any]) -> bool:
    command = state.get("installedCommand")
    status_line = settings.get("statusLine")
    return (
        isinstance(command, str)
        and isinstance(status_line, dict)
        and status_line.get("type") == "command"
        and status_line.get("command") == command
    )


def is_installed() -> bool:
    """Expose only the connection state, without logging configuration."""
    try:
        state = _read_json_object(bridge_directory() / STATE_FILENAME)
        settings = _read_json_object(settings_path())
        return (
            state.get("schemaVersion") == SCHEMA_VERSION
            and (bridge_directory() / BRIDGE_FILENAME).is_file()
            and _installed_command(state, settings)
        )
    except (OSError, ValueError, UnicodeError):
        return False


def _original_command() -> str | None:
    state_file = bridge_directory() / STATE_FILENAME
    if not state_file.exists():
        return None
    state = _read_json_object(state_file)
    original = state.get("originalStatusLine")
    if isinstance(original, dict) and original.get("type", "command") == "command":
        command = original.get("command")
        if isinstance(command, str) and command.strip():
            return command
    return None


def _quota_text(document: dict[str, Any]) -> str:
    limits = sanitize_rate_limits(document)
    labels = {"five_hour": "5h", "seven_day": "7d", "spend_limit": "Spend"}
    parts = []
    for name in WINDOWS:
        percentage = limits.get(name, {}).get("used_percentage")
        if percentage is not None:
            parts.append(f"{labels[name]} {percentage:g}%")
    return "Claude " + (" · ".join(parts) if parts else "quota unavailable")


def capture() -> int:
    # Capture time precedes input processing, so an overlapping slow invocation
    # cannot overwrite a newer invocation's snapshot after waiting for the lock.
    captured_at = time.time()
    raw_input = sys.stdin.buffer.read()
    capture_error: Exception | None = None
    document: dict[str, Any] = {}
    try:
        parsed = json.loads(raw_input)
        if not isinstance(parsed, dict):
            raise ValueError("Status line input must be a JSON object")
        document = parsed
    except (OSError, ValueError, UnicodeError) as error:
        capture_error = error
        print(f"Token Monitor could not capture quota: {error}", file=sys.stderr)
    else:
        # A callback can arrive without rate_limits, especially before an API
        # response. Record that fact without refreshing an older quota snapshot.
        for writer in (write_diagnostics, write_snapshot):
            try:
                writer(document, captured_at)
            except (OSError, ValueError, UnicodeError) as error:
                capture_error = error
                print(f"Token Monitor could not capture quota: {error}", file=sys.stderr)

    try:
        command = _original_command()
    except (OSError, ValueError, UnicodeError) as error:
        print(f"Token Monitor could not read status line state: {error}", file=sys.stderr)
        return 1
    if command:
        # Keep the user's existing status line intact, including its exact stdin
        # bytes, its output streams, and its command's exit status.
        return subprocess.run(command, shell=True, input=raw_input, check=False).returncode
    print(_quota_text(document))
    return 1 if capture_error else 0


def install() -> bool:
    """Install locally; preserve all unrelated settings and the prior statusLine."""
    directory = bridge_directory()
    with _locked(directory / ".install.lock"):
        destination = directory / BRIDGE_FILENAME
        source = Path(__file__).resolve().read_bytes()
        settings_file = settings_path()
        original_bytes = settings_file.read_bytes() if settings_file.exists() else None
        settings = _read_json_object(settings_file) if original_bytes is not None else {}
        state_file = directory / STATE_FILENAME
        state = _read_json_object(state_file) if state_file.exists() else None
        if state and _installed_command(state, settings):
            _atomic_bytes(destination, source)
            return False

        command = f"{shlex.quote(sys.executable)} {shlex.quote(str(destination))} capture"
        current = settings.get("statusLine")
        if isinstance(current, dict) and current.get("command") == command:
            raise ValueError("Existing Token Monitor status line has no valid installation state")
        if current is not None and (
            not isinstance(current, dict)
            or current.get("type", "command") != "command"
            or not isinstance(current.get("command"), str)
        ):
            raise ValueError("Existing statusLine is not a supported command configuration")

        backup_name = None
        if original_bytes is not None:
            # Unique backups keep a later explicit reinstall recoverable too.
            backup_name = f"settings.backup.{time.time_ns()}.json"
            _atomic_bytes(directory / backup_name, original_bytes)
        new_state = {
            "schemaVersion": SCHEMA_VERSION,
            "installedCommand": command,
            "originalStatusLinePresent": "statusLine" in settings,
            "originalStatusLine": current,
            "backupFile": backup_name,
        }
        status_line = dict(current) if isinstance(current, dict) else {}
        status_line.update({"type": "command", "command": command})
        settings["statusLine"] = status_line
        _atomic_bytes(destination, source)
        _atomic_json(state_file, new_state)
        _atomic_json(settings_file, settings)
        return True


def uninstall() -> bool:
    """Restore only our current statusLine, preserving subsequent user edits."""
    directory = bridge_directory()
    state_file = directory / STATE_FILENAME
    if not state_file.exists():
        return False
    with _locked(directory / ".install.lock"):
        if not state_file.exists():
            return False
        state = _read_json_object(state_file)
        settings_file = settings_path()
        settings = _read_json_object(settings_file) if settings_file.exists() else {}
        restored = _installed_command(state, settings)
        if restored:
            if state.get("originalStatusLinePresent"):
                settings["statusLine"] = state.get("originalStatusLine")
            else:
                settings.pop("statusLine", None)
            _atomic_json(settings_file, settings)
        # Keep backups and the copied script for recovery. In particular, do not
        # delete a script that a user's replacement command may still reference.
        state_file.unlink()
        return restored


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=("capture", "install", "uninstall"))
    parser.add_argument("--status", action="store_true", help="Print installation state and safe callback diagnostics")
    arguments = parser.parse_args()
    if arguments.status:
        print(json.dumps({"installed": is_installed(), **diagnostics_status()}))
        return 0
    if arguments.command is None:
        parser.error("a command or --status is required")
    try:
        if arguments.command == "capture":
            return capture()
        if arguments.command == "install":
            install()
            print(json.dumps({"installed": is_installed()}))
        elif arguments.command == "uninstall":
            uninstall()
            print(json.dumps({"installed": is_installed()}))
        return 0
    except (OSError, ValueError, UnicodeError) as error:
        print(f"Token Monitor bridge error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
