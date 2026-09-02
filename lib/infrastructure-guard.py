#!/usr/bin/env python3
"""Run one infrastructure mutation under a signal-safe host lock."""

from __future__ import annotations

import errno
import fcntl
import os
import signal
import stat
import subprocess
import sys
import time


def fail(message: str, status: int = 1) -> int:
    print(f"[fail] {message}", file=sys.stderr)
    return status


def process_group_has_live_members(process_group: int) -> bool:
    """Return whether a Linux process group still has a non-zombie member."""
    try:
        proc_entries = os.scandir("/proc")
    except OSError:
        # The public wrapper already relies on /proc for parent verification.
        # If it unexpectedly becomes unreadable, retain the lock conservatively.
        return True
    with proc_entries:
        for entry in proc_entries:
            if not entry.name.isdecimal():
                continue
            try:
                with open(f"/proc/{entry.name}/stat", encoding="ascii") as stat_file:
                    record = stat_file.read()
                closing = record.rfind(") ")
                if closing < 0:
                    continue
                fields = record[closing + 2 :].split()
                # Fields after comm begin with state, ppid, pgrp.
                if len(fields) >= 3 and int(fields[2]) == process_group:
                    if fields[0] != "Z":
                        return True
            except (FileNotFoundError, PermissionError, OSError, ValueError):
                # Processes can disappear between /proc enumeration and read.
                continue
    return False


def main(argv: list[str]) -> int:
    if len(argv) < 6 or argv[4] != "--":
        return fail("infrastructure guard arguments are invalid", 2)
    mode, wait_text, conflict_text, lock_path = argv[:4]
    command = argv[5:]
    if mode not in {"wait", "nowait"} or not command:
        return fail("infrastructure guard mode or command is invalid", 2)
    try:
        wait_seconds = int(wait_text)
        conflict_status = int(conflict_text)
    except ValueError:
        return fail("infrastructure guard timeout/status is invalid", 2)
    if wait_seconds < 1 or conflict_status < 1 or conflict_status > 255:
        return fail("infrastructure guard timeout/status is out of range", 2)

    flags = os.O_RDWR | os.O_CREAT
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        lock_fd = os.open(lock_path, flags, 0o600)
    except OSError as exc:
        return fail(f"infrastructure lock open failed: {exc}")
    try:
        os.set_inheritable(lock_fd, False)
        lock_stat = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_stat.st_mode):
            return fail("infrastructure lock is not a regular file")
        if lock_stat.st_uid != os.getuid():
            return fail("infrastructure lock owner differs from the current user")
        if lock_stat.st_nlink != 1:
            return fail("infrastructure lock link count is not 1")
        if stat.S_IMODE(lock_stat.st_mode) != 0o600:
            try:
                os.fchmod(lock_fd, 0o600)
            except OSError as exc:
                return fail(f"infrastructure lock mode repair failed: {exc}")
            lock_stat = os.fstat(lock_fd)
            if lock_stat.st_nlink != 1 or stat.S_IMODE(lock_stat.st_mode) != 0o600:
                return fail("infrastructure lock identity changed during mode repair")

        deadline = time.monotonic() + wait_seconds
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as exc:
                if exc.errno not in {errno.EACCES, errno.EAGAIN}:
                    return fail(f"infrastructure lock acquisition failed: {exc}")
                if mode == "nowait" or time.monotonic() >= deadline:
                    return fail(
                        f"다른 infrastructure 변경이 진행 중입니다 (exit {conflict_status}).",
                        conflict_status,
                    )
                time.sleep(0.05)

        child: subprocess.Popen[bytes] | None = None
        received_signal = 0
        escalation_deadline: float | None = None

        def forward(signum: int, _frame: object) -> None:
            nonlocal received_signal, escalation_deadline
            if received_signal == 0:
                received_signal = signum
                escalation_deadline = time.monotonic() + 5.0
                forwarded = signum
            else:
                forwarded = signal.SIGKILL
                escalation_deadline = time.monotonic()
            if child is not None:
                try:
                    os.killpg(child.pid, forwarded)
                except ProcessLookupError:
                    pass

        previous_handlers = {
            signum: signal.signal(signum, forward)
            for signum in (
                signal.SIGHUP,
                signal.SIGINT,
                signal.SIGQUIT,
                signal.SIGTERM,
            )
        }
        try:
            # Do not start a mutation if termination arrived after handler
            # installation but before process creation.
            if received_signal:
                return 128 + received_signal
            child_env = os.environ.copy()
            child_env["CKA_INFRA_GATE_ACTIVE"] = "1"
            child_env["CKA_INFRA_GATE_PARENT_PID"] = str(os.getpid())
            child = subprocess.Popen(
                command,
                env=child_env,
                start_new_session=True,
                close_fds=True,
            )
            # Close the remaining check-to-Popen race: a signal handled while
            # Popen was constructing the child must be forwarded immediately.
            if received_signal:
                try:
                    os.killpg(child.pid, received_signal)
                except ProcessLookupError:
                    pass
            while True:
                try:
                    child_status = child.wait(timeout=0.1)
                    break
                except subprocess.TimeoutExpired:
                    if (
                        received_signal
                        and escalation_deadline is not None
                        and time.monotonic() >= escalation_deadline
                    ):
                        try:
                            os.killpg(child.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        child_status = child.wait()
                        break

            if received_signal:
                # The command leader may exit before its background children.
                # Keep the lock until every member is gone or non-executable
                # (a zombie waiting for its external parent to reap it).
                group_deadline = time.monotonic() + 5.0
                group_killed = False
                while process_group_has_live_members(child.pid):
                    effective_deadline = group_deadline
                    if escalation_deadline is not None:
                        effective_deadline = min(effective_deadline, escalation_deadline)
                    if not group_killed and time.monotonic() >= effective_deadline:
                        try:
                            os.killpg(child.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        group_killed = True
                    time.sleep(0.05)
                return 128 + received_signal
            if child_status < 0:
                return 128 - child_status
            return child_status
        except OSError as exc:
            return fail(f"infrastructure command launch failed: {exc}")
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
    finally:
        os.close(lock_fd)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
