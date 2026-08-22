#!/usr/bin/env python3
"""Small persistent fake Docker CLI used by SSH supervisor fault tests."""

from __future__ import annotations

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
    lock_path = DB.with_suffix(DB.suffix + ".lock")
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if DB.exists():
            value = json.loads(DB.read_bytes())
        else:
            value = {"counter": 0, "containers": {}, "networks": {}, "log": []}
        try:
            yield value
        finally:
            temporary = DB.with_suffix(DB.suffix + f".{os.getpid()}.tmp")
            temporary.write_bytes(canonical(value))
            os.replace(temporary, DB)
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def new_id(db: dict[str, Any], kind: str) -> str:
    db["counter"] += 1
    return hashlib.sha256(f"{kind}:{db['counter']}".encode()).hexdigest()


def image_id(reference: str) -> str:
    return "sha256:" + hashlib.sha256(("image:" + reference).encode()).hexdigest()


def parse_options(arguments: list[str], flags: set[str]) -> tuple[dict[str, list[str]], list[str]]:
    options: dict[str, list[str]] = {}
    positional: list[str] = []
    index = 0
    while index < len(arguments):
        token = arguments[index]
        if token in flags:
            options.setdefault(token, []).append("true")
            index += 1
        elif token.startswith("--"):
            if index + 1 >= len(arguments):
                raise ValueError(f"missing option value: {token}")
            options.setdefault(token, []).append(arguments[index + 1])
            index += 2
        else:
            positional.append(token)
            index += 1
    return options, positional


