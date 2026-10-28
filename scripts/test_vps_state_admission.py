"""Bounded, read-only admission of foreign deployment-state producers.

Recognition grants preservation only. This module deliberately has no cleanup,
reconciliation, subprocess, network, or environment-evaluation capability.
"""
from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass

ROOT_ENTRIES = 4096
DESCENDANT_ENTRIES = 4096
MAX_DEPTH = 4
RECORD_BYTES = 64 * 1024
ENV_BYTES = 1024 * 1024
TOTAL_BYTES = 16 * 1024 * 1024
NAME_BYTES = 255
GENERATIONS = ".smtp-last-good-generations"
SELECTOR = ".smtp-last-good.current"
TRANSACTIONS = ".smtp-transactions"
POINTER = ".smtp-transaction.current"
OWNED_PATHS = [
    "private/capture-runtime.json", "private/post-capture.json",
    "private/capture-result.json", "private/capture-database-proof.json",
    "private/capture-media-proof.json", "private/postgres.dump.age",
    "private/uploads.tar.gz.age", "staging",
]
EMAIL_KEYS = (
    b"APP_EMAIL_PROVIDER", b"APP_EMAIL_FROM", b"APP_EMAIL_FROM_NAME",
    b"SPRING_MAIL_HOST", b"SPRING_MAIL_PORT", b"SPRING_MAIL_USERNAME",
    b"SPRING_MAIL_PASSWORD", b"APP_EMAIL_CONNECT_TIMEOUT_MS",
    b"APP_EMAIL_READ_TIMEOUT_MS", b"APP_EMAIL_WRITE_TIMEOUT_MS",
)
MANIFEST_KEYS = frozenset((
    "schema", "generation", "env_sha256", "non_email_config_sha256",
    "non_email_runtime_fingerprint", "runtime_fingerprint", "release_image",
    "release_version", "release_revision",
))

