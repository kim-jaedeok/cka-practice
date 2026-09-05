#!/usr/bin/env python3
"""Dependency lock invariants that do not require a live cluster."""

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCK = ROOT / "cluster" / "versions.lock.yaml"


def read_flat_lock():
    values = {}
    for line in LOCK.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, raw = line.split(":", 1)
        raw = raw.strip()
        if not (raw.startswith('"') and raw.endswith('"')):
            raise AssertionError(f"unquoted lock value: {key}")
        if key in values:
            raise AssertionError(f"duplicate lock key: {key}")
        values[key] = raw[1:-1]
    return values


class VersionLockTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = read_flat_lock()

    def test_kind_node_is_exact_v135_digest(self):
        image = self.lock["kind_node_image"]
        self.assertRegex(image, r"^kindest/node:v1\.35\.\d+@sha256:[0-9a-f]{64}$")
        self.assertEqual(self.lock["kubernetes_version"], image.split(":", 1)[1].split("@", 1)[0])

    def test_kind_release_binary_is_exact_and_checksummed(self):
        version = self.lock["kind_version"]
        self.assertEqual(self.lock["schema_version"], "2")
        self.assertEqual(
            self.lock["kind_release_base_url"],
            "https://github.com/kubernetes-sigs/kind/releases/download/" + version,
        )
        for arch in ("amd64", "arm64"):
            self.assertRegex(
                self.lock[f"kind_linux_{arch}_sha256"],
                r"^[0-9a-f]{64}$",
            )

    def test_etcd_image_is_exact_v36_patch(self):
        self.assertRegex(
            self.lock["etcd_image"],
            r"^registry\.k8s\.io/etcd:3\.6\.\d+-\d+$",
        )

    def test_remote_manifests_use_versioned_release_urls(self):
        for key in (
            "calico_manifest_url",
            "metrics_server_manifest_url",
            "ingress_nginx_manifest_url",
        ):
            url = self.lock[key]
            self.assertNotIn("/main/", url, key)
            self.assertNotIn("/master/", url, key)
            self.assertNotIn("/latest/", url, key)

    def test_ingress_controller_image_is_exact_versioned_digest(self):
        locked_version = self.lock["ingress_nginx_version"]
        self.assertTrue(locked_version.startswith("controller-"))
        version = locked_version[len("controller-") :]
        image = self.lock["ingress_nginx_controller_image"]
        self.assertRegex(
            image,
            r"^registry\.k8s\.io/ingress-nginx/controller:v\d+\.\d+\.\d+@sha256:[0-9a-f]{64}$",
        )
        self.assertEqual(image.split(":", 1)[1].split("@", 1)[0], version)

    def test_download_checksums_are_sha256(self):
        for key, value in self.lock.items():
            if key.endswith("_sha256"):
                self.assertRegex(value, re.compile(r"^[0-9a-f]{64}$"), key)

    def test_cloud_provider_kind_release_is_exact_and_versioned(self):
        version = self.lock["cloud_provider_kind_version"]
        self.assertRegex(version, r"^v\d+\.\d+\.\d+$")
        self.assertEqual(
            self.lock["cloud_provider_kind_release_base_url"],
            "https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/"
            + version,
        )
        self.assertRegex(
            self.lock["cloud_provider_kind_proxy_image"],
            r"^docker\.io/[a-z0-9._/-]+:v?\d+\.\d+\.\d+$",
        )
        self.assertRegex(
            self.lock["cloud_provider_kind_proxy_repo_digest"],
            r"^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$",
        )
        for arch in ("amd64", "arm64"):
            self.assertRegex(
                self.lock[f"cloud_provider_kind_linux_{arch}_sha256"],
                r"^[0-9a-f]{64}$",
            )
            self.assertRegex(
                self.lock[f"cloud_provider_kind_linux_{arch}_binary_sha256"],
                r"^[0-9a-f]{64}$",
            )


if __name__ == "__main__":
    unittest.main()
