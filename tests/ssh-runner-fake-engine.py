#!/usr/bin/env python3
"""Persistent fake Docker CLI for supervised-form input/network fault tests."""
from __future__ import annotations

import base64
import fcntl
import hashlib
import io
import json
import os
import sys
import tarfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator


DB = Path(os.environ.get("FAKE_ENGINE_DB", ""))
if not DB.is_absolute():
    print("FAKE_ENGINE_DB must be absolute", file=sys.stderr)
    raise SystemExit(90)


def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


@contextmanager
def database() -> Iterator[dict[str, Any]]:
    DB.parent.mkdir(parents=True, exist_ok=True)
    with DB.with_suffix(".lock").open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        value = json.loads(DB.read_text()) if DB.exists() else {"counter": 0, "containers": {}, "networks": {}, "log": []}
        try:
            yield value
        finally:
            temporary = DB.with_suffix(f".{os.getpid()}.tmp")
            temporary.write_bytes(canonical(value))
            os.replace(temporary, DB)


def new_id(db: dict[str, Any], kind: str) -> str:
    db["counter"] += 1
    return hashlib.sha256(f"{kind}:{db['counter']}".encode()).hexdigest()


def image_id(reference: str) -> str:
    return "sha256:" + hashlib.sha256(("image:" + reference).encode()).hexdigest()


def options(arguments: list[str], flags: set[str] = set()) -> tuple[dict[str, list[str]], list[str]]:
    parsed: dict[str, list[str]] = {}
    positional: list[str] = []
    index = 0
    while index < len(arguments):
        token = arguments[index]
        if token in flags:
            parsed.setdefault(token, []).append("true"); index += 1
        elif token.startswith("--"):
            if index + 1 >= len(arguments):
                fail(f"missing option value: {token}")
            parsed.setdefault(token, []).append(arguments[index + 1]); index += 2
        else:
            positional.append(token); index += 1
    return parsed, positional


def labels(parsed: dict[str, list[str]]) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry in parsed.get("--label", []):
        key, separator, value = entry.partition("=")
        if not separator: fail("invalid label")
        result[key] = value
    return result


def emit(value: Any) -> None:
    sys.stdout.buffer.write(canonical(value))


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def filtered(records: dict[str, Any], filters: list[str]) -> list[str]:
    wanted: dict[str, str] = {}
    for entry in filters:
        if entry.startswith("label="):
            key, _, value = entry[6:].partition("="); wanted[key] = value
    result = []
    for object_id, record in records.items():
        actual = record.get("Labels") or (record.get("Config") or {}).get("Labels") or {}
        if all(actual.get(key) == value for key, value in wanted.items()): result.append(object_id)
    return sorted(result)


def decode_files(record: dict[str, Any]) -> dict[str, bytes]:
    return {path: base64.b64decode(value) for path, value in record.get("Files", {}).items()}


def encode_file(record: dict[str, Any], path: str, value: bytes) -> None:
    record.setdefault("Files", {})[path] = base64.b64encode(value).decode()