# Producers retain their native jq/Bash evaluators. These fixed schemas never
# receive payloads; Inventory's stricter Python readers remain independently bounded.
PRODUCER_BETA_FILTERS = {
    "journal": r'''type=="object" and
    (keys|sort)==["capturedContainerId","capturedContainerSafe","capturedImageId","capturedRuntimeDigest","currentRuntimeHealthy","ownedPaths","phase","recoveryId","schema","state"] and
    .schema=="meet-backend/beta-recovery-journal/v1" and (.recoveryId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")) and
    (((.state=="nonterminal") and (.phase=="pre_stop" or .phase=="snapshot_complete" or .phase=="runtime_verified")) or
     ((.state=="terminal") and (.phase=="incident_resolved" or .phase=="superseded"))) and
    (.capturedContainerId|test("^[0-9a-f]{12,64}$")) and (.capturedImageId|test("^sha256:[0-9a-f]{64}$")) and
    (.capturedRuntimeDigest|test("^[0-9a-f]{64}$")) and (.currentRuntimeHealthy==true) and
    (.capturedContainerSafe==true) and .ownedPaths==$owned''',
    "incident": r'''type=="object" and (keys|sort)==["recoveryId","sanitized","schema","status"] and
    .schema=="meet-backend/beta-recovery-incident/v1" and .recoveryId==$id and
    .status==$status and ($status=="incident_resolved" or $status=="superseded") and
    .sanitized==true''',
}
PRODUCER_SMTP_SCHEMA = (
    ("schema", ""),
    ("generation", ""),
    ("env_sha256", r"^[0-9a-f]{64}$"),
    ("non_email_config_sha256", r"^[0-9a-f]{64}$"),
    ("non_email_runtime_fingerprint", r"^[0-9a-f]{64}$"),
    ("runtime_fingerprint", r"^[0-9a-f]{64}$"),
    ("release_image", r"^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$"),
    ("release_version", r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"),
    ("release_revision", r"^[0-9a-f]{40}$"),
)


class Rejected(Exception):
    """Bounded, nonsecret reason only."""


def require(value: bool, reason: str = "invalid_record") -> None:
    if not value:
        raise Rejected(reason)


def matches(pattern: str, value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value, re.ASCII) is not None


def generation_name(value: str) -> None:
    # Check before any lookup; Python's Unicode character count is not a byte cap.
    require(matches(r"[A-Za-z0-9][A-Za-z0-9._-]*", value)
            and 1 <= len(value.encode("ascii")) <= NAME_BYTES, "generation_name")


def _object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate_key")
        result[key] = value
    return result


def json_record(data: bytes) -> dict:
    require(len(data) <= RECORD_BYTES, "record_budget")
    try:
        value = json.loads(data, object_pairs_hook=_object,
                           parse_constant=lambda _: require(False))
    except (ValueError, UnicodeError, RecursionError):
        raise Rejected("invalid_json") from None
    require(isinstance(value, dict))
    return value


def beta_journal(data: bytes) -> dict:
    value = json_record(data)
    require(set(value) == {
        "schema", "recoveryId", "state", "phase", "capturedContainerId",
        "capturedImageId", "capturedRuntimeDigest", "currentRuntimeHealthy",
        "capturedContainerSafe", "ownedPaths"})
    require(value["schema"] == "meet-backend/beta-recovery-journal/v1"
            and matches(r"[A-Za-z0-9][A-Za-z0-9._-]{7,127}", value["recoveryId"])
            and ((value["state"] == "nonterminal" and value["phase"] in
                  ("pre_stop", "snapshot_complete", "runtime_verified"))
                 or (value["state"] == "terminal" and value["phase"] in
                     ("incident_resolved", "superseded")))
            and matches(r"[0-9a-f]{12,64}", value["capturedContainerId"])
            and matches(r"sha256:[0-9a-f]{64}", value["capturedImageId"])
            and matches(r"[0-9a-f]{64}", value["capturedRuntimeDigest"])
            and value["currentRuntimeHealthy"] is True
            and value["capturedContainerSafe"] is True
            and value["ownedPaths"] == OWNED_PATHS)
    return value


def beta_incident(data: bytes, recovery_id: str, phase: str) -> None:
    value = json_record(data)
    require(set(value) == {"schema", "recoveryId", "status", "sanitized"}
            and value["schema"] == "meet-backend/beta-recovery-incident/v1"
            and value["recoveryId"] == recovery_id and value["status"] == phase
            and phase in ("incident_resolved", "superseded")
            and value["sanitized"] is True)


def non_email_digest(data: bytes) -> str:
    # awk RS is LF only; print adds LF even to an unterminated final record.
    # Do not splitlines(): CR, VT, and other bytes are ordinary record contents.
    records = data.split(b"\n")
    if records[-1] == b"":
        records.pop()
    digest = hashlib.sha256()
    for record in records:
        if any(record.startswith(key + b"=") for key in EMAIL_KEYS):
            continue
        digest.update(record + b"\n")
    return digest.hexdigest()


def generation_record(name: str, env: bytes, manifest: bytes, *,
                      env_digest: str | None = None,
                      config_digest: str | None = None) -> dict[str, str]:
    generation_name(name)
    require(len(env) <= ENV_BYTES and len(manifest) <= RECORD_BYTES, "file_budget")
    try:
        text = manifest.decode("ascii")
    except UnicodeError:
        raise Rejected("manifest_encoding") from None
    # Bash read -r accepts an unterminated last record, but not blank records.
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    result = {}
    for line in lines:
        key, sep, value = line.partition("=")
        require(bool(sep) and key in MANIFEST_KEYS and key not in result)
        result[key] = value
    require(set(result) == MANIFEST_KEYS and result["schema"] == "2"
            and result["generation"] == name)
    for key in ("env_sha256", "non_email_config_sha256",
                "non_email_runtime_fingerprint", "runtime_fingerprint"):
        require(matches(r"[0-9a-f]{64}", result[key]))
    require(matches(r"ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}",
                    result["release_image"])
            and matches(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)",
                        result["release_version"])
            and matches(r"[0-9a-f]{40}", result["release_revision"])
            and result["env_sha256"] == (
                hashlib.sha256(env).hexdigest() if env_digest is None else env_digest)
            and result["non_email_config_sha256"] == (
                non_email_digest(env) if config_digest is None else config_digest))
    return result


def selector_value(data: bytes, generations: set[str]) -> str:
    try:
        value = data.decode("ascii")
    except UnicodeError:
        raise Rejected("selector_encoding") from None
    require(value.endswith("\n") and value.count("\n") == 1, "selector")
    value = value[:-1]
    generation_name(value)
    require(value in generations, "dangling_selector")
    return value


def identity(info: os.stat_result) -> tuple[int, ...]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def no_acl(fd: int) -> None:
    # Match the provider's trust envelope: extended access/default ACLs reject.
    for name in ("system.posix_acl_access", "system.posix_acl_default"):
        try:
            os.getxattr(fd, name)
        except OSError as exc:
            if exc.errno == errno.ENODATA:
                continue
            raise Rejected("acl_unavailable") from None
        raise Rejected("unsafe_acl")


