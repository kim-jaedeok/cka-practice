#!/usr/bin/env python3
"""Fail-closed verifier for Docker/OCI image archives used by controller cells.

The archive SHA written next to a locally generated cache is useful for
detecting accidental truncation, but it is not a trust root: an attacker able
to replace the archive can replace that adjacent checksum as well.  This
verifier instead binds every named image in the archive to the repository,
platform-manifest digest, and image-config digest committed in assets.lock.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys
import tarfile
from dataclasses import dataclass


SHA256 = re.compile(r"^sha256:([0-9a-f]{64})$")
MAX_JSON_BYTES = 16 * 1024 * 1024


class VerificationError(RuntimeError):
    pass


@dataclass(frozen=True)
class ExpectedImage:
    tag: str
    manifest_digest: str
    config_digest: str


def canonical_tag(reference: str) -> str:
    """Return Docker's canonical registry/name:tag spelling."""
    if "@" in reference:
        reference = reference.split("@", 1)[0]
    slash = reference.rfind("/")
    colon = reference.rfind(":")
    if colon <= slash:
        reference += ":latest"
    name, tag = reference.rsplit(":", 1)
    first = name.split("/", 1)[0]
    if "." not in first and ":" not in first and first != "localhost":
        name = f"docker.io/{name}" if "/" in name else f"docker.io/library/{name}"
    return f"{name}:{tag}"


def digest_hex(value: str, what: str) -> str:
    match = SHA256.fullmatch(value)
    if not match:
        raise VerificationError(f"invalid {what}: {value!r}")
    return match.group(1)


class Archive:
    def __init__(self, path: pathlib.Path):
        self.path = path
        self.tar = tarfile.open(path, mode="r:*")
        self.members: dict[str, tarfile.TarInfo] = {}
        self.consumed: set[str] = set()
        try:
            for member in self.tar:
                pure = pathlib.PurePosixPath(member.name)
                if (
                    pure.is_absolute()
                    or ".." in pure.parts
                    or str(pure) != member.name
                ):
                    raise VerificationError(f"unsafe archive member: {member.name!r}")
                if member.name in self.members:
                    raise VerificationError(f"duplicate archive member: {member.name!r}")
                if member.isdir():
                    if member.name not in {"blobs", "blobs/sha256"}:
                        raise VerificationError(
                            f"unexpected archive directory: {member.name!r}"
                        )
                elif not member.isfile():
                    # A loader must never get a symlink, hardlink, device or
                    # FIFO that the content-closure check does not account for.
                    raise VerificationError(
                        f"unsupported archive member type: {member.name!r}"
                    )
                self.members[member.name] = member
        except BaseException:
            self.tar.close()
            raise

    def close(self) -> None:
        self.tar.close()

    def _regular(self, name: str) -> tarfile.TarInfo:
        member = self.members.get(name)
        if member is None or not member.isfile() or member.issym() or member.islnk():
            raise VerificationError(f"missing or non-regular archive member: {name}")
        return member

    def read(self, name: str, *, maximum: int = MAX_JSON_BYTES) -> bytes:
        member = self._regular(name)
        if member.size > maximum:
            raise VerificationError(f"archive metadata member is too large: {name}")
        handle = self.tar.extractfile(member)
        if handle is None:
            raise VerificationError(f"cannot read archive member: {name}")
        data = handle.read(maximum + 1)
        if len(data) != member.size or len(data) > maximum:
            raise VerificationError(f"truncated or oversized archive member: {name}")
        self.consumed.add(name)
        return data

    def json(self, name: str) -> object:
        try:
            return json.loads(self.read(name))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise VerificationError(f"invalid JSON member: {name}") from exc

    def verify_blob(self, digest: str, size: int | None = None) -> bytes:
        hex_digest = digest_hex(digest, "blob digest")
        name = f"blobs/sha256/{hex_digest}"
        member = self._regular(name)
        if size is not None and member.size != size:
            raise VerificationError(f"blob size mismatch: {name}")
        handle = self.tar.extractfile(member)
        if handle is None:
            raise VerificationError(f"cannot read blob: {name}")
        hasher = hashlib.sha256()
        chunks: list[bytes] = []
        capture = member.size <= MAX_JSON_BYTES
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
            if capture:
                chunks.append(chunk)
        if hasher.hexdigest() != hex_digest:
            raise VerificationError(f"blob checksum mismatch: {name}")
        self.consumed.add(name)
        return b"".join(chunks) if capture else b""


