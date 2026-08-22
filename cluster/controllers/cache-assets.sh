#!/usr/bin/env bash
# Trusted online preparation step. The exam runtime never invokes this script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/controllers.sh
source "$ROOT/lib/controllers.sh"

for command_name in curl sha256sum mktemp python3; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "controller asset cache requires $command_name"
done

[ "$(controller_host_platform)" = "$CONTROLLER_PLATFORM" ] \
  || die "locked controller assets support $CONTROLLER_PLATFORM only"

# sn-05 reuses the kubeadm cache's locked nginx/BusyBox archive. Fail before
# any controller download so an incomplete preparation cannot consume network
# and only then discover that the Gateway workload cache is absent.
controller_bundle_verify "$GATEWAY_WORKLOAD_BUNDLE" \
  "$GATEWAY_BACKEND_IMAGE" "$GATEWAY_PROBE_IMAGE" \
  || die "Gateway workload cache missing or invalid; first run: bash cluster/cells/kubeadm/cache-packages.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cka-controller-assets.XXXXXX")"
cleanup_tmp() {
  case "$tmp" in
    "${TMPDIR:-/tmp}"/cka-controller-assets.*) rm -rf -- "$tmp" ;;
    *) warn "refusing to remove unexpected temporary path: $tmp" ;;
  esac
}
trap cleanup_tmp EXIT

download_locked() { # <url> <sha256> <output-name>
  local url="$1" expected="$2" output="$tmp/$3" actual
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
    --output "$output" "$url"
  actual="$(sha256sum "$output" | awk '{print $1}')"
  [ "$actual" = "$expected" ] \
    || die "official asset checksum mismatch: $3"
}

download_locked "$CERT_MANAGER_MANIFEST_URL" \
  "$CERT_MANAGER_MANIFEST_SHA256" "$CERT_MANAGER_MANIFEST"
download_locked "$GATEWAY_API_MANIFEST_URL" \
  "$GATEWAY_API_MANIFEST_SHA256" "$GATEWAY_API_MANIFEST"
download_locked "$ENVOY_GATEWAY_MANIFEST_URL" \
  "$ENVOY_GATEWAY_MANIFEST_SHA256" "$ENVOY_GATEWAY_MANIFEST"

# Docker Engine 29 enables the containerd image store by default.  Its image
# exporter currently has an upstream regression where an exact platform pull
# can be visible to `docker image inspect --platform`, yet `docker save
# --platform` rejects it or emits an archive without referenced OCI blobs.
# Fetch the immutable platform manifests and their content-addressed children
# through the Distribution API instead.  Every byte is independently checked
# against the committed manifest/config digests before the archive is written;
# controller_assets_verify below then verifies the completed closure again.
python3 - \
  "$tmp/$CERT_MANAGER_IMAGES_BUNDLE" "$CONTROLLER_PLATFORM" \
  "$CERT_MANAGER_CONTROLLER_IMAGE" "$CERT_MANAGER_CONTROLLER_DIGEST" \
  "$CERT_MANAGER_CONTROLLER_IMAGE_ID" \
  "$CERT_MANAGER_WEBHOOK_IMAGE" "$CERT_MANAGER_WEBHOOK_DIGEST" \
  "$CERT_MANAGER_WEBHOOK_IMAGE_ID" \
  "$CERT_MANAGER_CAINJECTOR_IMAGE" "$CERT_MANAGER_CAINJECTOR_DIGEST" \
  "$CERT_MANAGER_CAINJECTOR_IMAGE_ID" \
  --bundle \
  "$tmp/$ENVOY_GATEWAY_IMAGES_BUNDLE" "$CONTROLLER_PLATFORM" \
  "$ENVOY_GATEWAY_IMAGE" "$ENVOY_GATEWAY_DIGEST" \
  "$ENVOY_GATEWAY_IMAGE_ID" \
  "$ENVOY_PROXY_IMAGE" "$ENVOY_PROXY_DIGEST" \
  "$ENVOY_PROXY_IMAGE_ID" \
  "$ENVOY_RATELIMIT_IMAGE" "$ENVOY_RATELIMIT_DIGEST" \
  "$ENVOY_RATELIMIT_IMAGE_ID" <<'PY'
# CKA_CONTROLLER_ARCHIVE_BUILDER_BEGIN
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass


SHA256 = re.compile(r"^sha256:([0-9a-f]{64})$")
MAX_METADATA_BYTES = 16 * 1024 * 1024
MANIFEST_MEDIA_TYPES = {
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
}
MANIFEST_ACCEPT = ", ".join(sorted(MANIFEST_MEDIA_TYPES))
REGISTRIES = {
    "docker.io": ("registry-1.docker.io", {"auth.docker.io"}),
    "quay.io": ("quay.io", {"quay.io"}),
}