def names(fd: int, limit: int) -> frozenset[str]:
    result = set()
    with os.scandir(fd) as entries:
        for entry in entries:
            require(len(result) < limit, "entry_budget")
            name = entry.name
            require(0 < len(os.fsencode(name)) <= NAME_BYTES, "basename_budget")
            require(name not in result, "inventory_changed")
            result.add(name)
    return frozenset(result)


@dataclass(frozen=True)
class Classification:
    category: str
    disposition: str
    reason: str


@dataclass
class _Witness:
    parent: int
    name: str
    fd: int
    saved: tuple[int, ...]
    children: frozenset[str] | None
    data: bytes | None


class Inventory:
    """Pinned foreign witnesses; caller owns deploy lock and exact own artifacts.

    Exclusions identify existing provider-owned root names, never a wildcard.
    The complete root name set is still retained and rechecked across publication.
    Close on every path (including rejected classification).
    """
    def __init__(self, root_fd: int, excluded: set[str], opaque: set[str] = frozenset(),
                 root_path: str | None = None):
        self.root = os.dup(root_fd)
        self.witnesses: list[_Witness] = []
        self.opaque: list[_Witness] = []
        self.ancestors: list[_Witness] = []
        self.excluded = frozenset(excluded)
        self.results: dict[str, Classification] = {}
        self.entries = 0
        self.bytes_read = 0
        try:
            root = os.fstat(self.root)
            self.root_identity = identity(root)
            self.device = root.st_dev
            self._trust(self.root, root, True)
            self._pin_ancestry(root_path or os.readlink(f"/proc/self/fd/{self.root}"))
            self.root_names = names(self.root, ROOT_ENTRIES)
            require(POINTER not in self.root_names, "smtp_transaction")
            for name in opaque:
                require(name in self.root_names and name not in self.excluded)
                fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                             dir_fd=self.root)
                self.opaque.append(_Witness(self.root, name, fd,
                                            identity(os.fstat(fd)), None, None))
            # Complete inventory first; dependent selector validation comes last.
            foreign = self.root_names - self.excluded - opaque
            allowed = {GENERATIONS, SELECTOR, TRANSACTIONS}
            for name in foreign:
                require(name in allowed or name.startswith("beta-recovery-"),
                        "unbound_probe_sidecar" if name.startswith(
                            (".runtime.", ".pre-capture.")) else "unknown")
            generations = set()
            if GENERATIONS in foreign:
                directory = self._directory(self.root, GENERATIONS, 1)
                generations = set(directory.children)
                for name in generations:
                    generation_name(name)
                    child = self._directory(directory.fd, name, 2)
                    require(child.children == {"env", "manifest"})
                    env = self._file(child.fd, "env", ENV_BYTES)
                    manifest = self._file(child.fd, "manifest", RECORD_BYTES)
                    generation_record(name, env, manifest)
                self.results[GENERATIONS] = Classification("smtp-generations", "preserve", "valid")
            if TRANSACTIONS in foreign:
                directory = self._directory(self.root, TRANSACTIONS, 1)
                require(not directory.children, "orphan_smtp_transaction")
                self.results[TRANSACTIONS] = Classification("smtp-empty-transactions", "preserve", "empty")
            for name in foreign:
                if not name.startswith("beta-recovery-"):
                    continue
                directory = self._directory(self.root, name, 1)
                require(directory.children in (
                    {"journal.json", "incident.json"},
                    {"journal.json", "incident.json", "private"}), "beta_not_clean")
                journal = beta_journal(self._file(directory.fd, "journal.json", RECORD_BYTES))
                require(journal["recoveryId"] == name[len("beta-recovery-"):]
                        and journal["state"] == "terminal", "beta_nonterminal")
                beta_incident(self._file(directory.fd, "incident.json", RECORD_BYTES),
                              journal["recoveryId"], journal["phase"])
                if "private" in directory.children:
                    require(not self._directory(directory.fd, "private", 2).children,
                            "beta_not_clean")
                self.results[name] = Classification("beta-terminal", "preserve", "clean_terminal")
            if SELECTOR in foreign:
                selector_value(self._file(self.root, SELECTOR, NAME_BYTES + 1), generations)
                self.results[SELECTOR] = Classification("smtp-selector", "preserve", "bound")
            self.recheck(read_bytes=False)
        except BaseException:
            self.close()
            raise

    def _trust(self, fd: int, info: os.stat_result, directory: bool) -> None:
        require(info.st_dev == self.device
                and info.st_uid == 0 and info.st_gid == 0
                and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600)
                and (stat.S_ISDIR(info.st_mode) if directory else
                     stat.S_ISREG(info.st_mode) and info.st_nlink == 1), "unsafe_inode")
        no_acl(fd)
        # Linux mount IDs detect bind mounts even on the same device.
        require(self._mount(fd) == self._mount(self.root), "mount_escape")

    @staticmethod
    def _mount(fd: int) -> str:
        with open(f"/proc/self/fdinfo/{fd}", encoding="ascii") as stream:
            for line in stream:
                if line.startswith("mnt_id:"):
                    return line.strip()
        raise Rejected("mount_unavailable")

    def _open(self, parent: int, name: str, directory: bool) -> _Witness:
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        require(stat.S_ISDIR(before.st_mode) if directory else
                stat.S_ISREG(before.st_mode), "unsafe_type")
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOATIME
        if directory:
            flags |= os.O_DIRECTORY
        fd = os.open(name, flags, dir_fd=parent)
        try:
            info = os.fstat(fd)
            require(identity(info) == identity(before), "inode_changed")
            self._trust(fd, info, directory)
            witness = _Witness(parent, name, fd, identity(info), None, None)
            self.witnesses.append(witness)
            return witness
        except BaseException:
            os.close(fd)
            raise

    def _directory(self, parent: int, name: str, depth: int) -> _Witness:
        require(depth <= MAX_DEPTH, "depth_budget")
        witness = self._open(parent, name, True)
        witness.children = names(witness.fd, DESCENDANT_ENTRIES - self.entries)
        self.entries += len(witness.children)
        return witness

    def _read(self, fd: int, limit: int) -> bytes:
        size = os.fstat(fd).st_size
        require(size <= limit and self.bytes_read + size <= TOTAL_BYTES, "file_budget")
        chunks = []
        offset = 0
        while offset <= size:
            chunk = os.pread(fd, min(65536, size + 1 - offset), offset)
            if not chunk:
                break
            offset += len(chunk)
            self.bytes_read += len(chunk)
            require(offset <= size and self.bytes_read <= TOTAL_BYTES, "read_budget")
            chunks.append(chunk)
        require(offset == size, "short_read")
        return b"".join(chunks)

    def _pin_ancestry(self, path: str) -> None:
        require(path.startswith("/") and all(part not in ("", ".", "..")
                for part in path.split("/")[1:]), "root_path")
        parent = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.ancestors.append(_Witness(parent, "", parent,
                                       identity(os.fstat(parent)), None, None))
        for name in path.split("/")[1:]:
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=parent)
            self.ancestors.append(_Witness(parent, name, child,
                                           identity(os.fstat(child)), None, None))
            parent = child
        require(identity(os.fstat(parent)) == self.root_identity, "root_binding")
        self._check_ancestry()

    def _check_ancestry(self) -> None:
        for witness in self.ancestors:
            info = os.fstat(witness.fd)
            require(identity(info)[:5] == witness.saved[:5]
                    and info.st_uid == 0 and info.st_gid == 0
                    and not stat.S_IMODE(info.st_mode) & 0o022, "unsafe_ancestor")
            no_acl(witness.fd)
            if witness.name:
                self._binding(witness, directory=True, ancestor=True)

    def _binding(self, witness: _Witness, *, directory: bool,
                 ancestor: bool = False) -> None:
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOATIME
        if directory:
            flags |= os.O_DIRECTORY
        fd = os.open(witness.name, flags, dir_fd=witness.parent)
        try:
            actual = identity(os.fstat(fd))
            require((actual[:5] == witness.saved[:5] if ancestor else
                     actual == witness.saved)
                    and self._mount(fd) == self._mount(witness.fd), "named_binding")
        finally:
            os.close(fd)

    def _file(self, parent: int, name: str, limit: int) -> bytes:
        witness = self._open(parent, name, False)
        witness.data = self._read(witness.fd, limit)
        require(identity(os.fstat(witness.fd)) == witness.saved, "file_changed")
        return witness.data

    def recheck(self, *, added: frozenset[str] = frozenset(),
                removed: frozenset[str] = frozenset(), read_bytes: bool = True) -> None:
        """Exact own-name deltas only; never absorb new foreign evidence."""
        root = identity(os.fstat(self.root))
        self._check_ancestry()
        require(root[:5] == self.root_identity[:5], "root_changed")
        self._trust(self.root, os.fstat(self.root), True)
        require(names(self.root, ROOT_ENTRIES) == (self.root_names - removed) | added,
                "root_inventory_changed")
        self.bytes_read = 0
        for witness in self.opaque:
            require(identity(os.fstat(witness.fd)) == witness.saved
                    and identity(os.stat(witness.name, dir_fd=witness.parent,
                                         follow_symlinks=False)) == witness.saved,
                    "opaque_changed")
            self._binding(witness, directory=True)
        for witness in self.witnesses:
            require(identity(os.fstat(witness.fd)) == witness.saved
                    and identity(os.stat(witness.name, dir_fd=witness.parent,
                                         follow_symlinks=False)) == witness.saved,
                    "witness_changed")
            self._binding(witness, directory=witness.children is not None)
            self._trust(witness.fd, os.fstat(witness.fd), witness.children is not None)
            if witness.children is not None:
                require(names(witness.fd, DESCENDANT_ENTRIES) == witness.children,
                        "descendants_changed")
            elif read_bytes:
                require(self._read(witness.fd, len(witness.data)) == witness.data,
                        "bytes_changed")
                require(identity(os.fstat(witness.fd)) == witness.saved, "file_changed")
        require(names(self.root, ROOT_ENTRIES) == (self.root_names - removed) | added,
                "root_inventory_changed")

    def close(self) -> None:
        for witness in reversed(self.witnesses + self.opaque + self.ancestors):
            os.close(witness.fd)
        self.witnesses.clear()
        self.opaque.clear()
        self.ancestors.clear()
        if self.root is not None:
            os.close(self.root)
            self.root = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def _record_file(path: str, limit: int) -> bytes:
    """Producer CLI validates format only; Inventory owns admission trust."""
    if path == "-":
        import sys
        data = sys.stdin.buffer.read(limit + 1)
        require(len(data) <= limit, "file_budget")
        return data
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOATIME)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_size <= limit, "file_budget")
        data = os.pread(fd, limit + 1, 0)
        require(len(data) == before.st_size and len(data) <= limit
                and identity(before) == identity(os.fstat(fd)),
                "record_changed")
        return data
    finally:
        os.close(fd)


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description="Read-only producer record validation")
    sub = parser.add_subparsers(dest="mode", required=True)
    producer_beta = sub.add_parser("producer-beta-filter")
    producer_beta.add_argument("kind", choices=tuple(PRODUCER_BETA_FILTERS))
    sub.add_parser("producer-smtp-schema")
    beta = sub.add_parser("beta-journal")
    beta.add_argument("path")
    incident = sub.add_parser("beta-incident")
    incident.add_argument("path")
    incident.add_argument("recovery_id")
    incident.add_argument("phase")
    smtp = sub.add_parser("smtp-generation")
    smtp.add_argument("name")
    smtp.add_argument("env")
    smtp.add_argument("manifest")
    smtp.add_argument("env_digest")
    smtp.add_argument("config_digest")
    manifest = sub.add_parser("smtp-manifest")
    manifest.add_argument("name")
    manifest.add_argument("manifest")
    manifest.add_argument("env_digest")
    manifest.add_argument("config_digest")
    args = parser.parse_args()
    try:
        if args.mode == "producer-beta-filter":
            print(PRODUCER_BETA_FILTERS[args.kind])
        elif args.mode == "producer-smtp-schema":
            for key, pattern in PRODUCER_SMTP_SCHEMA:
                print(f"{key}\t{pattern}")
        elif args.mode == "beta-journal":
            beta_journal(_record_file(args.path, RECORD_BYTES))
        elif args.mode == "beta-incident":
            beta_incident(_record_file(args.path, RECORD_BYTES), args.recovery_id, args.phase)
        elif args.mode == "smtp-generation":
            generation_name(args.name)
            generation_record(args.name, _record_file(args.env, ENV_BYTES),
                              _record_file(args.manifest, RECORD_BYTES),
                              env_digest=args.env_digest, config_digest=args.config_digest)
        else:
            generation_name(args.name)
            generation_record(args.name, b"", _record_file(args.manifest, RECORD_BYTES),
                              env_digest=args.env_digest, config_digest=args.config_digest)
        return 0
    except (Rejected, OSError, ValueError):
        # Never include parsed input, credentials, manifests, or hashes.
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
