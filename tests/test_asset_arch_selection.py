#!/usr/bin/env python3
"""Run the real shell loaders under a stubbed `uname -m`.

x86_64/amd64 (and unknown) hosts must keep loading the original amd64 locks
and manifests. aarch64/arm64 hosts load the *.linux-arm64 counterparts.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")

DUMP = r"""
set -uo pipefail
source "$ROOT/lib/common.sh"
source "$ROOT/lib/controllers.sh"
source "$ROOT/lib/csi.sh"
source "$ROOT/cluster/cells/kubeadm/package-cache.sh"
for var in CONTROLLER_LOCK CONTROLLER_PLATFORM CONTROLLER_ENVOY_PROFILE \
  GATEWAY_WORKLOAD_BUNDLE CSI_LOCK CSI_PLATFORM CSI_DRIVER_MANIFEST_PATH \
  CSI_IMAGE_BUNDLE KUBEADM_PACKAGE_LOCK KUBEADM_PACKAGE_ARCH KUBEADM_PAUSE_BUNDLE; do
  printf '%s=%s\n' "$var" "${!var}"
done
"""


def bash_major() -> int:
    if not BASH:
        return 0
    result = subprocess.run(
        [BASH, "-c", 'printf %s "${BASH_VERSINFO[0]}"'],
        capture_output=True, text=True, check=False,
    )
    return int(result.stdout or 0)


@unittest.skipIf(bash_major() < 4, "bash >= 4 is required by the loaders")
class AssetArchSelection(unittest.TestCase):
    def load(self, machine: str, **overrides: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory(prefix="cka-uname-") as directory:
            stub = pathlib.Path(directory) / "uname"
            stub.write_text(
                "#!/bin/sh\n"
                f'[ "$1" = -m ] && {{ echo {machine}; exit 0; }}\n'
                'exec /usr/bin/uname "$@"\n'
            )
            stub.chmod(0o755)
            env = {
                key: value for key, value in os.environ.items()
                if not key.startswith(("CONTROLLER_", "CSI_", "KUBEADM_"))
            }
            env.update(overrides)
            env["ROOT"] = str(ROOT)
            env["PATH"] = f"{directory}:{env.get('PATH', '/usr/bin:/bin')}"
            result = subprocess.run(
                [BASH, "-c", DUMP], env=env, capture_output=True, text=True,
                timeout=60, check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines())

    def assert_amd64(self, values: dict[str, str]) -> None:
        self.assertEqual(values["CONTROLLER_LOCK"], str(ROOT / "cluster/controllers/assets.lock"))
        self.assertEqual(values["CONTROLLER_PLATFORM"], "linux/amd64")
        self.assertEqual(
            values["CONTROLLER_ENVOY_PROFILE"],
            str(ROOT / "cluster/controllers/profiles/envoy-clusterip.yaml"),
        )
        self.assertEqual(values["GATEWAY_WORKLOAD_BUNDLE"], "kubeadm-workloads-linux-amd64.tar")
        self.assertEqual(values["CSI_LOCK"], str(ROOT / "cluster/csi/assets.lock"))
        self.assertEqual(values["CSI_PLATFORM"], "linux/amd64")
        self.assertEqual(
            values["CSI_DRIVER_MANIFEST_PATH"], str(ROOT / "cluster/csi/csi-hostpath-driver.yaml")
        )
        self.assertEqual(values["CSI_IMAGE_BUNDLE"], "csi-hostpath-images-linux-amd64.tar")
        self.assertEqual(
            values["KUBEADM_PACKAGE_LOCK"], str(ROOT / "cluster/cells/kubeadm/packages.lock")
        )
        self.assertEqual(values["KUBEADM_PACKAGE_ARCH"], "amd64")
        self.assertEqual(values["KUBEADM_PAUSE_BUNDLE"], "kubeadm-pause-linux-amd64.tar")

    def assert_arm64(self, values: dict[str, str]) -> None:
        self.assertEqual(
            values["CONTROLLER_LOCK"], str(ROOT / "cluster/controllers/assets.linux-arm64.lock")
        )
        self.assertEqual(values["CONTROLLER_PLATFORM"], "linux/arm64")
        self.assertEqual(
            values["CONTROLLER_ENVOY_PROFILE"],
            str(ROOT / "cluster/controllers/profiles/envoy-clusterip.linux-arm64.yaml"),
        )
        self.assertEqual(values["GATEWAY_WORKLOAD_BUNDLE"], "kubeadm-workloads-linux-arm64.tar")
        self.assertEqual(values["CSI_LOCK"], str(ROOT / "cluster/csi/assets.linux-arm64.lock"))
        self.assertEqual(values["CSI_PLATFORM"], "linux/arm64")
        self.assertEqual(
            values["CSI_DRIVER_MANIFEST_PATH"],
            str(ROOT / "cluster/csi/csi-hostpath-driver.linux-arm64.yaml"),
        )
        self.assertEqual(values["CSI_IMAGE_BUNDLE"], "csi-hostpath-images-linux-arm64.tar")
        self.assertEqual(
            values["KUBEADM_PACKAGE_LOCK"],
            str(ROOT / "cluster/cells/kubeadm/packages.linux-arm64.lock"),
        )
        self.assertEqual(values["KUBEADM_PACKAGE_ARCH"], "arm64")
        self.assertEqual(values["KUBEADM_PAUSE_BUNDLE"], "kubeadm-pause-linux-arm64.tar")

    def test_amd64_hosts_keep_the_original_files(self):
        for machine in ("x86_64", "amd64"):
            with self.subTest(machine=machine):
                self.assert_amd64(self.load(machine))

    def test_unknown_hosts_fall_back_to_the_original_files(self):
        self.assert_amd64(self.load("ppc64le"))

    def test_arm64_hosts_load_arm64_files(self):
        for machine in ("aarch64", "arm64"):
            with self.subTest(machine=machine):
                self.assert_arm64(self.load(machine))

    def test_envoy_profile_follows_an_overridden_controller_lock(self):
        values = self.load(
            "aarch64", CONTROLLER_LOCK=str(ROOT / "cluster/controllers/assets.lock")
        )
        self.assertEqual(values["CONTROLLER_PLATFORM"], "linux/amd64")
        self.assertEqual(
            values["CONTROLLER_ENVOY_PROFILE"],
            str(ROOT / "cluster/controllers/profiles/envoy-clusterip.yaml"),
        )


if __name__ == "__main__":
    unittest.main()
