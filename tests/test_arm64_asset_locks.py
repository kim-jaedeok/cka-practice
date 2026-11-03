#!/usr/bin/env python3
"""linux/arm64 counterparts of the disposable-cell asset locks.

The amd64 locks (packages.lock, assets.lock) stay byte-for-byte unchanged and
keep their own contract tests. Each *.linux-arm64.lock must carry the same
keys, keep architecture-neutral values identical, and pin the official arm64
platform-manifest, image-config and .deb digests below.
"""

from __future__ import annotations

import hashlib
import pathlib
import re
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
KUBEADM = ROOT / "cluster" / "cells" / "kubeadm"
CONTROLLERS = ROOT / "cluster" / "controllers"
CSI = ROOT / "cluster" / "csi"
VERIFIER = CONTROLLERS / "verify-oci-archive.py"
HEX64 = re.compile(r"[0-9a-f]{64}")


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


# Official linux/arm64 values: platform manifests and image configs from the
# registries' image indexes, .deb SHA256 fields from pkgs.k8s.io Packages.
ARM64_KUBEADM = {
    "pause_digest": "sha256:a433214620b407678934ebd69690a9ed6066247231eacfba181fab20dbc3dbf1",
    "pause_image_id": "sha256:3884a337192318652b28de0de1aeb07f446a14f220feb5066f03e93f23ea3b60",
    "workload_nginx_image_id": "sha256:8524ce6c9242ecdadb2974f0924ce4dd02f04d46915d5a0076eeccc0208cd6f8",
    "workload_busybox_image_id": "sha256:b7c873bd97bdc9046fc894e0b216c8aef31e0db4c5b761fb53022e40577ab6c0",
    "cri_tools_from_sha256": "ab8ff8eace53b18fb7316d17f3fa29a01f6fd92b885d3014db415ab7b84619cc",
    "cri_tools_to_sha256": "8c8373e8fb301d4a272671eb64bf957ddfb19c87afbcad0fc294dfb29ff8c1be",
    "kubernetes_cni_from_sha256": "fbe479bf9b303fc88bd7c61769687235efa36f684e8ec5e97d45d08669dd1d4d",
    "kubernetes_cni_to_sha256": "fbe479bf9b303fc88bd7c61769687235efa36f684e8ec5e97d45d08669dd1d4d",
    "kubeadm_from_sha256": "5e7513cb1d80fb31886ce7c7c97b2931c8663e856e65216d54cf3c1f9b30d577",
    "kubelet_from_sha256": "ae08405903a5ad8c0d116d7ae8a25154f298b141efce9018f975ddd1981dc53c",
    "kubectl_from_sha256": "d54bda2fe46784e39d9aaa0831b090782520deaaa1ca5993b2e4d126ffbeb04c",
    "kubeadm_to_sha256": "1e4652c10e36c1405dd27fae58191992d835534b7cda8daa11276323535d1f3e",
    "kubelet_to_sha256": "f2ebc0a55ef925a06d0e7343d1337a553cd6e4838bd284e8f4c0b13004a064b9",
    "kubectl_to_sha256": "2ecc3549965c1446c67337b9cc02a39f86dee94373348cb97ff52da37dbf91fd",
}

