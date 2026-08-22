#!/usr/bin/env python3
"""Contracts for the real ca-06 N-1 to N package upgrade cell."""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CELL = ROOT / "cluster" / "cells" / "kubeadm"
CA06 = ROOT / "questions" / "cluster-architecture" / "ca-06"


def load_lock() -> dict[str, str]:
    result: dict[str, str] = {}
    for number, line in enumerate((CELL / "packages.lock").read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r'([a-z][a-z0-9_]*): "([^"]+)"', line)
        if not match:
            raise AssertionError(f"packages.lock:{number}: invalid entry")
        key, value = match.groups()
        if key in result:
            raise AssertionError(f"packages.lock:{number}: duplicate {key}")
        result[key] = value
    return result


class KubeadmPackageLockTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = load_lock()

    def test_adjacent_minor_versions_and_official_repositories(self):
        self.assertEqual(self.lock["from_version"], "1.34.0-1.1")
        self.assertEqual(self.lock["to_version"], "1.35.0-1.1")
        self.assertEqual(
            self.lock["from_repository"],
            "https://pkgs.k8s.io/core:/stable:/v1.34/deb",
        )
        self.assertEqual(
            self.lock["to_repository"],
            "https://pkgs.k8s.io/core:/stable:/v1.35/deb",
        )

    def test_all_ten_packages_are_file_and_checksum_locked(self):
        versions = {
            "cri-tools": ("1.34.0-1.1", "1.35.0-1.1"),
            "kubernetes-cni": ("1.7.1-1.1", "1.8.0-1.1"),
            "kubeadm": ("1.34.0-1.1", "1.35.0-1.1"),
            "kubelet": ("1.34.0-1.1", "1.35.0-1.1"),
            "kubectl": ("1.34.0-1.1", "1.35.0-1.1"),
        }
        official_sha256 = {
            ("cri-tools", "from"): "90c1f4c9d602e904214fa4e6315b47687c7964a6bd1d2420e63b266233bba20c",
            ("cri-tools", "to"): "325b0d3731cb1daf210da5026a1d9ea35f5d63cab156c8817c0e136e36a60788",
            ("kubernetes-cni", "from"): "92aff22a4f49fa27a615353215a1602033de80ed908dd1f243270163e741b78a",
            ("kubernetes-cni", "to"): "39fbccec875ea73bda221cc6777b1344733bd81c875aa1faa5271854f9c7f9c5",
        }
        for package, (from_version, to_version) in versions.items():
            key = package.replace("-", "_")
            for side, version in (("from", from_version), ("to", to_version)):
                self.assertEqual(
                    self.lock[f"{key}_{side}_file"],
                    f"{package}_{version}_amd64.deb",
                )
                self.assertRegex(self.lock[f"{key}_{side}_sha256"], r"^[0-9a-f]{64}$")
                if (package, side) in official_sha256:
                    self.assertEqual(
                        self.lock[f"{key}_{side}_sha256"],
                        official_sha256[(package, side)],
                    )

    def test_upgrade_uses_real_packages_and_binary_versions(self):
        combined = "\n".join(
            (CA06 / name).read_text(encoding="utf-8")
            for name in ("setup.sh", "solve.sh", "grade.sh", "question.md", "answer.md")
        )
        self.assertNotIn("stand-in", combined.lower())
        self.assertNotIn("/var/lib/cka/pkg", combined)
        self.assertIn("kubeadm upgrade node", combined)
        self.assertIn("kubelet --version", combined)
        self.assertIn("status.nodeInfo.kubeletVersion", combined)
        self.assertFalse((CA06 / "node-setup.sh").exists())

    def test_seed_requires_checksum_verified_local_debs(self):
        seed = (CELL / "seed-upgrade.sh").read_text(encoding="utf-8")
        cache = (CELL / "package-cache.sh").read_text(encoding="utf-8")
        self.assertIn("SHA256SUMS", seed)
        self.assertIn('source "$SCRIPT_DIR/package-cache.sh"', seed)
        self.assertIn("export DEBIAN_FRONTEND=noninteractive", seed)
        self.assertIn('dpkg --force-confold --install "$@"', seed)
        self.assertIn("cri-tools kubernetes-cni kubeadm kubelet kubectl", seed)
        self.assertIn("for package in cri-tools kubernetes-cni kubeadm kubelet kubectl", cache)
        self.assertIn("sha256sum --check --strict", cache)

    def test_blank_cells_preload_the_exact_kubeadm_pause_image(self):
        self.assertEqual(self.lock["pause_image"], "registry.k8s.io/pause:3.10.1")
        self.assertEqual(
            self.lock["pause_digest"],
            "sha256:e5b941ef8f71de54dc3a13398226c269ba217d06650a21bd3afcf9d890cf1f41",
        )
        self.assertEqual(
            self.lock["pause_image_id"],
            "sha256:cd073f4c5f6a8e9dc6f3125ba00cf60819cae95c1ec84a1f146ee4a9cf9e803f",
        )
        cell = (CELL / "cell.sh").read_text(encoding="utf-8")
        cache = (CELL / "cache-packages.sh").read_text(encoding="utf-8")
        self.assertIn('preload_kubeadm_pause "$qid"', cell)
        self.assertIn("kind load image-archive", cell)
        self.assertIn("crictl inspecti", cell)
        self.assertIn('docker pull --platform linux/amd64 "$pause_ref"', cache)
        self.assertEqual(cache.count("docker image save --platform linux/amd64"), 2)

    def test_cell_workloads_are_offline_and_digest_locked(self):
        expected = {
            "workload_nginx_digest": "sha256:1881968aff6f7cdcc4b888c00a11f4ce241ad7ec957e0cb4a9e19e93a3ff87ea",
            "workload_nginx_image_id": "sha256:5dfe511714e1fa9a9d1074193a6cc7fa0feab5d680be166336817a5fb57f4cbd",
            "workload_busybox_digest": "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662",
            "workload_busybox_image_id": "sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d",
        }
        for key, value in expected.items():
            self.assertEqual(self.lock[key], value)
        cell = (CELL / "cell.sh").read_text(encoding="utf-8")
        cache = (CELL / "cache-packages.sh").read_text(encoding="utf-8")
        self.assertIn("kubeadm_workload_cache_verify", cell)
        self.assertIn("kind load image-archive", cell)
        self.assertNotIn("crictl pull", cell)
        self.assertIn('docker pull --platform linux/amd64 "$workload_ref"', cache)
        self.assertIn("docker image save --platform linux/amd64", cache)


if __name__ == "__main__":
    unittest.main()
