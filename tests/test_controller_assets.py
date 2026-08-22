#!/usr/bin/env python3
"""Static archive-scope contracts for disposable controller labs."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import pathlib
import re
import sys
import tarfile
import tempfile
import types
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = ROOT / "cluster" / "controllers" / "cache-assets.sh"
VERIFIER_PATH = ROOT / "cluster" / "controllers" / "verify-oci-archive.py"

SPEC = importlib.util.spec_from_file_location("controller_archive_verifier", VERIFIER_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFIER
SPEC.loader.exec_module(VERIFIER)

CACHE_TEXT = CACHE.read_text(encoding="utf-8")
BUILDER_MATCH = re.search(
    r"# CKA_CONTROLLER_ARCHIVE_BUILDER_BEGIN\n(.*?)"
    r"# CKA_CONTROLLER_ARCHIVE_BUILDER_END",
    CACHE_TEXT,
    re.DOTALL,
)
assert BUILDER_MATCH is not None
BUILDER = types.ModuleType("controller_archive_builder_test")
sys.modules[BUILDER.__name__] = BUILDER
exec(compile(BUILDER_MATCH.group(1), str(CACHE), "exec"), BUILDER.__dict__)


def json_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def add_tar_file(archive: tarfile.TarFile, name: str, data: bytes) -> None:
    member = tarfile.TarInfo(name)
    member.size = len(data)
    member.mode = 0o644
    archive.addfile(member, io.BytesIO(data))


def build_archive(
    path: pathlib.Path,
    tags: list[str],
    *,
    tamper_layer: bool = False,
    legacy_tag: str | None = None,
    add_attachment: bool = False,
    add_unreferenced_blob: bool = False,
) -> tuple[list[object], list[str]]:
    blobs: dict[str, bytes] = {}
    descriptors: list[dict[str, object]] = []
    legacy: list[dict[str, object]] = []
    expected: list[object] = []

    for index, tag in enumerate(tags):
        config_data = json_bytes(
            {
                "architecture": "amd64",
                "os": "linux",
                "rootfs": {"type": "layers", "diff_ids": []},
                "marker": tag,
            }
        )
        config_digest = digest(config_data)
        layer_data = f"locked-layer-{index}".encode()
        layer_digest = digest(layer_data)
        stored_layer = layer_data + (b"-tampered" if tamper_layer and index == 0 else b"")
        manifest_data = json_bytes(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": {
                    "mediaType": "application/vnd.oci.image.config.v1+json",
                    "digest": config_digest,
                    "size": len(config_data),
                },
                "layers": [
                    {
                        "mediaType": "application/vnd.oci.image.layer.v1.tar",
                        "digest": layer_digest,
                        "size": len(layer_data),
                    }
                ],
            }
        )
        manifest_digest = digest(manifest_data)
        blobs[config_digest] = config_data
        blobs[layer_digest] = stored_layer
        blobs[manifest_digest] = manifest_data
        descriptors.append(
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": manifest_digest,
                "size": len(manifest_data),
                "annotations": {"io.containerd.image.name": tag},
                "platform": {"architecture": "amd64", "os": "linux"},
            }
        )
        legacy.append(
            {
                "Config": f"blobs/sha256/{config_digest.removeprefix('sha256:')}",
                "RepoTags": [legacy_tag if index == 0 and legacy_tag else tag],
                "Layers": [f"blobs/sha256/{layer_digest.removeprefix('sha256:')}"],
            }
        )
        expected.append(VERIFIER.ExpectedImage(tag, manifest_digest, config_digest))

    attachments: list[str] = []
    if add_attachment:
        attachment_config = json_bytes({"architecture": "unknown", "os": "unknown"})
        attachment_layer = b'{"predicateType":"test"}'
        attachment_config_digest = digest(attachment_config)
        attachment_layer_digest = digest(attachment_layer)
        attachment_manifest = json_bytes(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": {
                    "mediaType": "application/vnd.oci.image.config.v1+json",
                    "digest": attachment_config_digest,
                    "size": len(attachment_config),
                },
                "layers": [
                    {
                        "mediaType": "application/vnd.in-toto+json",
                        "digest": attachment_layer_digest,
                        "size": len(attachment_layer),
                    }
                ],
            }
        )
        attachment_digest = digest(attachment_manifest)
        blobs[attachment_config_digest] = attachment_config
        blobs[attachment_layer_digest] = attachment_layer
        blobs[attachment_digest] = attachment_manifest
        descriptors.append(
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": attachment_digest,
                "size": len(attachment_manifest),
                "annotations": {
                    "io.containerd.manifest.subject": expected[0].manifest_digest
                },
            }
        )
        attachments.append(attachment_digest)

    index_data = json_bytes(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": descriptors,
        }
    )
    with tarfile.open(path, "w") as archive:
        for blob_digest, data in blobs.items():
            add_tar_file(
                archive,
                f"blobs/sha256/{blob_digest.removeprefix('sha256:')}",
                data,
            )
        if add_unreferenced_blob:
            add_tar_file(archive, "blobs/sha256/" + "f" * 64, b"unlocked")
        add_tar_file(archive, "index.json", index_data)
        add_tar_file(archive, "manifest.json", json_bytes(legacy))
        add_tar_file(archive, "oci-layout", json_bytes({"imageLayoutVersion": "1.0.0"}))
    return expected, attachments


class ControllerAssetCacheContract(unittest.TestCase):
    def test_cache_does_not_depend_on_docker_containerd_export(self):
        self.assertNotRegex(
            CACHE_TEXT,
            re.compile(r"^\s*docker\s+(?:pull|tag|save)\b", re.MULTILINE),
        )
        self.assertNotIn("controller_docker_image_id_matches", CACHE_TEXT)
        self.assertIn("through the Distribution API instead", CACHE_TEXT)

    def test_bundle_builder_receives_every_locked_identity_triplet(self):
        prefixes = (
            "CERT_MANAGER_CONTROLLER",
            "CERT_MANAGER_WEBHOOK",
            "CERT_MANAGER_CAINJECTOR",
            "ENVOY_GATEWAY",
            "ENVOY_PROXY",
            "ENVOY_RATELIMIT",
        )
        for prefix in prefixes:
            expected = (
                f'"${prefix}_IMAGE" "${prefix}_DIGEST" \\\n'
                f'  "${prefix}_IMAGE_ID"'
            )
            self.assertIn(expected, CACHE_TEXT)
        self.assertEqual(CACHE_TEXT.count("  --bundle \\\n"), 1)

    def test_workload_bundle_is_verified_before_any_controller_download(self):
        preflight = CACHE_TEXT.index(
            'controller_bundle_verify "$GATEWAY_WORKLOAD_BUNDLE"'
        )
        first_download = CACHE_TEXT.index(
            'download_locked "$CERT_MANAGER_MANIFEST_URL"'
        )
        self.assertLess(preflight, first_download)
        self.assertIn(
            "first run: bash cluster/cells/kubeadm/cache-packages.sh", CACHE_TEXT
        )


class FakeRegistryClient:
    def __init__(self, tag: str, *, corrupt_layer: bool = False):
        self.tag = tag
        self.config = json_bytes(
            {
                "architecture": "amd64",
                "os": "linux",
                "rootfs": {"type": "layers", "diff_ids": []},
            }
        )
        self.layer = b"locked-registry-layer"
        self.config_digest = digest(self.config)
        self.layer_digest = digest(self.layer)
        self.manifest = json_bytes(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": {
                    "mediaType": "application/vnd.oci.image.config.v1+json",
                    "digest": self.config_digest,
                    "size": len(self.config),
                },
                "layers": [
                    {
                        "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                        "digest": self.layer_digest,
                        "size": len(self.layer),
                    }
                ],
            }
        )
        self.manifest_digest = digest(self.manifest)
        self.corrupt_layer = corrupt_layer

    def metadata(self, spec):
        if spec.tag != self.tag:
            raise AssertionError("unexpected fake registry tag")
        return self.manifest

    def blob(self, spec, blob_digest, size, output):
        if spec.tag != self.tag:
            raise AssertionError("unexpected fake registry tag")
        blobs = {
            self.config_digest: self.config,
            self.layer_digest: b"tampered" if self.corrupt_layer else self.layer,
        }
        output.write_bytes(blobs[blob_digest])


class ControllerArchiveBuilderTest(unittest.TestCase):
    def test_exact_registry_content_builds_a_platform_scoped_archive(self):
        tag = "docker.io/example/locked:v1"
        client = FakeRegistryClient(tag)
        spec = BUILDER.ImageSpec(
            tag, client.manifest_digest, client.config_digest
        )
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.tar"
            BUILDER.build_bundle(archive, "linux/amd64", [spec], client)
            VERIFIER.verify_archive(
                archive,
                "linux/amd64",
                [
                    VERIFIER.ExpectedImage(
                        tag, client.manifest_digest, client.config_digest
                    )
                ],
            )

    def test_builder_rejects_a_registry_blob_that_breaks_the_lock(self):
        tag = "docker.io/example/locked:v1"
        client = FakeRegistryClient(tag, corrupt_layer=True)
        spec = BUILDER.ImageSpec(
            tag, client.manifest_digest, client.config_digest
        )
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.tar"
            with self.assertRaises(BUILDER.CacheError):
                BUILDER.build_bundle(archive, "linux/amd64", [spec], client)


class ControllerArchiveVerifierTest(unittest.TestCase):
    def test_exact_archive_and_locked_attachment_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.tar"
            images, attachments = build_archive(
                archive, ["registry.example/locked/app:v1"], add_attachment=True
            )
            VERIFIER.verify_archive(archive, "linux/amd64", images, attachments)

    def test_extra_named_image_is_rejected_even_with_replaced_sidecar(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.tar"
            images, _ = build_archive(
                archive,
                ["registry.example/locked/app:v1", "registry.example/extra/app:v1"],
            )
            sidecar = archive.with_suffix(".tar.sha256")
            sidecar.write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "\n")
            with self.assertRaises(VERIFIER.VerificationError):
                VERIFIER.verify_archive(archive, "linux/amd64", images[:1])

    def test_tampered_layer_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.tar"
            images, _ = build_archive(
                archive, ["registry.example/locked/app:v1"], tamper_layer=True
            )
            with self.assertRaises(VERIFIER.VerificationError):
                VERIFIER.verify_archive(archive, "linux/amd64", images)

    def test_legacy_tag_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / "bundle.tar"
            images, _ = build_archive(
                archive,
                ["registry.example/locked/app:v1"],
                legacy_tag="registry.example/drifted/app:v1",
            )
            with self.assertRaises(VERIFIER.VerificationError):
                VERIFIER.verify_archive(archive, "linux/amd64", images)

    def test_unlocked_attachment_and_unreferenced_blob_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            attachment_archive = pathlib.Path(directory) / "attachment.tar"
            images, _ = build_archive(
                attachment_archive,
                ["registry.example/locked/app:v1"],
                add_attachment=True,
            )
            with self.assertRaises(VERIFIER.VerificationError):
                VERIFIER.verify_archive(attachment_archive, "linux/amd64", images)

            blob_archive = pathlib.Path(directory) / "blob.tar"
            images, _ = build_archive(
                blob_archive,
                ["registry.example/locked/app:v1"],
                add_unreferenced_blob=True,
            )
            with self.assertRaises(VERIFIER.VerificationError):
                VERIFIER.verify_archive(blob_archive, "linux/amd64", images)

    def test_links_devices_fifos_and_unexpected_directories_are_rejected(self):
        member_types = {
            "symlink": tarfile.SYMTYPE,
            "hardlink": tarfile.LNKTYPE,
            "device": tarfile.CHRTYPE,
            "fifo": tarfile.FIFOTYPE,
        }
        with tempfile.TemporaryDirectory() as directory:
            for label, member_type in member_types.items():
                with self.subTest(member_type=label):
                    archive = pathlib.Path(directory) / f"{label}.tar"
                    images, _ = build_archive(
                        archive, ["registry.example/locked/app:v1"]
                    )
                    with tarfile.open(archive, "a") as output:
                        member = tarfile.TarInfo(f"malicious-{label}")
                        member.type = member_type
                        member.linkname = "index.json"
                        output.addfile(member)
                    with self.assertRaises(VERIFIER.VerificationError):
                        VERIFIER.verify_archive(archive, "linux/amd64", images)

            archive = pathlib.Path(directory) / "directory.tar"
            images, _ = build_archive(
                archive, ["registry.example/locked/app:v1"]
            )
            with tarfile.open(archive, "a") as output:
                member = tarfile.TarInfo("blobs/unlocked")
                member.type = tarfile.DIRTYPE
                output.addfile(member)
            with self.assertRaises(VERIFIER.VerificationError):
                VERIFIER.verify_archive(archive, "linux/amd64", images)


if __name__ == "__main__":
    unittest.main()
