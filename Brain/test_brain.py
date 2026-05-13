"""
test_brain.py
=============
Minimal smoke tests for screenai_brain.py.
Runs on any platform — no Mac needed, no Nuitka build needed.

Tests:
  1. The brain emits {"evt":"ready"} on startup.
  2. It responds to "ping" with {"evt":"pong"}.
  3. _delatex correctly converts a few sample LaTeX expressions.
  4. get_machine_id returns a 64-character hex string.
  5. Unknown commands produce a log event, not a crash.
  6. set_setting / get_setting round-trip works.

Usage:
    python3 test_brain.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from typing import List

# Allow importing screenai_brain when this test runs from the Brain folder.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import screenai_brain  # noqa: E402


# ---------------------------------------------------------------------------
#  In-process unit tests (no subprocess)
# ---------------------------------------------------------------------------

class TestDelatex(unittest.TestCase):
    def test_simple_frac(self):
        self.assertEqual(screenai_brain._delatex(r"\frac{1}{2}"), "(1)/(2)")

    def test_nested_frac_sqrt(self):
        # \frac{\sqrt{\pi}}{2} → (√(π))/(2)
        self.assertEqual(screenai_brain._delatex(r"\frac{\sqrt{\pi}}{2}"),
                         "(√(π))/(2)")

    def test_mathbb_R(self):
        self.assertIn("ℝ", screenai_brain._delatex(r"x \in \mathbb{R}"))

    def test_superscript(self):
        self.assertEqual(screenai_brain._delatex(r"x^2 + y^2"), "x² + y²")

    def test_greek(self):
        self.assertEqual(screenai_brain._delatex(r"\alpha + \beta = \gamma"),
                         "α + β = γ")

    def test_no_latex_passthrough(self):
        plain = "Just a normal sentence."
        self.assertEqual(screenai_brain._delatex(plain), plain)

    def test_empty(self):
        self.assertEqual(screenai_brain._delatex(""), "")


class TestMachineID(unittest.TestCase):
    def test_returns_hex_string(self):
        mid = screenai_brain.get_machine_id()
        self.assertEqual(len(mid), 64)
        int(mid, 16)  # raises if not hex


class TestSettings(unittest.TestCase):
    def setUp(self):
        # Redirect settings to a temp file so we don't clobber the real one.
        self.tmpdir = tempfile.mkdtemp()
        self._orig_dir  = screenai_brain.SETTINGS_DIR
        self._orig_file = screenai_brain.SETTINGS_FILE
        screenai_brain.SETTINGS_DIR  = self.tmpdir
        screenai_brain.SETTINGS_FILE = os.path.join(self.tmpdir, "settings.json")

    def tearDown(self):
        screenai_brain.SETTINGS_DIR  = self._orig_dir
        screenai_brain.SETTINGS_FILE = self._orig_file

    def test_defaults_when_missing(self):
        s = screenai_brain._load_settings()
        self.assertEqual(s["ai_provider"], "grok")
        self.assertTrue(s["panel_enabled"])
        self.assertFalse(s["bubble_enabled"])

    def test_roundtrip(self):
        s = screenai_brain._load_settings()
        s["ai_provider"] = "claude"
        s["bubble_enabled"] = True
        screenai_brain._save_settings(s)
        s2 = screenai_brain._load_settings()
        self.assertEqual(s2["ai_provider"], "claude")
        self.assertTrue(s2["bubble_enabled"])

    def test_unknown_keys_dropped(self):
        path = screenai_brain.SETTINGS_FILE
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"ai_provider": "claude", "nonsense_key": 42}, f)
        s = screenai_brain._load_settings()
        self.assertEqual(s["ai_provider"], "claude")
        self.assertNotIn("nonsense_key", s)


# ---------------------------------------------------------------------------
#  Subprocess integration test — exercises the JSON-over-stdio loop end-to-end
# ---------------------------------------------------------------------------

class TestIPC(unittest.TestCase):
    """Spawn the brain as a subprocess and verify the full IPC loop."""

    @classmethod
    def setUpClass(cls):
        # Point the subprocess brain at a tempdir so the IPC tests don't
        # clobber the developer's real settings.json.
        cls._tmpdir = tempfile.mkdtemp(prefix="screengpt-test-")

    @classmethod
    def tearDownClass(cls):
        import shutil
        shutil.rmtree(cls._tmpdir, ignore_errors=True)

    @classmethod
    def _send_commands(cls, commands: List[dict], timeout: float = 5.0) -> List[dict]:
        """Pipe `commands` to the brain on stdin, collect events from stdout."""
        env = dict(os.environ)
        # Force unbuffered Python so we don't deadlock waiting on a full buffer.
        env["PYTHONUNBUFFERED"] = "1"
        # Redirect settings to a tempdir — see setUpClass.
        env["CALIB_SETTINGS_DIR"] = cls._tmpdir
        proc = subprocess.Popen(
            [sys.executable, "screenai_brain.py"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=os.path.dirname(os.path.abspath(__file__)),
            env=env,
            text=True,
        )
        input_blob = "\n".join(json.dumps(c) for c in commands) + "\n"
        try:
            out, err = proc.communicate(input=input_blob, timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate()
            raise AssertionError(f"Brain hung. stderr:\n{err}")

        events: List[dict] = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except Exception:
                pass
        return events

    def test_ready_then_pong(self):
        events = self._send_commands([
            {"cmd": "ping"},
            {"cmd": "shutdown"},
        ])
        evt_names = [e.get("evt") for e in events]
        self.assertIn("ready", evt_names)
        self.assertIn("pong", evt_names)
        self.assertIn("shutdown_ok", evt_names)

    def test_machine_id(self):
        events = self._send_commands([
            {"cmd": "get_machine_id"},
            {"cmd": "shutdown"},
        ])
        mid_events = [e for e in events if e.get("evt") == "machine_id"]
        self.assertEqual(len(mid_events), 1)
        self.assertEqual(len(mid_events[0]["value"]), 64)

    def test_unknown_command_logs_error(self):
        events = self._send_commands([
            {"cmd": "this_does_not_exist"},
            {"cmd": "shutdown"},
        ])
        log_events = [e for e in events
                      if e.get("evt") == "log" and e.get("level") == "err"]
        self.assertTrue(any("Unknown command" in e.get("msg", "")
                            for e in log_events))

    def test_setting_roundtrip(self):
        # Uses the tempdir from setUpClass via CALIB_SETTINGS_DIR — no
        # risk of clobbering the developer's real settings.json.
        events = self._send_commands([
            {"cmd": "set_setting", "key": "ai_provider", "value": "claude"},
            {"cmd": "get_setting", "key": "ai_provider"},
            {"cmd": "shutdown"},
        ])
        get_events = [e for e in events
                      if e.get("evt") == "setting_value"
                      and e.get("key") == "ai_provider"]
        self.assertTrue(any(e.get("value") == "claude" for e in get_events))

    def test_scan_without_login_errors(self):
        events = self._send_commands([
            {"cmd": "scan", "image_b64": "AAAA"},
            {"cmd": "shutdown"},
        ])
        scan_err = [e for e in events if e.get("evt") == "scan_err"]
        self.assertTrue(any("Not logged in" in e.get("msg", "")
                            for e in scan_err))


if __name__ == "__main__":
    unittest.main(verbosity=2)
