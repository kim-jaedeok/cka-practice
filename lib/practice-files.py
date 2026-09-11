#!/usr/bin/env python3
"""Track root practice files; callers hold the infrastructure lifecycle lock."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def valid_qid(value):
    return isinstance(value, str) and re.fullmatch(r"(st|wl|sn|ca|ts)-[0-9]{2}", value)


def valid_name(value):
    return (isinstance(value, str) and bool(value) and not value.startswith(".")
            and not any(c in value for c in "/\\\0:"))


def redirected(info):
    return (stat.S_ISLNK(info.st_mode)
            or bool(getattr(info, "st_file_attributes", 0) & 0x400))


def directory(path, create=False):
    require(path.is_absolute() and path != Path(path.anchor), "unsafe root/state path")
    require(path.resolve() == path, "root/state must be canonical, without symlinks")
    for part in (*reversed(path.parents), path):
        try:
            info = part.lstat()
        except FileNotFoundError:
            if not create:
                raise
            part.mkdir()
            info = part.lstat()
        require(stat.S_ISDIR(info.st_mode) and not redirected(info), "unsafe directory ancestry")


def signature(root, name):
    require(valid_name(name) and (root / name).parent == root, "unsafe filename")
    try:
        info = (root / name).lstat()
    except FileNotFoundError:
        return None
    if (not stat.S_ISREG(info.st_mode) or redirected(info)
            or getattr(info, "st_file_attributes", 0) & 0x2):
        return None
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def git(root, *args):
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith("GIT_")}
    return subprocess.run(["git", "-C", str(root), *args], env=env, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def eligible(root):
    names = (os.fsdecode(n) for n in git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if n)
    return {n: value for n in names if valid_name(n) and (value := signature(root, n)) is not None}


def baseline(root):
    # Include tracked/ignored names too: becoming untracked is not creation.
    return sorted(p.name for p in root.iterdir() if valid_name(p.name))


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate journal key")
        result[key] = value
    return result


def validate(data, root):
    require(type(data) is dict and set(data) == {"version", "root", "active", "baseline", "owners"}, "invalid journal keys")
    require(type(data["version"]) is int and data["version"] == 1, "invalid journal version")
    require(data["root"] == str(root), "journal root mismatch")
    require(data["active"] is None or valid_qid(data["active"]), "invalid active question")
    names = data["baseline"]
    require(type(names) is list and all(valid_name(n) for n in names), "invalid baseline")
    require(len(names) == len(set(names)), "duplicate baseline")
    require(type(data["owners"]) is dict, "invalid owners")
    for name, owner in data["owners"].items():
        require(valid_name(name) and type(owner) is dict and set(owner) == {"qid", "signature", "pending"}, "invalid owner")
        require(valid_qid(owner["qid"]) and type(owner["pending"]) is bool, "invalid owner state")
        sig = owner["signature"]
        require(type(sig) is list and len(sig) == 5 and all(type(v) is int for v in sig), "invalid file signature")


def check_journal(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    require(stat.S_ISREG(info.st_mode) and not redirected(info), "unsafe journal file")
    return True


def save(root, state, data):
    validate(data, root)
    directory(root)
    directory(state)
    journal = state / "practice-files.json"
    check_journal(journal)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=state,
                                         prefix=".practice-files-", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(data, stream, ensure_ascii=True, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        check_journal(journal)
        os.replace(temporary, journal)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def checkpoint(data, files):
    owners, active, released = data["owners"], data["active"], set()
    for name, owner in list(owners.items()):
        changed = files.get(name) != owner["signature"]
        if name not in files or (changed and (owner["pending"] or active != owner["qid"])):
            del owners[name]
            released.add(name)
        elif changed:
            owner["signature"] = files[name]
    if active is not None:
        for name in files.keys() - set(data["baseline"]) - released - owners.keys():
            owners[name] = {"qid": active, "signature": files[name], "pending": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("action", choices=("pause", "start", "cleanup", "cleanup-all", "adopt"))
    parser.add_argument("qid", nargs="?")
    parser.add_argument("filenames", nargs="*")
    args = parser.parse_args(argv)
    if args.action in ("cleanup-all", "pause"):
        require(args.qid is None and not args.filenames, "unexpected question or filenames")
    else:
        require(valid_qid(args.qid), "invalid question")
        require(bool(args.filenames) if args.action == "adopt" else not args.filenames, "invalid filenames for action")
    require(all(valid_name(n) for n in args.filenames), "invalid filename")
    root, state = Path(args.root), Path(args.state)
    directory(root)
    require(Path(os.fsdecode(git(root, "rev-parse", "--show-toplevel")).rstrip("\r\n")).resolve() == root, "root is not the Git top-level")
    directory(state, create=True)
    journal = state / "practice-files.json"
    if check_journal(journal):
        data = json.loads(journal.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    else:
        if args.action in ("cleanup", "cleanup-all"):
            return
        data = {"version": 1, "root": str(root), "active": None,
                "baseline": baseline(root), "owners": {}}
    validate(data, root)
    files = eligible(root)
    checkpoint(data, files)
    owners = data["owners"]
    if args.action == "adopt":
        for name in args.filenames:
            require(name in files and (name not in owners or owners[name]["qid"] == args.qid), "cannot adopt file: " + name)
        for name in args.filenames:
            owners[name] = {"qid": args.qid, "signature": files[name], "pending": False}
    elif args.action == "pause":
        data["active"] = None
    else:
        for owner in owners.values():
            if args.action == "cleanup-all" or owner["qid"] == args.qid:
                owner["pending"] = True
        if args.action in ("start", "cleanup-all") or data["active"] == args.qid:
            data["active"] = None
    data["baseline"] = baseline(root)
    # Persist deletion intent and the exact observed file before unlinking.
    save(root, state, data)
    if args.action in ("pause", "adopt"):
        return
    for name, owner in list(owners.items()):
        if not owner["pending"]:
            continue
        directory(root)
        target = root / name
        require(target.parent == root, "deletion target escaped repository")
        if eligible(root).get(name) == owner["signature"] and signature(root, name) == owner["signature"]:
            target.unlink()
            print("연습 파일 삭제: " + name)
        # Missing, replaced, linked, tracked, or ignored files lose ownership.
        del owners[name]
        save(root, state, data)
    if args.action == "start":
        data["active"] = args.qid
    data["baseline"] = baseline(root)
    save(root, state, data)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"practice-files: {error}", file=sys.stderr)
        sys.exit(1)
