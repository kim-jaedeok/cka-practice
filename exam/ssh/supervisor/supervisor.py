#!/usr/bin/env python3
"""Fail-closed lifecycle supervisor for designated-host SSH practice runs.

The trusted host process is the only component allowed to talk to the container
engine.  Candidate containers are created stopped, recorded by immutable full
object IDs, and are never addressed by their mutable names after creation.

This module intentionally uses only the Python standard library so the host
service does not need a runtime package download.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import dataclasses
import errno
import fcntl
import hashlib
import ipaddress
import io
import json
import os
import re
import resource
import secrets
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Any, Iterator, Sequence


SCHEMA_VERSION = 1
MAX_DURATION_SECONDS = 8 * 60 * 60
MAX_ANSWER_FILE_BYTES = 8 * 1024 * 1024
MAX_ANSWER_TOTAL_BYTES = 32 * 1024 * 1024
MAX_ENGINE_OUTPUT_BYTES = 40 * 1024 * 1024
MAX_INPUT_FILE_BYTES = 8 * 1024 * 1024
MAX_INPUT_TOTAL_BYTES = 64 * 1024 * 1024
MAX_INPUT_FILES = 2000
RUN_ID_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$")
QUESTION_ID_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
FILE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
RELATIVE_INPUT_RE = re.compile(r"^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
IMAGE_ID_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
TERMINAL_PHASES = {"SEALED", "COLLECTED", "CLEANED", "INVALID"}
BLOCKED_FILESYSTEMS = {
    "9p",
    "cifs",
    "drvfs",
    "fuseblk",
    "fuse.sshfs",
    "nfs",
    "nfs4",
    "smb2",
    "vfat",
}


class SupervisorError(RuntimeError):
    """Expected fail-closed supervisor error."""


class IntegrityError(SupervisorError):
    """Protected state or engine identity does not match the run."""


class EngineError(SupervisorError):
    """Container engine command failed."""


class EngineTimeout(EngineError):
    """Container engine command exceeded its bound."""


@dataclasses.dataclass(frozen=True)
class CommandResult:
    stdout: bytes
    stderr: bytes

    def text(self) -> str:
        return self.stdout.decode("utf-8", "strict").strip()


def linux_parent_death_guard(parent_pid: int) -> None:
    """Ensure an in-flight engine client cannot outlive a crashed supervisor."""
    libc = ctypes.CDLL(None, use_errno=True)
    # PR_SET_PDEATHSIG = 1.  systemd also kills the service cgroup, while this
    # closes the direct CLI invocation window used by prepare/session commands.
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0:
        os._exit(127)
    if os.getppid() != parent_pid:
        os.kill(os.getpid(), signal.SIGKILL)


def linux_engine_child_setup(parent_pid: int, output_cap: int) -> None:
    """Apply lifecycle and output-file bounds before executing an engine CLI."""
    linux_parent_death_guard(parent_pid)
    # The limit applies to every regular file the CLI opens, not just captured
    # stdout/stderr.  Keep the process-wide ceiling at the supervisor's global
    # maximum and enforce smaller per-command caps by polling the dedicated
    # output spools in the parent.
    requested = max(output_cap + 1, MAX_ENGINE_OUTPUT_BYTES + 1)
    _soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    if hard != resource.RLIM_INFINITY:
        requested = min(requested, hard)
    resource.setrlimit(resource.RLIMIT_FSIZE, (requested, requested))


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def epoch_now() -> int:
    return int(time.time())


def require_linux_boot_id() -> str:
    path = Path("/proc/sys/kernel/random/boot_id")
    try:
        value = path.read_text(encoding="ascii").strip()
    except OSError as exc:
        raise SupervisorError("the supervisor requires a native Linux /proc boot_id") from exc
    if not value or len(value) > 128:
        raise SupervisorError("invalid Linux boot_id")
    return value


def validate_run_id(run_id: str) -> str:
    if not RUN_ID_RE.fullmatch(run_id):
        raise SupervisorError("run id must match [a-z0-9][a-z0-9-]* and be at most 32 characters")
    return run_id


def parse_answer(value: str) -> dict[str, str]:
    if ":" not in value:
        raise SupervisorError("answer allowlist entry must be QUESTION_ID:FILE_NAME")
    question_id, file_name = value.split(":", 1)
    if not QUESTION_ID_RE.fullmatch(question_id):
        raise SupervisorError(f"invalid question id in answer allowlist: {question_id}")
    if not FILE_NAME_RE.fullmatch(file_name) or ".." in file_name:
        raise SupervisorError(f"invalid file name in answer allowlist: {file_name}")
    return {"question_id": question_id, "file_name": file_name}


def ensure_regular_owned(path: Path, *, mode: int | None = None) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise IntegrityError(f"protected file is unavailable: {path}") from exc
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise IntegrityError(f"protected path is not a regular non-symlink file: {path}")
    if metadata.st_uid != os.geteuid():
        raise IntegrityError(f"protected file is not owned by the supervisor user: {path}")
    if mode is not None and stat.S_IMODE(metadata.st_mode) != mode:
        raise IntegrityError(f"protected file mode must be {mode:04o}: {path}")
    return metadata


def create_once(path: Path, value: bytes, mode: int) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, mode)
    try:
        os.write(descriptor, value)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(path, mode)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def atomic_replace(path: Path, value: bytes, mode: int = 0o600) -> None:
    temporary = path.parent / f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    create_once(temporary, value, mode)
    os.replace(temporary, path)
    os.chmod(path, mode)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def append_audit(path: Path, event: dict[str, Any]) -> None:
    event = {"at_epoch": epoch_now(), **event}
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        os.write(descriptor, canonical_bytes(event))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(path, 0o600)


def filesystem_type(path: Path) -> str:
    try:
        result = subprocess.run(
            ["stat", "-f", "-c", "%T", str(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SupervisorError(f"cannot determine state filesystem type: {path}") from exc
    return result.stdout.decode("ascii", "strict").strip().lower()


def secure_state_root(raw: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        raise SupervisorError("state root must be an absolute native Linux path")
    if not path.exists():
        path.mkdir(mode=0o700, parents=True)
    resolved = path.resolve(strict=True)
    if resolved != path:
        raise SupervisorError("state root must be canonical and contain no symlink components")
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        raise SupervisorError("state root must be a real directory")
    if metadata.st_uid != os.geteuid():
        raise SupervisorError("state root must be owned by the supervisor user")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise SupervisorError("state root must not be accessible by group or other users")
    kind = filesystem_type(path)
    if kind in BLOCKED_FILESYSTEMS:
        raise SupervisorError(f"state root filesystem is not accepted for protected state: {kind}")
    return path


@contextlib.contextmanager
def kernel_lock(path: Path, *, blocking: bool = True) -> Iterator[None]:
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        operation = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
        try:
            fcntl.flock(descriptor, operation)
        except BlockingIOError as exc:
            raise SupervisorError(f"another supervisor transition owns the kernel lock: {path}") from exc
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


class Engine:
    def __init__(self, executable: str, timeout_seconds: float):
        candidate = shutil.which(executable) if "/" not in executable else executable
        if not candidate:
            raise SupervisorError(f"container engine command is not available: {executable}")
        resolved = Path(candidate).resolve(strict=True)
        if not resolved.is_file() or not os.access(resolved, os.X_OK):
            raise SupervisorError(f"container engine is not an executable file: {resolved}")
        self.path = resolved
        self.sha256 = sha256_file(resolved)
        self.timeout_seconds = float(timeout_seconds)
        if not 0 < self.timeout_seconds <= 30:
            raise SupervisorError("engine timeout must be greater than zero and at most 30 seconds")

    def _run(
        self,
        arguments: Sequence[str],
        *,
        input_bytes: bytes | None = None,
        timeout_seconds: float | None = None,
        allow_failure: bool = False,
        output_cap: int = MAX_ENGINE_OUTPUT_BYTES,
    ) -> CommandResult:
        command = [str(self.path), *arguments]
        timeout = self.timeout_seconds if timeout_seconds is None else timeout_seconds
        parent_pid = os.getpid()
        try:
            with tempfile.TemporaryFile(mode="w+b") as input_spool, \
                 tempfile.TemporaryFile(mode="w+b") as stdout_spool, \
                 tempfile.TemporaryFile(mode="w+b") as stderr_spool:
                if input_bytes is not None:
                    input_spool.write(input_bytes)
                    input_spool.seek(0)
                process = subprocess.Popen(
                    command,
                    stdin=input_spool,
                    stdout=stdout_spool,
                    stderr=stderr_spool,
                    preexec_fn=lambda: linux_engine_child_setup(parent_pid, output_cap),
                )
                deadline = time.monotonic() + timeout
                while process.poll() is None:
                    stdout_size = os.fstat(stdout_spool.fileno()).st_size
                    stderr_size = os.fstat(stderr_spool.fileno()).st_size
                    if stdout_size + stderr_size > output_cap:
                        process.kill()
                        process.wait()
                        raise EngineError("engine command output exceeded its bounded contract")
                    if time.monotonic() >= deadline:
                        process.kill()
                        process.wait()
                        raise EngineTimeout(f"engine command exceeded {timeout:g}s: {' '.join(arguments[:3])}")
                    time.sleep(0.01)
                stdout_size = os.fstat(stdout_spool.fileno()).st_size
                stderr_size = os.fstat(stderr_spool.fileno()).st_size
                if stdout_size + stderr_size > output_cap:
                    raise EngineError("engine command output exceeded its bounded contract")
                stdout_spool.seek(0)
                stderr_spool.seek(0)
                stdout = stdout_spool.read()
                stderr = stderr_spool.read()
                returncode = process.returncode
        except (OSError, subprocess.SubprocessError) as exc:
            raise EngineError(f"cannot execute container engine: {exc}") from exc
        if returncode and not allow_failure:
            detail = stderr.decode("utf-8", "replace").strip()[:400]
            raise EngineError(f"engine command failed ({returncode}): {' '.join(arguments[:3])}: {detail}")
        return CommandResult(stdout, stderr)

    def _json(self, arguments: Sequence[str]) -> Any:
        result = self._run(arguments)
        try:
            return json.loads(result.stdout)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise EngineError(f"engine returned invalid JSON for {' '.join(arguments[:3])}") from exc

    def image(self, reference: str, expected_role: str) -> dict[str, Any]:
        records = self._json(["image", "inspect", reference])
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise EngineError("image inspection did not return exactly one object")
        record = records[0]
        image_id = record.get("Id")
        labels = ((record.get("Config") or {}).get("Labels") or {})
        if not isinstance(image_id, str) or not IMAGE_ID_RE.fullmatch(image_id):
            raise EngineError("image inspection did not return a full sha256 image ID")
        if labels.get("org.cka-practice.ssh-image-role") != expected_role:
            raise EngineError(f"image does not declare SSH role {expected_role}: {reference}")
        return {"id": image_id, "reference": reference}

    def create_network(self, name: str, labels: dict[str, str]) -> str:
        arguments = ["network", "create", "--driver", "bridge", "--internal"]
        for key, value in sorted(labels.items()):
            arguments.extend(["--label", f"{key}={value}"])
        arguments.append(name)
        object_id = self._run(arguments).text()
        if not HEX64_RE.fullmatch(object_id):
            raise EngineError("network create did not return a full immutable ID")
        return object_id

    def create_container(
        self,
        *,
        name: str,
        hostname: str,
        network_id: str,
        labels: dict[str, str],
        image: str,
        role: str,
    ) -> str:
        arguments = [
            "container",
            "create",
            "--name",
            name,
            "--hostname",
            hostname,
            "--network",
            network_id,
        ]
        if role == "target":
            arguments.extend(["--network-alias", "cka-target", "--pids-limit", "512", "--cap-drop", "NET_RAW", "--cap-drop", "MKNOD"])
        else:
            arguments.extend(
                [
                    "--interactive",
                    "--tty",
                    "--pids-limit",
                    "128",
                    "--cap-drop",
                    "ALL",
                    "--security-opt",
                    "no-new-privileges",
                    "--tmpfs",
                    "/tmp:rw,noexec,nosuid,size=32m",
                ]
            )
        for key, value in sorted(labels.items()):
            arguments.extend(["--label", f"{key}={value}"])
        arguments.append(image)
        object_id = self._run(arguments).text()
        if not HEX64_RE.fullmatch(object_id):
            raise EngineError("container create did not return a full immutable ID")
        return object_id

    def inspect_container(self, object_id: str) -> dict[str, Any]:
        require_hex_id(object_id, "container")
        records = self._json(["container", "inspect", object_id])
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise EngineError("container inspection did not return exactly one object")
        return records[0]

    def inspect_network(self, object_id: str) -> dict[str, Any]:
        require_hex_id(object_id, "network")
        records = self._json(["network", "inspect", object_id])
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise EngineError("network inspection did not return exactly one object")
        return records[0]

    def list_containers(self, run_id: str, nonce: str) -> set[str]:
        result = self._run(
            [
                "container",
                "ls",
                "--all",
                "--quiet",
                "--no-trunc",
                "--filter",
                f"label=org.cka-practice.ssh-supervisor.run={run_id}",
                "--filter",
                f"label=org.cka-practice.ssh-supervisor.nonce={nonce}",
            ]
        )
        return parse_full_id_lines(result.text(), "container")

    def list_networks(self, run_id: str, nonce: str) -> set[str]:
        result = self._run(
            [
                "network",
                "ls",
                "--quiet",
                "--no-trunc",
                "--filter",
                f"label=org.cka-practice.ssh-supervisor.run={run_id}",
                "--filter",
                f"label=org.cka-practice.ssh-supervisor.nonce={nonce}",
            ]
        )
        return parse_full_id_lines(result.text(), "network")

    def start(self, object_id: str) -> None:
        require_hex_id(object_id, "container")
        self._run(["container", "start", object_id])

    def stop(self, object_id: str) -> None:
        require_hex_id(object_id, "container")
        self._run(["container", "stop", "--time", "0", object_id])

    def kill(self, object_id: str) -> None:
        require_hex_id(object_id, "container")
        self._run(["container", "kill", "--signal", "KILL", object_id])

    def remove_container(self, object_id: str) -> None:
        require_hex_id(object_id, "container")
        self._run(["container", "rm", object_id])

    def remove_network(self, object_id: str) -> None:
        require_hex_id(object_id, "network")
        self._run(["network", "rm", object_id])

    def connect_network(self, network_id: str, object_id: str) -> None:
        require_hex_id(network_id, "external network")
        require_hex_id(object_id, "container")
        self._run(["network", "connect", network_id, object_id])

    def copy_archive_into(self, object_id: str, archive: bytes) -> None:
        require_hex_id(object_id, "container")
        if not archive or len(archive) > MAX_INPUT_TOTAL_BYTES + (16 * 1024 * 1024):
            raise EngineError("input archive is empty or exceeds its bounded contract")
        self._run(
            ["container", "cp", "-", f"{object_id}:/"],
            input_bytes=archive,
            timeout_seconds=min(30.0, max(self.timeout_seconds, 10.0)),
            output_cap=4096,
        )

    def exec(
        self,
        object_id: str,
        arguments: Sequence[str],
        *,
        user: str,
        input_bytes: bytes | None = None,
        output_cap: int = 1024 * 1024,
        timeout_seconds: float | None = None,
        purpose: str | None = None,
    ) -> CommandResult:
        require_hex_id(object_id, "container")
        command = ["container", "exec"]
        if input_bytes is not None:
            command.append("--interactive")
        command.extend(["--user", user, object_id, *arguments])
        try:
            return self._run(
                command,
                input_bytes=input_bytes,
                output_cap=output_cap,
                timeout_seconds=timeout_seconds,
            )
        except SupervisorError as exc:
            if purpose is None:
                raise
            raise EngineError(f"{purpose}: {exc}") from exc

    def copy_archive(self, object_id: str, source: str) -> CommandResult:
        require_hex_id(object_id, "container")
        return self._run(
            ["container", "cp", f"{object_id}:{source}", "-"],
            allow_failure=True,
            output_cap=MAX_ENGINE_OUTPUT_BYTES,
        )


def _safe_source_file(path: Path, *, max_bytes: int, min_bytes: int = 1) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise SupervisorError(f"input source is not readable: {path}") from exc
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SupervisorError(f"input source must be a regular, non-linked file: {path}")
    if metadata.st_size < min_bytes or metadata.st_size > max_bytes:
        raise SupervisorError(f"input source has an invalid size: {path}")
    value = path.read_bytes()
    if len(value) != metadata.st_size:
        raise SupervisorError(f"input source changed while it was read: {path}")
    after = path.lstat()
    if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
    ):
        raise SupervisorError(f"input source changed while it was snapshotted: {path}")
    return value


def _canonical_source_path(raw: Any, *, kind: str) -> Path:
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        raise SupervisorError(f"{kind} path is invalid")
    path = Path(raw)
    if not path.is_absolute():
        raise SupervisorError(f"{kind} path must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise SupervisorError(f"{kind} path cannot be resolved: {path}") from exc
    if resolved != path:
        raise SupervisorError(f"{kind} path must be canonical and contain no symlink components: {path}")
    return resolved


def _archive_member(name: str, value: bytes, *, mode: int, uid: int, gid: int) -> tuple[tarfile.TarInfo, io.BytesIO]:
    member = tarfile.TarInfo(name)
    member.size = len(value)
    member.mode = mode
    member.uid = uid
    member.gid = gid
    member.uname = "candidate" if uid == 10001 else "root"
    member.gname = "candidate" if gid == 10001 else "root"
    member.mtime = 0
    return member, io.BytesIO(value)


def load_form_inputs(raw_path: str | None) -> tuple[dict[str, Any] | None, bytes | None]:
    """Validate and snapshot a runner input manifest before any object starts."""
    if raw_path is None:
        return None, None
    manifest_path = _canonical_source_path(raw_path, kind="input manifest")
    payload = _safe_source_file(manifest_path, max_bytes=1024 * 1024)
    try:
        value = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise SupervisorError("input manifest is not valid JSON") from exc
    if not isinstance(value, dict) or set(value) != {"schema_version", "active_question", "questions"}:
        raise SupervisorError("input manifest has unknown or missing fields")
    if value.get("schema_version") != 1 or not isinstance(value.get("questions"), list):
        raise SupervisorError("input manifest schema is invalid")
    questions = value["questions"]
    if not 1 <= len(questions) <= 128:
        raise SupervisorError("input manifest must contain between 1 and 128 questions")
    active = value.get("active_question")
    if not isinstance(active, str) or not QUESTION_ID_RE.fullmatch(active):
        raise SupervisorError("input manifest active question is invalid")

    contract_questions: list[dict[str, Any]] = []
    archive_entries: list[tuple[str, bytes, int, int, int]] = []
    seen_questions: set[str] = set()
    total = 0
    file_count = 0
    active_kubeconfig: bytes | None = None
    for item in questions:
        if not isinstance(item, dict) or set(item) != {"question_id", "kubeconfig", "work_root"}:
            raise SupervisorError("input manifest question entry is invalid")
        question_id = item.get("question_id")
        if not isinstance(question_id, str) or not QUESTION_ID_RE.fullmatch(question_id):
            raise SupervisorError("input manifest question id is invalid")
        if question_id in seen_questions:
            raise SupervisorError(f"input manifest contains duplicate question: {question_id}")
        seen_questions.add(question_id)

        kubeconfig_path = _canonical_source_path(item.get("kubeconfig"), kind=f"{question_id} kubeconfig")
        kubeconfig = _safe_source_file(kubeconfig_path, max_bytes=MAX_INPUT_FILE_BYTES)
        try:
            kubeconfig.decode("utf-8", "strict")
        except UnicodeDecodeError as exc:
            raise SupervisorError(f"{question_id} kubeconfig is not UTF-8") from exc
        kube_destination = f"etc/cka/kubeconfigs/{question_id}.yaml"
        archive_entries.append((kube_destination, kubeconfig, 0o444, 0, 0))
        total += len(kubeconfig)
        file_count += 1
        if question_id == active:
            active_kubeconfig = kubeconfig

        work_root = _canonical_source_path(item.get("work_root"), kind=f"{question_id} work root")
        if not work_root.is_dir() or work_root.is_symlink():
            raise SupervisorError(f"{question_id} work root must be a real directory")
        work_files: list[dict[str, Any]] = []
        for current, directories, names in os.walk(work_root, topdown=True, followlinks=False):
            current_path = Path(current)
            for directory in list(directories):
                candidate = current_path / directory
                metadata = candidate.lstat()
                if candidate.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
                    raise SupervisorError(f"work input contains a linked or special directory: {candidate}")
            for name in sorted(names):
                source = current_path / name
                relative = source.relative_to(work_root).as_posix()
                if not RELATIVE_INPUT_RE.fullmatch(relative) or any(part in {".", ".."} for part in Path(relative).parts):
                    raise SupervisorError(f"work input has an unsafe relative path: {relative}")
                content = _safe_source_file(source, max_bytes=MAX_INPUT_FILE_BYTES, min_bytes=0)
                total += len(content)
                file_count += 1
                if total > MAX_INPUT_TOTAL_BYTES or file_count > MAX_INPUT_FILES:
                    raise SupervisorError("form inputs exceed the bounded snapshot contract")
                destination = f"home/candidate/cka/{question_id}/{relative}"
                archive_entries.append((destination, content, 0o644, 10001, 10001))
                work_files.append({"path": relative, "sha256": sha256_bytes(content), "size": len(content)})
        contract_questions.append(
            {
                "question_id": question_id,
                "kubeconfig_sha256": sha256_bytes(kubeconfig),
                "kubeconfig_size": len(kubeconfig),
                "work_files": work_files,
            }
        )

    if active not in seen_questions or active_kubeconfig is None:
        raise SupervisorError("active question is not present in the input manifest")
    archive_entries.append(("home/candidate/.kube/config", active_kubeconfig, 0o600, 10001, 10001))
    active_marker = (active + "\n").encode("ascii")
    archive_entries.append(("home/candidate/.kube/active-question", active_marker, 0o600, 10001, 10001))
    total += len(active_kubeconfig) + len(active_marker)
    file_count += 2
    if total > MAX_INPUT_TOTAL_BYTES or file_count > MAX_INPUT_FILES:
        raise SupervisorError("form inputs exceed the bounded snapshot contract")

    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.PAX_FORMAT) as archive:
        directories = {"home/candidate/cka"}
        for question_id in seen_questions:
            directories.add(f"home/candidate/cka/{question_id}")
        for name, _content, _mode, uid, _gid in archive_entries:
            parent = Path(name).parent
            while parent.as_posix() not in {".", "home", "home/candidate"}:
                if parent.as_posix().startswith("home/candidate/cka"):
                    directories.add(parent.as_posix())
                parent = parent.parent
        for directory in sorted(directories, key=lambda value: (value.count("/"), value)):
            member = tarfile.TarInfo(directory)
            member.type = tarfile.DIRTYPE
            member.mode = 0o755
            member.uid = 10001
            member.gid = 10001
            member.uname = "candidate"
            member.gname = "candidate"
            member.mtime = 0
            archive.addfile(member)
        for name, content, mode, uid, gid in sorted(archive_entries, key=lambda entry: entry[0]):
            member, handle = _archive_member(name, content, mode=mode, uid=uid, gid=gid)
            archive.addfile(member, handle)
    bundle = stream.getvalue()
    contract = {
        "schema_version": 1,
        "source_manifest_sha256": sha256_bytes(payload),
        "active_question": active,
        "questions": contract_questions,
        "file_count": file_count,
        "total_bytes": total,
        "bundle_sha256": sha256_bytes(bundle),
    }
    return contract, bundle


def require_hex_id(value: str, kind: str) -> str:
    if not HEX64_RE.fullmatch(value):
        raise IntegrityError(f"{kind} manifest value is not a full immutable ID")
    return value


def parse_full_id_lines(value: str, kind: str) -> set[str]:
    if not value:
        return set()
    result: set[str] = set()
    for line in value.splitlines():
        object_id = line.strip()
        require_hex_id(object_id, kind)
        result.add(object_id)
    return result


class RunStore:
    def __init__(self, state_root: Path, run_id: str):
        self.root = state_root
        self.run_id = validate_run_id(run_id)
        self.run_dir = state_root / "runs" / run_id
        self.manifest_path = self.run_dir / "manifest.json"
        self.manifest_hash_path = self.run_dir / "manifest.sha256"
        self.objects_path = self.run_dir / "objects.json"
        self.objects_hash_path = self.run_dir / "objects.sha256"
        self.allocation_path = self.run_dir / "allocation.jsonl"
        self.status_path = self.run_dir / "status.json"
        self.timer_proof_path = self.run_dir / "timer-proof.json"
        self.guard_proof_path = self.run_dir / "guard-proof.json"
        self.seal_proof_path = self.run_dir / "seal-proof.json"
        self.invalid_seal_proof_path = self.run_dir / "invalid-seal-proof.json"
        self.allocation_recovery_proof_path = self.run_dir / "allocation-recovery-proof.json"
        self.cleanup_intent_path = self.run_dir / "cleanup-intent.json"
        self.audit_path = self.run_dir / "audit.jsonl"
        self.active_path = state_root / "active.json"
        self.transition_lock_path = state_root / "transition.lock"
        self.seal_lock_path = self.run_dir / "seal.lock"

    def prepare_directory(self) -> None:
        runs = self.root / "runs"
        runs.mkdir(mode=0o700, exist_ok=True)
        os.chmod(runs, 0o700)
        if self.run_dir.exists() or self.run_dir.is_symlink():
            raise SupervisorError(f"run id is create-once and already exists: {self.run_id}")
        self.run_dir.mkdir(mode=0o700)

    def write_status(
        self,
        phase: str,
        *,
        valid: bool,
        details: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        previous_revision = 0
        if self.status_path.exists():
            try:
                previous_revision = int(self.read_status().get("revision", 0))
            except SupervisorError:
                previous_revision = 0
        value: dict[str, Any] = {
            "schema_version": 1,
            "run_id": self.run_id,
            "phase": phase,
            "valid": bool(valid),
            "revision": previous_revision + 1,
            "updated_at_epoch": epoch_now(),
        }
        if details:
            value["details"] = details
        atomic_replace(self.status_path, canonical_bytes(value), 0o600)
        append_audit(self.audit_path, {"event": "status", "phase": phase, "valid": bool(valid)})
        return value

    def read_status(self) -> dict[str, Any]:
        ensure_regular_owned(self.status_path, mode=0o600)
        try:
            value = json.loads(self.status_path.read_bytes())
        except (OSError, json.JSONDecodeError) as exc:
            raise IntegrityError("status record is corrupt") from exc
        if not isinstance(value, dict) or value.get("run_id") != self.run_id:
            raise IntegrityError("status record belongs to a different run")
        return value

    def create_active(self, nonce: str) -> None:
        if self.active_path.exists() or self.active_path.is_symlink():
            ensure_regular_owned(self.active_path, mode=0o600)
            try:
                active = json.loads(self.active_path.read_bytes())
            except (OSError, json.JSONDecodeError) as exc:
                raise IntegrityError("active-run record is corrupt") from exc
            raise SupervisorError(f"another run has not been cleaned up: {active.get('run_id', 'unknown')}")
        create_once(
            self.active_path,
            canonical_bytes({"schema_version": 1, "run_id": self.run_id, "run_nonce": nonce}),
            0o600,
        )

    def require_active(self, nonce: str) -> None:
        ensure_regular_owned(self.active_path, mode=0o600)
        try:
            value = json.loads(self.active_path.read_bytes())
        except (OSError, json.JSONDecodeError) as exc:
            raise IntegrityError("active-run record is corrupt") from exc
        if value != {"schema_version": 1, "run_id": self.run_id, "run_nonce": nonce}:
            raise IntegrityError("active-run record does not match this run")

    def clear_active(self, nonce: str) -> None:
        self.require_active(nonce)
        self.active_path.unlink()
        directory_fd = os.open(self.active_path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

    def append_allocation(self, value: dict[str, Any]) -> None:
        append_audit(self.allocation_path, value)

    def finalize_create_once(self, path: Path, hash_path: Path, value: Any) -> str:
        payload = canonical_bytes(value)
        digest = sha256_bytes(payload)
        create_once(path, payload, 0o400)
        create_once(hash_path, (digest + "\n").encode("ascii"), 0o400)
        return digest

    def load_create_once(self, path: Path, hash_path: Path) -> tuple[dict[str, Any], str]:
        ensure_regular_owned(path, mode=0o400)
        ensure_regular_owned(hash_path, mode=0o400)
        payload = path.read_bytes()
        expected = hash_path.read_text(encoding="ascii").strip()
        actual = sha256_bytes(payload)
        if not HEX64_RE.fullmatch(expected) or not secrets.compare_digest(expected, actual):
            raise IntegrityError(f"create-once record digest mismatch: {path.name}")
        try:
            value = json.loads(payload)
        except json.JSONDecodeError as exc:
            raise IntegrityError(f"create-once record is not valid JSON: {path.name}") from exc
        if not isinstance(value, dict):
            raise IntegrityError(f"create-once record is not an object: {path.name}")
        return value, actual

    def load_manifest(self) -> tuple[dict[str, Any], str]:
        manifest, digest = self.load_create_once(self.manifest_path, self.manifest_hash_path)
        validate_manifest(manifest, self.run_id)
        return manifest, digest

    def load_objects(self) -> tuple[dict[str, Any], str]:
        objects, digest = self.load_create_once(self.objects_path, self.objects_hash_path)
        validate_objects_ledger(objects, self.run_id)
        return objects, digest


def validate_labels(labels: Any, run_id: str, nonce: str, *, role: str | None = None) -> dict[str, str]:
    if not isinstance(labels, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in labels.items()):
        raise IntegrityError("manifest labels are invalid")
    expected = {
        "org.cka-practice.ssh-supervisor.run": run_id,
        "org.cka-practice.ssh-supervisor.nonce": nonce,
        "org.cka-practice.ssh-supervisor.managed": "true",
    }
    if role:
        expected["org.cka-practice.ssh-supervisor.role"] = role
    else:
        expected["org.cka-practice.ssh-supervisor.purpose"] = "designated-host"
    for key, value in expected.items():
        if labels.get(key) != value:
            raise IntegrityError(f"manifest label mismatch: {key}")
    return labels


def validate_objects_ledger(value: dict[str, Any], run_id: str) -> None:
    if value.get("schema_version") != 1 or value.get("run_id") != run_id:
        raise IntegrityError("objects ledger belongs to a different run")
    nonce = value.get("run_nonce")
    if not isinstance(nonce, str) or not HEX64_RE.fullmatch(nonce):
        raise IntegrityError("objects ledger nonce is invalid")
    engine = value.get("engine")
    if not isinstance(engine, dict) or not Path(str(engine.get("path", ""))).is_absolute():
        raise IntegrityError("objects ledger engine is invalid")
    if not HEX64_RE.fullmatch(str(engine.get("sha256", ""))):
        raise IntegrityError("objects ledger engine digest is invalid")
    objects = value.get("objects")
    if not isinstance(objects, dict) or set(objects) != {"network", "target", "base"}:
        raise IntegrityError("objects ledger topology is invalid")
    network = objects["network"]
    require_hex_id(str(network.get("id", "")), "network")
    validate_labels(network.get("labels"), run_id, nonce)
    for role in ("target", "base"):
        record = objects[role]
        require_hex_id(str(record.get("id", "")), "container")
        if record.get("role") != role or not IMAGE_ID_RE.fullmatch(str(record.get("image_id", ""))):
            raise IntegrityError(f"objects ledger {role} identity is invalid")
        validate_labels(record.get("labels"), run_id, nonce, role=role)


def validate_manifest(value: dict[str, Any], run_id: str) -> None:
    if value.get("schema_version") != SCHEMA_VERSION or value.get("run_id") != run_id:
        raise IntegrityError("manifest belongs to a different run or schema")
    validate_objects_ledger(
        {
            "schema_version": value.get("schema_version"),
            "run_id": value.get("run_id"),
            "run_nonce": value.get("run_nonce"),
            "engine": value.get("engine"),
            "objects": value.get("objects"),
        },
        run_id,
    )
    nonce = str(value.get("timer_proof_nonce", ""))
    if not HEX64_RE.fullmatch(nonce):
        raise IntegrityError("manifest timer proof nonce is invalid")
    guard_nonce = str(value.get("guard_proof_nonce", ""))
    if not HEX64_RE.fullmatch(guard_nonce):
        raise IntegrityError("manifest guard proof nonce is invalid")
    created = value.get("created_at_epoch")
    deadline = value.get("deadline_epoch")
    duration = value.get("duration_seconds")
    if not all(isinstance(item, int) and item > 0 for item in (created, deadline, duration)):
        raise IntegrityError("manifest deadline fields are invalid")
    if duration > MAX_DURATION_SECONDS or deadline != created + duration:
        raise IntegrityError("manifest deadline is inconsistent")
    policy = value.get("policy")
    if not isinstance(policy, dict) or policy.get("seal_order") != ["target", "base"]:
        raise IntegrityError("manifest seal policy is invalid")
    if any(
        policy.get(key) is not False
        for key in ("candidate_has_engine_socket", "candidate_has_repository_mount", "candidate_has_grader_secret")
    ):
        raise IntegrityError("manifest candidate isolation policy is invalid")
    allowlist = value.get("answer_allowlist")
    if not isinstance(allowlist, list) or len(allowlist) > 128:
        raise IntegrityError("manifest answer allowlist is invalid")
    seen: set[tuple[str, str]] = set()
    for item in allowlist:
        if not isinstance(item, dict) or set(item) != {"question_id", "file_name"}:
            raise IntegrityError("manifest answer allowlist entry is invalid")
        parsed = parse_answer(f"{item['question_id']}:{item['file_name']}")
        key = (parsed["question_id"], parsed["file_name"])
        if key in seen:
            raise IntegrityError("manifest answer allowlist contains a duplicate")
        seen.add(key)
    form = value.get("form")
    external = value.get("external_network")
    if (form is None) != (external is None):
        raise IntegrityError("form inputs and external cluster network must be recorded together")
    if form is not None:
        validate_form_contract(form)
        if not isinstance(external, dict) or set(external) != {"id", "name", "driver", "internal", "labels_sha256"}:
            raise IntegrityError("external cluster network record is invalid")
        require_hex_id(str(external.get("id", "")), "external network")
        if not all(isinstance(external.get(key), str) and external[key] for key in ("name", "driver")):
            raise IntegrityError("external cluster network identity is incomplete")
        if not isinstance(external.get("internal"), bool) or not HEX64_RE.fullmatch(str(external.get("labels_sha256", ""))):
            raise IntegrityError("external cluster network fingerprint is invalid")
        form_questions = {item["question_id"] for item in form["questions"]}
        if any(item["question_id"] not in form_questions for item in allowlist):
            raise IntegrityError("answer allowlist escapes the immutable form")


def validate_form_contract(form: Any) -> None:
    if not isinstance(form, dict) or set(form) != {
        "schema_version",
        "source_manifest_sha256",
        "active_question",
        "questions",
        "file_count",
        "total_bytes",
        "bundle_sha256",
    }:
        raise IntegrityError("form input contract is invalid")
    if form.get("schema_version") != 1:
        raise IntegrityError("form input contract schema is invalid")
    if not HEX64_RE.fullmatch(str(form.get("source_manifest_sha256", ""))) \
       or not HEX64_RE.fullmatch(str(form.get("bundle_sha256", ""))):
        raise IntegrityError("form input digest is invalid")
    active = form.get("active_question")
    questions = form.get("questions")
    if not isinstance(active, str) or not QUESTION_ID_RE.fullmatch(active) or not isinstance(questions, list):
        raise IntegrityError("form input question set is invalid")
    seen: set[str] = set()
    counted_files = 2
    counted_bytes = len((active + "\n").encode("ascii"))
    active_size = 0
    for item in questions:
        if not isinstance(item, dict) or set(item) != {
            "question_id", "kubeconfig_sha256", "kubeconfig_size", "work_files"
        }:
            raise IntegrityError("form input question entry is invalid")
        question_id = item.get("question_id")
        if not isinstance(question_id, str) or not QUESTION_ID_RE.fullmatch(question_id) or question_id in seen:
            raise IntegrityError("form input question identity is invalid")
        seen.add(question_id)
        if not HEX64_RE.fullmatch(str(item.get("kubeconfig_sha256", ""))):
            raise IntegrityError("form kubeconfig digest is invalid")
        size = item.get("kubeconfig_size")
        if not isinstance(size, int) or not 1 <= size <= MAX_INPUT_FILE_BYTES:
            raise IntegrityError("form kubeconfig size is invalid")
        counted_files += 1
        counted_bytes += size
        if question_id == active:
            active_size = size
        work_files = item.get("work_files")
        if not isinstance(work_files, list):
            raise IntegrityError("form work file contract is invalid")
        paths: set[str] = set()
        for work in work_files:
            if not isinstance(work, dict) or set(work) != {"path", "sha256", "size"}:
                raise IntegrityError("form work file entry is invalid")
            relative = work.get("path")
            if not isinstance(relative, str) or not RELATIVE_INPUT_RE.fullmatch(relative) or relative in paths:
                raise IntegrityError("form work file path is invalid")
            paths.add(relative)
            if not HEX64_RE.fullmatch(str(work.get("sha256", ""))):
                raise IntegrityError("form work file digest is invalid")
            work_size = work.get("size")
            if not isinstance(work_size, int) or not 0 <= work_size <= MAX_INPUT_FILE_BYTES:
                raise IntegrityError("form work file size is invalid")
            counted_files += 1
            counted_bytes += work_size
    if active not in seen:
        raise IntegrityError("form active question is missing")
    counted_bytes += active_size
    if form.get("file_count") != counted_files or form.get("total_bytes") != counted_bytes:
        raise IntegrityError("form input accounting is inconsistent")
    if counted_files > MAX_INPUT_FILES or counted_bytes > MAX_INPUT_TOTAL_BYTES:
        raise IntegrityError("form input accounting exceeds policy")


def labels_for(run_id: str, nonce: str, role: str | None = None) -> dict[str, str]:
    labels = {
        "org.cka-practice.ssh-supervisor.run": run_id,
        "org.cka-practice.ssh-supervisor.nonce": nonce,
        "org.cka-practice.ssh-supervisor.managed": "true",
    }
    if role:
        labels["org.cka-practice.ssh-supervisor.role"] = role
    else:
        labels["org.cka-practice.ssh-supervisor.purpose"] = "designated-host"
    return labels


def engine_from_manifest(manifest: dict[str, Any], requested_path: str | None = None) -> Engine:
    record = manifest["engine"]
    engine = Engine(requested_path or record["path"], float(record["command_timeout_seconds"]))
    if str(engine.path) != record["path"] or not secrets.compare_digest(engine.sha256, record["sha256"]):
        raise IntegrityError("container engine executable does not match the immutable manifest")
    return engine


def inspect_container_identity(
    engine: Engine,
    manifest: dict[str, Any],
    role: str,
    *,
    require_running: bool | None = None,
) -> dict[str, Any]:
    expected = manifest["objects"][role]
    record = engine.inspect_container(expected["id"])
    if record.get("Id") != expected["id"] or record.get("Image") != expected["image_id"]:
        raise IntegrityError(f"{role} immutable object or image ID changed")
    labels = ((record.get("Config") or {}).get("Labels") or {})
    for key, value in expected["labels"].items():
        if labels.get(key) != value:
            raise IntegrityError(f"{role} ownership label mismatch: {key}")
    binds = ((record.get("HostConfig") or {}).get("Binds")) or []
    mounts = record.get("Mounts") or []
    if binds or mounts:
        raise IntegrityError(f"{role} unexpectedly exposes a host bind, volume, or secret mount")
    running = ((record.get("State") or {}).get("Running"))
    if not isinstance(running, bool):
        raise IntegrityError(f"{role} runtime state is invalid")
    if require_running is not None and running is not require_running:
        expectation = "running" if require_running else "stopped"
        raise IntegrityError(f"{role} is not {expectation}")
    return record


def run_network_name(manifest: dict[str, Any]) -> str:
    return f"cka-supervisor-{manifest['run_id']}-{manifest['run_nonce'][:12]}-net"


def inspect_network_identity(
    engine: Engine,
    manifest: dict[str, Any],
    expected_active_endpoints: set[str],
) -> dict[str, Any]:
    expected = manifest["objects"]["network"]
    record = engine.inspect_network(expected["id"])
    if record.get("Id") != expected["id"]:
        raise IntegrityError("network immutable object ID changed")
    if record.get("Name") != run_network_name(manifest):
        raise IntegrityError("run network name differs from the immutable run identity")
    labels = record.get("Labels") or {}
    for key, value in expected["labels"].items():
        if labels.get(key) != value:
            raise IntegrityError(f"network ownership label mismatch: {key}")
    if record.get("Internal") is not True:
        raise IntegrityError("run network is no longer internal")
    endpoints = record.get("Containers")
    if not isinstance(endpoints, dict):
        raise IntegrityError("run network endpoint inventory is unavailable")
    if any(not isinstance(endpoint, dict) for endpoint in endpoints.values()):
        raise IntegrityError("run network endpoint inventory is invalid")
    actual_endpoints = {require_hex_id(str(object_id), "network endpoint") for object_id in endpoints}
    if actual_endpoints != expected_active_endpoints:
        raise IntegrityError("run network active endpoints differ from the exact running manifest IDs")
    return record


def network_fingerprint(record: dict[str, Any]) -> dict[str, Any]:
    labels = record.get("Labels") or {}
    if not isinstance(labels, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in labels.items()):
        raise IntegrityError("external cluster network labels are invalid")
    name = record.get("Name")
    driver = record.get("Driver")
    internal = record.get("Internal")
    if not isinstance(name, str) or not name or not isinstance(driver, str) or not driver or not isinstance(internal, bool):
        raise IntegrityError("external cluster network identity is incomplete")
    return {
        "id": require_hex_id(str(record.get("Id", "")), "external network"),
        "name": name,
        "driver": driver,
        "internal": internal,
        "labels_sha256": sha256_bytes(canonical_bytes(labels)),
    }


def inspect_external_network_identity(engine: Engine, manifest: dict[str, Any]) -> dict[str, Any] | None:
    expected = manifest.get("external_network")
    if expected is None:
        return None
    actual = network_fingerprint(engine.inspect_network(expected["id"]))
    if actual != expected:
        raise IntegrityError("external cluster network identity changed")
    return actual


def inspect_container_attachments(manifest: dict[str, Any], role: str, record: dict[str, Any]) -> None:
    internal_id = manifest["objects"]["network"]["id"]
    if ((record.get("HostConfig") or {}).get("NetworkMode")) != internal_id:
        raise IntegrityError(f"{role} primary network differs from the immutable run network ID")
    networks = ((record.get("NetworkSettings") or {}).get("Networks"))
    if not isinstance(networks, dict):
        raise IntegrityError(f"{role} network attachments are unavailable")
    expected = {run_network_name(manifest): internal_id}
    if role == "target" and manifest.get("form") is not None:
        expected[manifest["external_network"]["name"]] = manifest["external_network"]["id"]
    if set(networks) != set(expected):
        raise IntegrityError(f"{role} network attachment names differ from the immutable manifest")
    running = ((record.get("State") or {}).get("Running"))
    if not isinstance(running, bool):
        raise IntegrityError(f"{role} runtime state is invalid")
    for name, attachment in networks.items():
        if not isinstance(attachment, dict):
            raise IntegrityError(f"{role} network attachment is invalid")
        # Docker records the selected network name and HostConfig.NetworkMode
        # for a created-but-never-started container, but leaves NetworkID and
        # EndpointID empty until the runtime endpoint exists.  Once running,
        # the exact immutable network ID must be present.
        attachment_id = str(attachment.get("NetworkID", ""))
        if running:
            if attachment_id != expected[name]:
                raise IntegrityError(f"{role} active network ID differs from the immutable manifest")
        elif attachment_id not in {"", expected[name]}:
            raise IntegrityError(f"{role} stopped network ID differs from the immutable manifest")


def exact_internal_ipv4(manifest: dict[str, Any], role: str, record: dict[str, Any]) -> str:
    if ((record.get("State") or {}).get("Running")) is not True:
        raise IntegrityError(f"{role} has no active internal IPv4 address while stopped")
    networks = ((record.get("NetworkSettings") or {}).get("Networks"))
    if not isinstance(networks, dict):
        raise IntegrityError(f"{role} network attachments are unavailable")
    attachment = networks.get(run_network_name(manifest))
    if not isinstance(attachment, dict):
        raise IntegrityError(f"{role} internal network attachment is unavailable")
    expected_network_id = manifest["objects"]["network"]["id"]
    if attachment.get("NetworkID") != expected_network_id:
        raise IntegrityError(f"{role} active internal network ID differs from the immutable manifest")
    try:
        address = ipaddress.IPv4Address(str(attachment.get("IPAddress", "")))
    except ipaddress.AddressValueError as exc:
        raise IntegrityError(f"{role} active internal IPv4 address is invalid") from exc
    if address.is_unspecified or address.is_loopback or address.is_link_local or address.is_multicast:
        raise IntegrityError(f"{role} active internal IPv4 address is unsafe")
    return str(address)


def inspect_exact_topology(engine: Engine, manifest: dict[str, Any]) -> None:
    expected_containers = {manifest["objects"][role]["id"] for role in ("target", "base")}
    expected_networks = {manifest["objects"]["network"]["id"]}
    actual_containers = engine.list_containers(manifest["run_id"], manifest["run_nonce"])
    actual_networks = engine.list_networks(manifest["run_id"], manifest["run_nonce"])
    if actual_containers != expected_containers:
        raise IntegrityError("managed container topology differs from the immutable manifest")
    if actual_networks != expected_networks:
        raise IntegrityError("managed network topology differs from the immutable manifest")
    records = {
        role: inspect_container_identity(engine, manifest, role)
        for role in ("target", "base")
    }
    inspect_container_attachments(manifest, "target", records["target"])
    inspect_container_attachments(manifest, "base", records["base"])
    active_endpoints = {
        manifest["objects"][role]["id"]
        for role, record in records.items()
        if ((record.get("State") or {}).get("Running")) is True
    }
    inspect_network_identity(engine, manifest, active_endpoints)
    inspect_external_network_identity(engine, manifest)


def build_object_record(
    engine: Engine,
    object_id: str,
    labels: dict[str, str],
    role: str,
    image_id: str,
) -> dict[str, Any]:
    synthetic = {
        "run_id": labels["org.cka-practice.ssh-supervisor.run"],
        "run_nonce": labels["org.cka-practice.ssh-supervisor.nonce"],
        "objects": {role: {"id": object_id, "image_id": image_id, "labels": labels, "role": role}},
    }
    expected = synthetic["objects"][role]
    record = engine.inspect_container(object_id)
    if record.get("Id") != object_id or record.get("Image") != image_id:
        raise IntegrityError(f"created {role} did not retain its immutable identity")
    actual_labels = ((record.get("Config") or {}).get("Labels") or {})
    for key, value in labels.items():
        if actual_labels.get(key) != value:
            raise IntegrityError(f"created {role} label mismatch: {key}")
    if ((record.get("State") or {}).get("Running")) is not False:
        raise IntegrityError(f"created {role} was not stopped")
    if (((record.get("HostConfig") or {}).get("Binds")) or []) or (record.get("Mounts") or []):
        raise IntegrityError(f"created {role} exposes a mount")
    return expected


def command_prepare(args: argparse.Namespace) -> int:
    run_id = validate_run_id(args.run_id)
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, run_id)
    duration = int(args.duration_seconds)
    if duration < 1 or duration > MAX_DURATION_SECONDS:
        raise SupervisorError(f"duration must be between 1 and {MAX_DURATION_SECONDS} seconds")
    answers = [parse_answer(value) for value in args.answer]
    if len({(item['question_id'], item['file_name']) for item in answers}) != len(answers):
        raise SupervisorError("duplicate answer allowlist entry")
    form_contract, input_bundle = load_form_inputs(args.input_manifest)
    if form_contract is None and args.external_network_id is not None:
        raise SupervisorError("external cluster network requires an immutable input manifest")
    if form_contract is not None and args.external_network_id is None:
        raise SupervisorError("supervised form inputs require an exact external cluster network ID")
    if form_contract is not None:
        form_questions = {item["question_id"] for item in form_contract["questions"]}
        for answer in answers:
            if answer["question_id"] not in form_questions:
                raise SupervisorError("answer allowlist references a question outside the immutable form")
    engine = Engine(args.engine, args.engine_timeout_seconds)
    external_network: dict[str, Any] | None = None
    if args.external_network_id is not None:
        external_id = require_hex_id(args.external_network_id, "external network")
        external_network = network_fingerprint(engine.inspect_network(external_id))
    created_at = epoch_now()
    deadline = created_at + duration
    nonce = secrets.token_hex(32)
    timer_nonce = secrets.token_hex(32)
    guard_nonce = secrets.token_hex(32)

    with kernel_lock(store.transition_lock_path):
        store.prepare_directory()
        store.create_active(nonce)
        store.append_allocation(
            {
                "event": "header",
                "schema_version": 1,
                "run_id": run_id,
                "run_nonce": nonce,
                "engine": {"path": str(engine.path), "sha256": engine.sha256},
            }
        )
        store.write_status("ALLOCATING", valid=False)
        try:
            target_image = engine.image(args.target_image, "target")
            base_image = engine.image(args.base_image, "base")
            network_labels = labels_for(run_id, nonce)
            target_labels = labels_for(run_id, nonce, "target")
            base_labels = labels_for(run_id, nonce, "base")
            prefix = f"cka-supervisor-{run_id}-{nonce[:12]}"

            network_name = f"{prefix}-net"
            store.append_allocation(
                {"event": "intent", "kind": "network", "name": network_name, "labels": network_labels}
            )
            network_id = engine.create_network(network_name, network_labels)
            store.append_allocation({"event": "object", "kind": "network", "id": network_id, "labels": network_labels})
            network_record = engine.inspect_network(network_id)
            if network_record.get("Id") != network_id or network_record.get("Internal") is not True:
                raise IntegrityError("created network identity or internal policy is invalid")
            for key, value in network_labels.items():
                if (network_record.get("Labels") or {}).get(key) != value:
                    raise IntegrityError(f"created network label mismatch: {key}")

            target_name = f"{prefix}-target"
            store.append_allocation(
                {
                    "event": "intent",
                    "kind": "target",
                    "name": target_name,
                    "labels": target_labels,
                    "image_id": target_image["id"],
                }
            )
            target_id = engine.create_container(
                name=target_name,
                hostname="cka-target",
                network_id=network_id,
                labels=target_labels,
                image=args.target_image,
                role="target",
            )
            store.append_allocation({"event": "object", "kind": "target", "id": target_id, "labels": target_labels, "image_id": target_image["id"]})
            target_record = build_object_record(engine, target_id, target_labels, "target", target_image["id"])

            if external_network is not None:
                engine.connect_network(external_network["id"], target_id)
                if input_bundle is None:
                    raise IntegrityError("input bundle is missing for supervised form")
                engine.copy_archive_into(target_id, input_bundle)

            base_name = f"{prefix}-base"
            store.append_allocation(
                {
                    "event": "intent",
                    "kind": "base",
                    "name": base_name,
                    "labels": base_labels,
                    "image_id": base_image["id"],
                }
            )
            base_id = engine.create_container(
                name=base_name,
                hostname="base",
                network_id=network_id,
                labels=base_labels,
                image=args.base_image,
                role="base",
            )
            store.append_allocation({"event": "object", "kind": "base", "id": base_id, "labels": base_labels, "image_id": base_image["id"]})
            base_record = build_object_record(engine, base_id, base_labels, "base", base_image["id"])

            objects = {
                "network": {"id": network_id, "labels": network_labels},
                "target": target_record,
                "base": base_record,
            }
            ledger = {
                "schema_version": 1,
                "run_id": run_id,
                "run_nonce": nonce,
                "engine": {"path": str(engine.path), "sha256": engine.sha256},
                "objects": objects,
            }
            objects_digest = store.finalize_create_once(store.objects_path, store.objects_hash_path, ledger)
            manifest = {
                "schema_version": SCHEMA_VERSION,
                "run_id": run_id,
                "run_nonce": nonce,
                "created_at_epoch": created_at,
                "deadline_epoch": deadline,
                "duration_seconds": duration,
                "boot_id": require_linux_boot_id(),
                "engine": {
                    "path": str(engine.path),
                    "sha256": engine.sha256,
                    "command_timeout_seconds": engine.timeout_seconds,
                },
                "timer_proof_nonce": timer_nonce,
                "guard_proof_nonce": guard_nonce,
                "objects": objects,
                "answer_allowlist": answers,
                "policy": {
                    "seal_order": ["target", "base"],
                    "objects_created_stopped": True,
                    "candidate_has_engine_socket": False,
                    "candidate_has_repository_mount": False,
                    "candidate_has_grader_secret": False,
                    "max_answer_file_bytes": MAX_ANSWER_FILE_BYTES,
                    "max_answer_total_bytes": MAX_ANSWER_TOTAL_BYTES,
                },
            }
            if form_contract is not None and external_network is not None:
                manifest["form"] = form_contract
                manifest["external_network"] = external_network
            validate_manifest(manifest, run_id)
            if form_contract is not None:
                inspect_exact_topology(engine, manifest)
                inspect_container_identity(engine, manifest, "target", require_running=False)
                inspect_container_identity(engine, manifest, "base", require_running=False)
            manifest_digest = store.finalize_create_once(store.manifest_path, store.manifest_hash_path, manifest)
            os.chmod(store.allocation_path, 0o400)
            store.write_status(
                "PREPARED",
                valid=True,
                details={"manifest_sha256": manifest_digest, "objects_sha256": objects_digest},
            )
        except BaseException as exc:
            store.write_status("INVALID", valid=False, details={"reason": "allocation-failed", "error": str(exc)[:400]})
            raise

    print(
        json.dumps(
            {
                "run_id": run_id,
                "phase": "PREPARED",
                "deadline_epoch": deadline,
                "timer_unit": timer_unit_name(run_id, nonce),
            },
            sort_keys=True,
        )
    )
    return 0


def timer_unit_name(run_id: str, nonce: str) -> str:
    return f"cka-ssh-deadline-{run_id}-{nonce[:12]}.timer"


def guard_unit_name(run_id: str, nonce: str) -> str:
    return f"cka-ssh-guard-{run_id}-{nonce[:12]}.service"


def command_timer_ready(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    with kernel_lock(store.transition_lock_path):
        manifest, digest = store.load_manifest()
        store.require_active(manifest["run_nonce"])
        status = store.read_status()
        if status.get("phase") != "PREPARED" or not status.get("valid"):
            raise SupervisorError("timer can only be authorized for a valid prepared run")
        if epoch_now() >= manifest["deadline_epoch"]:
            raise SupervisorError("deadline elapsed before the independent timer was authorized")
        expected_unit = timer_unit_name(store.run_id, manifest["run_nonce"])
        if args.unit != expected_unit:
            raise IntegrityError(f"timer unit must be exactly {expected_unit}")
        systemctl = Engine(args.systemctl, min(float(args.systemctl_timeout_seconds), 30.0))
        scope_arguments = ["--user"] if args.systemctl_scope == "user" else []
        result = systemctl._run([*scope_arguments, "is-active", "--quiet", expected_unit], output_cap=4096)
        if result.stdout.strip() not in (b"", b"active"):
            raise SupervisorError("independent deadline timer did not report active")
        proof = {
            "schema_version": 1,
            "run_id": store.run_id,
            "run_nonce": manifest["run_nonce"],
            "manifest_sha256": digest,
            "timer_proof_nonce": manifest["timer_proof_nonce"],
            "deadline_epoch": manifest["deadline_epoch"],
            "unit": expected_unit,
            "checked_at_epoch": epoch_now(),
            "systemctl": {"path": str(systemctl.path), "sha256": systemctl.sha256},
            "systemctl_scope": args.systemctl_scope,
        }
        if store.timer_proof_path.exists():
            ensure_regular_owned(store.timer_proof_path, mode=0o400)
            existing = json.loads(store.timer_proof_path.read_bytes())
            if existing != proof:
                raise IntegrityError("timer proof is create-once and differs from this authorization")
        else:
            create_once(store.timer_proof_path, canonical_bytes(proof), 0o400)
        append_audit(store.audit_path, {"event": "timer-ready", "unit": expected_unit})
    print(json.dumps(proof, sort_keys=True))
    return 0


def load_timer_proof(store: RunStore, manifest: dict[str, Any], digest: str) -> dict[str, Any]:
    ensure_regular_owned(store.timer_proof_path, mode=0o400)
    try:
        proof = json.loads(store.timer_proof_path.read_bytes())
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError("timer proof is corrupt") from exc
    expected = {
        "run_id": store.run_id,
        "run_nonce": manifest["run_nonce"],
        "manifest_sha256": digest,
        "timer_proof_nonce": manifest["timer_proof_nonce"],
        "deadline_epoch": manifest["deadline_epoch"],
        "unit": timer_unit_name(store.run_id, manifest["run_nonce"]),
    }
    for key, value in expected.items():
        if proof.get(key) != value:
            raise IntegrityError(f"timer proof mismatch: {key}")
    return proof


def create_or_validate_guard_proof(
    store: RunStore,
    manifest: dict[str, Any],
    digest: str,
    engine: Engine,
    unit: str,
) -> dict[str, Any]:
    expected_unit = guard_unit_name(store.run_id, manifest["run_nonce"])
    if unit != expected_unit:
        raise IntegrityError(f"guard unit must be exactly {expected_unit}")
    expected = {
        "schema_version": 1,
        "run_id": store.run_id,
        "run_nonce": manifest["run_nonce"],
        "manifest_sha256": digest,
        "guard_proof_nonce": manifest["guard_proof_nonce"],
        "boot_id": manifest["boot_id"],
        "unit": expected_unit,
    }
    if store.guard_proof_path.exists():
        ensure_regular_owned(store.guard_proof_path, mode=0o400)
        try:
            proof = json.loads(store.guard_proof_path.read_bytes())
        except (OSError, json.JSONDecodeError) as exc:
            raise IntegrityError("guard proof is corrupt") from exc
        for key, value in expected.items():
            if proof.get(key) != value:
                raise IntegrityError(f"guard proof mismatch: {key}")
        return proof

    # The first guard process publishes readiness only after it has verified
    # the independent timer and the stopped create-before-start topology.
    load_timer_proof(store, manifest, digest)
    status = store.read_status()
    if status.get("phase") != "PREPARED" or not status.get("valid"):
        raise SupervisorError("first guard start requires a valid prepared run")
    inspect_exact_topology(engine, manifest)
    inspect_container_identity(engine, manifest, "target", require_running=False)
    inspect_container_identity(engine, manifest, "base", require_running=False)
    proof = {**expected, "ready_at_epoch": epoch_now()}
    create_once(store.guard_proof_path, canonical_bytes(proof), 0o400)
    append_audit(store.audit_path, {"event": "guard-ready", "unit": expected_unit})
    return proof


def load_guard_proof(store: RunStore, manifest: dict[str, Any], digest: str, unit: str) -> dict[str, Any]:
    if not store.guard_proof_path.exists():
        raise SupervisorError("restartable guard has not published readiness")
    # Validation does not need an engine operation after the proof exists.
    ensure_regular_owned(store.guard_proof_path, mode=0o400)
    try:
        proof = json.loads(store.guard_proof_path.read_bytes())
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError("guard proof is corrupt") from exc
    expected = {
        "run_id": store.run_id,
        "run_nonce": manifest["run_nonce"],
        "manifest_sha256": digest,
        "guard_proof_nonce": manifest["guard_proof_nonce"],
        "boot_id": manifest["boot_id"],
        "unit": guard_unit_name(store.run_id, manifest["run_nonce"]),
    }
    if unit != expected["unit"]:
        raise IntegrityError(f"guard unit must be exactly {expected['unit']}")
    for key, value in expected.items():
        if proof.get(key) != value:
            raise IntegrityError(f"guard proof mismatch: {key}")
    return proof


def command_guard_ready(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    manifest, digest = store.load_manifest()
    proof = load_guard_proof(store, manifest, digest, args.unit)
    print(json.dumps(proof, sort_keys=True))
    return 0


def provision_ssh(store: RunStore, engine: Engine, manifest: dict[str, Any]) -> None:
    base_id = manifest["objects"]["base"]["id"]
    target_id = manifest["objects"]["target"]["id"]
    target_record = inspect_container_identity(engine, manifest, "target", require_running=True)
    target_ipv4 = exact_internal_ipv4(manifest, "target", target_record)
    engine.exec(
        target_id,
        [
            "sh",
            "-c",
            "set -eu; for attempt in $(seq 1 20); do "
            "if ss -H -lnt 'sport = :22' | grep -q .; then exit 0; fi; "
            "sleep 0.25; done; exit 1",
        ],
        user="root",
        timeout_seconds=min(30.0, max(engine.timeout_seconds, 10.0)),
        purpose="target SSH listener readiness",
    )
    engine.exec(
        base_id,
        [
            "sh",
            "-c",
            "set -eu; expected=$1; "
            "if grep -Eq '(^|[[:space:]])cka-target($|[[:space:]])' /etc/hosts; then exit 1; fi; "
            "printf '%s cka-target\\n' \"$expected\" >> /etc/hosts; "
            "set -- $(getent ahostsv4 cka-target); test \"${1:-}\" = \"$expected\"",
            "cka-target-binding",
            target_ipv4,
        ],
        user="root",
        purpose="base exact target-host binding",
    )
    append_audit(
        store.audit_path,
        {"event": "target-host-bound", "target_ipv4": target_ipv4},
    )
    engine.exec(
        base_id,
        [
            "bash",
            "-c",
            'set -euo pipefail; ssh_dir=/home/candidate/.ssh; umask 077; '
            'mkdir -p "$ssh_dir"; chmod 0700 "$ssh_dir"; '
            'test ! -e "$ssh_dir/id_ed25519"; ssh-keygen -q -t ed25519 -N "" -f "$ssh_dir/id_ed25519"',
        ],
        user="candidate",
        purpose="base candidate key generation",
    )
    public_key = engine.exec(
        base_id,
        ["cat", "/home/candidate/.ssh/id_ed25519.pub"],
        user="candidate",
        output_cap=4096,
        purpose="base candidate public-key read",
    ).stdout.strip()
    if not re.fullmatch(rb"ssh-ed25519 [A-Za-z0-9+/=]{32,1024}(?: [^\r\n]{1,128})?", public_key):
        raise IntegrityError("generated candidate public key is invalid")
    engine.exec(
        target_id,
        [
            "sh",
            "-c",
            "set -eu; umask 077; cat > /home/candidate/.ssh/authorized_keys; "
            "chown candidate:candidate /home/candidate/.ssh/authorized_keys; "
            "chmod 0600 /home/candidate/.ssh/authorized_keys",
        ],
        user="root",
        input_bytes=public_key + b"\n",
        purpose="target authorized-key installation",
    )
    engine.exec(
        base_id,
        [
            "bash",
            "-c",
            'set -euo pipefail; ssh_dir=/home/candidate/.ssh; for attempt in 1 2 3; do '
            'if ssh-keyscan -4 -T 2 -t ed25519 cka-target > "$ssh_dir/known_hosts" 2>"$ssh_dir/keyscan.err" '
            '&& test -s "$ssh_dir/known_hosts"; then chmod 0600 "$ssh_dir/known_hosts"; exit 0; fi; '
            'sleep 0.25; done; getent ahostsv4 cka-target >&2 || true; '
            'cat "$ssh_dir/keyscan.err" >&2 || true; exit 1',
        ],
        user="candidate",
        timeout_seconds=min(30.0, max(engine.timeout_seconds, 10.0)),
        purpose="base-to-target host-key readiness",
    )
    sentinel = engine.exec(
        base_id,
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "cka-target",
            "test \"$(id -un)\" = candidate && ! command -v ssh >/dev/null 2>&1 && printf CKA_SSH_OK",
        ],
        user="candidate",
        output_cap=4096,
        purpose="base-to-target SSH verification",
    ).stdout
    if sentinel != b"CKA_SSH_OK":
        raise IntegrityError("base-to-target SSH verification failed")


def verify_form_inputs(engine: Engine, manifest: dict[str, Any]) -> None:
    form = manifest.get("form")
    if form is None:
        return
    target_id = manifest["objects"]["target"]["id"]
    checks: list[str] = []
    active_hash = ""
    for question in form["questions"]:
        question_id = question["question_id"]
        kube_hash = question["kubeconfig_sha256"]
        checks.append(f"{kube_hash}  /etc/cka/kubeconfigs/{question_id}.yaml")
        if question_id == form["active_question"]:
            active_hash = kube_hash
        for work in question["work_files"]:
            checks.append(f"{work['sha256']}  /home/candidate/cka/{question_id}/{work['path']}")
    checks.append(f"{active_hash}  /home/candidate/.kube/config")
    marker_hash = sha256_bytes((form["active_question"] + "\n").encode("ascii"))
    checks.append(f"{marker_hash}  /home/candidate/.kube/active-question")
    result = engine.exec(
        target_id,
        ["sha256sum", "--check", "--strict", "--status", "-"],
        user="root",
        input_bytes=("\n".join(checks) + "\n").encode("ascii"),
        output_cap=4096,
    )
    if result.stdout or result.stderr:
        # --status is expected to be silent.  Treat unexpected output as an
        # image/tool contract change instead of accepting a weaker check.
        raise IntegrityError("form input verification produced unexpected output")


def start_container_before_seal(store: RunStore, engine: Engine, manifest: dict[str, Any], role: str) -> None:
    """Serialize the check-and-start edge against the independent sealer.

    The seal path does not wait for the broad transition lock.  This narrow
    per-run lock prevents a container start from landing after a deadline seal
    proof was created while keeping all non-start activation work outside the
    deadline-critical section.
    """
    with kernel_lock(store.seal_lock_path):
        if store.seal_proof_path.exists():
            raise SupervisorError(f"seal was committed before {role} start")
        if epoch_now() >= manifest["deadline_epoch"]:
            raise SupervisorError(f"deadline reached before {role} start")
        engine.start(manifest["objects"][role]["id"])
        inspect_container_identity(engine, manifest, role, require_running=True)


def command_activate(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    failure: BaseException | None = None
    manifest: dict[str, Any] | None = None
    with kernel_lock(store.transition_lock_path):
        manifest, digest = store.load_manifest()
        store.require_active(manifest["run_nonce"])
        load_timer_proof(store, manifest, digest)
        load_guard_proof(store, manifest, digest, guard_unit_name(store.run_id, manifest["run_nonce"]))
        status = store.read_status()
        if status.get("phase") == "RUNNING" and status.get("valid"):
            print(json.dumps(status, sort_keys=True))
            return 0
        if status.get("phase") != "PREPARED" or not status.get("valid"):
            raise SupervisorError("only a valid prepared run can be activated")
        engine = engine_from_manifest(manifest, args.engine)
        if require_linux_boot_id() != manifest["boot_id"]:
            raise IntegrityError("host boot changed before activation")
        if epoch_now() >= manifest["deadline_epoch"]:
            raise SupervisorError("deadline elapsed before activation")
        try:
            inspect_exact_topology(engine, manifest)
            inspect_container_identity(engine, manifest, "target", require_running=False)
            inspect_container_identity(engine, manifest, "base", require_running=False)
            start_container_before_seal(store, engine, manifest, "target")
            verify_form_inputs(engine, manifest)
            if epoch_now() >= manifest["deadline_epoch"] or store.seal_proof_path.exists():
                raise SupervisorError("deadline reached during activation")
            start_container_before_seal(store, engine, manifest, "base")
            provision_ssh(store, engine, manifest)
            with kernel_lock(store.seal_lock_path):
                if epoch_now() >= manifest["deadline_epoch"] or store.seal_proof_path.exists():
                    raise SupervisorError("deadline reached during SSH provisioning")
                status = store.write_status(
                    "RUNNING",
                    valid=True,
                    details={"manifest_sha256": digest, "deadline_epoch": manifest["deadline_epoch"]},
                )
        except BaseException as exc:
            error = str(exc)[:400]
            append_audit(store.audit_path, {"event": "activation-failed", "error": error})
            store.write_status("INVALID", valid=False, details={"reason": "activation-failed", "error": error})
            failure = exc
    if failure is not None and manifest is not None:
        try:
            seal_run(store, args.engine, "activation-failure", extra_invalid=["activation-failed"])
        except SupervisorError:
            pass
        raise failure
    print(json.dumps(status, sort_keys=True))
    return 0


def try_stop_container(engine: Engine, manifest: dict[str, Any], role: str, incidents: list[str]) -> dict[str, Any]:
    object_id = manifest["objects"][role]["id"]
    try:
        record = inspect_container_identity(engine, manifest, role)
    except SupervisorError as exc:
        incidents.append(f"{role}-identity:{exc}")
        return {"id": object_id, "identity_verified": False, "running": None}
    if ((record.get("State") or {}).get("Running")) is True:
        try:
            engine.stop(object_id)
        except SupervisorError as exc:
            incidents.append(f"{role}-stop:{exc}")
            try:
                engine.kill(object_id)
            except SupervisorError as kill_exc:
                incidents.append(f"{role}-kill:{kill_exc}")
    try:
        final = inspect_container_identity(engine, manifest, role)
        running = ((final.get("State") or {}).get("Running"))
    except SupervisorError as exc:
        incidents.append(f"{role}-verify:{exc}")
        return {"id": object_id, "identity_verified": False, "running": None}
    if running:
        incidents.append(f"{role}-still-running")
    return {"id": object_id, "identity_verified": True, "running": running}


def validate_existing_seal_proof(store: RunStore, manifest: dict[str, Any], digest: str, engine: Engine) -> dict[str, Any]:
    ensure_regular_owned(store.seal_proof_path, mode=0o400)
    try:
        proof = json.loads(store.seal_proof_path.read_bytes())
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError("seal proof is corrupt") from exc
    if proof.get("run_id") != store.run_id or proof.get("run_nonce") != manifest["run_nonce"]:
        raise IntegrityError("seal proof belongs to a different run")
    if proof.get("manifest_sha256") != digest:
        raise IntegrityError("seal proof manifest digest mismatch")
    expected_ids = {role: manifest["objects"][role]["id"] for role in ("target", "base")}
    actual_ids = {item.get("role"): item.get("id") for item in proof.get("containers", []) if isinstance(item, dict)}
    if actual_ids != expected_ids:
        raise IntegrityError("seal proof container IDs differ from the manifest")
    inspect_container_identity(engine, manifest, "target", require_running=False)
    inspect_container_identity(engine, manifest, "base", require_running=False)
    return proof


def seal_run(
    store: RunStore,
    requested_engine: str | None,
    reason: str,
    *,
    extra_invalid: list[str] | None = None,
) -> dict[str, Any]:
    manifest, digest = store.load_manifest()
    engine = engine_from_manifest(manifest, requested_engine)
    with kernel_lock(store.seal_lock_path):
        if store.seal_proof_path.exists():
            return validate_existing_seal_proof(store, manifest, digest, engine)
        now = epoch_now()
        # A user/operator command racing the authoritative timer at or after
        # the immutable boundary is still a deadline seal.  Keeping "manual"
        # here would let a timed-out perfect diagnostic score become PASS.
        if reason in {"manual", "operator"} and now >= manifest["deadline_epoch"]:
            reason = "deadline"
        incidents = list(extra_invalid or [])
        if reason == "activation-failure":
            incidents.append("activation-failed")
        if reason == "deadline" and now < manifest["deadline_epoch"]:
            raise SupervisorError("refusing an early deadline seal")
        try:
            inspect_exact_topology(engine, manifest)
        except SupervisorError as exc:
            incidents.append(f"topology:{exc}")
        containers: list[dict[str, Any]] = []
        for role in ("target", "base"):
            outcome = try_stop_container(engine, manifest, role, incidents)
            containers.append({"role": role, **outcome})
        all_stopped = all(item["identity_verified"] and item["running"] is False for item in containers)
        sealed_at = epoch_now()
        # The candidate cutoff is complete only after both exact container IDs
        # have been stopped and that state has been re-inspected.  A manual
        # request that acquired the lock before the deadline but completed the
        # cutoff at/after it is therefore still deadline provenance.
        if reason in {"manual", "operator"} and sealed_at >= manifest["deadline_epoch"]:
            reason = "deadline"
        if sealed_at > manifest["deadline_epoch"] + 1:
            incidents.append(f"deadline-missed-by-{sealed_at - manifest['deadline_epoch']}-seconds")
        proof = {
            "schema_version": 1,
            "run_id": store.run_id,
            "run_nonce": manifest["run_nonce"],
            "manifest_sha256": digest,
            "deadline_epoch": manifest["deadline_epoch"],
            "sealed_at_epoch": sealed_at,
            "reason": reason,
            "containers": containers,
            "seal_order": ["target", "base"],
            "seal_proven": all_stopped,
            "valid": all_stopped and not incidents,
            "incidents": incidents,
        }
        if all_stopped:
            create_once(store.seal_proof_path, canonical_bytes(proof), 0o400)
        phase = "SEALED" if proof["valid"] else "INVALID"
        store.write_status(
            phase,
            valid=proof["valid"],
            details={
                "seal_proven": all_stopped,
                "reason": reason,
                "incidents": incidents,
                "manifest_sha256": digest,
            },
        )
        append_audit(store.audit_path, {"event": "seal", "reason": reason, "seal_proven": all_stopped, "valid": proof["valid"]})
        if not all_stopped:
            raise SupervisorError("target/base stop could not be proven; collection and grading remain forbidden")
        return proof


def command_seal(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    proof = seal_run(store, args.engine, args.reason)
    print(json.dumps(proof, sort_keys=True))
    return 0 if proof["valid"] else 2


def emergency_seal_from_objects(store: RunStore, requested_engine: str | None, reason: str) -> dict[str, Any]:
    objects, objects_digest = store.load_objects()
    engine_record = objects["engine"]
    engine = Engine(requested_engine or engine_record["path"], 3.0)
    if str(engine.path) != engine_record["path"] or engine.sha256 != engine_record["sha256"]:
        raise IntegrityError("engine does not match emergency objects ledger")
    synthetic = {
        "run_id": store.run_id,
        "run_nonce": objects["run_nonce"],
        "objects": objects["objects"],
    }
    incidents = [reason]
    containers = []
    with kernel_lock(store.seal_lock_path):
        for role in ("target", "base"):
            outcome = try_stop_container(engine, synthetic, role, incidents)
            containers.append({"role": role, **outcome})
        all_stopped = all(item["identity_verified"] and item["running"] is False for item in containers)
        proof = {
            "schema_version": 1,
            "run_id": store.run_id,
            "run_nonce": objects["run_nonce"],
            "objects_sha256": objects_digest,
            "reason": reason,
            "sealed_at_epoch": epoch_now(),
            "containers": containers,
            "seal_proven": all_stopped,
            "valid": False,
            "incidents": incidents,
        }
        if store.invalid_seal_proof_path.exists():
            ensure_regular_owned(store.invalid_seal_proof_path, mode=0o400)
        else:
            create_once(store.invalid_seal_proof_path, canonical_bytes(proof), 0o400)
        store.write_status("INVALID", valid=False, details={"seal_proven": all_stopped, "reason": reason})
        return proof


def load_allocation_journal(
    store: RunStore,
) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    metadata = ensure_regular_owned(store.allocation_path)
    mode = stat.S_IMODE(metadata.st_mode)
    if mode not in {0o600, 0o400}:
        raise IntegrityError("allocation journal has an unsafe mode")
    header: dict[str, Any] | None = None
    intents: list[dict[str, Any]] = []
    objects: list[dict[str, Any]] = []
    try:
        lines = store.allocation_path.read_text(encoding="ascii").splitlines()
    except OSError as exc:
        raise IntegrityError("allocation journal cannot be read") from exc
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise IntegrityError("allocation journal is corrupt") from exc
        if not isinstance(event, dict):
            raise IntegrityError("allocation journal event is invalid")
        if event.get("event") == "header":
            if header is not None:
                raise IntegrityError("allocation journal has multiple headers")
            header = event
        elif event.get("event") == "intent":
            intents.append(event)
        elif event.get("event") == "object":
            objects.append(event)
        else:
            raise IntegrityError("allocation journal contains an unknown event")
    if header is None or header.get("run_id") != store.run_id:
        raise IntegrityError("allocation journal belongs to a different run")
    nonce = str(header.get("run_nonce", ""))
    if not HEX64_RE.fullmatch(nonce):
        raise IntegrityError("allocation journal nonce is invalid")
    engine = header.get("engine")
    if not isinstance(engine, dict) or not Path(str(engine.get("path", ""))).is_absolute():
        raise IntegrityError("allocation journal engine is invalid")
    if not HEX64_RE.fullmatch(str(engine.get("sha256", ""))):
        raise IntegrityError("allocation journal engine digest is invalid")
    prefix = f"cka-supervisor-{store.run_id}-{nonce[:12]}"
    expected_names = {
        "network": f"{prefix}-net",
        "target": f"{prefix}-target",
        "base": f"{prefix}-base",
    }
    seen_intents: set[str] = set()
    for event in intents:
        kind = event.get("kind")
        if kind not in {"network", "target", "base"} or kind in seen_intents:
            raise IntegrityError("allocation journal intent topology is invalid")
        seen_intents.add(kind)
        if event.get("name") != expected_names[kind]:
            raise IntegrityError("allocation journal intent name is invalid")
        validate_labels(event.get("labels"), store.run_id, nonce, role=kind if kind in {"target", "base"} else None)
        if kind in {"target", "base"} and not IMAGE_ID_RE.fullmatch(str(event.get("image_id", ""))):
            raise IntegrityError("allocation journal intent image ID is invalid")
    seen: set[str] = set()
    intents_by_kind = {event["kind"]: event for event in intents}
    for event in objects:
        kind = event.get("kind")
        if kind not in {"network", "target", "base"} or kind in seen:
            raise IntegrityError("allocation journal object topology is invalid")
        seen.add(kind)
        intent = intents_by_kind.get(kind)
        if intent is None:
            raise IntegrityError("allocation journal object has no durable create intent")
        require_hex_id(str(event.get("id", "")), "allocation object")
        validate_labels(event.get("labels"), store.run_id, nonce, role=kind if kind in {"target", "base"} else None)
        if event.get("labels") != intent.get("labels"):
            raise IntegrityError("allocation journal object labels differ from its create intent")
        if kind in {"target", "base"} and not IMAGE_ID_RE.fullmatch(str(event.get("image_id", ""))):
            raise IntegrityError("allocation journal container image ID is invalid")
        if kind in {"target", "base"} and event.get("image_id") != intent.get("image_id"):
            raise IntegrityError("allocation journal object image differs from its create intent")
    return header, intents, objects


def recover_incomplete_allocation(store: RunStore, requested_engine: str | None, reason: str) -> dict[str, Any]:
    header, intents, events = load_allocation_journal(store)
    engine_record = header["engine"]
    engine = Engine(requested_engine or engine_record["path"], 3.0)
    if str(engine.path) != engine_record["path"] or engine.sha256 != engine_record["sha256"]:
        raise IntegrityError("engine does not match incomplete-allocation journal")
    nonce = header["run_nonce"]
    intents_by_kind = {event["kind"]: event for event in intents}
    by_kind = {event["kind"]: event for event in events}

    # A create request can succeed in the daemon before its CLI prints the
    # immutable ID.  Reconcile the fsynced pre-create intent against the exact
    # nonce label set, and persist any safely discovered ID before deletion.
    actual_container_ids = engine.list_containers(store.run_id, nonce)
    if len(actual_container_ids) > 2:
        raise IntegrityError("incomplete allocation has an ambiguous container label set")
    discovered_containers: dict[str, tuple[str, dict[str, Any]]] = {}
    for object_id in actual_container_ids:
        record = engine.inspect_container(object_id)
        labels = ((record.get("Config") or {}).get("Labels") or {})
        role = labels.get("org.cka-practice.ssh-supervisor.role")
        intent = intents_by_kind.get(str(role))
        if role not in {"target", "base"} or intent is None or role in discovered_containers:
            raise IntegrityError("incomplete allocation container role is ambiguous")
        journaled = by_kind.get(role)
        if journaled is not None and journaled["id"] != object_id:
            raise IntegrityError(f"incomplete {role} differs from its journaled immutable ID")
        if record.get("Id") != object_id or record.get("Image") != intent["image_id"]:
            raise IntegrityError(f"incomplete {role} immutable identity mismatch")
        for key, value in intent["labels"].items():
            if labels.get(key) != value:
                raise IntegrityError(f"incomplete {role} ownership mismatch")
        if str(record.get("Name", "")).lstrip("/") != intent["name"]:
            raise IntegrityError(f"incomplete {role} create-intent name mismatch")
        if ((record.get("State") or {}).get("Running")) is not False:
            raise IntegrityError(f"incomplete {role} unexpectedly started")
        if (((record.get("HostConfig") or {}).get("Binds")) or []) or (record.get("Mounts") or []):
            raise IntegrityError(f"incomplete {role} unexpectedly exposes a mount")
        discovered_containers[role] = (object_id, record)

    actual_network_ids = engine.list_networks(store.run_id, nonce)
    if len(actual_network_ids) > 1:
        raise IntegrityError("incomplete allocation has an ambiguous network label set")
    discovered_network: tuple[str, dict[str, Any]] | None = None
    if actual_network_ids:
        intent = intents_by_kind.get("network")
        if intent is None:
            raise IntegrityError("incomplete allocation network has no create intent")
        object_id = next(iter(actual_network_ids))
        journaled = by_kind.get("network")
        if journaled is not None and journaled["id"] != object_id:
            raise IntegrityError("incomplete network differs from its journaled immutable ID")
        record = engine.inspect_network(object_id)
        if record.get("Id") != object_id or record.get("Internal") is not True:
            raise IntegrityError("incomplete network immutable identity mismatch")
        labels = record.get("Labels") or {}
        for key, value in intent["labels"].items():
            if labels.get(key) != value:
                raise IntegrityError("incomplete network ownership mismatch")
        if record.get("Name") != intent["name"]:
            raise IntegrityError("incomplete network create-intent name mismatch")
        discovered_network = (object_id, record)

    # Discovery is durable before any deletion.  A retry can therefore accept
    # an absent journaled ID as evidence that the preceding removal completed.
    for role in ("target", "base"):
        discovered = discovered_containers.get(role)
        if discovered is not None and role not in by_kind:
            object_id, _record = discovered
            intent = intents_by_kind[role]
            event = {
                "event": "object",
                "kind": role,
                "id": object_id,
                "labels": intent["labels"],
                "image_id": intent["image_id"],
            }
            store.append_allocation(event)
            by_kind[role] = event
    if discovered_network is not None and "network" not in by_kind:
        object_id, _record = discovered_network
        intent = intents_by_kind["network"]
        event = {"event": "object", "kind": "network", "id": object_id, "labels": intent["labels"]}
        store.append_allocation(event)
        by_kind["network"] = event

    removed: list[dict[str, str]] = []
    for role in ("target", "base"):
        discovered = discovered_containers.get(role)
        if discovered is not None:
            engine.remove_container(discovered[0])
        event = by_kind.get(role)
        if event is not None:
            removed.append({"kind": role, "id": event["id"]})
    if engine.list_containers(store.run_id, nonce):
        raise SupervisorError("incomplete allocation container cleanup could not be proven")
    if discovered_network is not None:
        engine.remove_network(discovered_network[0])
    network = by_kind.get("network")
    if network is not None:
        removed.append({"kind": "network", "id": network["id"]})
    if engine.list_networks(store.run_id, nonce):
        raise SupervisorError("incomplete allocation network cleanup could not be proven")
    os.chmod(store.allocation_path, 0o400)
    proof = {
        "schema_version": 1,
        "run_id": store.run_id,
        "run_nonce": nonce,
        "reason": reason,
        "recovered_at_epoch": epoch_now(),
        "removed": removed,
        "valid": False,
    }
    if store.allocation_recovery_proof_path.exists():
        ensure_regular_owned(store.allocation_recovery_proof_path, mode=0o400)
    else:
        create_once(store.allocation_recovery_proof_path, canonical_bytes(proof), 0o400)
    store.write_status("INVALID", valid=False, details={"reason": reason, "incomplete_resources_removed": True})
    if store.active_path.exists():
        store.clear_active(nonce)
    return proof


def command_recover(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    try:
        manifest, digest = store.load_manifest()
    except SupervisorError as exc:
        if store.objects_path.exists():
            proof = emergency_seal_from_objects(store, args.engine, f"manifest-integrity:{exc}")
        else:
            proof = recover_incomplete_allocation(store, args.engine, f"incomplete-allocation:{exc}")
        print(json.dumps(proof, sort_keys=True))
        return 2
    engine = engine_from_manifest(manifest, args.engine)
    try:
        store.require_active(manifest["run_nonce"])
        status = store.read_status()
        phase = status.get("phase")
        if store.seal_proof_path.exists():
            proof = validate_existing_seal_proof(store, manifest, digest, engine)
            print(json.dumps(proof, sort_keys=True))
            return 0 if proof.get("valid") else 2
        if require_linux_boot_id() != manifest["boot_id"]:
            proof = seal_run(store, args.engine, "recovery", extra_invalid=["host-boot-changed"])
            print(json.dumps(proof, sort_keys=True))
            return 2
        inspect_exact_topology(engine, manifest)
        target = inspect_container_identity(engine, manifest, "target")
        base = inspect_container_identity(engine, manifest, "base")
        running = {
            "target": bool((target.get("State") or {}).get("Running")),
            "base": bool((base.get("State") or {}).get("Running")),
        }
        if phase == "PREPARED" and any(running.values()):
            proof = seal_run(store, args.engine, "recovery", extra_invalid=["unexpected-running-object-before-activation"])
            print(json.dumps(proof, sort_keys=True))
            return 2
        if phase == "RUNNING" and running != {"target": True, "base": True}:
            proof = seal_run(store, args.engine, "recovery", extra_invalid=["partial-running-topology"])
            print(json.dumps(proof, sort_keys=True))
            return 2
        if epoch_now() >= manifest["deadline_epoch"]:
            proof = seal_run(store, args.engine, "deadline")
            print(json.dumps(proof, sort_keys=True))
            return 0 if proof["valid"] else 2
        if phase not in {"PREPARED", "RUNNING"}:
            raise IntegrityError(f"cannot recover run in phase {phase}")
        output = {
            "run_id": store.run_id,
            "phase": phase,
            "valid": True,
            "seconds_remaining": manifest["deadline_epoch"] - epoch_now(),
        }
        print(json.dumps(output, sort_keys=True))
        return 0
    except SupervisorError as exc:
        try:
            proof = seal_run(store, args.engine, "recovery", extra_invalid=[f"recovery-integrity:{exc}"])
            print(json.dumps(proof, sort_keys=True))
        except SupervisorError:
            store.write_status("INVALID", valid=False, details={"reason": "recovery-failed", "error": str(exc)[:400]})
        return 2


def command_watch(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    manifest, digest = store.load_manifest()
    engine = engine_from_manifest(manifest, args.engine)
    first_start = not store.guard_proof_path.exists()
    if first_start:
        with kernel_lock(store.transition_lock_path):
            # Reload inside the transition lock so readiness cannot race the
            # activation transition.
            manifest, digest = store.load_manifest()
            store.require_active(manifest["run_nonce"])
            create_or_validate_guard_proof(store, manifest, digest, engine, args.unit)
    else:
        load_guard_proof(store, manifest, digest, args.unit)
        # A restarted guard performs an immediate consistency audit.  A crash
        # between target/base start is therefore sealed now, not at deadline.
        if store.seal_proof_path.exists():
            return 0
        try:
            status = store.read_status()
            phase = status.get("phase")
            inspect_exact_topology(engine, manifest)
            target = inspect_container_identity(engine, manifest, "target")
            base = inspect_container_identity(engine, manifest, "base")
            running = {
                "target": bool((target.get("State") or {}).get("Running")),
                "base": bool((base.get("State") or {}).get("Running")),
            }
            if phase == "PREPARED" and running != {"target": False, "base": False}:
                proof = seal_run(store, args.engine, "recovery", extra_invalid=["guard-restart-during-activation"])
                return 0 if proof["valid"] else 2
            if phase == "RUNNING" and running != {"target": True, "base": True}:
                proof = seal_run(store, args.engine, "recovery", extra_invalid=["guard-restart-partial-topology"])
                return 0 if proof["valid"] else 2
            if phase not in {"PREPARED", "RUNNING"}:
                proof = seal_run(store, args.engine, "recovery", extra_invalid=[f"guard-restart-phase-{phase}"])
                return 0 if proof["valid"] else 2
        except SupervisorError as exc:
            proof = seal_run(store, args.engine, "recovery", extra_invalid=[f"guard-restart-integrity:{exc}"])
            return 0 if proof["valid"] else 2
    while True:
        if store.seal_proof_path.exists():
            return 0
        if require_linux_boot_id() != manifest["boot_id"]:
            proof = seal_run(store, args.engine, "recovery", extra_invalid=["host-boot-changed"])
            return 0 if proof["valid"] else 2
        remaining = manifest["deadline_epoch"] - epoch_now()
        if remaining <= 0:
            proof = seal_run(store, args.engine, "deadline")
            return 0 if proof["valid"] else 2
        time.sleep(min(float(args.poll_seconds), float(remaining), 1.0))


def load_valid_seal_gate(store: RunStore, requested_engine: str | None) -> tuple[dict[str, Any], str, Engine, dict[str, Any]]:
    manifest, digest = store.load_manifest()
    engine = engine_from_manifest(manifest, requested_engine)
    proof = validate_existing_seal_proof(store, manifest, digest, engine)
    if not proof.get("seal_proven") or not proof.get("valid"):
        raise SupervisorError("run does not have a valid seal proof")
    status = store.read_status()
    if status.get("phase") not in {"SEALED", "COLLECTED"} or not status.get("valid"):
        raise SupervisorError("run status does not authorize collection or grading")
    inspect_exact_topology(engine, manifest)
    return manifest, digest, engine, proof


def safe_extract_answer(archive: bytes, expected_name: str, max_bytes: int) -> bytes:
    try:
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:*") as bundle:
            members = bundle.getmembers()
            regular = []
            for member in members:
                normalized = Path(member.name)
                if normalized.is_absolute() or ".." in normalized.parts:
                    raise IntegrityError("answer archive contains path traversal")
                if member.issym() or member.islnk() or member.isdev() or member.isdir():
                    if member.isdir():
                        continue
                    raise IntegrityError("answer archive contains a link or special file")
                if not member.isfile():
                    raise IntegrityError("answer archive contains an unsupported member")
                regular.append(member)
            if len(regular) != 1 or Path(regular[0].name).name != expected_name:
                raise IntegrityError("answer archive does not contain exactly the allowlisted file")
            member = regular[0]
            if member.size < 0 or member.size > max_bytes:
                raise IntegrityError("answer file exceeds its bounded size")
            handle = bundle.extractfile(member)
            if handle is None:
                raise IntegrityError("answer file cannot be extracted")
            value = handle.read(max_bytes + 1)
            if len(value) != member.size or len(value) > max_bytes:
                raise IntegrityError("answer file size changed during extraction")
            return value
    except tarfile.TarError as exc:
        raise IntegrityError("answer archive is invalid") from exc


def command_collect(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    destination = Path(args.destination)
    if not destination.is_absolute() or destination.exists() or destination.is_symlink():
        raise SupervisorError("collection destination must be a new absolute path")
    parent = destination.parent.resolve(strict=True)
    if parent != destination.parent or parent.is_symlink():
        raise SupervisorError("collection destination parent must be canonical and non-symlink")
    with kernel_lock(store.transition_lock_path):
        manifest, digest, engine, proof = load_valid_seal_gate(store, args.engine)
        destination.mkdir(mode=0o700)
        total = 0
        collected: list[str] = []
        for entry in manifest["answer_allowlist"]:
            question_id = entry["question_id"]
            file_name = entry["file_name"]
            source = f"/home/candidate/cka/{question_id}/{file_name}"
            result = engine.copy_archive(manifest["objects"]["target"]["id"], source)
            if result.stderr and not result.stdout:
                detail = result.stderr.decode("utf-8", "replace").lower()
                if "no such file" in detail or "could not find" in detail:
                    continue
                raise EngineError(f"cannot collect allowlisted answer {question_id}/{file_name}")
            value = safe_extract_answer(result.stdout, file_name, manifest["policy"]["max_answer_file_bytes"])
            total += len(value)
            if total > manifest["policy"]["max_answer_total_bytes"]:
                raise IntegrityError("collected answers exceed total size limit")
            question_dir = destination / question_id
            question_dir.mkdir(mode=0o700)
            answer_path = question_dir / file_name
            create_once(answer_path, value, 0o600)
            collected.append(f"{question_id}/{file_name}")
        status = store.write_status(
            "COLLECTED",
            valid=True,
            details={
                "manifest_sha256": digest,
                "seal_proof_sha256": sha256_file(store.seal_proof_path),
                "destination": str(destination),
                "files": collected,
            },
        )
    print(json.dumps(status, sort_keys=True))
    return 0


def command_authorize_grade(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    with kernel_lock(store.transition_lock_path):
        manifest, digest, _engine, proof = load_valid_seal_gate(store, args.engine)
        authorization = {
            "schema_version": 1,
            "run_id": store.run_id,
            "run_nonce": manifest["run_nonce"],
            "manifest_sha256": digest,
            "seal_proof_sha256": sha256_file(store.seal_proof_path),
            "authorized_at_epoch": epoch_now(),
            "operation": "grade",
            "seal_reason": proof["reason"],
            "sealed_at_epoch": proof["sealed_at_epoch"],
            "deadline_epoch": manifest["deadline_epoch"],
            "deadline_enforced": proof["reason"] == "deadline",
        }
        append_audit(store.audit_path, {"event": "grade-authorized", "manifest_sha256": digest})
    print(json.dumps(authorization, sort_keys=True))
    return 0


def command_status(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    manifest, digest = store.load_manifest()
    status = store.read_status()
    output = {
        **status,
        "deadline_epoch": manifest["deadline_epoch"],
        "seconds_remaining": max(0, manifest["deadline_epoch"] - epoch_now()),
        "manifest_sha256": digest,
        "seal_proof": store.seal_proof_path.exists(),
    }
    print(json.dumps(output, sort_keys=True))
    return 0


def command_preflight(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    output = {
        "schema_version": 1,
        "state_root": str(state_root),
        "filesystem": filesystem_type(state_root),
        "boot_id": require_linux_boot_id(),
    }
    print(json.dumps(output, sort_keys=True))
    return 0


def command_candidate_entry(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    with kernel_lock(store.transition_lock_path):
        manifest, digest = store.load_manifest()
        store.require_active(manifest["run_nonce"])
        status = store.read_status()
        if status.get("phase") != "RUNNING" or not status.get("valid"):
            raise SupervisorError("candidate entry is available only for a valid running session")
        if epoch_now() >= manifest["deadline_epoch"] or store.seal_proof_path.exists():
            raise SupervisorError("candidate entry is closed because the session deadline or seal was reached")
        engine = engine_from_manifest(manifest, args.engine)
        inspect_exact_topology(engine, manifest)
        inspect_container_identity(engine, manifest, "target", require_running=True)
        inspect_container_identity(engine, manifest, "base", require_running=True)
        output = {
            "schema_version": 1,
            "run_id": store.run_id,
            "manifest_sha256": digest,
            "base_container_id": manifest["objects"]["base"]["id"],
            "candidate_user": "candidate",
            "ssh_destination": "cka-target",
        }
    print(json.dumps(output, sort_keys=True))
    return 0


def cleanup_intent_value(manifest: dict[str, Any], manifest_digest: str) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "run_id": manifest["run_id"],
        "run_nonce": manifest["run_nonce"],
        "manifest_sha256": manifest_digest,
        "objects": {
            "target": manifest["objects"]["target"]["id"],
            "base": manifest["objects"]["base"]["id"],
            "network": manifest["objects"]["network"]["id"],
        },
    }


def load_cleanup_intent(store: RunStore, manifest: dict[str, Any], manifest_digest: str) -> dict[str, Any]:
    ensure_regular_owned(store.cleanup_intent_path, mode=0o400)
    try:
        value = json.loads(store.cleanup_intent_path.read_bytes())
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError("cleanup intent is corrupt") from exc
    expected = cleanup_intent_value(manifest, manifest_digest)
    if value != expected:
        raise IntegrityError("cleanup intent differs from the immutable manifest")
    return value


def inspect_cleanup_remainder(engine: Engine, manifest: dict[str, Any]) -> tuple[set[str], set[str]]:
    run_id = manifest["run_id"]
    nonce = manifest["run_nonce"]
    expected_containers = {manifest["objects"][role]["id"] for role in ("target", "base")}
    expected_network = {manifest["objects"]["network"]["id"]}
    actual_containers = engine.list_containers(run_id, nonce)
    actual_networks = engine.list_networks(run_id, nonce)
    if not actual_containers.issubset(expected_containers):
        raise IntegrityError("cleanup remainder contains a non-manifest container")
    if not actual_networks.issubset(expected_network):
        raise IntegrityError("cleanup remainder contains a non-manifest network")
    if actual_containers and not actual_networks:
        raise IntegrityError("cleanup remainder lost its immutable run network")
    for role in ("target", "base"):
        if manifest["objects"][role]["id"] in actual_containers:
            record = inspect_container_identity(engine, manifest, role, require_running=False)
            inspect_container_attachments(manifest, role, record)
    if actual_networks:
        inspect_network_identity(engine, manifest, set())
    return actual_containers, actual_networks


def command_cleanup(args: argparse.Namespace) -> int:
    state_root = secure_state_root(args.state_root)
    store = RunStore(state_root, args.run_id)
    with kernel_lock(store.transition_lock_path):
        manifest, digest = store.load_manifest()
        engine = engine_from_manifest(manifest, args.engine)
        status = store.read_status()
        active_exists = store.active_path.exists()
        intent_exists = store.cleanup_intent_path.exists()
        if not active_exists:
            if not intent_exists or status.get("phase") != "CLEANED" or not status.get("valid"):
                raise IntegrityError("cleanup has no matching active run or completed transaction")
            load_cleanup_intent(store, manifest, digest)
            remaining_containers, remaining_networks = inspect_cleanup_remainder(engine, manifest)
            if remaining_containers or remaining_networks:
                raise IntegrityError("completed cleanup status still has managed resources")
            print(json.dumps(status, sort_keys=True))
            return 0
        store.require_active(manifest["run_nonce"])
        if intent_exists:
            load_cleanup_intent(store, manifest, digest)
        else:
            if store.seal_proof_path.exists():
                validate_existing_seal_proof(store, manifest, digest, engine)
            else:
                inspect_container_identity(engine, manifest, "target", require_running=False)
                inspect_container_identity(engine, manifest, "base", require_running=False)
            inspect_exact_topology(engine, manifest)
            create_once(store.cleanup_intent_path, canonical_bytes(cleanup_intent_value(manifest, digest)), 0o400)
            append_audit(store.audit_path, {"event": "cleanup-intent", "manifest_sha256": digest})

        remaining_containers, remaining_networks = inspect_cleanup_remainder(engine, manifest)
        for role in ("target", "base"):
            object_id = manifest["objects"][role]["id"]
            if object_id in remaining_containers:
                engine.remove_container(object_id)
        remaining_containers, remaining_networks = inspect_cleanup_remainder(engine, manifest)
        if remaining_containers:
            raise SupervisorError("container cleanup could not be proven")
        network_id = manifest["objects"]["network"]["id"]
        if network_id in remaining_networks:
            engine.remove_network(network_id)
        remaining_containers, remaining_networks = inspect_cleanup_remainder(engine, manifest)
        if remaining_containers or remaining_networks:
            raise SupervisorError("resource cleanup could not be proven")
        status = store.write_status("CLEANED", valid=True, details={"resources_removed": True})
        store.clear_active(manifest["run_nonce"])
    print(json.dumps(status, sort_keys=True))
    return 0


def add_common(parser: argparse.ArgumentParser, *, engine: bool = True) -> None:
    parser.add_argument("--state-root", default=os.environ.get("CKA_SSH_SUPERVISOR_STATE_ROOT", "/var/lib/cka-practice/ssh-supervisor"))
    parser.add_argument("--run-id", required=True)
    if engine:
        parser.add_argument("--engine", default=os.environ.get("CKA_SSH_ENGINE", "docker"))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CKA designated-host SSH exam supervisor")
    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("preflight", help="validate protected native state without creating a run")
    preflight.add_argument("--state-root", default=os.environ.get("CKA_SSH_SUPERVISOR_STATE_ROOT", "/var/lib/cka-practice/ssh-supervisor"))
    preflight.set_defaults(function=command_preflight)

    prepare = subparsers.add_parser("prepare", help="create stopped objects and the immutable manifest")
    add_common(prepare)
    prepare.add_argument("--duration-seconds", required=True, type=int)
    prepare.add_argument("--base-image", default="cka-practice/ssh-base:v1")
    prepare.add_argument("--target-image", default="cka-practice/ssh-target:v1")
    prepare.add_argument("--engine-timeout-seconds", type=float, default=5.0)
    prepare.add_argument("--answer", action="append", default=[], metavar="QUESTION_ID:FILE_NAME")
    prepare.add_argument("--input-manifest", metavar="ABSOLUTE_PATH")
    prepare.add_argument("--external-network-id", metavar="FULL_NETWORK_ID")
    prepare.set_defaults(function=command_prepare)

    timer_ready = subparsers.add_parser("timer-ready", help="record proof that the independent deadline timer is active")
    add_common(timer_ready, engine=False)
    timer_ready.add_argument("--unit", required=True)
    timer_ready.add_argument("--systemctl", default=os.environ.get("CKA_SSH_SYSTEMCTL", "systemctl"))
    timer_ready.add_argument("--systemctl-scope", choices=["system", "user"], default="system")
    timer_ready.add_argument("--systemctl-timeout-seconds", type=float, default=3.0)
    timer_ready.set_defaults(function=command_timer_ready)

    guard_ready = subparsers.add_parser("guard-ready", help="verify the restartable guard readiness handshake")
    add_common(guard_ready, engine=False)
    guard_ready.add_argument("--unit", required=True)
    guard_ready.set_defaults(function=command_guard_ready)

    activate = subparsers.add_parser("activate", help="start exact manifest objects and provision candidate SSH")
    add_common(activate)
    activate.set_defaults(function=command_activate)

    seal = subparsers.add_parser("seal", help="idempotently stop target then base and create seal proof")
    add_common(seal)
    seal.add_argument("--reason", choices=["deadline", "manual", "operator", "activation-failure"], default="operator")
    seal.set_defaults(function=command_seal)

    recover = subparsers.add_parser("recover", help="fail-closed recovery after supervisor restart")
    add_common(recover)
    recover.set_defaults(function=command_recover)

    watch = subparsers.add_parser("watch", help="restartable fallback deadline watcher")
    add_common(watch)
    watch.add_argument("--unit", required=True)
    watch.add_argument("--poll-seconds", type=float, default=0.25)
    watch.set_defaults(function=command_watch)

    collect = subparsers.add_parser("collect", help="collect only immutable-manifest allowlisted answers after a valid seal")
    add_common(collect)
    collect.add_argument("--destination", required=True)
    collect.set_defaults(function=command_collect)

    authorize = subparsers.add_parser("authorize-grade", help="fail unless a valid seal proof authorizes host-only grading")
    add_common(authorize)
    authorize.set_defaults(function=command_authorize_grade)

    status = subparsers.add_parser("status", help="show protected run status")
    add_common(status, engine=False)
    status.set_defaults(function=command_status)

    candidate_entry = subparsers.add_parser("candidate-entry", help="return the exact base ID for a valid running session")
    add_common(candidate_entry)
    candidate_entry.set_defaults(function=command_candidate_entry)

    cleanup = subparsers.add_parser("cleanup", help="remove only exact manifest objects and preserve audit state")
    add_common(cleanup)
    cleanup.set_defaults(function=command_cleanup)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.function(args))
    except SupervisorError as exc:
        print(f"ssh-supervisor: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("ssh-supervisor: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
