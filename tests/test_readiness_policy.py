#!/usr/bin/env python3
"""Validate that local readiness is stricter than the official pass mark."""

import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
POLICY = ROOT / "exam" / "readiness-policy.yaml"
CURRICULUM = ROOT / "curriculum" / "cka-v1.35.yaml"
READINESS_DOC = ROOT / "docs" / "readiness-policy.md"
SSH_LIVE = ROOT / "tests" / "ssh-supervised-live-test.sh"
SSH_LIVE_VOLUME_LIFECYCLE = ROOT / "tests" / "ssh-live-volume-lifecycle.sh"
OPERATOR_LIVE = ROOT / "tests" / "operator-gateway-live-test.sh"
OPT_IN_REQUIRED_LIVE = (
    ROOT / "tests" / "kubeadm-live-test.sh",
    ROOT / "tests" / "csi-live-test.sh",
    SSH_LIVE,
)


class ReadinessPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = json.loads(POLICY.read_text(encoding="utf-8"))
        cls.curriculum = json.loads(CURRICULUM.read_text(encoding="utf-8"))
        cls.readiness_doc = READINESS_DOC.read_text(encoding="utf-8")

    def test_conservative_gates_are_internally_consistent(self):
        official = self.policy["officialPassPercent"]
        ready = self.policy["practiceReady"]
        self.assertEqual(official, 66)
        self.assertGreater(ready["minimumOverallPercentEachRun"], official)
        self.assertGreaterEqual(ready["minimumValidBlindRuns"], 2)
        self.assertGreaterEqual(ready["minimumDomainPercentEachRun"], 0)
        self.assertLessEqual(ready["minimumDomainPercentEachRun"], 100)
        self.assertEqual(ready["maximumOvertimeSeconds"], 0)
        self.assertTrue(ready["requireAllCurriculumCompetenciesCovered"])

    def test_sources_are_official(self):
        for source in self.policy["sources"]:
            self.assertTrue(
                source.startswith("https://docs.linuxfoundation.org/")
                or source.startswith("https://training.linuxfoundation.org/"),
                source,
            )

    def test_supervised_live_gate_checks_host_space_before_docker_allocation(self):
        script = SSH_LIVE.read_text(encoding="utf-8")
        guard = script.index("cell_host_storage_preflight")
        network_create = script.index("docker network create")
        cluster_create = script.index("kind create cluster")
        self.assertLess(guard, network_create)
        self.assertLess(guard, cluster_create)

    def test_supervised_live_uses_canonical_cluster_and_provider_network(self):
        script = SSH_LIVE.read_text(encoding="utf-8")
        self.assertIn('CLUSTER_NAME="cka"', script)
        self.assertNotIn('CLUSTER_NAME="cka-$RUN_ID"', script)
        self.assertIn('NETWORK_NAME="kind"', script)
        self.assertNotIn('NETWORK_NAME="cka-${RUN_ID}-net"', script)
        self.assertNotIn('KIND_EXPERIMENTAL_DOCKER_NETWORK="$NETWORK_NAME"', script)
        self.assertIn('org.cka-practice.ssh-live.run=$RUN_ID', script)
        self.assertIn('export CKA_CONTEXT="kind-$CLUSTER_NAME"', script)
        self.assertIn('--name "$CLUSTER_NAME"', script)

    def test_supervised_live_seals_and_removes_only_exact_node_volumes(self):
        script = SSH_LIVE.read_text(encoding="utf-8")
        lifecycle = SSH_LIVE_VOLUME_LIFECYCLE.read_text(encoding="utf-8")
        node_record = script.index("record_current_nodes || die_live")
        volume_seal = script.index("seal_exact_node_volumes || die_live", node_record)
        workload_setup = script.index('bash "$ROOT/cluster/setup-cluster.sh"')
        cleanup_verify = script.index('ssh_live_volume_verify "$NODE_VOLUME_JOURNAL" 1')
        node_remove = script.index("remove_exact_nodes || rc=1", cleanup_verify)
        volume_remove = script.index(
            'ssh_live_volume_remove_sealed "$NODE_VOLUME_JOURNAL"', node_remove
        )
        self.assertLess(node_record, volume_seal)
        self.assertLess(volume_seal, workload_setup)
        self.assertLess(cleanup_verify, node_remove)
        self.assertLess(node_remove, volume_remove)
        self.assertIn('[[ "$1" =~ ^[0-9a-f]{64}$ ]]', lifecycle)
        self.assertIn("_ssh_live_volume_fingerprint", lifecycle)
        self.assertIn("_ssh_live_volume_attachment_ids", lifecycle)
        self.assertIn('"$SSH_LIVE_DOCKER_BIN" volume rm "$name"', lifecycle)
        self.assertIn("node_inventory_is_recorded_subset", script)
        self.assertNotIn("volume prune", lifecycle)
        self.assertNotIn("volume ls", lifecycle)

    def test_supervised_live_rejects_canonical_orphans_before_mutation(self):
        script = SSH_LIVE.read_text(encoding="utf-8")
        orphan_inventory = script.index('canonical_orphans="$(docker container ls')
        canonical_filter = script.index(
            'label=io.x-k8s.kind.cluster=$CLUSTER_NAME', orphan_inventory
        )
        orphan_refusal = script.index(
            "refusing canonical KIND node containers not reported by kind",
            canonical_filter,
        )
        network_create = script.index("docker network create")
        cluster_create = script.index("kind create cluster")
        self.assertLess(orphan_inventory, orphan_refusal)
        self.assertLess(orphan_refusal, network_create)
        self.assertLess(orphan_refusal, cluster_create)

    def test_supervised_live_rejects_preexisting_kind_network_before_mutation(self):
        script = SSH_LIVE.read_text(encoding="utf-8")
        inventory = script.index('docker network ls --no-trunc --format json')
        exact_name = script.index('record.get("Name") == target', inventory)
        refusal = script.index(
            "refusing a host with a pre-existing canonical KIND network",
            exact_name,
        )
        network_create = script.index("docker network create")
        cluster_create = script.index("kind create cluster")
        self.assertLess(inventory, exact_name)
        self.assertLess(exact_name, refusal)
        self.assertLess(refusal, network_create)
        self.assertLess(refusal, cluster_create)

    def test_omitted_required_live_opt_in_is_not_a_success(self):
        for path in OPT_IN_REQUIRED_LIVE:
            preflight = "\n".join(path.read_text(encoding="utf-8").splitlines()[:20])
            self.assertIn("SKIP", preflight, path.name)
            self.assertIn("exit 77", preflight, path.name)
            self.assertNotIn("exit 0", preflight, path.name)

        operator_preflight = "\n".join(
            OPERATOR_LIVE.read_text(encoding="utf-8").splitlines()[:20]
        )
        self.assertIn("CKA_CONTROLLER_LIVE", operator_preflight)
        self.assertIn("|| die", operator_preflight)
        self.assertNotIn("exit 0", operator_preflight)

    def test_readiness_document_tracks_live_registry_without_overclaiming(self):
        validation = self.curriculum["implementationValidation"]
        self.assertIn(validation["status"], self.readiness_doc)
        for suite in validation["requiredLiveSuites"]:
            self.assertIn(suite, self.readiness_doc)
        for item in validation["liveResults"]["passed"]:
            if item["suite"] == "tests/ssh-supervised-live-test.sh":
                self.assertEqual(len(item["cases"]), 17)
                continue
            for qid in item["cases"]:
                self.assertIn(f"`{qid}`", self.readiness_doc)
        self.assertEqual(validation["liveResults"]["pending"], [])
        ssh = next(
            item
            for item in validation["liveResults"]["passed"]
            if item["suite"] == "tests/ssh-supervised-live-test.sh"
        )
        for supporting in ssh["supportingChecksPassed"]:
            self.assertIn(supporting, self.readiness_doc)
        self.assertIn("17문항 전체 gate를 실행했다", self.readiness_doc)
        self.assertIn("104/104", self.readiness_doc)
        self.assertIn("deadline이 `TIMEOUT`을 강제", self.readiness_doc)
        self.assertIn("guard process를 강제로 종료한 뒤 재시작", self.readiness_doc)
        self.assertIn("저장소의 구현·live 검증 완료", self.readiness_doc)
        self.assertIn("공식 합격 보장이나 개인의 학습", self.readiness_doc)
        self.assertNotIn("static-complete-live-pending", self.readiness_doc)
        self.assertNotIn("clean-host 전체 gate 미실행", self.readiness_doc)
        self.assertNotIn("guard readiness", self.readiness_doc)
        self.assertNotIn("현재 `ca-12`만", self.readiness_doc)


if __name__ == "__main__":
    unittest.main()
