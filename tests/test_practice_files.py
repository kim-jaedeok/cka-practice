"""Root practice-file ownership and deletion boundaries, using real Git repos."""
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "lib" / "practice-files.py"


class PracticeFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cka-practice-files-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "repo"
        self.root.mkdir()
        self.state = self.root / ".state"
        self.git("init", "-q")
        self.write(".gitignore", ".state/\nignored.txt\n")
        self.write("tracked.yaml", "tracked")
        self.git("add", ".gitignore", "tracked.yaml")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args],
                              check=True, capture_output=True)

    def write(self, name, text="answer"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def run_action(self, *args, success=True):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root),
             "--state", str(self.state), *args],
            capture_output=True, text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def test_reset_removes_new_root_files_and_preserves_baseline(self):
        self.write("existing.txt", "keep")
        self.run_action("start", "ca-09")
        self.write("issuer.yaml")
        self.write("certificate.yaml")
        self.write("tracked.yaml", "edited")
        self.write("ignored.txt")
        self.write(".private")
        self.write("notes/answer.txt")
        self.run_action("start", "ca-09")
        for name in ("issuer.yaml", "certificate.yaml"):
            self.assertFalse((self.root / name).exists())
        for name in ("existing.txt", "tracked.yaml", "ignored.txt", ".private", "notes/answer.txt"):
            self.assertTrue((self.root / name).exists(), name)

    def test_question_switch_keeps_file_ownership(self):
        self.run_action("start", "ca-09")
        self.write("issuer.yaml")
        self.run_action("start", "ts-01")
        self.write("output.txt")
        self.run_action("cleanup", "ca-09")
        self.assertFalse((self.root / "issuer.yaml").exists())
        self.assertTrue((self.root / "output.txt").exists())
        self.run_action("cleanup-all")
        self.assertFalse((self.root / "output.txt").exists())
        self.run_action("cleanup-all")

    def test_missing_journal_does_not_infer_ownership(self):
        self.write("issuer.yaml")
        self.run_action("cleanup", "ca-09")
        self.run_action("cleanup-all")
        self.assertTrue((self.root / "issuer.yaml").exists())

    def test_explicit_adoption_handles_existing_practice_files(self):
        self.write("issuer.yaml")
        self.write("certificate.yaml")
        self.write("keep.txt")
        self.run_action("adopt", "ca-09", "issuer.yaml", "certificate.yaml")
        self.run_action("cleanup", "ca-09")
        self.assertFalse((self.root / "issuer.yaml").exists())
        self.assertFalse((self.root / "certificate.yaml").exists())
        self.assertTrue((self.root / "keep.txt").exists())

    def test_newly_tracked_file_is_protected(self):
        self.run_action("start", "ca-09")
        self.write("saved.yaml")
        self.run_action("start", "ts-01")
        self.git("add", "saved.yaml")
        self.run_action("cleanup-all")
        self.assertTrue((self.root / "saved.yaml").exists())

    def test_cleanup_ends_active_session(self):
        self.run_action("start", "ca-09")
        self.write("issuer.yaml")
        self.run_action("cleanup", "ca-09")
        self.write("unrelated.txt")
        self.run_action("cleanup-all")
        self.assertTrue((self.root / "unrelated.txt").exists())

    def test_other_question_overwrite_releases_old_owner(self):
        self.run_action("start", "ca-09")
        self.write("answer.yaml", "first question")
        self.run_action("start", "ts-01")
        self.write("answer.yaml", "second question answer")
        self.run_action("cleanup", "ca-09")
        self.assertEqual((self.root / "answer.yaml").read_text(), "second question answer")

    def test_interrupted_delete_preserves_retry_and_replacement(self):
        spec = importlib.util.spec_from_file_location("practice_files_test", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.run_action("start", "ca-09")
        self.write("a.yaml")
        self.write("b.yaml")
        original_unlink = Path.unlink

        def fail_second(path, *args, **kwargs):
            if path == self.root / "b.yaml":
                raise PermissionError("injected deletion failure")
            return original_unlink(path, *args, **kwargs)

        with patch.object(Path, "unlink", fail_second):
            with self.assertRaises(PermissionError):
                module.main(["--root", str(self.root), "--state", str(self.state),
                             "cleanup", "ca-09"])
        self.assertFalse((self.root / "a.yaml").exists())
        journal = json.loads((self.state / "practice-files.json").read_text())
        self.assertTrue(journal["owners"]["b.yaml"]["pending"])
        self.write("b.yaml", "replacement to preserve")
        self.run_action("cleanup", "ca-09")
        self.assertEqual((self.root / "b.yaml").read_text(), "replacement to preserve")

    def test_released_ownership_does_not_delete_same_name_later(self):
        self.run_action("start", "ca-09")
        self.write("saved.yaml")
        self.run_action("start", "ts-01")
        self.git("add", "saved.yaml")
        self.run_action("cleanup", "ca-09")
        self.git("rm", "--cached", "saved.yaml")
        self.run_action("cleanup", "ca-09")
        self.assertTrue((self.root / "saved.yaml").exists())

    def test_invalid_adoption_is_all_or_nothing(self):
        self.write("issuer.yaml")
        self.run_action("adopt", "ca-09", "issuer.yaml", "../outside", success=False)
        self.run_action("cleanup-all")
        self.assertTrue((self.root / "issuer.yaml").exists())
        self.run_action("adopt", "ca-09", "tracked.yaml", success=False)
        self.run_action("start", "../outside", success=False)

    def test_corrupt_journal_does_not_delete_files(self):
        self.run_action("start", "ca-09")
        self.write("issuer.yaml")
        journal = self.state / "practice-files.json"
        journal.write_text('{"version":999}', encoding="utf-8")
        self.run_action("cleanup-all", success=False)
        self.assertTrue((self.root / "issuer.yaml").exists())
        self.assertEqual(json.loads(journal.read_text())["version"], 999)

    @unittest.skipIf(os.name == "nt", "requires unprivileged POSIX symlinks")
    def test_symlinks_do_not_delete_external_data(self):
        outside = Path(self.temp.name) / "outside.txt"
        outside.write_text("keep")
        self.run_action("start", "ca-09")
        (self.root / "linked.yaml").symlink_to(outside)
        self.run_action("cleanup-all")
        self.assertEqual(outside.read_text(), "keep")
        self.assertTrue((self.root / "linked.yaml").is_symlink())

    @unittest.skipIf(os.name == "nt", "requires unprivileged POSIX symlinks")
    def test_symlinked_state_refuses_to_write_or_delete(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        self.state.symlink_to(outside, target_is_directory=True)
        self.run_action("start", "ca-09", success=False)
        self.assertEqual(list(outside.iterdir()), [])

    @unittest.skipIf(os.name == "nt", "run Bash integration under Linux/WSL")
    def test_runtime_and_cluster_down_delete_real_root_files(self):
        (self.root / "lib").mkdir()
        shutil.copyfile(SCRIPT, self.root / "lib" / SCRIPT.name)
        source_root = SCRIPT.parent.parent
        (self.root / "cluster").mkdir()
        shutil.copyfile(source_root / "cluster" / "versions.lock.yaml",
                        self.root / "cluster" / "versions.lock.yaml")
        script = r'''
set -euo pipefail
source "$SOURCE_ROOT/lib/common.sh"
source "$SOURCE_ROOT/lib/question-runtime.sh"
meta_get() { :; }
require_cluster() { :; }
require_cluster_readonly() { :; }
_question_runtime_load_cell_library() { :; }
cell_selection_clear_current() { :; }
_question_runtime_run_script() { :; }
mkdir -p "$CKA_ROOT/question"
touch "$CKA_ROOT/question/teardown.sh"
question_runtime_start ca-09 "$CKA_ROOT/question"
printf answer > "$CKA_ROOT/issuer.yaml"
question_runtime_reset ca-09 "$CKA_ROOT/question"
test ! -e "$CKA_ROOT/issuer.yaml"
printf answer > "$CKA_ROOT/certificate.yaml"
question_runtime_cleanup ca-09 "$CKA_ROOT/question"
test ! -e "$CKA_ROOT/certificate.yaml"
question_runtime_start ca-09 "$CKA_ROOT/question"
printf answer > "$CKA_ROOT/issuer.yaml"
eval "$(sed -n '/^cmd_cluster_down() (/,/^)/p' "$SOURCE_ROOT/cka")"
deny_if_exam_locked() { :; }
_cloud_provider_kind_validate_cluster_name() { :; }
cell_feature_enabled() { :; }
_cell_lock() { :; }
_cell_cleanup_all_managed_locked() { :; }
cloud_provider_kind_cleanup_cluster_loadbalancers() { :; }
cloud_provider_kind_stop_if_no_clusters() { :; }
kind() { :; }
cmd_cluster_down
test ! -e "$CKA_ROOT/issuer.yaml"
'''
        result = subprocess.run(
            ["bash"], input=script, text=True, capture_output=True,
            env={**os.environ, "SOURCE_ROOT": str(source_root),
                 "CKA_ROOT": str(self.root), "CKA_STATE_DIR": str(self.state),
                 "CKA_WORK_DIR": str(self.root / "work")},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