ARM64_CONTROLLERS = {
    "cert_manager_controller_digest": "sha256:9a2807ada15c98aea85162bed3a9d602a5a4760206158661433be0b3ea133837",
    "cert_manager_controller_image_id": "sha256:5283ffc3ebd6cf46ecf84f5e56730734b3de8d3de456c3a909f0077b5337c55d",
    "cert_manager_webhook_digest": "sha256:f6ed5d53a40429c99a28b68ce0429f3d75ac9588403519c6772a76df35f37695",
    "cert_manager_webhook_image_id": "sha256:4694bc08f6c866b0820ff7e82d673029b6d48ba0aaf79af528987ca114f426ec",
    "cert_manager_cainjector_digest": "sha256:0c5930d51b9acc07b1d1f6befa46bdc3591fc52c0254f6209bf595eb5fdb3b7c",
    "cert_manager_cainjector_image_id": "sha256:187d7de7d1d04dd40dbc62236b0e75eea4a0ae336b0de824c6e27e28fb102381",
    "envoy_gateway_digest": "sha256:47db1ae68eead0ca7ba96ca23e7654fd95a43c1c8fdc63f55b9e77054107f6c5",
    "envoy_gateway_image_id": "sha256:81a4ed31671d179b62f9c6e7675375e20a7b945a59a08d9c3a2915810cf3980a",
    "envoy_proxy_digest": "sha256:8dbb967dba5d22a28f0e7974173aa6d4a5621ce48ac6d44142d9b4d9c960af14",
    "envoy_proxy_image_id": "sha256:141de0b9b2d440fc04c25aaaa369c601e229388bff9b0669cb9c66ef8bf0ac98",
    "envoy_ratelimit_digest": "sha256:8cd6ed736b24ccbfafda66a3428b85cfac8280cb816d3ad100aa295b4969e8a1",
    "envoy_ratelimit_image_id": "sha256:cf3f6513da4384605c8a72d702fb4b35952b7fe10e9ad6dbb872bf06e6e06757",
    "gateway_workload_attachment_digests": (
        "sha256:f460228af1a366e38fde461b880629971d27e9c3b1d11d909cb6482fef7597ae "
        "sha256:ed5a410d4e00c9c70c0f7e76b9e27d32b4db688d581b1797fded4c543bb19041"
    ),
    "gateway_backend_digest": "sha256:c5c2b964a499822699fdf5e520bf8a3c2cc6434f8caac07a2028d7f3023b9972",
    "gateway_backend_image_id": "sha256:8524ce6c9242ecdadb2974f0924ce4dd02f04d46915d5a0076eeccc0208cd6f8",
    "gateway_probe_digest": "sha256:bd44eb136a95dcc8dc58995e43abc40a413f2e8e3d4a2aae6bccbe94686acb05",
    "gateway_probe_image_id": "sha256:b7c873bd97bdc9046fc894e0b216c8aef31e0db4c5b761fb53022e40577ab6c0",
}

ARM64_CSI = {
    "hostpath_digest": "sha256:a28d9a736b343381e9e73d8f795aea608df4bda40ab83807a17cf602265dba12",
    "hostpath_image_id": "sha256:10e75dd2f2bd1ed1b9d25d108f9fd4215ad129089341a8c708dfa1b790ba187f",
    "registrar_digest": "sha256:a2e2060fca736107daafe4958910143bd08af3f456efb1fdc8dc54a9da582b83",
    "registrar_image_id": "sha256:b98ccb75f056aed6106d123450a93b3b89362ff36d8d5fd4a36d84f4f0e20d04",
    "liveness_digest": "sha256:94de3d3bf21334ac646e942b2411100bb38f66ea98bfb9cf43b27dd5c1fb921e",
    "liveness_image_id": "sha256:702feb92f34854bc56800397349124db6c4483fe59c43fe3e45adfd5140b2745",
    "provisioner_digest": "sha256:6e755c658dff4f5270a9d0214b41d031b64c3df94d0086c0042287cc46cc0862",
    "provisioner_image_id": "sha256:611e36ee5ed9768df3626fd282d9ef8e70e4bf375806ec67cdf0296fb1b109bc",
    "attacher_digest": "sha256:a2b51767c0f639a1b96c2197526306cd970ac038e542ac46a16d4120c0065020",
    "attacher_image_id": "sha256:350ee4ecfc365de622033f50c3d45ed10341ab3f7e785d840387c986bbde9a1b",
}