class CacheError(RuntimeError):
    pass


@dataclass(frozen=True)
class ImageSpec:
    tag: str
    manifest_digest: str
    config_digest: str


def digest_hex(value: str, what: str) -> str:
    match = SHA256.fullmatch(value)
    if not match:
        raise CacheError(f"invalid {what}: {value!r}")
    return match.group(1)


def json_bytes(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def verify_bytes(data: bytes, digest: str, size: int | None, what: str) -> None:
    expected = digest_hex(digest, f"{what} digest")
    if size is not None and len(data) != size:
        raise CacheError(f"{what} size mismatch: {digest}")
    if hashlib.sha256(data).hexdigest() != expected:
        raise CacheError(f"{what} digest mismatch: {digest}")


def verify_file(path: pathlib.Path, digest: str, size: int, what: str) -> None:
    if not path.is_file() or path.is_symlink() or path.stat().st_size != size:
        raise CacheError(f"{what} size or type mismatch: {digest}")
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            hasher.update(chunk)
    if hasher.hexdigest() != digest_hex(digest, f"{what} digest"):
        raise CacheError(f"{what} digest mismatch: {digest}")


def parse_image(tag: str) -> tuple[str, str, str]:
    if "@" in tag or "/" not in tag:
        raise CacheError(f"image must use a canonical tagged reference: {tag!r}")
    registry, remainder = tag.split("/", 1)
    if registry not in REGISTRIES:
        raise CacheError(f"unsupported locked registry: {registry!r}")
    slash = remainder.rfind("/")
    colon = remainder.rfind(":")
    if colon <= slash:
        raise CacheError(f"locked image has no explicit tag: {tag!r}")
    repository = remainder[:colon]
    if not re.fullmatch(r"[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*", repository):
        raise CacheError(f"invalid locked repository: {repository!r}")
    return registry, REGISTRIES[registry][0], repository


class HTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        target = urllib.parse.urlsplit(newurl)
        if target.scheme != "https" or not target.hostname:
            raise CacheError(f"registry attempted an unsafe redirect: {newurl!r}")
        redirected = super().redirect_request(request, fp, code, msg, headers, newurl)
        if redirected is None:
            return None
        source = urllib.parse.urlsplit(request.full_url)
        if (source.hostname, source.port) != (target.hostname, target.port):
            redirected.remove_header("Authorization")
        return redirected


class RegistryClient:
    def __init__(self) -> None:
        self.opener = urllib.request.build_opener(HTTPSRedirectHandler())
        self.tokens: dict[tuple[str, str], str] = {}

    def _token(self, registry: str, repository: str, challenge: str) -> str:
        key = (registry, repository)
        if key in self.tokens:
            return self.tokens[key]
        scheme, separator, raw = challenge.partition(" ")
        if scheme.lower() != "bearer" or not separator:
            raise CacheError("registry did not offer Bearer authentication")
        try:
            fields = urllib.request.parse_keqv_list(urllib.request.parse_http_list(raw))
        except (TypeError, ValueError) as exc:
            raise CacheError("registry returned an invalid authentication challenge") from exc
        realm = fields.get("realm", "")
        parsed = urllib.parse.urlsplit(realm)
        allowed_hosts = REGISTRIES[registry][1]
        if parsed.scheme != "https" or parsed.hostname not in allowed_hosts:
            raise CacheError(f"registry returned an untrusted token realm: {realm!r}")
        query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        if fields.get("service"):
            query.append(("service", fields["service"]))
        query.append(("scope", f"repository:{repository}:pull"))
        token_url = urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, parsed.path, urllib.parse.urlencode(query), "")
        )
        request = urllib.request.Request(
            token_url,
            headers={"Accept": "application/json", "User-Agent": "cka-practice-cache/1"},
        )
        with self.opener.open(request, timeout=60) as response:
            data = response.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise CacheError("registry token response is too large")
        try:
            payload = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise CacheError("registry token response is invalid JSON") from exc
        token = payload.get("token") or payload.get("access_token")
        if not isinstance(token, str) or not token or len(token) > 16384 or "\n" in token:
            raise CacheError("registry token response has no valid token")
        self.tokens[key] = token
        return token

    def open(self, registry: str, host: str, repository: str, path: str, accept: str):
        url = f"https://{host}/v2/{repository}/{path}"
        headers = {"Accept": accept, "User-Agent": "cka-practice-cache/1"}
        token = self.tokens.get((registry, repository))
        if token:
            headers["Authorization"] = f"Bearer {token}"
        for attempt in range(3):
            request = urllib.request.Request(url, headers=headers)
            try:
                return self.opener.open(request, timeout=120)
            except urllib.error.HTTPError as exc:
                if exc.code == 401 and attempt == 0:
                    challenge = exc.headers.get("WWW-Authenticate", "")
                    exc.close()
                    headers["Authorization"] = f"Bearer {self._token(registry, repository, challenge)}"
                    continue
                if exc.code in {429, 500, 502, 503, 504} and attempt < 2:
                    exc.close()
                    time.sleep(attempt + 1)
                    continue
                raise CacheError(f"registry request failed ({exc.code}): {url}") from exc
            except urllib.error.URLError as exc:
                if attempt < 2:
                    time.sleep(attempt + 1)
                    continue
                raise CacheError(f"registry request failed: {url}: {exc.reason}") from exc
        raise AssertionError("unreachable registry retry state")

    def metadata(self, spec: ImageSpec) -> bytes:
        registry, host, repository = parse_image(spec.tag)
        path = f"manifests/{urllib.parse.quote(spec.manifest_digest, safe=':')}"
        with self.open(registry, host, repository, path, MANIFEST_ACCEPT) as response:
            data = response.read(MAX_METADATA_BYTES + 1)
        if len(data) > MAX_METADATA_BYTES:
            raise CacheError(f"image manifest is too large: {spec.tag}")
        verify_bytes(data, spec.manifest_digest, None, f"manifest for {spec.tag}")
        return data

    def blob(self, spec: ImageSpec, digest: str, size: int, output: pathlib.Path) -> None:
        registry, host, repository = parse_image(spec.tag)
        path = f"blobs/{urllib.parse.quote(digest, safe=':')}"
        temporary = output.with_suffix(".part")
        hasher = hashlib.sha256()
        total = 0
        try:
            with self.open(registry, host, repository, path, "application/octet-stream") as response:
                length = response.headers.get("Content-Length")
                if length is not None and length.isdigit() and int(length) != size:
                    raise CacheError(f"registry blob Content-Length mismatch: {digest}")
                with temporary.open("xb") as handle:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > size:
                            raise CacheError(f"registry blob exceeds locked size: {digest}")
                        hasher.update(chunk)
                        handle.write(chunk)
            if total != size or hasher.hexdigest() != digest_hex(digest, "blob digest"):
                raise CacheError(f"registry blob verification failed: {digest}")
            os.replace(temporary, output)
        finally:
            temporary.unlink(missing_ok=True)