def labels_from(options: dict[str, list[str]]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in options.get("--label", []):
        key, separator, item = value.partition("=")
        if not separator:
            raise ValueError("invalid label")
        result[key] = item
    return result


def filtered(records: dict[str, Any], filters: list[str]) -> list[str]:
    required = {}
    for value in filters:
        if value.startswith("label="):
            key, _, item = value[6:].partition("=")
            required[key] = item
    result = []
    for object_id, record in records.items():
        labels = record.get("Labels") or (record.get("Config") or {}).get("Labels") or {}
        if all(labels.get(key) == value for key, value in required.items()):
            result.append(object_id)
    return sorted(result)


def emit_json(value: Any) -> None:
    sys.stdout.buffer.write(canonical(value))


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def main() -> int:
    arguments = sys.argv[1:]
    command_text = " ".join(arguments)
    fail_match = os.environ.get("FAKE_ENGINE_FAIL_MATCH", "")
    if fail_match and fail_match in command_text:
        fail("injected engine command failure")
    hang_match = os.environ.get("FAKE_ENGINE_HANG_MATCH", "")
    if hang_match and hang_match in command_text:
        time.sleep(float(os.environ.get("FAKE_ENGINE_HANG_SECONDS", "60")))

    # timer-ready uses the same executable as a fake systemctl.
    if arguments[:2] == ["is-active", "--quiet"] and len(arguments) == 3:
        return 0

    with database() as db:
        db["log"].append({"argv": arguments, "at": time.time()})
        if arguments[:2] == ["image", "inspect"] and len(arguments) == 3:
            reference = arguments[2]
            if "target" in reference:
                role = "target"
            elif "base" in reference:
                role = "base"
            else:
                fail("unknown fake image")
            emit_json([{"Id": image_id(reference), "Config": {"Labels": {"org.cka-practice.ssh-image-role": role}}}])
            return 0

        if arguments[:2] == ["network", "create"]:
            options, positional = parse_options(arguments[2:], {"--internal"})
            if len(positional) != 1:
                fail("network create needs a name")
            object_id = new_id(db, "network")
            db["networks"][object_id] = {
                "Id": object_id,
                "Name": positional[0],
                "Internal": "--internal" in options,
                "Labels": labels_from(options),
                "Containers": {},
            }
            if os.environ.get("FAKE_ENGINE_POST_CREATE_FAIL_KIND") == "network":
                print("injected failure after network creation", file=sys.stderr)
                return 75
            print(object_id)
            return 0

        if arguments[:2] == ["network", "inspect"] and len(arguments) == 3:
            record = db["networks"].get(arguments[2])
            if record is None:
                fail("no such network")
            emit_json([record])
            return 0

        if arguments[:2] == ["network", "ls"]:
            options, positional = parse_options(arguments[2:], {"--quiet", "--no-trunc"})
            if positional:
                fail("unexpected network ls argument")
            print("\n".join(filtered(db["networks"], options.get("--filter", []))))
            return 0

        if arguments[:2] == ["network", "rm"] and len(arguments) == 3:
            if db["networks"].pop(arguments[2], None) is None:
                fail("no such network")
            print(arguments[2])
            return 0

        if arguments[:2] in (["network", "connect"], ["network", "disconnect"]):
            network_id, object_id = arguments[-2:]
            network = db["networks"].get(network_id)
            record = db["containers"].get(object_id)
            if network is None or record is None:
                fail("unknown attachment object")
            name = network["Name"]
            if arguments[1] == "connect":
                record["AttachedNetworks"][name] = network_id
                record["NetworkSettings"]["Networks"][name] = {
                    "NetworkID": network_id if record["State"]["Running"] else "",
                    "IPAddress": record["FakeIPAddress"] if record["State"]["Running"] else "",
                }
                if record["State"]["Running"]:
                    network["Containers"][object_id] = {}
            else:
                record["AttachedNetworks"].pop(name, None)
                record["NetworkSettings"]["Networks"].pop(name, None)
                network["Containers"].pop(object_id, None)
            return 0

        if arguments[:2] == ["container", "create"]:
            options, positional = parse_options(arguments[2:], {"--interactive", "--tty"})
            if len(positional) != 1:
                fail("container create needs exactly one image")
            reference = positional[0]
            network_values = options.get("--network", [])
            if len(network_values) != 1 or network_values[0] not in db["networks"]:
                fail("unknown network")
            object_id = new_id(db, "container")
            network = db["networks"][network_values[0]]
            db["containers"][object_id] = {
                "Id": object_id,
                "Name": options.get("--name", [""])[-1],
                "Image": image_id(reference),
                "Config": {"Labels": labels_from(options)},
                "HostConfig": {"Binds": [], "NetworkMode": network_values[0]},
                "Mounts": [],
                "State": {"Running": False},
                "NetworkSettings": {"Networks": {network["Name"]: {"NetworkID": "", "IPAddress": ""}}},
                "AttachedNetworks": {network["Name"]: network_values[0]},
                "FakeIPAddress": f"172.30.0.{10 + db['counter']}",
                "Files": {},
            }
            role = db["containers"][object_id]["Config"]["Labels"].get(
                "org.cka-practice.ssh-supervisor.role"
            )
            if os.environ.get("FAKE_ENGINE_POST_CREATE_FAIL_KIND") == role:
                print(f"injected failure after {role} creation", file=sys.stderr)
                return 75
            print(object_id)
            return 0

        if arguments[:2] == ["container", "inspect"] and len(arguments) == 3:
            record = db["containers"].get(arguments[2])
            if record is None:
                fail("no such container")
            emit_json([{key: value for key, value in record.items() if key not in {"Files", "AttachedNetworks", "FakeIPAddress"}}])
            return 0

        if arguments[:2] == ["container", "ls"]:
            options, positional = parse_options(arguments[2:], {"--all", "--quiet", "--no-trunc"})
            if positional:
                fail("unexpected container ls argument")
            print("\n".join(filtered(db["containers"], options.get("--filter", []))))
            return 0

        if arguments[:2] in (["container", "start"], ["container", "stop"], ["container", "kill"]):
            operation = arguments[1]
            object_id = arguments[-1]
            record = db["containers"].get(object_id)
            if record is None:
                fail("no such container")
            running = operation == "start"
            record["State"]["Running"] = running
            for name, network_id in record["AttachedNetworks"].items():
                record["NetworkSettings"]["Networks"][name]["NetworkID"] = network_id if running else ""
                record["NetworkSettings"]["Networks"][name]["IPAddress"] = record["FakeIPAddress"] if running else ""
                if running:
                    db["networks"][network_id]["Containers"][object_id] = {}
                else:
                    db["networks"][network_id]["Containers"].pop(object_id, None)
            print(object_id)
            return 0

        if arguments[:2] == ["container", "rm"] and len(arguments) == 3:
            if db["containers"].pop(arguments[2], None) is None:
                fail("no such container")
            for network in db["networks"].values():
                network["Containers"].pop(arguments[2], None)
            print(arguments[2])
            return 0

        if arguments[:2] == ["container", "rename"] and len(arguments) == 4:
            record = db["containers"].get(arguments[2])
            if record is None:
                fail("no such container")
            record["Name"] = arguments[3]
            return 0

        if arguments[:2] == ["container", "exec"]:
            options, positional = parse_options(arguments[2:], {"--interactive"})
            if not positional:
                fail("exec is missing container id")
            object_id, command = positional[0], positional[1:]
            record = db["containers"].get(object_id)
            if record is None or not record["State"]["Running"]:
                fail("container is not running")
            if command[:1] == ["cat"] and command[1:] == ["/home/candidate/.ssh/id_ed25519.pub"]:
                print("ssh-ed25519 " + "A" * 64 + " fake@base")
            elif command[:1] == ["ssh"]:
                sys.stdout.write("CKA_SSH_OK")
            return 0

        if arguments[:2] == ["container", "cp"] and len(arguments) == 4:
            source, destination = arguments[2], arguments[3]
            if destination != "-" or ":" not in source:
                fail("unsupported cp")
            object_id, path = source.split(":", 1)
            record = db["containers"].get(object_id)
            if record is None:
                fail("no such container")
            flood_bytes = int(os.environ.get("FAKE_ENGINE_CP_FLOOD_BYTES", "0"))
            if flood_bytes > 0:
                chunk = b"X" * (64 * 1024)
                descriptor = sys.stdout.fileno()
                remaining = flood_bytes
                while remaining:
                    value = chunk[: min(len(chunk), remaining)]
                    os.write(descriptor, value)
                    remaining -= len(value)
                return 0
            if path not in record["Files"]:
                fail("could not find the file")
            value = record["Files"][path].encode()
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode="w") as archive:
                member = tarfile.TarInfo(Path(path).name)
                member.size = len(value)
                archive.addfile(member, io.BytesIO(value))
            sys.stdout.buffer.write(stream.getvalue())
            return 0

        if arguments[:2] == ["debug", "mutate-label"] and len(arguments) == 5:
            record = db["containers"].get(arguments[2])
            if record is None:
                fail("no such container")
            record["Config"]["Labels"][arguments[3]] = arguments[4]
            return 0

        if arguments[:2] == ["debug", "put-file"] and len(arguments) == 5:
            record = db["containers"].get(arguments[2])
            if record is None:
                fail("no such container")
            record["Files"][arguments[3]] = arguments[4]
            return 0

        fail("unsupported fake engine command: " + command_text)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
