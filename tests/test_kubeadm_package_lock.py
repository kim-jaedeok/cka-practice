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
        self.assertEqual(self.lock["from_version"], "1.36.0-1.1")
        self.assertEqual(self.lock["to_version"], "1.37.0-1.1")
        self.assertEqual(
            self.lock["from_repository"],
            "https://pkgs.k8s.io/core:/stable:/v1.36/deb",
        )
        self.assertEqual(
            self.lock["to_repository"],
            "https://pkgs.k8s.io/core:/stable:/v1.37/deb",
        )

    def test_all_ten_packages_are_file_and_checksum_locked(self):
        # Both v1.36 and v1.37 repositories publish kubernetes-cni 1.9.1.
        versions = {
            "cri-tools": ("1.36.0-1.1", "1.37.0-1.1"),
            "kubernetes-cni": ("1.9.1-1.1", "1.9.1-1.1"),
            "kubeadm": ("1.36.0-1.1", "1.37.0-1.1"),
            "kubelet": ("1.36.0-1.1", "1.37.0-1.1"),
            "kubectl": ("1.36.0-1.1", "1.37.0-1.1"),
        }
        official_sha256 = {
            ("cri-tools", "from"): "8cff9279de7767239e11bf9c21016579a4246e04e7da0c500c7a3f8491db986a",
            ("cri-tools", "to"): "a8eeede0deadc3d9e8f72859732441bfc86fbe60688926ef5410f01338927b71",
            ("kubernetes-cni", "from"): "4cd72d8cef4499d3dc410874287b40e8b4241e0772938c5820cbee37986c1d93",
            ("kubernetes-cni", "to"): "4cd72d8cef4499d3dc410874287b40e8b4241e0772938c5820cbee37986c1d93",
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
        self.assertEqual(self.lock["pause_image"], "registry.k8s.io/pause:3.10.2")
        self.assertEqual(
            self.lock["pause_digest"],
            "sha256:412c4a7219cb8a299a37337f3d87810c5340095322e15594a1637785adad0f17",
        )
        self.assertEqual(
            self.lock["pause_image_id"],
            "sha256:4a83b15d3ecfe0d916b2d0a7991bc2854a629b8097017c2ee1ff65b30ae4c07c",
        )
        cell = (CELL / "cell.sh").read_text(encoding="utf-8")
        cache = (CELL / "cache-packages.sh").read_text(encoding="utf-8")
        self.assertIn('preload_kubeadm_pause "$qid"', cell)
        self.assertIn("kind load image-archive", cell)
        self.assertIn("crictl inspecti", cell)
        self.assertIn('docker pull --platform "linux/$KUBEADM_PACKAGE_ARCH" "$pause_ref"', cache)
        self.assertEqual(
            cache.count('docker image save --platform "linux/$KUBEADM_PACKAGE_ARCH"'), 2
        )

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
        self.assertIn('docker pull --platform "linux/$KUBEADM_PACKAGE_ARCH" "$workload_ref"', cache)
        self.assertIn('docker image save --platform "linux/$KUBEADM_PACKAGE_ARCH"', cache)


if __name__ == "__main__":
    unittest.main()