# Keys whose value legitimately differs between the amd64 and arm64 locks
# without holding a digest.
PLATFORM_LABEL_KEYS = {
    "architecture", "platform", "pause_bundle", "workload_bundle",
    "cert_manager_images_bundle", "envoy_gateway_images_bundle",
    "gateway_workload_bundle", "image_bundle", "driver_manifest",
    "cri_tools_from_file", "cri_tools_to_file", "kubernetes_cni_from_file",
    "kubernetes_cni_to_file", "kubeadm_from_file", "kubelet_from_file",
    "kubectl_from_file", "kubeadm_to_file", "kubelet_to_file", "kubectl_to_file",
}


class Arm64LockParity(unittest.TestCase):
    PAIRS = (
        (KUBEADM / "packages.lock", KUBEADM / "packages.linux-arm64.lock", ARM64_KUBEADM),
        (CONTROLLERS / "assets.lock", CONTROLLERS / "assets.linux-arm64.lock", ARM64_CONTROLLERS),
        (CSI / "assets.lock", CSI / "assets.linux-arm64.lock",
         {**ARM64_CSI, "driver_manifest_sha256": None}),
    )

    def test_arm64_locks_differ_only_in_platform_values(self):
        for amd64_path, arm64_path, official in self.PAIRS:
            with self.subTest(lock=arm64_path.name, dir=arm64_path.parent.name):
                amd64 = flat_lock(amd64_path)
                arm64 = flat_lock(arm64_path)
                self.assertEqual(list(amd64), list(arm64))
                for key, value in arm64.items():
                    self.assertNotIn("amd64", value, key)
                    if key in official:
                        if official[key] is not None:
                            self.assertEqual(value, official[key], key)
                        self.assertNotEqual(value, amd64[key], key)
                    elif key in PLATFORM_LABEL_KEYS:
                        self.assertEqual(
                            value,
                            amd64[key].replace("amd64", "arm64").replace(
                                "csi-hostpath-driver.yaml",
                                "csi-hostpath-driver.linux-arm64.yaml",
                            ),
                            key,
                        )
                    else:
                        self.assertEqual(value, amd64[key], key)

    def test_arm64_platform_fields(self):
        self.assertEqual(flat_lock(KUBEADM / "packages.linux-arm64.lock")["architecture"], "arm64")
        self.assertEqual(flat_lock(CONTROLLERS / "assets.linux-arm64.lock")["platform"], "linux/arm64")
        self.assertEqual(flat_lock(CSI / "assets.linux-arm64.lock")["platform"], "linux/arm64")


class Arm64PinnedManifests(unittest.TestCase):
    @staticmethod
    def neutral(text: str) -> str:
        return HEX64.sub("<digest>", text)

    def test_csi_driver_manifest_pins_arm64_platform_digests(self):
        lock = flat_lock(CSI / "assets.linux-arm64.lock")
        path = CSI / lock["driver_manifest"]
        text = path.read_text(encoding="utf-8")
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), lock["driver_manifest_sha256"])
        expected = [
            f"{lock[f'{prefix}_image'].rsplit(':', 1)[0]}@{lock[f'{prefix}_digest']}"
            for prefix in ("hostpath", "registrar", "liveness", "provisioner", "attacher")
        ]
        actual = re.findall(r"^\s+image:\s+(\S+)\s*$", text, re.MULTILINE)
        self.assertCountEqual(actual, expected)
        amd64_text = (CSI / "csi-hostpath-driver.yaml").read_text(encoding="utf-8")
        self.assertEqual(self.neutral(text), self.neutral(amd64_text))

    def test_envoy_profile_pins_arm64_proxy_digest(self):
        lock = flat_lock(CONTROLLERS / "assets.linux-arm64.lock")
        profiles = CONTROLLERS / "profiles"
        text = (profiles / "envoy-clusterip.linux-arm64.yaml").read_text(encoding="utf-8")
        pinned = f"{lock['envoy_proxy_image']}@{lock['envoy_proxy_digest']}"
        self.assertEqual(text.count(f"image: {pinned}"), 1)
        amd64_text = (profiles / "envoy-clusterip.yaml").read_text(encoding="utf-8")
        self.assertEqual(self.neutral(text), self.neutral(amd64_text))


