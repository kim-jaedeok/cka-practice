#!/usr/bin/env python3
"""Dependency-free validation for the flat question metadata contract."""

from __future__ import annotations

import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA_PATH = ROOT / "exam" / "question.schema.json"


def parse_scalar(raw: str):
    value = raw.strip()
    if not value:
        return ""
    if value in {"true", "false"}:
        return value == "true"
    if re.fullmatch(r"[0-9]+", value):
        return int(value)
    if value[0] in '["{' or value == "null":
        return json.loads(value)
    return value


def load_flat_yaml(path: pathlib.Path) -> dict[str, object]:
    result: dict[str, object] = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        if raw_line[:1].isspace() or ":" not in raw_line:
            raise AssertionError(f"{path}:{number}: metadata must remain flat key: value YAML")
        key, value = raw_line.split(":", 1)
        if not re.fullmatch(r"[a-z][a-z0-9_]*", key):
            raise AssertionError(f"{path}:{number}: invalid key {key!r}")
        if key in result:
            raise AssertionError(f"{path}:{number}: duplicate key {key!r}")
        result[key] = parse_scalar(value)
    return result


class QuestionMetadataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        cls.properties = cls.schema["properties"]
        cls.required = set(cls.schema["required"])

    def assert_property(self, key: str, value: object, source: pathlib.Path):
        spec = self.properties[key]
        with self.subTest(source=source.name, key=key):
            if "type" in spec:
                expected = spec["type"]
                type_ok = {
                    "string": isinstance(value, str),
                    "integer": isinstance(value, int) and not isinstance(value, bool),
                    "boolean": isinstance(value, bool),
                    "array": isinstance(value, list),
                    "object": isinstance(value, dict),
                }[expected]
                self.assertTrue(type_ok, f"{source}: {key} must be {expected}")
            if "enum" in spec:
                self.assertIn(value, spec["enum"], f"{source}: unsupported {key}={value!r}")
            if isinstance(value, int) and "minimum" in spec:
                self.assertGreaterEqual(value, spec["minimum"], f"{source}: {key}")
            if isinstance(value, str) and "minLength" in spec:
                self.assertGreaterEqual(len(value), spec["minLength"], f"{source}: {key}")
            if isinstance(value, str) and "pattern" in spec:
                self.assertRegex(value, re.compile(spec["pattern"]), f"{source}: {key}")
            if isinstance(value, list):
                if spec.get("uniqueItems"):
                    self.assertEqual(len(value), len(set(value)), f"{source}: duplicate {key}")
                item_pattern = spec.get("items", {}).get("pattern")
                if item_pattern:
                    for item in value:
                        self.assertIsInstance(item, str, f"{source}: {key} item")
                        self.assertRegex(item, re.compile(item_pattern), f"{source}: {key} item")

    def test_all_question_metadata(self):
        files = sorted((ROOT / "questions").glob("*/*/meta.yaml"))
        self.assertTrue(files)
        for source in files:
            data = load_flat_yaml(source)
            with self.subTest(source=source):
                self.assertFalse(self.required - data.keys(), f"{source}: missing required keys")
                self.assertFalse(data.keys() - self.properties.keys(), f"{source}: unknown keys")
                self.assertEqual(data["id"], source.parent.name)
                self.assertEqual(data["domain"], source.parent.parent.name)
                for key, value in data.items():
                    self.assert_property(key, value, source)

                environment = data.get("environment", "shared-kind")
                mode = data.get("mode", "shared")
                mock_exam = data.get("mock_exam", True)
                if environment != "shared-kind":
                    self.assertEqual(data.get("isolation"), "disposable-cell", source)
                    self.assertIn(mode, {"individual-only", "full-readiness"}, source)
                    self.assertFalse(mock_exam, source)
                    self.assertIn("designated_host", data, source)
                    self.assertIn("ssh_profile", data, source)
                if mode == "individual-only":
                    self.assertFalse(mock_exam, source)

                for answer_file in data.get("answer_files", []):
                    self.assertNotIn("..", pathlib.PurePosixPath(answer_file).parts, source)
                    self.assertFalse(pathlib.PurePosixPath(answer_file).is_absolute(), source)

    def test_host_destructive_troubleshooting_labs_are_not_mock_candidates(self):
        catalog_path = ROOT / "exam" / "forms" / "question-catalog.tsv"
        catalog_enabled = {}
        for raw_line in catalog_path.read_text(encoding="utf-8").splitlines():
            if not raw_line or raw_line.startswith("#"):
                continue
            fields = raw_line.split("|")
            self.assertEqual(len(fields), 7, f"invalid catalog row: {raw_line}")
            catalog_enabled[fields[0]] = fields[6]

        for qid in ("ts-13", "ts-14", "ts-15"):
            source = ROOT / "questions" / "troubleshooting" / qid / "meta.yaml"
            data = load_flat_yaml(source)
            with self.subTest(qid=qid):
                self.assertEqual(data.get("mode"), "individual-only")
                self.assertIs(data.get("mock_exam"), False)
                self.assertIs(data.get("destructive"), True)
                self.assertEqual(
                    catalog_enabled.get(qid),
                    "false",
                    f"{qid} must remain disabled in the shared mock catalog",
                )


if __name__ == "__main__":
    unittest.main()