def main() -> int:
    args = sys.argv[1:]
    delay_match = os.environ.get("FAKE_ENGINE_DELAY_MATCH", "")
    if delay_match and delay_match in " ".join(args):
        time.sleep(float(os.environ.get("FAKE_ENGINE_DELAY_SECONDS", "1")))
    if args[:2] == ["--user", "is-active"]:
        return 0
    if args[:2] == ["is-active", "--quiet"]:
        return 0
    with database() as db:
        db["log"].append({"argv": args, "at": time.time()})
        if args[:2] == ["image", "inspect"] and len(args) == 3:
            reference = args[2]
            role = "target" if "target" in reference else "base" if "base" in reference else ""
            if not role: fail("unknown image")
            emit([{"Id": image_id(reference), "Config": {"Labels": {"org.cka-practice.ssh-image-role": role}}}]); return 0

        if args[:2] == ["network", "create"]:
            parsed, positional = options(args[2:], {"--internal"})
            if len(positional) != 1: fail("network name required")
            object_id = new_id(db, "network")
            db["networks"][object_id] = {"Id": object_id, "Name": positional[0], "Driver": parsed.get("--driver", ["bridge"])[-1],
                                                  "Internal": "--internal" in parsed, "Labels": labels(parsed), "Containers": {}}
            print(object_id); return 0
        if args[:2] == ["network", "inspect"] and len(args) == 3:
            record = db["networks"].get(args[2])
            if not record: fail("no such network")
            emit([record]); return 0
        if args[:2] == ["network", "ls"]:
            parsed, positional = options(args[2:], {"--quiet", "--no-trunc"})
            if positional: fail("unexpected network ls positional")
            print("\n".join(filtered(db["networks"], parsed.get("--filter", [])))); return 0
        if args[:2] == ["network", "rm"] and len(args) == 3:
            if db["networks"].pop(args[2], None) is None: fail("no such network")
            print(args[2]); return 0
        if args[:2] in (["network", "connect"], ["network", "disconnect"]):
            network_id, container_id = args[-2:]
            network = db["networks"].get(network_id); container = db["containers"].get(container_id)
            if not network or not container: fail("unknown attachment object")
            attached = container["NetworkSettings"]["Networks"]
            if args[1] == "connect":
                container["AttachedNetworks"][network["Name"]] = network_id
                attached[network["Name"]] = {
                    "NetworkID": network_id if container["State"]["Running"] else "",
                    "IPAddress": container["FakeIPAddress"] if container["State"]["Running"] else "",
                }
                if container["State"]["Running"]:
                    network["Containers"][container_id] = {}
            else:
                container["AttachedNetworks"].pop(network["Name"], None)
                attached.pop(network["Name"], None)
                network["Containers"].pop(container_id, None)
            return 0

        if args[:2] == ["container", "create"]:
            parsed, positional = options(args[2:], {"--interactive", "--tty"})
            if len(positional) != 1: fail("one image required")
            network_id = parsed.get("--network", [""])[-1]; network = db["networks"].get(network_id)
            if not network: fail("unknown network")
            object_id = new_id(db, "container")
            db["containers"][object_id] = {
                "Id": object_id, "Name": parsed.get("--name", [""])[-1], "Image": image_id(positional[0]),
                "Config": {"Labels": labels(parsed)}, "HostConfig": {"Binds": [], "NetworkMode": network_id}, "Mounts": [],
                "State": {"Running": False},
                "NetworkSettings": {"Networks": {network["Name"]: {"NetworkID": "", "IPAddress": ""}}},
                "AttachedNetworks": {network["Name"]: network_id},
                "FakeIPAddress": f"172.30.0.{10 + db['counter']}", "Files": {}}
            print(object_id); return 0
        if args[:2] == ["container", "inspect"] and len(args) == 3:
            record = db["containers"].get(args[2])
            if not record: fail("no such container")
            emit([{key: value for key, value in record.items() if key not in {"Files", "AttachedNetworks", "FakeIPAddress"}}]); return 0
        if args[:2] == ["container", "ls"]:
            parsed, positional = options(args[2:], {"--all", "--quiet", "--no-trunc"})
            if positional: fail("unexpected container ls positional")
            print("\n".join(filtered(db["containers"], parsed.get("--filter", [])))); return 0
        if args[:2] in (["container", "start"], ["container", "stop"], ["container", "kill"]):
            record = db["containers"].get(args[-1])
            if not record: fail("no such container")
            running = args[1] == "start"
            record["State"]["Running"] = running
            for name, network_id in record["AttachedNetworks"].items():
                record["NetworkSettings"]["Networks"][name]["NetworkID"] = network_id if running else ""
                record["NetworkSettings"]["Networks"][name]["IPAddress"] = record["FakeIPAddress"] if running else ""
                if running:
                    db["networks"][network_id]["Containers"][args[-1]] = {}
                else:
                    db["networks"][network_id]["Containers"].pop(args[-1], None)
            print(args[-1]); return 0
        if args[:2] == ["container", "rm"] and len(args) == 3:
            if db["containers"].pop(args[2], None) is None: fail("no such container")
            for network in db["networks"].values(): network["Containers"].pop(args[2], None)
            print(args[2]); return 0

        if args[:2] == ["container", "cp"] and len(args) == 4:
            source, destination = args[2:]
            if source == "-" and destination.endswith(":/"):
                container_id = destination[:-2]; record = db["containers"].get(container_id)
                if not record: fail("no such container")
                data = sys.stdin.buffer.read()
                with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
                    for member in archive.getmembers():
                        if member.isfile():
                            handle = archive.extractfile(member)
                            encode_file(record, "/" + member.name.lstrip("/"), handle.read() if handle else b"")
                return 0
            if destination == "-" and ":" in source:
                container_id, path = source.split(":", 1); record = db["containers"].get(container_id)
                if not record or path not in decode_files(record): fail("could not find the file")
                value = decode_files(record)[path]; stream = io.BytesIO()
                with tarfile.open(fileobj=stream, mode="w") as archive:
                    member = tarfile.TarInfo(Path(path).name); member.size = len(value); archive.addfile(member, io.BytesIO(value))
                sys.stdout.buffer.write(stream.getvalue()); return 0
            fail("unsupported cp")

        if args[:2] == ["container", "exec"]:
            parsed, positional = options(args[2:], {"--interactive"})
            if not positional: fail("missing container id")
            record = db["containers"].get(positional[0]); command = positional[1:]
            if not record or not record["State"]["Running"]: fail("container is not running")
            input_bytes = sys.stdin.buffer.read() if "--interactive" in parsed else b""
            if command[:1] == ["cat"] and command[1:] == ["/home/candidate/.ssh/id_ed25519.pub"]:
                print("ssh-ed25519 " + "A" * 64 + " fake@base")
            elif command[:1] == ["ssh"]:
                sys.stdout.write("CKA_SSH_OK")
            elif command[:1] == ["sha256sum"]:
                files = decode_files(record)
                for line in input_bytes.decode("ascii").splitlines():
                    digest, path = line.split("  ", 1)
                    if path not in files or hashlib.sha256(files[path]).hexdigest() != digest: fail("checksum mismatch")
            return 0

        if args[:2] == ["debug", "put-file"] and len(args) == 5:
            record = db["containers"].get(args[2])
            if not record: fail("no such container")
            encode_file(record, args[3], args[4].encode()); return 0
        if args[:2] == ["debug", "mutate-label"] and len(args) == 5:
            record = db["containers"].get(args[2])
            if not record: fail("no such container")
            record["Config"]["Labels"][args[3]] = args[4]; return 0
        fail("unsupported fake command: " + " ".join(args))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
