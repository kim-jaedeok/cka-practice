#!/usr/bin/env python3
"""Validate the official CKA v1.35 competency registry."""

import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "curriculum" / "cka-v1.35.yaml"
QUESTION_ID = re.compile(r"^(ca|sn|st|ts|wl)-\d{2}$")


class CurriculumRegistryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # JSON is a strict subset of YAML, so this file stays dependency-free.
        cls.data = json.loads(REGISTRY.read_text(encoding="utf-8"))

    def test_domain_weights_and_competency_count(self):
        domains = self.data["domains"]
        self.assertEqual(sum(domain["weight"] for domain in domains), 100)
        self.assertEqual(sum(len(domain["competencies"]) for domain in domains), 27)

    def test_competency_ids_are_unique(self):
        ids = [
            item["id"]
            for domain in self.data["domains"]
            for item in domain["competencies"]
        ]
        self.assertEqual(len(ids), len(set(ids)))

    def test_current_lab_references_exist(self):
        for domain in self.data["domains"]:
            for item in domain["competencies"]:
                with self.subTest(competency=item["id"]):
                    self.assertIn(item["status"], {"covered", "partial", "gap"})
                    for qid in item["labs"]:
                        self.assertRegex(qid, QUESTION_ID)
                        matches = list((ROOT / "questions").glob(f"*/{qid}"))
                        self.assertEqual(len(matches), 1, qid)

                    if item["status"] == "covered":
                        self.assertTrue(item["labs"])
                    else:
                        self.assertTrue(item["planned"])

    def test_required_live_suites_are_real_scripts(self):
        validation = self.data["implementationValidation"]
        self.assertEqual(validation["status"], "practice-ready-live-complete")
        suites = validation["requiredLiveSuites"]
        self.assertGreaterEqual(len(suites), 4)
        self.assertEqual(len(suites), len(set(suites)))
        for relative in suites:
            with self.subTest(suite=relative):
                self.assertRegex(relative, r"^tests/[a-z0-9-]+\.sh$")
                self.assertTrue((ROOT / relative).is_file())

    def test_live_results_partition_required_suites(self):
        validation = self.data["implementationValidation"]
        results = validation["liveResults"]
        self.assertEqual(results["validatedOn"], "2026-08-23")

        passed = {item["suite"]: item for item in results["passed"]}
        pending = {item["suite"]: item for item in results["pending"]}
        self.assertFalse(set(passed) & set(pending))
        self.assertEqual(
            set(validation["requiredLiveSuites"]), set(passed) | set(pending)
        )
        self.assertEqual(
            passed["tests/kubeadm-live-test.sh"]["cases"],
            ["ca-12", "ca-11", "ca-06"],
        )
        self.assertEqual(
            passed["tests/operator-gateway-live-test.sh"]["cases"],
            ["ca-09", "ca-13", "sn-05"],
        )
        self.assertEqual(
            passed["tests/csi-live-test.sh"]["cases"], ["st-06"]
        )
        ssh = passed["tests/ssh-supervised-live-test.sh"]
        self.assertEqual(
            ssh["cases"],
            [
                "wl-03",
                "wl-02",
                "ts-01",
                "ts-03",
                "wl-08",
                "ts-02",
                "ts-04",
                "sn-01",
                "st-01",
                "sn-09",
                "sn-08",
                "st-04",
                "ca-01",
                "ca-02",
                "ca-05",
                "ca-08",
                "ts-10",
            ],
        )
        self.assertEqual(ssh["score"], "104/104")
        self.assertEqual(ssh["deadlineVerdict"], "TIMEOUT")
        self.assertEqual(ssh["guardRestart"], "passed")
        self.assertEqual(ssh["sshPath"], "base-to-target passed")
        self.assertEqual(
            ssh["postCleanupObjects"],
            {
                "kindClusters": 0,
                "sshObjects": 0,
                "kindNodes": 0,
                "kindNetworks": 0,
                "dockerVolumes": 0,
            },
        )
        self.assertTrue(all(item["cleanup"] == "passed" for item in passed.values()))
        self.assertEqual(pending, {})
        supporting = ssh["supportingChecksPassed"]
        self.assertEqual(
            supporting,
            [
                "tests/ssh-supervisor-docker-smoke.sh",
                "tests/ssh-runner-docker-smoke.sh",
            ],
        )
        for relative in supporting:
            self.assertTrue((ROOT / relative).is_file(), relative)


if __name__ == "__main__":
    unittest.main()