def descriptor(value: object, what: str) -> tuple[str, int, str]:
    if not isinstance(value, dict):
        raise CacheError(f"invalid {what} descriptor")
    digest = value.get("digest")
    size = value.get("size")
    media_type = value.get("mediaType")
    if not isinstance(digest, str) or not isinstance(size, int) or size < 0:
        raise CacheError(f"invalid {what} digest or size")
    if not isinstance(media_type, str) or not media_type:
        raise CacheError(f"invalid {what} media type")
    digest_hex(digest, f"{what} digest")
    return digest, size, media_type


def add_bytes(archive: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o644
    info.mtime = 0
    archive.addfile(info, __import__("io").BytesIO(data))


def add_file(archive: tarfile.TarFile, name: str, path: pathlib.Path) -> None:
    info = tarfile.TarInfo(name)
    info.size = path.stat().st_size
    info.mode = 0o644
    info.mtime = 0
    with path.open("rb") as handle:
        archive.addfile(info, handle)


def build_bundle(
    output: pathlib.Path,
    platform: str,
    specs: list[ImageSpec],
    client: RegistryClient,
) -> None:
    try:
        wanted_os, wanted_arch = platform.split("/", 1)
    except ValueError as exc:
        raise CacheError(f"invalid locked platform: {platform!r}") from exc
    if (wanted_os, wanted_arch) != ("linux", "amd64"):
        raise CacheError(f"unsupported locked platform: {platform!r}")
    if not specs or len({spec.tag for spec in specs}) != len(specs):
        raise CacheError("bundle image set is empty or contains duplicate tags")

    index_descriptors: list[dict[str, object]] = []
    legacy: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="oci-blobs.", dir=output.parent) as directory:
        blob_dir = pathlib.Path(directory)
        blobs: dict[str, pathlib.Path] = {}
        for spec in specs:
            digest_hex(spec.manifest_digest, "locked manifest digest")
            digest_hex(spec.config_digest, "locked config digest")
            manifest_bytes = client.metadata(spec)
            verify_bytes(
                manifest_bytes,
                spec.manifest_digest,
                None,
                f"manifest for {spec.tag}",
            )
            try:
                manifest = json.loads(manifest_bytes)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise CacheError(f"invalid image manifest JSON: {spec.tag}") from exc
            if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 2:
                raise CacheError(f"invalid image manifest: {spec.tag}")
            media_type = manifest.get("mediaType")
            if media_type not in MANIFEST_MEDIA_TYPES:
                raise CacheError(f"unsupported image manifest media type: {spec.tag}")
            config_digest, config_size, _ = descriptor(manifest.get("config"), "config")
            if config_digest != spec.config_digest:
                raise CacheError(f"locked config digest mismatch: {spec.tag}")
            layers = manifest.get("layers")
            if not isinstance(layers, list) or not layers:
                raise CacheError(f"image manifest has no layers: {spec.tag}")
            children = [manifest["config"], *layers]
            for child in children:
                child_digest, child_size, _ = descriptor(child, "child")
                path = blobs.get(child_digest)
                if path is None:
                    path = blob_dir / digest_hex(child_digest, "child digest")
                    client.blob(spec, child_digest, child_size, path)
                    blobs[child_digest] = path
                verify_file(path, child_digest, child_size, "image blob")
            config_path = blobs[config_digest]
            try:
                image_config = json.loads(config_path.read_bytes())
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise CacheError(f"invalid image config JSON: {spec.tag}") from exc
            if not isinstance(image_config, dict) or (
                image_config.get("os"), image_config.get("architecture")
            ) != (wanted_os, wanted_arch):
                raise CacheError(f"image config platform mismatch: {spec.tag}")
            manifest_path = blob_dir / digest_hex(spec.manifest_digest, "manifest digest")
            manifest_path.write_bytes(manifest_bytes)
            blobs[spec.manifest_digest] = manifest_path
            index_descriptors.append(
                {
                    "mediaType": media_type,
                    "digest": spec.manifest_digest,
                    "size": len(manifest_bytes),
                    "annotations": {
                        "io.containerd.image.name": spec.tag,
                        "org.opencontainers.image.ref.name": spec.tag.rsplit(":", 1)[1],
                    },
                    "platform": {"architecture": wanted_arch, "os": wanted_os},
                }
            )
            legacy.append(
                {
                    "Config": f"blobs/sha256/{digest_hex(config_digest, 'config digest')}",
                    "RepoTags": [spec.tag],
                    "Layers": [
                        f"blobs/sha256/{digest_hex(descriptor(layer, 'layer')[0], 'layer digest')}"
                        for layer in layers
                    ],
                }
            )

        index = {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": index_descriptors,
        }
        with tarfile.open(output, mode="x") as archive:
            for name in ("blobs", "blobs/sha256"):
                info = tarfile.TarInfo(name)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.mtime = 0
                archive.addfile(info)
            for blob_digest in sorted(blobs):
                add_file(
                    archive,
                    f"blobs/sha256/{digest_hex(blob_digest, 'archive blob digest')}",
                    blobs[blob_digest],
                )
            add_bytes(archive, "index.json", json_bytes(index))
            add_bytes(archive, "manifest.json", json_bytes(legacy))
            add_bytes(archive, "oci-layout", json_bytes({"imageLayoutVersion": "1.0.0"}))