def load_json_bytes(data: bytes, what: str) -> dict[str, object]:
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise VerificationError(f"invalid {what} JSON") from exc
    if not isinstance(value, dict):
        raise VerificationError(f"invalid {what} object")
    return value


def verify_descriptor_blob(archive: Archive, descriptor: dict[str, object]) -> dict[str, object]:
    digest = descriptor.get("digest")
    size = descriptor.get("size")
    if not isinstance(digest, str) or not isinstance(size, int) or size < 0:
        raise VerificationError("invalid OCI descriptor")
    return load_json_bytes(archive.verify_blob(digest, size), "OCI manifest")


def verify_referenced_blobs(archive: Archive, manifest: dict[str, object]) -> list[str]:
    config = manifest.get("config")
    layers = manifest.get("layers")
    if not isinstance(config, dict) or not isinstance(layers, list):
        raise VerificationError("OCI manifest lacks config or layers")
    descriptors = [config, *layers]
    layer_names: list[str] = []
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            raise VerificationError("invalid OCI child descriptor")
        digest = descriptor.get("digest")
        size = descriptor.get("size")
        if not isinstance(digest, str) or not isinstance(size, int) or size < 0:
            raise VerificationError("invalid OCI child digest or size")
        archive.verify_blob(digest, size)
    for descriptor in layers:
        assert isinstance(descriptor, dict)
        digest = descriptor["digest"]
        assert isinstance(digest, str)
        layer_names.append(f"blobs/sha256/{digest_hex(digest, 'layer digest')}")
    return layer_names


