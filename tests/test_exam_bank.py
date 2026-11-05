#!/usr/bin/env python3
"""Contracts that keep the held-out exam bank apart from practice questions."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BANK = ROOT / "exam" / "bank"
QUESTIONS = ROOT / "questions"
DOMAINS = {
    "st": "storage",
    "wl": "workloads-scheduling",
    "sn": "services-networking",
    "ca": "cluster-architecture",
    "ts": "troubleshooting",
}
REQUIRED_FILES = ("meta.yaml", "question.md", "setup.sh", "grade.sh", "solve.sh", "answer.md")


def shell_regex(name: str) -> re.Pattern[str]:
    text = (ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
    match = re.search(rf"^{name}='([^']+)'$", text, re.MULTILINE)
    if not match:
        raise AssertionError(f"{name} is missing from lib/common.sh")
    return re.compile(match.group(1))


PRACTICE_RE = shell_regex("CKA_PRACTICE_ID_RE")
BANK_RE = shell_regex("CKA_EXAM_BANK_ID_RE")
SAMPLE_IDS = ["st-01", "ts-17", "ex-st-01", "ex-ts-17", "xx-01", "ex-xx-01", "st-1", "ex-st-001", "smoke"]


def meta_value(path: pathlib.Path, key: str) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}:"):
            return line.split(":", 1)[1].strip()
    return ""


class IdRulesTest(unittest.TestCase):
    def test_practice_and_bank_rules_do_not_overlap(self):
        for qid in SAMPLE_IDS:
            with self.subTest(qid=qid):
                self.assertFalse(PRACTICE_RE.fullmatch(qid) and BANK_RE.fullmatch(qid))
        self.assertTrue(PRACTICE_RE.fullmatch("ts-01"))
        self.assertTrue(BANK_RE.fullmatch("ex-ts-01"))
        self.assertFalse(PRACTICE_RE.fullmatch("ex-ts-01"))
        self.assertFalse(BANK_RE.fullmatch("ts-01"))

    def test_schema_and_supervisor_accept_exactly_both_rules(self):
        schema = json.loads((ROOT / "exam" / "question.schema.json").read_text(encoding="utf-8"))
        schema_re = re.compile(schema["properties"]["id"]["pattern"])
        supervisor = (ROOT / "exam" / "ssh" / "supervisor" / "supervisor.py").read_text(encoding="utf-8")
        match = re.search(r'^QUESTION_ID_RE = re\.compile\(r"([^"]+)"\)$', supervisor, re.MULTILINE)
        self.assertIsNotNone(match)
        supervisor_re = re.compile(match.group(1))
        for qid in SAMPLE_IDS:
            expected = bool(PRACTICE_RE.fullmatch(qid) or BANK_RE.fullmatch(qid))
            with self.subTest(qid=qid):
                self.assertEqual(bool(schema_re.fullmatch(qid)), expected)
                self.assertEqual(bool(supervisor_re.fullmatch(qid)), expected)


class LayoutTest(unittest.TestCase):
    def test_practice_directories_use_practice_ids(self):
        dirs = [p for p in QUESTIONS.glob("*/*") if p.is_dir()]
        self.assertTrue(dirs)
        for qdir in dirs:
            with self.subTest(qdir=qdir.name):
                self.assertRegex(qdir.name, PRACTICE_RE)

    def test_bank_questions_are_complete_and_placed_by_domain(self):
        self.assertTrue((BANK / "README.md").is_file())
        for qdir in (p for p in BANK.glob("*/*") if p.is_dir()):
            with self.subTest(qdir=qdir.name):
                self.assertRegex(qdir.name, BANK_RE)
                self.assertEqual(qdir.parent.name, DOMAINS[qdir.name.split("-")[1]])
                for name in REQUIRED_FILES:
                    self.assertTrue((qdir / name).is_file(), name)
                self.assertEqual(meta_value(qdir / "meta.yaml", "id"), qdir.name)
                self.assertEqual(meta_value(qdir / "meta.yaml", "domain"), qdir.parent.name)


class IsolationTest(unittest.TestCase):
    """Practice-facing lists and the web UI must never name a bank question."""

    def test_practice_registries_do_not_list_bank_ids(self):
        for relative in (
            "exam/forms/question-catalog.tsv",
            "curriculum/cka-v1.37.yaml",
            "exam/ssh/supported-questions.txt",
            "exam/ssh/answer-files.tsv",
        ):
            text = (ROOT / relative).read_text(encoding="utf-8")
            with self.subTest(file=relative):
                self.assertIsNone(re.search(r"\bex-(st|wl|sn|ca|ts)-[0-9]{2}\b", text))

    def test_web_ui_accepts_practice_ids_only(self):
        spec = importlib.util.spec_from_file_location("cka_web_server_bank", ROOT / "web" / "server.py")
        server = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(server)
        self.assertEqual(pathlib.Path(server.QUESTIONS_DIR), QUESTIONS)
        for qid in SAMPLE_IDS:
            with self.subTest(qid=qid):
                self.assertEqual(
                    bool(server.PRACTICE_ID_RE.fullmatch(qid)), bool(PRACTICE_RE.fullmatch(qid))
                )
        self.assertIsNone(server.question_detail("ex-ts-01"))
        self.assertIsNone(server.question_detail(".."))


if __name__ == "__main__":
    unittest.main()