def parse_bundles(arguments: list[str]) -> list[tuple[pathlib.Path, str, list[ImageSpec]]]:
    bundles: list[list[str]] = [[]]
    for argument in arguments:
        if argument == "--bundle":
            bundles.append([])
        else:
            bundles[-1].append(argument)
    parsed: list[tuple[pathlib.Path, str, list[ImageSpec]]] = []
    for fields in bundles:
        if len(fields) < 5 or (len(fields) - 2) % 3:
            raise CacheError("invalid controller archive builder arguments")
        specs = [ImageSpec(*fields[index:index + 3]) for index in range(2, len(fields), 3)]
        parsed.append((pathlib.Path(fields[0]), fields[1], specs))
    return parsed


def main(arguments: list[str]) -> int:
    client = RegistryClient()
    for output, platform, specs in parse_bundles(arguments):
        build_bundle(output, platform, specs, client)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CacheError as exc:
        raise SystemExit(f"controller image cache failed: {exc}")
# CKA_CONTROLLER_ARCHIVE_BUILDER_END
PY

for bundle in "$CERT_MANAGER_IMAGES_BUNDLE" "$ENVOY_GATEWAY_IMAGES_BUNDLE"; do
  sha256sum "$tmp/$bundle" | awk '{print $1}' > "$tmp/$bundle.sha256"
done

mkdir -p "$CONTROLLER_ASSET_DIR"
for name in \
  "$CERT_MANAGER_MANIFEST" "$GATEWAY_API_MANIFEST" \
  "$ENVOY_GATEWAY_MANIFEST" "$CERT_MANAGER_IMAGES_BUNDLE" \
  "$CERT_MANAGER_IMAGES_BUNDLE.sha256" "$ENVOY_GATEWAY_IMAGES_BUNDLE" \
  "$ENVOY_GATEWAY_IMAGES_BUNDLE.sha256"; do
  install -m 0644 "$tmp/$name" "$CONTROLLER_ASSET_DIR/$name"
done

controller_assets_verify all
ok "controller assets cached and verified: $CONTROLLER_ASSET_DIR"
