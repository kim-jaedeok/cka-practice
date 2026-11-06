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

    def setUp(self):
        # Keep these local-exam tests independent of a real supervised run.
        patcher = mock.patch.object(SERVER, "ssh_exam_active", return_value=False)
        patcher.start()
        self.addCleanup(patcher.stop)

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


class _ServerCase(unittest.TestCase):
    def request(self, method, path, payload=None):
        server = SERVER.ThreadingHTTPServer(("127.0.0.1", 0), SERVER.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            try:
                body = json.dumps(payload) if payload is not None else None
                connection.request(method, path, body=body, headers={"Content-Type": "application/json"})
                response = connection.getresponse()
                return response.status, json.loads(response.read().decode("utf-8"))
            finally:
                connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


class SshExamWebTest(_ServerCase):
    """Supervised SSH exam (cka exam-ssh) support in the web UI."""

    def setUp(self):
        import tempfile
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = pathlib.Path(tmp.name)
        self.runner = self.root / "runner"
        self.supervisor = self.root / "supervisor"
        self.forms = self.root / "forms"
        self.ledger = self.root / "ledger.tsv"
        for name, value in {
            "SSH_RUNNER_ROOT": str(self.runner),
            "SSH_SUPERVISOR_ROOT": str(self.supervisor),
            "EXAM_BANK_FORMS_DIR": str(self.forms),
            "EXAM_BANK_LEDGER": str(self.ledger),
        }.items():
            patcher = mock.patch.object(SERVER, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def make_run(self, run_id="ssh-1", phase="RUNNING", form=None, deadline=None):
        run = self.runner / "runs" / run_id
        run.mkdir(parents=True)
        (self.runner / "active").write_text(run_id, encoding="utf-8")
        (run / "status").write_text(f"{phase}|detail", encoding="utf-8")
        if form:
            (run / "form.json").write_text(json.dumps({"form": form, "blind": True}), encoding="utf-8")
        if deadline:
            sup = self.supervisor / "runs" / run_id
            sup.mkdir(parents=True)
            (sup / "manifest.json").write_text(json.dumps({"deadline_epoch": deadline}), encoding="utf-8")

    def test_state_without_an_active_run(self):
        self.assertEqual(SERVER.ssh_exam_state(), {"active": False})
        self.assertFalse(SERVER.ssh_exam_active())

    def test_state_reports_phase_form_and_deadline(self):
        self.make_run(phase="RUNNING", form="A", deadline=2000000000)
        state = SERVER.ssh_exam_state()
        self.assertEqual(
            {k: state[k] for k in ("active", "runId", "phase", "form", "blind", "deadlineEpoch")},
            {"active": True, "runId": "ssh-1", "phase": "RUNNING", "form": "A",
             "blind": True, "deadlineEpoch": 2000000000},
        )
        with mock.patch.object(SERVER, "exam_state", return_value="NONE"):
            self.assertTrue(SERVER.exam_actions_locked())
            status, body = self.request("GET", "/api/exam/state")
        self.assertEqual(status, 200)
        self.assertEqual((body["sshActive"], body["practiceLocked"]), (True, True))

    def test_unexpected_run_id_or_phase_is_corrupt(self):
        self.runner.mkdir()
        (self.runner / "active").write_text("../escape", encoding="utf-8")
        self.assertEqual(SERVER.ssh_exam_state(), {"active": True, "phase": "CORRUPT"})
        (self.runner / "active").unlink()
        self.make_run(phase="RUNNIN")
        self.assertEqual(SERVER.ssh_exam_state()["phase"], "CORRUPT")

    def test_forms_list_names_and_exposure_only(self):
        self.forms.mkdir()
        for name in ("A.tsv", "B.tsv", "lower.tsv", "README.md"):
            (self.forms / name).write_text("ex-ts-01|1|||\n", encoding="utf-8")
        self.ledger.write_text("A\tssh-1\t2026-11-06T00:00:00Z\tEXPOSED\n", encoding="utf-8")
        forms = SERVER.exam_bank_forms()
        self.assertEqual(forms, [{"form": "A", "exposed": True}, {"form": "B", "exposed": False}])
        self.assertNotIn("ex-", json.dumps(forms))

    def test_phase_cli_for_the_terminal_wrapper(self):
        self.make_run(phase="RUNNING")
        env = dict(SERVER.os.environ, CKA_SSH_RUNNER_STATE_ROOT=str(self.runner),
                   CKA_SSH_SUPERVISOR_STATE_ROOT=str(self.supervisor))
        out = subprocess.run(["python3", str(ROOT / "web" / "server.py"), "--ssh-phase"],
                             env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(out.stdout.strip(), "RUNNING")
        (self.runner / "active").unlink()
        out = subprocess.run(["python3", str(ROOT / "web" / "server.py"), "--ssh-phase"],
                             env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(out.stdout.strip(), "NONE")

    def test_actions_validate_input_and_delegate_to_cka(self):
        with mock.patch.object(SERVER, "run_cka", return_value=(0, "ok")) as run_cka:
            for bad in ({"cmd": "begin", "form": "a"}, {"cmd": "begin", "form": "AB"},
                        {"cmd": "begin"}, {"cmd": "seal"}, {"cmd": "start"}):
                status, _ = self.request("POST", "/api/exam-ssh", bad)
                self.assertEqual(status, 400, bad)
            run_cka.assert_not_called()

            self.request("POST", "/api/exam-ssh", {"cmd": "begin", "form": "B", "allowSeen": True})
            self.request("POST", "/api/exam-ssh", {"cmd": "begin", "form": "A", "allowSeen": "yes"})
            self.request("POST", "/api/exam-ssh", {"cmd": "finish"})
            self.request("POST", "/api/exam-ssh", {"cmd": "cleanup"})
            self.assertEqual([c.args[0] for c in run_cka.call_args_list], [
                ["exam-ssh", "begin", "--form", "B", "--allow-seen"],
                ["exam-ssh", "begin", "--form", "A"],
                ["exam-ssh", "finish"],
                ["exam-ssh", "cleanup"],
            ])

    def test_question_number_is_bounded_and_text_comes_from_the_runner(self):
        with mock.patch.object(SERVER, "run_cka", return_value=(0, "body")) as run_cka:
            for bad in ("0", "18", "x", "01"):
                status, _ = self.request("GET", "/api/exam-ssh/question/" + bad)
                self.assertEqual(status, 400, bad)
            status, body = self.request("GET", "/api/exam-ssh/question/17")
        self.assertEqual(status, 200)
        self.assertEqual(body["output"], "body")
        run_cka.assert_called_once_with(["exam-ssh", "question", "17"], timeout=60)

    def test_local_exam_cannot_start_during_a_supervised_run(self):
        self.make_run(phase="RUNNING")
        with mock.patch.object(SERVER, "run_cka") as run_cka:
            status, _ = self.request("POST", "/api/exam", {"cmd": "start"})
        self.assertEqual(status, 409)
        run_cka.assert_not_called()


if __name__ == "__main__":
    unittest.main()