class ArchSelection(unittest.TestCase):
    def test_runtime_selects_lock_by_host_architecture(self):
        for path, lock_name in (
            (KUBEADM / "package-cache.sh", "packages.linux-arm64.lock"),
            (ROOT / "lib" / "controllers.sh", "assets.linux-arm64.lock"),
            (ROOT / "lib" / "csi.sh", "assets.linux-arm64.lock"),
        ):
            text = path.read_text(encoding="utf-8")
            self.assertIn('case "$(uname -m)" in', text, path)
            self.assertIn("aarch64|arm64)", text, path)
            self.assertIn(lock_name, text, path)

    def test_scripts_do_not_hard_code_amd64(self):
        for path in (
            KUBEADM / "package-cache.sh",
            KUBEADM / "cache-packages.sh",
            KUBEADM / "seed-upgrade.sh",
            ROOT / "questions" / "cluster-architecture" / "ca-06" / "solve.sh",
        ):
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"_amd64\.deb|linux/amd64|linux-amd64", path)


class Arm64CachedBundles(unittest.TestCase):
    """Optional: verify locally cached arm64 bundles when they exist."""

    def run_verifier(self, bundle, platform, images, attachments=()):
        arguments = [sys.executable, str(VERIFIER), str(bundle), platform]
        for image in images:
            arguments.extend(image)
        if attachments:
            arguments.extend(["--attachments", *attachments])
        subprocess.run(arguments, check=True, timeout=120)

    def test_cached_csi_bundle(self):
        lock = flat_lock(CSI / "assets.linux-arm64.lock")
        bundle = CSI / "assets" / lock["image_bundle"]
        if not bundle.is_file():
            self.skipTest("optional local arm64 CSI cache is absent")
        self.run_verifier(bundle, lock["platform"], [
            (lock[f"{p}_image"], lock[f"{p}_digest"], lock[f"{p}_image_id"])
            for p in ("hostpath", "registrar", "liveness", "provisioner", "attacher")
        ])

    def test_cached_controller_bundles(self):
        lock = flat_lock(CONTROLLERS / "assets.linux-arm64.lock")
        bundles = {
            "cert_manager_images_bundle": (
                "cert_manager_controller", "cert_manager_webhook", "cert_manager_cainjector",
            ),
            "envoy_gateway_images_bundle": ("envoy_gateway", "envoy_proxy", "envoy_ratelimit"),
        }
        for bundle_key, prefixes in bundles.items():
            bundle = CONTROLLERS / "assets" / lock[bundle_key]
            with self.subTest(bundle=bundle.name):
                if not bundle.is_file():
                    self.skipTest("optional local arm64 controller cache is absent")
                self.run_verifier(bundle, lock["platform"], [
                    (lock[f"{p}_image"], lock[f"{p}_digest"], lock[f"{p}_image_id"])
                    for p in prefixes
                ])

    def test_cached_gateway_workload_bundle(self):
        lock = flat_lock(CONTROLLERS / "assets.linux-arm64.lock")
        bundle = KUBEADM / "packages" / lock["gateway_workload_bundle"]
        if not bundle.is_file():
            self.skipTest("optional local arm64 kubeadm workload cache is absent")
        self.run_verifier(
            bundle,
            lock["platform"],
            [
                (lock["gateway_backend_image"], lock["gateway_backend_digest"], lock["gateway_backend_image_id"]),
                (lock["gateway_probe_image"], lock["gateway_probe_digest"], lock["gateway_probe_image_id"]),
            ],
            lock["gateway_workload_attachment_digests"].split(),
        )


if __name__ == "__main__":
    unittest.main()
