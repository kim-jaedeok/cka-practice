#!/usr/bin/env python3
"""Static provenance and semantic contracts for the disposable CSI lab."""

from __future__ import annotations

import hashlib
import pathlib
import re
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CSI = ROOT / "cluster" / "csi"
QDIR = ROOT / "questions" / "storage" / "st-06"


def flat_lock(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r'([a-z][a-z0-9_]*): "([^"]+)"', line)
        if not match:
            raise AssertionError(f"{path}:{number}: invalid flat lock entry")
        key, value = match.groups()
        if key in values:
            raise AssertionError(f"{path}:{number}: duplicate {key}")
        values[key] = value
    return values


class CsiAssetContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = flat_lock(CSI / "assets.lock")
        cls.manifest_path = CSI / cls.lock["driver_manifest"]
        cls.manifest = cls.manifest_path.read_text(encoding="utf-8")

    def test_source_and_manifest_are_immutable(self):
        self.assertEqual(
            self.lock["source_repository"],
            "https://github.com/kubernetes-csi/csi-driver-host-path",
        )
        self.assertRegex(self.lock["source_tag"], r"^v\d+\.\d+\.\d+$")
        self.assertRegex(self.lock["source_commit"], r"^[0-9a-f]{40}$")
        actual = hashlib.sha256(self.manifest_path.read_bytes()).hexdigest()
        self.assertEqual(actual, self.lock["driver_manifest_sha256"])

    def test_every_runtime_image_uses_the_locked_registry_digest(self):
        linux_amd64_children = {
            "hostpath": "sha256:cf08eec6a810b81299e6342719fb77c4c4072fbd43541c30ae1a4ca47a93c326",
            "registrar": "sha256:0fc05c749072bea889beffc97499f6836f74aebe351c78ff8d90d671c35f04da",
            "liveness": "sha256:c966d36f5353f71033c1a7b0321a9a670f8929af8740f714e455902b312a82a6",
            "provisioner": "sha256:54de28a6565647405647b34d092eefb4a51c7be14f29bdafc721773a5ec0600c",
            "attacher": "sha256:41dc0a91e103ee2e499df459526eb76ae57db0e8789385757df34fdac11e92d8",
        }
        linux_amd64_configs = {
            "hostpath": "sha256:09f69e9cbcb0d5e4bca212f2a4f403127b246b93b767b24fb61bc9f4dd243858",
            "registrar": "sha256:905ecc40d0b09c1ccfe82596e1996bf8285346ef31be259080e7277429116337",
            "liveness": "sha256:b6d35c6d5906de641322e3e440847ce219111a7ad5df72f0b2c6e15562c2ca9b",
            "provisioner": "sha256:d2554c75df37acb1f0671d9f66e395b402243cd82c778f0863d4d5361780a5d6",
            "attacher": "sha256:7272884ab4c3e4b672210d2839d599f38af7977c46b1c30594e81ce568b1967f",
        }
        self.assertEqual(self.lock["schema_version"], "2")
        self.assertEqual(self.lock["platform"], "linux/amd64")
        pairs = []
        for prefix in ("hostpath", "registrar", "liveness", "provisioner", "attacher"):
            image = self.lock[f"{prefix}_image"]
            digest = self.lock[f"{prefix}_digest"]
            self.assertRegex(image, r"^registry\.k8s\.io/sig-storage/.+:v\d+\.\d+\.\d+$")
            self.assertRegex(digest, r"^sha256:[0-9a-f]{64}$")
            self.assertEqual(digest, linux_amd64_children[prefix])
            self.assertEqual(self.lock[f"{prefix}_image_id"], linux_amd64_configs[prefix])
            pairs.append(f"{image.rsplit(':', 1)[0]}@{digest}")
        actual = re.findall(r"^\s+image:\s+(\S+)\s*$", self.manifest, re.MULTILINE)
        self.assertCountEqual(actual, pairs)

    def test_bundle_is_platform_scoped_and_import_is_verified(self):
        cache = (CSI / "cache-images.sh").read_text(encoding="utf-8")
        runtime = (ROOT / "lib" / "csi.sh").read_text(encoding="utf-8")
        self.assertIn('docker pull --platform "$CSI_PLATFORM" "$ref"', cache)
        self.assertRegex(
            cache,
            r'docker image save --platform "\$CSI_PLATFORM" \\\n'
            r'\s+--output "\$tmp/\$CSI_IMAGE_BUNDLE" '
            r'"\$\{locked_tags\[@\]\}"',
        )
        self.assertNotRegex(cache, r"docker image save\s+--output")
        self.assertIn('docker image tag "$ref" "$image"', cache)
        self.assertIn('csi_archive_verify "$tmp/$CSI_IMAGE_BUNDLE"', cache)
        self.assertIn('python3 "$CSI_ARCHIVE_VERIFIER"', runtime)
        self.assertIn('status.get("id", "")', runtime)
        self.assertIn('ctr --namespace=k8s.io images tag --local --force', runtime)
        self.assertIn('csi_node_ref_manifest_matches', runtime)
        self.assertIn('csi_node_manifest_config_matches', runtime)
        self.assertIn('csi_node_publish_pinned_ref "$node" "$image"', runtime)
        self.assertIn('expected_repo_digest in digests', runtime)

    def test_csi_mutations_require_the_selected_sealed_cell(self):
        runtime = (ROOT / "lib" / "csi.sh").read_text(encoding="utf-8")
        setup = (QDIR / "setup.sh").read_text(encoding="utf-8")
        teardown = (QDIR / "teardown.sh").read_text(encoding="utf-8")
        self.assertIn("cell_active_identity_matches st-06 csi-cell", runtime)
        self.assertIn("csi_require_disposable_cell", runtime)
        self.assertIn('csi_require_disposable_cell "$QID" csi-cell', setup)
        self.assertIn("csi_require_disposable_cell st-06 csi-cell", teardown)
        self.assertNotRegex(
            runtime,
            r"CKA_CONTEXT.*\^kind-cka-cell-st-06",
        )

    def test_csi_preload_external_commands_have_process_deadlines(self):
        runtime = (ROOT / "lib" / "csi.sh").read_text(encoding="utf-8")
        self.assertIn(
            'csi_external_timeout() { timeout --foreground --kill-after=5s "$@"; }',
            runtime,
        )
        self.assertIn("csi_docker exec", runtime)
        self.assertIn("csi_external_timeout 300s kind load image-archive", runtime)
        self.assertIn("csi_external_timeout 30s kind get nodes", runtime)
        self.assertIn('cell_wait_api_ready "$1"', runtime)

    def test_cached_bundle_passes_locked_semantic_verifier_when_present(self):
        bundle = CSI / "assets" / self.lock["image_bundle"]
        checksum = pathlib.Path(f"{bundle}.sha256")
        if not bundle.is_file() or not checksum.is_file():
            self.skipTest("optional local CSI cache is absent")
        self.assertFalse(bundle.is_symlink())
        self.assertEqual(
            hashlib.sha256(bundle.read_bytes()).hexdigest(),
            checksum.read_text(encoding="utf-8").strip(),
        )
        arguments = [
            sys.executable,
            str(ROOT / "cluster" / "controllers" / "verify-oci-archive.py"),
            str(bundle),
            self.lock["platform"],
        ]
        for prefix in ("hostpath", "registrar", "liveness", "provisioner", "attacher"):
            arguments.extend(
                [
                    self.lock[f"{prefix}_image"],
                    self.lock[f"{prefix}_digest"],
                    self.lock[f"{prefix}_image_id"],
                ]
            )
        subprocess.run(arguments, check=True, timeout=60)

    def test_manifest_has_real_csi_control_and_node_components(self):
        for token in (
            "kind: CSIDriver",
            "name: hostpath.csi.k8s.io",
            "name: node-driver-registrar",
            "name: csi-provisioner",
            "name: csi-attacher",
            "mountPropagation: Bidirectional",
            "/var/lib/kubelet/plugins_registry",
        ):
            self.assertIn(token, self.manifest)
        self.assertEqual(self.manifest.count("imagePullPolicy: Never"), 5)
        self.assertNotIn("imagePullPolicy: IfNotPresent", self.manifest)

    def test_registrar_health_port_is_valid_and_not_candidate_scope(self):
        registrar = re.search(
            r"        - name: node-driver-registrar\n(?P<body>.*?)"
            r"(?=        - name: liveness-probe\n)",
            self.manifest,
            re.DOTALL,
        )
        self.assertIsNotNone(registrar)
        body = registrar.group("body")
        declared = re.search(r"\n\s+ports:\n\s+- name: ([a-z0-9-]+)\n", body)
        probe = re.search(r"\n\s+livenessProbe:.*?\n\s+port: ([a-z0-9-]+)\n", body, re.DOTALL)
        self.assertIsNotNone(declared)
        self.assertIsNotNone(probe)
        port_name = declared.group(1)
        self.assertEqual(port_name, probe.group(1))
        self.assertLessEqual(len(port_name), 15)
        self.assertRegex(port_name, r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
        self.assertRegex(port_name, r"[a-z]")

        question = (QDIR / "question.md").read_text(encoding="utf-8")
        meta = (QDIR / "meta.yaml").read_text(encoding="utf-8")
        self.assertNotIn(port_name, question)
        self.assertNotIn("registrar-health", question)
        self.assertRegex(meta, r"(?m)^points: 10$")

    def test_cri_polling_treats_empty_status_as_a_quiet_miss(self):
        runtime = (ROOT / "lib" / "csi.sh").read_text(encoding="utf-8")
        self.assertIn("except (json.JSONDecodeError, UnicodeDecodeError):", runtime)
        self.assertIn("for ((attempt=1; attempt<=30; attempt++))", runtime)
        self.assertIn('crictl inspecti "$2" 2>/dev/null', runtime)

    def test_grader_api_reads_and_streaming_exec_are_bounded(self):
        grade = (QDIR / "grade.sh").read_text(encoding="utf-8")
        self.assertIn('ST06_API_REQUEST_TIMEOUT="10s"', grade)
        self.assertIn('kctx --request-timeout="$ST06_API_REQUEST_TIMEOUT" "$@"', grade)
        self.assertIn('ST06_EXEC_TIMEOUT="15s"', grade)
        self.assertIn('timeout --foreground "$ST06_EXEC_TIMEOUT"', grade)
        self.assertIn("124|137)", grade)
        self.assertIn("grade_invalid \"st-06 writer data-path exec exceeded", grade)
        self.assertIn(
            '"st06_writer_contract && st06_writer_marker_exact"',
            grade,
        )
        self.assertNotIn("$(kctx -n csi-lab exec writer", grade)

        raw_gets = [
            line
            for line in grade.splitlines()
            if re.search(r"\bkctx\b.*\bget\b", line)
            and "st06_kctx" not in line
        ]
        self.assertEqual(raw_gets, [])

    def test_live_runner_reports_every_grade_and_alternative_stage(self):
        live = (ROOT / "tests" / "csi-live-test.sh").read_text(encoding="utf-8")
        for label in (
            "canonical solution",
            "canonical grade",
            "alternative: request canonical writer deletion",
            "alternative: wait for canonical writer deletion",
            "alternative: apply writer without nodeSelector",
            "alternative: wait for writer Ready",
            "alternative grade",
            "cleanup disposable CSI cell",
        ):
            self.assertIn(label, live)
        self.assertIn('timeout --foreground "${seconds}s" "$@"', live)
        self.assertIn("csi_live_diagnostics", live)
        self.assertIn("[diag] writer deletion and scheduling fields", live)
        self.assertIn("[diag] API-defaulted CSIDriver spec", live)
        self.assertIn("[diag] CSINode driver registrations", live)
        self.assertIn("DRIVERS:.spec.drivers[*].name", live)
        self.assertIn("--wait=false", live)
        self.assertIn('wait --for=delete pod/writer --timeout="${ALTERNATIVE_DELETE_WAIT}s"', live)
        self.assertIn("cleanup output is preserved above", live)
        self.assertNotIn('grade.sh" >/dev/null', live)
        self.assertNotIn('cleanup "$QID" >/dev/null', live)

    def test_csidriver_registration_uses_api_semantics_not_exact_shape(self):
        grade = (QDIR / "grade.sh").read_text(encoding="utf-8")
        match = re.search(
            r'driver, nodes = values\n(?P<body>.*?)'
            r'raise SystemExit\(0 if driver_ok and bool\(registered\) else 1\)',
            grade,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        verifier_body = match.group("body")

        def accepted(spec, registered_nodes):
            nodes = {
                "items": [
                    {
                        "metadata": {"name": "control-plane"},
                        "spec": {"drivers": None},
                    }
                ] + [
                    {
                        "metadata": {"name": f"node-{index}"},
                        "spec": {"drivers": [{"name": "hostpath.csi.k8s.io"}]},
                    }
                    for index in range(registered_nodes)
                ]
            }
            scope = {"driver": {"spec": spec}, "nodes": nodes}
            exec(verifier_body, scope)
            return scope["driver_ok"] and bool(scope["registered"])

        # Empty lifecycle modes and attachRequired are API-defaulted to the
        # Persistent attach behavior, and registration on multiple nodes is
        # valid for a node plugin.
        self.assertTrue(accepted({}, 2))
        self.assertTrue(
            accepted(
                {
                    "attachRequired": True,
                    "volumeLifecycleModes": ["Persistent", "Ephemeral"],
                    "podInfoOnMount": False,
                    "fsGroupPolicy": "ReadWriteOnceWithFSType",
                },
                1,
            )
        )
        self.assertFalse(accepted({"attachRequired": False}, 1))
        self.assertFalse(accepted({"volumeLifecycleModes": ["Ephemeral"]}, 1))
        self.assertFalse(accepted({}, 0))
        self.assertNotIn("len(registered) == 1", grade)
        self.assertIn('item.get("spec", {}).get("drivers") or []', grade)

    def test_lab_rejects_static_volume_shortcuts(self):
        grade = (QDIR / "grade.sh").read_text(encoding="utf-8")
        for token in (
            'csi.get("driver") == "hostpath.csi.k8s.io"',
            'bool(csi.get("volumeHandle"))',
            '"hostPath" not in ps and "local" not in ps',
            'annotations.get("pv.kubernetes.io/provisioned-by")',
            '"pvc-" + claim.get("metadata", {}).get("uid", "")',
            'storage.kubernetes.io/csiProvisionerIdentity',
            "get csinodes",
            "get volumeattachments",
            'get("persistentVolumeName")',
            'get("attached") is True',
        ):
            self.assertIn(token, grade)
        near_miss = (QDIR / "near-miss.sh").read_text(encoding="utf-8")
        self.assertIn("hostPath:", near_miss)

    def test_required_question_files_exist(self):
        for name in (
            "meta.yaml",
            "setup.sh",
            "question.md",
            "solve.sh",
            "answer.md",
            "grade.sh",
            "near-miss.sh",
            "teardown.sh",
        ):
            self.assertTrue((QDIR / name).is_file(), name)

    def test_reference_paths_reactivate_the_exact_cell(self):
        for name in ("solve.sh", "near-miss.sh"):
            text = (QDIR / name).read_text(encoding="utf-8")
            self.assertIn("cell_activate st-06 csi-cell", text)


if __name__ == "__main__":
    unittest.main()
