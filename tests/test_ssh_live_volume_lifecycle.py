#!/usr/bin/env python3
"""Cluster-free fake-Docker tests for the SSH live node-volume allowlist."""

import json
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "tests" / "ssh-live-volume-lifecycle.sh"
NODE_A = "a" * 64
NODE_B = "b" * 64
VOLUME_A = "c" * 64
VOLUME_B = "d" * 64
FOREIGN = "e" * 64


def bash_path(path):
    """Return a path understood by the selected Bash implementation."""
    path = pathlib.Path(path).resolve()
    if os.name == "nt":
        drive = path.drive.rstrip(":").lower()
        suffix = path.as_posix().split(":", 1)[1]
        return f"/{drive}{suffix}"
    return str(path)


def bash_binary():
    if os.name == "nt":
        candidate = pathlib.Path(os.environ["ProgramFiles"]) / "Git" / "bin" / "bash.exe"
        if candidate.is_file():
            return str(candidate)
    return shutil.which("bash") or "bash"


FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys

path = os.environ["FAKE_DOCKER_STATE"]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)

def save():
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(state, stream, sort_keys=True)

args = sys.argv[1:]
if args[:2] == ["container", "inspect"]:
    ident = args[-1]
    container = state["containers"].get(ident)
    if container is None:
        raise SystemExit(1)
    if "--format" in args:
        for volume, destination in container["mounts"]:
            print(f"{volume}|{destination}")
    else:
        print("[]")
elif args[:2] == ["volume", "inspect"]:
    name = args[-1]
    volume = state["volumes"].get(name)
    if volume is None:
        raise SystemExit(1)
    print(f'{name}|local|local|/fake/{name}|{volume["created"]}|{{}}|{{}}')
elif args and args[0] == "ps":
    value = next(item for item in args if item.startswith("volume="))
    name = value.split("=", 1)[1]
    volume = state["volumes"].get(name)
    if volume:
        print("\n".join(volume["attached"]))
elif args == ["info"]:
    pass
elif args[:2] == ["container", "rm"]:
    for ident in args[2:]:
        container = state["containers"].pop(ident, None)
        if container:
            for volume, _ in container["mounts"]:
                if volume in state["volumes"]:
                    state["volumes"][volume]["attached"] = [
                        item for item in state["volumes"][volume]["attached"] if item != ident
                    ]
    save()
elif args[:2] == ["volume", "rm"]:
    name = args[2]
    volume = state["volumes"].get(name)
    if volume is None or volume["attached"]:
        raise SystemExit(1)
    del state["volumes"][name]
    state["rm_log"].append(name)
    save()
elif args[:1] == ["test-attach"]:
    state["volumes"][args[1]]["attached"].append(args[2])
    save()
elif args[:1] == ["test-drift"]:
    state["volumes"][args[1]]["created"] = "replacement-generation"
    save()
else:
    raise SystemExit(f"unsupported fake docker command: {args!r}")
'''


class SshLiveVolumeLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ssh-live-volume-test-")
        self.addCleanup(self.temp.cleanup)
        root = pathlib.Path(self.temp.name)
        self.state = root / "state.json"
        self.docker = root / "docker"
        self.journal = root / "journal"
        self.docker.write_text(FAKE_DOCKER, encoding="utf-8")
        self.docker.chmod(0o755)
        self.state.write_text(
            json.dumps(
                {
                    "containers": {
                        NODE_A: {"mounts": [[VOLUME_A, "/var"]]},
                        NODE_B: {"mounts": [[VOLUME_B, "/var"]]},
                    },
                    "volumes": {
                        VOLUME_A: {"created": "generation-a", "attached": [NODE_A]},
                        VOLUME_B: {"created": "generation-b", "attached": [NODE_B]},
                    },
                    "rm_log": [],
                }
            ),
            encoding="utf-8",
        )

    def run_scenario(self, body):
        env = os.environ.copy()
        env.update(
            {
                "FAKE_DOCKER_STATE": str(self.state),
                "SSH_LIVE_DOCKER_BIN": bash_path(self.docker),
                "JOURNAL": bash_path(self.journal),
                "NODE_A": NODE_A,
                "NODE_B": NODE_B,
                "VOLUME_A": VOLUME_A,
                "VOLUME_B": VOLUME_B,
                "FOREIGN": FOREIGN,
            }
        )
        script = textwrap.dedent(
            f"""\
            set -Eeuo pipefail
            source {shlex.quote(bash_path(LIBRARY))}
            {body}
            """
        )
        return subprocess.run(
            [bash_binary(), "-c", script],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def read_state(self):
        return json.loads(self.state.read_text(encoding="utf-8"))

    def test_exact_sealed_volumes_are_removed_after_exact_nodes(self):
        result = self.run_scenario(
            """
            ssh_live_volume_journal_seal "$JOURNAL" "$NODE_A" "$NODE_B"
            ssh_live_volume_verify "$JOURNAL" 0 "$NODE_A" "$NODE_B"
            "$SSH_LIVE_DOCKER_BIN" container rm "$NODE_A" "$NODE_B"
            ssh_live_volume_remove_sealed "$JOURNAL" "$NODE_A" "$NODE_B"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.assertEqual(state["containers"], {})
        self.assertEqual(state["volumes"], {})
        self.assertEqual(state["rm_log"], [VOLUME_A, VOLUME_B])

    def test_partial_cleanup_retry_accepts_only_already_absent_sealed_volume(self):
        result = self.run_scenario(
            """
            ssh_live_volume_journal_seal "$JOURNAL" "$NODE_A" "$NODE_B"
            "$SSH_LIVE_DOCKER_BIN" container rm "$NODE_A" "$NODE_B"
            "$SSH_LIVE_DOCKER_BIN" volume rm "$VOLUME_A"
            ssh_live_volume_remove_sealed "$JOURNAL" "$NODE_A" "$NODE_B"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.assertEqual(state["volumes"], {})
        self.assertEqual(state["rm_log"], [VOLUME_A, VOLUME_B])

    def test_foreign_attachment_fails_before_any_delete(self):
        result = self.run_scenario(
            """
            ssh_live_volume_journal_seal "$JOURNAL" "$NODE_A" "$NODE_B"
            "$SSH_LIVE_DOCKER_BIN" test-attach "$VOLUME_A" "$FOREIGN"
            ! ssh_live_volume_verify "$JOURNAL" 1 "$NODE_A" "$NODE_B"
            "$SSH_LIVE_DOCKER_BIN" container inspect "$NODE_A" >/dev/null
            "$SSH_LIVE_DOCKER_BIN" container inspect "$NODE_B" >/dev/null
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.assertEqual(state["rm_log"], [])
        self.assertIn(NODE_A, state["containers"])

    def test_generation_drift_is_not_resealed_or_removed(self):
        result = self.run_scenario(
            """
            ssh_live_volume_journal_seal "$JOURNAL" "$NODE_A" "$NODE_B"
            before="$(sha256sum "$JOURNAL")"
            "$SSH_LIVE_DOCKER_BIN" test-drift "$VOLUME_A"
            ! ssh_live_volume_journal_seal "$JOURNAL" "$NODE_A" "$NODE_B"
            after="$(sha256sum "$JOURNAL")"
            test "$before" = "$after"
            "$SSH_LIVE_DOCKER_BIN" container rm "$NODE_A" "$NODE_B"
            ! ssh_live_volume_remove_sealed "$JOURNAL" "$NODE_A" "$NODE_B"
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.assertEqual(state["rm_log"], [])
        self.assertIn(VOLUME_A, state["volumes"])


if __name__ == "__main__":
    unittest.main()