def verify_archive(
    path: pathlib.Path,
    platform: str,
    images: list[ExpectedImage],
    attachment_digests: list[str] | None = None,
) -> None:
    if not path.is_file() or path.is_symlink():
        raise VerificationError(f"archive is missing or is a symlink: {path}")
    try:
        wanted_os, wanted_arch = platform.split("/", 1)
    except ValueError as exc:
        raise VerificationError(f"invalid platform: {platform!r}") from exc

    expected: dict[str, ExpectedImage] = {}
    for image in images:
        tag = canonical_tag(image.tag)
        digest_hex(image.manifest_digest, "manifest digest")
        digest_hex(image.config_digest, "config digest")
        if tag in expected:
            raise VerificationError(f"duplicate expected image: {tag}")
        expected[tag] = ExpectedImage(tag, image.manifest_digest, image.config_digest)
    if not expected:
        raise VerificationError("expected image set is empty")
    expected_attachments = set(attachment_digests or [])
    if len(expected_attachments) != len(attachment_digests or []):
        raise VerificationError("duplicate expected attachment digest")
    for digest in expected_attachments:
        digest_hex(digest, "attachment digest")

    archive = Archive(path)
    try:
        index = archive.json("index.json")
        if not isinstance(index, dict) or index.get("schemaVersion") != 2:
            raise VerificationError("invalid OCI index")
        descriptors = index.get("manifests")
        if not isinstance(descriptors, list):
            raise VerificationError("OCI index has no manifests")

        seen: set[str] = set()
        seen_attachments: set[str] = set()
        legacy_layers: dict[str, list[str]] = {}
        expected_manifest_digests = {item.manifest_digest for item in expected.values()}
        for descriptor in descriptors:
            if not isinstance(descriptor, dict):
                raise VerificationError("invalid OCI index descriptor")
            annotations = descriptor.get("annotations") or {}
            if not isinstance(annotations, dict):
                raise VerificationError("invalid OCI descriptor annotations")
            image_name = annotations.get("io.containerd.image.name")
            manifest = verify_descriptor_blob(archive, descriptor)
            layers = verify_referenced_blobs(archive, manifest)

            if image_name is None:
                # Docker may retain SBOM/provenance attestations. Their exact
                # manifest digests are part of assets.lock, so adding another
                # runnable or metadata manifest cannot expand the archive.
                attachment_digest = descriptor.get("digest")
                subject = annotations.get("io.containerd.manifest.subject")
                if (
                    attachment_digest not in expected_attachments
                    or attachment_digest in seen_attachments
                    or subject not in expected_manifest_digests
                ):
                    raise VerificationError("unexpected or unbound OCI attachment")
                seen_attachments.add(attachment_digest)
                continue
            if not isinstance(image_name, str):
                raise VerificationError("invalid OCI image name annotation")
            tag = canonical_tag(image_name)
            wanted = expected.get(tag)
            if wanted is None or tag in seen:
                raise VerificationError(f"unexpected or duplicate OCI image: {tag}")
            if descriptor.get("digest") != wanted.manifest_digest:
                raise VerificationError(f"platform manifest mismatch: {tag}")
            descriptor_platform = descriptor.get("platform")
            if descriptor_platform is not None:
                if not isinstance(descriptor_platform, dict):
                    raise VerificationError(f"invalid platform descriptor: {tag}")
                if descriptor_platform.get("os") != wanted_os or descriptor_platform.get("architecture") != wanted_arch:
                    raise VerificationError(f"wrong image platform: {tag}")

            config = manifest.get("config")
            if not isinstance(config, dict) or config.get("digest") != wanted.config_digest:
                raise VerificationError(f"image config mismatch: {tag}")
            config_bytes = archive.verify_blob(wanted.config_digest, config.get("size") if isinstance(config.get("size"), int) else None)
            image_config = load_json_bytes(config_bytes, "image config")
            if image_config.get("os") != wanted_os or image_config.get("architecture") != wanted_arch:
                raise VerificationError(f"image config platform mismatch: {tag}")
            legacy_layers[tag] = layers
            seen.add(tag)

        if seen != set(expected):
            missing = sorted(set(expected) - seen)
            raise VerificationError(f"OCI index is missing locked images: {missing}")
        if seen_attachments != expected_attachments:
            missing = sorted(expected_attachments - seen_attachments)
            raise VerificationError(f"OCI index is missing locked attachments: {missing}")

        legacy = archive.json("manifest.json")
        if not isinstance(legacy, list):
            raise VerificationError("invalid Docker archive manifest")
        legacy_seen: set[str] = set()
        for entry in legacy:
            if not isinstance(entry, dict):
                raise VerificationError("invalid Docker manifest entry")
            tags = entry.get("RepoTags")
            config_name = entry.get("Config")
            layers = entry.get("Layers")
            if not isinstance(tags, list) or len(tags) != 1 or not isinstance(tags[0], str):
                raise VerificationError("each Docker manifest entry must have one tag")
            if not isinstance(config_name, str) or not isinstance(layers, list):
                raise VerificationError("invalid Docker manifest config or layers")
            tag = canonical_tag(tags[0])
            wanted = expected.get(tag)
            if wanted is None or tag in legacy_seen:
                raise VerificationError(f"unexpected or duplicate Docker image: {tag}")
            config_data = archive.read(config_name)
            if hashlib.sha256(config_data).hexdigest() != digest_hex(wanted.config_digest, "config digest"):
                raise VerificationError(f"Docker config mismatch: {tag}")
            if layers != legacy_layers[tag]:
                raise VerificationError(f"Docker layer list mismatch: {tag}")
            legacy_seen.add(tag)
        if legacy_seen != set(expected):
            missing = sorted(set(expected) - legacy_seen)
            raise VerificationError(f"Docker manifest is missing locked images: {missing}")

        layout = archive.json("oci-layout")
        if not isinstance(layout, dict) or layout.get("imageLayoutVersion") != "1.0.0":
            raise VerificationError("invalid OCI layout marker")
        regular_members = {
            name for name, member in archive.members.items() if member.isfile()
        }
        if regular_members != archive.consumed:
            unexpected = sorted(regular_members - archive.consumed)
            raise VerificationError(f"unreferenced archive members: {unexpected}")
    finally:
        archive.close()


def main(argv: list[str]) -> int:
    try:
        separator = argv.index("--attachments")
    except ValueError:
        separator = len(argv)
    image_args = argv[3:separator]
    attachment_digests = argv[separator + 1 :] if separator < len(argv) else []
    if len(argv) < 6 or not image_args or len(image_args) % 3 or any(
        value == "--attachments" for value in attachment_digests
    ):
        print(
            "usage: verify-oci-archive.py ARCHIVE OS/ARCH "
            "TAG MANIFEST_DIGEST CONFIG_DIGEST [...] "
            "[--attachments MANIFEST_DIGEST ...]",
            file=sys.stderr,
        )
        return 2
    images = [
        ExpectedImage(image_args[index], image_args[index + 1], image_args[index + 2])
        for index in range(0, len(image_args), 3)
    ]
    try:
        verify_archive(
            pathlib.Path(argv[1]), argv[2], images, attachment_digests
        )
    except (OSError, tarfile.TarError, VerificationError) as exc:
        print(f"controller archive verification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
