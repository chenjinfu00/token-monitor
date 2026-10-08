"""Behavioral tests; all configuration and output live in temporary homes."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


BRIDGE_PATH = Path(__file__).with_name("claude_bridge.py")
SPEC = importlib.util.spec_from_file_location("claude_bridge", BRIDGE_PATH)
assert SPEC is not None and SPEC.loader is not None
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="token-monitor-test-")
        self.home = Path(self.temporary.name)
        self.data = self.home / "private-data"
        self.environment = patch.dict(
            os.environ,
            {"TOKEN_MONITOR_HOME": str(self.home), "TOKEN_MONITOR_DATA_DIR": str(self.data)},
        )
        self.environment.start()
        self.settings = self.home / ".claude" / "settings.json"

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def write_settings(self, document: dict) -> bytes:
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        content = (json.dumps(document, indent=4) + "\n").encode()
        self.settings.write_bytes(content)
        return content

    def read_settings(self) -> dict:
        return json.loads(self.settings.read_bytes())

    def run_bridge(self, *arguments: str, input_bytes: bytes | None = None, installed=False):
        script = bridge.bridge_directory() / bridge.BRIDGE_FILENAME if installed else BRIDGE_PATH
        return subprocess.run(
            [sys.executable, str(script), *arguments],
            input=input_bytes,
            capture_output=True,
            check=False,
            env=os.environ.copy(),
        )

    def test_capture_keeps_only_permitted_fields(self):
        document = {
            "token": "secret",
            "api_key": "secret",
            "session_id": "private",
            "context_window": {"total_input_tokens": 100},
            "rate_limits": {
                "five_hour": {"used_percentage": 23.5, "resets_at": 1900000000, "key": "secret"},
                "seven_day": {"used_percentage": 42, "resets_at": 1900500000},
                "spend_limit": {"used_percentage": 101, "resets_at": 1901000000, "used_usd": 99},
                "unknown": {"used_percentage": 99},
            },
        }
        bridge.write_snapshot(document, captured_at=1000)
        output = (self.data / "claude-quota.json").read_bytes()
        snapshot = json.loads(output)
        self.assertEqual(set(snapshot), {"schemaVersion", "capturedAt", "rateLimits"})
        self.assertEqual(set(snapshot["rateLimits"]), set(bridge.WINDOWS))
        for window in snapshot["rateLimits"].values():
            self.assertEqual(set(window), {"used_percentage", "resets_at"})
        for forbidden in (b"secret", b"private", b"input_tokens", b"used_usd"):
            self.assertNotIn(forbidden, output)
        self.assertEqual(stat.S_IMODE((self.data / "claude-quota.json").stat().st_mode), 0o600)

    def test_diagnostics_store_only_callback_shape_and_permitted_window_names(self):
        document = {
            "version": "2.1.33",
            "session_id": "private-session",
            "account": {"email": "private-account"},
            "conversation": "private-conversation",
            "context_window": {"current_usage": {"input_tokens": 123, "secret": "private-token"}},
            "rate_limits": {
                "five_hour": {"used_percentage": 23.5, "secret": "private-quota"},
                "seven_day": {"resets_at": 1900500000},
                "spend_limit": {"used_percentage": True, "resets_at": "later"},
                "unknown": {"used_percentage": 99},
            },
        }
        self.assertTrue(bridge.write_diagnostics(document, 1000))
        destination = self.data / bridge.DIAGNOSTICS_FILENAME
        output = destination.read_bytes()
        self.assertEqual(json.loads(output), {
            "schemaVersion": 1,
            "capturedAt": 1000,
            "callbackReceived": True,
            "hasAPIResponse": True,
            "hasRateLimits": True,
            "quotaWindows": ["five_hour", "seven_day"],
            "version": "2.1.33",
        })
        self.assertNotIn(b"private", output)
        self.assertNotIn(b"input_tokens", output)
        self.assertNotIn(b"used_percentage", output)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)

    def test_missing_quota_capture_still_records_diagnostics_without_refreshing_quota(self):
        bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 60, "resets_at": 1000}}}, 20)
        before = (self.data / "claude-quota.json").read_bytes()
        result = self.run_bridge("capture", input_bytes=b'{"version":"2.1.33","context_window":{"current_usage":{}}}')
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.data / "claude-quota.json").read_bytes(), before)
        diagnostics = json.loads((self.data / bridge.DIAGNOSTICS_FILENAME).read_bytes())
        self.assertIs(diagnostics["callbackReceived"], True)
        self.assertIs(diagnostics["hasAPIResponse"], True)
        self.assertIs(diagnostics["hasRateLimits"], False)
        self.assertEqual(diagnostics["quotaWindows"], [])
        self.assertGreater(diagnostics["capturedAt"], 20)

    def test_repeated_quota_updates_callback_diagnostics_only(self):
        document = {"rate_limits": {"five_hour": {"used_percentage": 60, "resets_at": 1000}}}
        bridge.write_snapshot(document, 20)
        before = (self.data / "claude-quota.json").read_bytes()
        result = self.run_bridge("capture", input_bytes=json.dumps(document).encode())
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.data / "claude-quota.json").read_bytes(), before)
        self.assertTrue(bridge.diagnostics_status()["diagnosticsPresent"])

    def test_invalid_capture_input_does_not_write_any_data(self):
        for raw in (b"{invalid", b"[]", b"null", b'"private-conversation"'):
            result = self.run_bridge("capture", input_bytes=raw)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.data / bridge.DIAGNOSTICS_FILENAME).exists())
            self.assertFalse((self.data / "claude-quota.json").exists())

    def test_diagnostics_flags_check_dict_shape_and_version_is_strict(self):
        for document in (
            {"version": "2.1.33-private", "context_window": {"current_usage": None}, "rate_limits": None},
            {"version": "private-2.1.33", "context_window": {"current_usage": []}, "rate_limits": []},
            {"version": 2.1, "context_window": [], "rate_limits": "private"},
        ):
            bridge.write_diagnostics(document)
            diagnostics = json.loads((self.data / bridge.DIAGNOSTICS_FILENAME).read_bytes())
            self.assertIs(diagnostics["hasAPIResponse"], False)
            self.assertIs(diagnostics["hasRateLimits"], False)
            self.assertEqual(diagnostics["quotaWindows"], [])
            self.assertNotIn("version", diagnostics)
        bridge.write_diagnostics({"context_window": {"current_usage": {}}, "rate_limits": {}})
        self.assertIs(bridge.diagnostics_status()["hasAPIResponse"], True)
        self.assertIs(bridge.diagnostics_status()["hasRateLimits"], True)

    def test_older_overlapping_callback_cannot_replace_newer_diagnostics(self):
        self.assertTrue(bridge.write_diagnostics({"rate_limits": {}}, 20))
        before = (self.data / bridge.DIAGNOSTICS_FILENAME).read_bytes()
        self.assertFalse(bridge.write_diagnostics({}, 19))
        self.assertEqual((self.data / bridge.DIAGNOSTICS_FILENAME).read_bytes(), before)

    def test_failed_diagnostics_atomic_replace_preserves_previous_and_does_not_touch_quota(self):
        bridge.write_snapshot({}, 20)
        bridge.write_diagnostics({}, 20)
        original_quota = (self.data / "claude-quota.json").read_bytes()
        original_diagnostics = (self.data / bridge.DIAGNOSTICS_FILENAME).read_bytes()
        with patch.object(bridge.os, "replace", side_effect=OSError("simulated disk failure")):
            with self.assertRaises(OSError):
                bridge.write_diagnostics({"rate_limits": {}}, 21)
        self.assertEqual((self.data / "claude-quota.json").read_bytes(), original_quota)
        self.assertEqual((self.data / bridge.DIAGNOSTICS_FILENAME).read_bytes(), original_diagnostics)
        self.assertEqual(list(self.data.glob(".statusline-diagnostics.json.*")), [])

    def test_status_sanitizes_diagnostics_instead_of_echoing_untrusted_file(self):
        bridge.write_diagnostics({}, 20)
        destination = self.data / bridge.DIAGNOSTICS_FILENAME
        document = json.loads(destination.read_bytes())
        document.update({
            "session_id": "private-session",
            "version": "2.1.33-private",
            "quotaWindows": ["five_hour", "private-account", "seven_day", "five_hour"],
        })
        destination.write_text(json.dumps(document))
        result = self.run_bridge("--status")
        self.assertEqual(result.returncode, 0)
        summary = json.loads(result.stdout)
        self.assertEqual(summary["windowNames"], ["five_hour", "seven_day"])
        self.assertIsNone(summary["version"])
        self.assertNotIn(b"private", result.stdout)
        document["capturedAt"] = "private-account"
        destination.write_text(json.dumps(document))
        self.assertFalse(bridge.diagnostics_status()["diagnosticsPresent"])

    def test_missing_windows_and_no_data_are_not_zero(self):
        bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 50}}}, 10)
        snapshot = json.loads((self.data / "claude-quota.json").read_bytes())
        self.assertNotIn("seven_day", snapshot["rateLimits"])
        # Explicit empty quota data clears windows; an omitted field does not.
        bridge.write_snapshot({"rate_limits": {}}, 11)
        snapshot = json.loads((self.data / "claude-quota.json").read_bytes())
        self.assertEqual(snapshot["rateLimits"], {})
        self.assertEqual(snapshot["capturedAt"], 11)

    def test_idle_session_cannot_decrease_usage_in_same_active_window(self):
        first = {"rate_limits": {"five_hour": {"used_percentage": 60, "resets_at": 1000}}}
        bridge.write_snapshot(first, 20)
        before = (self.data / "claude-quota.json").read_bytes()
        stale = {"rate_limits": {"five_hour": {"used_percentage": 20, "resets_at": 1000}}}
        self.assertFalse(bridge.write_snapshot(stale, 21))
        self.assertEqual((self.data / "claude-quota.json").read_bytes(), before)

    def test_merge_retains_high_usage_and_accepts_changed_other_window(self):
        first = {"rate_limits": {
            "five_hour": {"used_percentage": 60, "resets_at": 1000},
            "seven_day": {"used_percentage": 30, "resets_at": 2000},
        }}
        bridge.write_snapshot(first, 20)
        mixed = {"rate_limits": {
            "five_hour": {"used_percentage": 20, "resets_at": 1000},
            "seven_day": {"used_percentage": 40, "resets_at": 2000},
        }}
        self.assertTrue(bridge.write_snapshot(mixed, 21))
        snapshot = json.loads((self.data / "claude-quota.json").read_bytes())
        self.assertEqual(snapshot["rateLimits"]["five_hour"]["used_percentage"], 60)
        self.assertEqual(snapshot["rateLimits"]["seven_day"]["used_percentage"], 40)
        self.assertEqual(snapshot["capturedAt"], 21)
        self.assertIs(snapshot["conservative"], True)

    def test_repeated_quota_does_not_rewrite_or_refresh_capture_time(self):
        document = {"rate_limits": {"five_hour": {"used_percentage": 60, "resets_at": 1000}}}
        bridge.write_snapshot(document, 20)
        before = (self.data / "claude-quota.json").read_bytes()
        with patch.object(bridge, "_atomic_json", side_effect=AssertionError("must not rewrite")):
            self.assertFalse(bridge.write_snapshot(document, 21))
        self.assertEqual((self.data / "claude-quota.json").read_bytes(), before)

    def test_missing_or_null_rate_limits_preserve_observation_age(self):
        document = {"rate_limits": {"five_hour": {"used_percentage": 60, "resets_at": 1000}}}
        bridge.write_snapshot(document, 20)
        before = (self.data / "claude-quota.json").read_bytes()
        for missing in ({}, {"rate_limits": None}):
            self.assertFalse(bridge.write_snapshot(missing, 21))
            self.assertEqual((self.data / "claude-quota.json").read_bytes(), before)

    def test_first_missing_quota_is_recorded_as_empty_once(self):
        self.assertTrue(bridge.write_snapshot({}, 20))
        self.assertFalse(bridge.write_snapshot({"rate_limits": None}, 21))
        snapshot = json.loads((self.data / "claude-quota.json").read_bytes())
        self.assertEqual(snapshot["rateLimits"], {})
        self.assertEqual(snapshot["capturedAt"], 20)

    def test_partial_windows_remain_missing_instead_of_merging_old_fields(self):
        first = {"rate_limits": {
            "five_hour": {"used_percentage": 60, "resets_at": 1000},
            "seven_day": {"used_percentage": 30, "resets_at": 2000},
        }}
        bridge.write_snapshot(first, 20)
        bridge.write_snapshot({"rate_limits": {"five_hour": {"resets_at": 1000}}}, 21)
        snapshot = json.loads((self.data / "claude-quota.json").read_bytes())
        self.assertEqual(snapshot["rateLimits"], {"five_hour": {"resets_at": 1000}})

    def test_new_reset_time_accepts_lower_usage_without_conservative_marker(self):
        bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 60, "resets_at": 1000}}}, 20)
        bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 10, "resets_at": 2000}}}, 21)
        snapshot = json.loads((self.data / "claude-quota.json").read_bytes())
        self.assertEqual(snapshot["rateLimits"]["five_hour"]["used_percentage"], 10)
        self.assertNotIn("conservative", snapshot)

    def test_expired_window_does_not_hold_high_usage(self):
        bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 60, "resets_at": 21}}}, 20)
        bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 10, "resets_at": 21}}}, 22)
        snapshot = json.loads((self.data / "claude-quota.json").read_bytes())
        self.assertEqual(snapshot["rateLimits"]["five_hour"]["used_percentage"], 10)
        self.assertNotIn("conservative", snapshot)

    def test_malformed_numeric_fields_do_not_become_zero(self):
        document = {"rate_limits": {"five_hour": {"used_percentage": True, "resets_at": "later"},
                                    "seven_day": {"used_percentage": float("nan"), "resets_at": -1}}}
        self.assertEqual(bridge.sanitize_rate_limits(document), {})

    def test_older_overlapping_capture_cannot_replace_new_snapshot(self):
        bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 60}}}, 20)
        self.assertFalse(bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 10}}}, 19))
        snapshot = json.loads((self.data / "claude-quota.json").read_bytes())
        self.assertEqual(snapshot["rateLimits"]["five_hour"]["used_percentage"], 60)

    def test_failed_atomic_replace_leaves_previous_snapshot_intact(self):
        bridge.write_snapshot({}, 20)
        original = (self.data / "claude-quota.json").read_bytes()
        with patch.object(bridge.os, "replace", side_effect=OSError("simulated disk failure")):
            with self.assertRaises(OSError):
                bridge.write_snapshot({"rate_limits": {"five_hour": {"used_percentage": 1}}}, 21)
        self.assertEqual((self.data / "claude-quota.json").read_bytes(), original)
        self.assertEqual(list(self.data.glob(".claude-quota.json.*")), [])

    def test_install_backs_up_and_preserves_all_other_settings(self):
        prior = {"model": "opus", "permissions": {"allow": ["Read"]},
                 "statusLine": {"type": "command", "command": "cat", "padding": 3}}
        original_bytes = self.write_settings(prior)
        self.assertTrue(bridge.install())
        settings = self.read_settings()
        self.assertEqual(settings["model"], prior["model"])
        self.assertEqual(settings["permissions"], prior["permissions"])
        self.assertEqual(settings["statusLine"]["padding"], 3)
        self.assertTrue(bridge.is_installed())
        state = json.loads((bridge.bridge_directory() / bridge.STATE_FILENAME).read_bytes())
        self.assertEqual(state["originalStatusLine"], prior["statusLine"])
        self.assertEqual((bridge.bridge_directory() / state["backupFile"]).read_bytes(), original_bytes)

    def test_install_is_idempotent(self):
        self.write_settings({"statusLine": {"type": "command", "command": "cat"}})
        bridge.install()
        before = self.settings.read_bytes()
        state_before = (bridge.bridge_directory() / bridge.STATE_FILENAME).read_bytes()
        self.assertFalse(bridge.install())
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertEqual((bridge.bridge_directory() / bridge.STATE_FILENAME).read_bytes(), state_before)
        self.assertEqual(len(list(bridge.bridge_directory().glob("settings.backup.*.json"))), 1)

    def test_previous_status_line_receives_exact_input_and_streams(self):
        prior_script = self.home / "prior statusline.py"
        prior_script.write_text(
            "import sys\n"
            "sys.stdout.buffer.write(sys.stdin.buffer.read())\n"
            "sys.stderr.write('original stderr\\n')\n"
            "sys.exit(7)\n"
        )
        command = f"{shlex.quote(sys.executable)} {shlex.quote(str(prior_script))}"
        self.write_settings({"statusLine": {"type": "command", "command": command}})
        bridge.install()
        raw = b' { "rate_limits": {"five_hour": {"used_percentage": 22, "resets_at": 1900000000}}, "session_id":"private" }\n'
        result = self.run_bridge("capture", input_bytes=raw, installed=True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, raw)
        self.assertEqual(result.stderr, b"original stderr\n")
        self.assertNotIn(b"private", (self.data / "claude-quota.json").read_bytes())

    def test_uninstall_restores_original_status_line_and_keeps_later_edits(self):
        original_line = {"type": "command", "command": "cat", "padding": 2}
        self.write_settings({"statusLine": original_line, "model": "old"})
        bridge.install()
        settings = self.read_settings()
        settings["model"] = "changed"
        settings["laterField"] = {"keep": True}
        self.write_settings(settings)
        self.assertTrue(bridge.uninstall())
        settings = self.read_settings()
        self.assertEqual(settings["statusLine"], original_line)
        self.assertEqual(settings["model"], "changed")
        self.assertEqual(settings["laterField"], {"keep": True})
        self.assertFalse(bridge.is_installed())
        self.assertFalse(bridge.uninstall())

    def test_uninstall_preserves_user_replacement_status_line(self):
        self.write_settings({"statusLine": {"type": "command", "command": "cat"}})
        bridge.install()
        replacement = {"type": "command", "command": "printf new", "padding": 9}
        self.write_settings({"statusLine": replacement, "other": "later"})
        self.assertFalse(bridge.uninstall())
        self.assertEqual(self.read_settings(), {"statusLine": replacement, "other": "later"})

    def test_new_settings_uninstall_does_not_leave_status_line(self):
        bridge.install()
        self.assertTrue(bridge.uninstall())
        self.assertEqual(self.read_settings(), {})

    def test_explicit_reinstall_wraps_user_replacement(self):
        self.write_settings({"statusLine": {"type": "command", "command": "cat"}})
        bridge.install()
        replacement = {"type": "command", "command": "printf replaced"}
        self.write_settings({"statusLine": replacement})
        bridge.install()
        bridge.uninstall()
        self.assertEqual(self.read_settings()["statusLine"], replacement)

    def test_invalid_settings_fail_without_modifying_user_file(self):
        self.settings.parent.mkdir()
        original = b"{broken json"
        self.settings.write_bytes(original)
        result = self.run_bridge("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.settings.read_bytes(), original)

    def test_status_exposes_only_installed_and_safe_diagnostic_fields(self):
        self.write_settings({"apiKeyHelper": "private-command", "statusLine": {"type": "command", "command": "cat"}})
        for expected in (False, True):
            if expected:
                bridge.install()
            result = self.run_bridge("--status")
            self.assertEqual(json.loads(result.stdout), {
                "installed": expected,
                "diagnosticsPresent": False,
                "lastCallbackAt": None,
                "hasAPIResponse": False,
                "hasRateLimits": False,
                "windowNames": [],
                "version": None,
            })
            self.assertEqual(result.stderr, b"")

    def test_default_capture_reports_missing_data_explicitly(self):
        result = self.run_bridge("capture", input_bytes=b"{}")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"quota unavailable", result.stdout)
        self.assertNotIn(b"0%", result.stdout)

    def test_default_data_directory_uses_overridden_home(self):
        with patch.dict(os.environ):
            os.environ.pop("TOKEN_MONITOR_DATA_DIR", None)
            self.assertEqual(bridge.data_path(), self.home / "Library" / "Application Support" / "Token Monitor")


if __name__ == "__main__":
    unittest.main()
