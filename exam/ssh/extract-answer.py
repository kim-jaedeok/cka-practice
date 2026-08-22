#!/usr/bin/env python3
"""Extract one bounded regular file from a docker-cp tar stream."""

from __future__ import annotations

import argparse
import os
import sys
import tarfile

MAX_BYTES = 8 * 1024 * 1024
EMPTY_ARCHIVE = 20
UNSAFE_ARCHIVE = 21


def fail(message: str, code: int = UNSAFE_ARCHIVE) -> "NoReturn":
    print(f"answer extraction: {message}", file=sys.stderr)
    raise SystemExit(code)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if args.name in {"", ".", ".."} or "/" in args.name or "\\" in args.name:
        fail("unsafe expected basename")
    output = os.path.abspath(args.output)
    parent = os.path.dirname(output)
    if not os.path.isdir(parent) or os.path.islink(parent):
        fail("output parent must be a real directory")
    if os.path.lexists(output):
        fail("output already exists")

    seen = False
    try:
        archive = tarfile.open(fileobj=sys.stdin.buffer, mode="r|*")
        for member in archive:
            normalized = member.name
            while normalized.startswith("./"):
                normalized = normalized[2:]
            if normalized in {"", "."} and member.isdir():
                continue
            if seen or normalized != args.name:
                fail(f"unexpected archive member: {member.name!r}")
            if not member.isreg() or member.issym() or member.islnk():
                fail("answer is not an ordinary file")
            if member.size < 0 or member.size > MAX_BYTES:
                fail(f"answer exceeds {MAX_BYTES} bytes")
            source = archive.extractfile(member)
            if source is None:
                fail("regular-file payload is missing")
            temp = f"{output}.tmp.{os.getpid()}"
            try:
                with open(temp, "xb") as destination:
                    remaining = member.size
                    while remaining:
                        chunk = source.read(min(1024 * 1024, remaining))
                        if not chunk:
                            fail("truncated answer payload")
                        destination.write(chunk)
                        remaining -= len(chunk)
                    if source.read(1):
                        fail("answer payload exceeded its header size")
                    destination.flush()
                    os.fsync(destination.fileno())
                os.chmod(temp, 0o600)
                os.replace(temp, output)
            finally:
                try:
                    os.unlink(temp)
                except FileNotFoundError:
                    pass
            seen = True
    except tarfile.ReadError:
        return EMPTY_ARCHIVE

    if not seen:
        return EMPTY_ARCHIVE
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
