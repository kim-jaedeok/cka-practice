#!/usr/bin/env python3
"""Cell kind configs gain a read-only kernel-config mount only when needed.

kubeadm preflight reads /proc/config.gz or /boot/config-<release>. Hosts whose
kernel lacks /proc/config.gz (e.g. a Colima Ubuntu VM) get /boot/config-*
mounted into every cell node. The checked-in kind configs stay unchanged.
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIGS = (
    ROOT / "cluster" / "cells" / "kubeadm" / "bootstrap-kind.yaml",
    ROOT / "cluster" / "cells" / "kubeadm" / "ha-kind.yaml",
    ROOT / "cluster" / "cells" / "kubeadm" / "upgrade-kind.yaml",
    ROOT / "cluster" / "cells" / "generic" / "kind.yaml",
)
KERNEL = "/boot/config-6.8.0-test"
BASH = shutil.which("bash")


def bash_major() -> int:
    if not BASH:
        return 0
    result = subprocess.run(
        [BASH, "-c", 'printf %s "${BASH_VERSINFO[0]}"'],
        capture_output=True, text=True, check=False,
    )
    return int(result.stdout or 0)


@unittest.skipIf(bash_major() < 4, "bash >= 4 is required by lib/cell.sh")
class CellKernelConfigMount(unittest.TestCase):
    def render(self, source: pathlib.Path) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="cka-kind-config-") as directory:
            output = pathlib.Path(directory) / "kind.yaml"
            result = subprocess.run(
                [BASH, "-c", 'source "$1/lib/cell.sh" && _cell_render_kind_config "$2" "$3" "$4"',
                 "_", str(ROOT), str(source), str(output), KERNEL],
                capture_output=True, text=True, timeout=60, check=False,
            )
            result.stdout = output.read_text(encoding="utf-8") if output.exists() else ""
            return result

    def test_every_node_gets_one_read_only_mount(self):
        for config in CONFIGS:
            with self.subTest(config=config.name):
                original = config.read_text(encoding="utf-8").splitlines()
                result = self.render(config)
                self.assertEqual(result.returncode, 0, result.stderr)
                rendered = result.stdout.splitlines()
                nodes = sum(1 for line in original if line.startswith("  - role: "))
                self.assertGreater(nodes, 0)
                self.assertEqual(rendered.count("    extraMounts:"), nodes)
                self.assertEqual(rendered.count(f"      - hostPath: {KERNEL}"), nodes)
                self.assertEqual(rendered.count(f"        containerPath: {KERNEL}"), nodes)
                self.assertEqual(rendered.count("        readOnly: true"), nodes)
                added = {
                    "    extraMounts:", f"      - hostPath: {KERNEL}",
                    f"        containerPath: {KERNEL}", "        readOnly: true",
                }
                self.assertEqual([line for line in rendered if line not in added], original)

    def test_existing_extra_mounts_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="cka-kind-source-") as directory:
            source = pathlib.Path(directory) / "kind.yaml"
            source.write_text(
                "kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n"
                "  - role: control-plane\n    extraMounts: []\n",
                encoding="utf-8",
            )
            self.assertNotEqual(self.render(source).returncode, 0)

    def test_cell_create_uses_and_removes_the_rendered_copy(self):
        library = (ROOT / "lib" / "cell.sh").read_text(encoding="utf-8")
        self.assertIn("[ ! -e /proc/config.gz ] || return 1", library)
        self.assertIn('config="$rendered_config"', library)
        self.assertIn('[ -z "$rendered_config" ] || rm -f -- "$rendered_config"', library)
        for config in CONFIGS:
            self.assertNotIn("extraMounts", config.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
