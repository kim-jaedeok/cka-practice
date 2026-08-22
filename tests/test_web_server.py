#!/usr/bin/env python3
"""Fast unit tests for web-side exam action locking."""

import http.client
import importlib.util
import json
import pathlib
import re
import signal
import subprocess
import threading
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cka_web_server", ROOT / "web" / "server.py")
SERVER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SERVER)


class ExamLockTest(unittest.TestCase):
    def test_web_timeouts_cover_runner_worst_case_and_cleanup(self):
        runner = (ROOT / "exam" / "mock-exam.sh").read_text(encoding="utf-8")

        def constant(name):
            match = re.search(rf"^{name}=(\d+)$", runner, re.MULTILINE)
            self.assertIsNotNone(match, name)
            return int(match.group(1))

        setup = constant("SETUP_TIMEOUT_SEC")
        grade = constant("GRADE_TIMEOUT_SEC")
        cleanup = constant("CLEANUP_TOTAL_TIMEOUT_SEC")
        self.assertGreaterEqual(
            SERVER.EXAM_COMMAND_TIMEOUT,
            17 * setup + 17 * grade + cleanup,
        )
        self.assertGreaterEqual(SERVER.EXAM_TERMINATION_GRACE, cleanup + 30)

    def test_only_active_exam_states_lock_practice_actions(self):
        for state in ("PREPARING", "RUNNING", "SEALED", "GRADING"):
            with mock.patch.object(SERVER, "exam_state", return_value=state):
                self.assertTrue(SERVER.exam_actions_locked(), state)

        for state in ("ARCHIVED", "INVALID", "NONE"):
            with mock.patch.object(SERVER, "exam_state", return_value=state):
                self.assertFalse(SERVER.exam_actions_locked(), state)

        for state in ("CORRUPT", "", "UNKNOWN"):
            with mock.patch.object(SERVER, "exam_state", return_value=state):
                self.assertTrue(SERVER.exam_actions_locked(), state)

    def test_missing_state_file_is_none(self):
        with mock.patch("builtins.open", side_effect=FileNotFoundError):
            self.assertEqual(SERVER.exam_state(), "NONE")

    def test_unreadable_or_invalid_state_fails_closed(self):
        with mock.patch("builtins.open", side_effect=PermissionError):
            self.assertEqual(SERVER.exam_state(), "CORRUPT")
        with mock.patch("builtins.open", mock.mock_open(read_data="RUNNIN")):
            self.assertEqual(SERVER.exam_state(), "CORRUPT")

    def test_posix_timeout_terminates_the_whole_process_group(self):
        proc = mock.Mock(pid=4321)
        proc.communicate.side_effect = [
            subprocess.TimeoutExpired(["cka"], 3),
            (b"terminated", None),
            (b"", None),
        ]

        with mock.patch.object(SERVER.os, "name", "posix"), \
                mock.patch.object(SERVER.subprocess, "Popen", return_value=proc) as popen, \
                mock.patch.object(SERVER.os, "killpg", create=True) as killpg:
            code, output = SERVER.run_cka(["exam", "start"], timeout=3)

        self.assertEqual(code, 124)
        self.assertIn("3", output)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        killpg.assert_called_once_with(4321, signal.SIGTERM)

    def test_posix_timeout_escalates_to_kill_for_a_stuck_process_group(self):
        proc = mock.Mock(pid=9876)
        proc.communicate.side_effect = [
            subprocess.TimeoutExpired(["cka"], 3),
            subprocess.TimeoutExpired(["cka"], SERVER.EXAM_TERMINATION_GRACE),
            (b"", None),
        ]

        with mock.patch.object(SERVER.os, "name", "posix"), \
                mock.patch.object(SERVER.subprocess, "Popen", return_value=proc), \
                mock.patch.object(SERVER.os, "killpg", create=True) as killpg, \
                mock.patch.object(SERVER.signal, "SIGKILL", 9, create=True):
            code, _ = SERVER.run_cka(["exam", "start"], timeout=3)

        self.assertEqual(code, 124)
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(9876, signal.SIGTERM), mock.call(9876, 9)],
        )

    def test_active_exam_returns_http_409_for_practice_action(self):
        server = SERVER.ThreadingHTTPServer(("127.0.0.1", 0), SERVER.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with mock.patch.object(SERVER, "exam_actions_locked", return_value=True), \
                    mock.patch.object(SERVER, "exam_state", return_value="RUNNING"), \
                    mock.patch.object(SERVER, "state_get", return_value="not-started"), \
                    mock.patch.object(SERVER, "run_cka") as run_cka:
                connection = http.client.HTTPConnection(
                    "127.0.0.1", server.server_port, timeout=3
                )
                try:
                    connection.request(
                        "POST",
                        "/api/action",
                        body=json.dumps({"cmd": "start", "id": "ts-01"}),
                        headers={"Content-Type": "application/json"},
                    )
                    response = connection.getresponse()
                    body = json.loads(response.read().decode("utf-8"))
                finally:
                    connection.close()

            self.assertEqual(response.status, 409)
            self.assertEqual(body["code"], 1)
            self.assertEqual(body["status"], "not-started")
            self.assertIn("RUNNING", body["output"])
            run_cka.assert_not_called()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())


if __name__ == "__main__":
    unittest.main()
