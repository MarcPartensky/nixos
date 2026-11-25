#!/usr/bin/env python3
"""pqbox: encrypted dumps to a post-quantum public key (ML-KEM-768).

Schema (suite 1), identical to the previous Go version so that the archives
and keys already produced stay readable:
  - Hybrid KEM  : ML-KEM-768 (FIPS 203) + ephemeral X25519
  - KDF         : HKDF-SHA256 over (ss_mlkem || ss_x25519), info "pqbox v1"
  - Encryption  : AES-256-GCM per 1 MiB chunks, nonce = prefix(8) || counter(4)
  - Private key : sealed by PBKDF2-HMAC-SHA256 (1 000 000 iterations) + AES-GCM

Transport: paramiko (SFTP + exec), with reading of ~/.ssh/config, ProxyJump,
retries and atomic upload. No call to ssh/scp/rsync.

Commands:
  keygen, seal, reseal, pub, encrypt, decrypt, inspect, selftest,
  backup <coeur|volume|mortes|all>, check, test-ssh
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import getpass
import hashlib
import json
import os
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import paramiko
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import mlkem, x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

HERE = Path(__file__).resolve().parent

MAGIC = b"PQB1"
SUITE = 1
CHUNK = 1 << 20
NONCE_PREFIX = 8
PUB_MAGIC = "pqbox-public-key-v1"
KEY_MAGIC = "pqbox-private-key-v1"
X25519_SIZE = 32
MLKEM_EK = 1184
MLKEM_CT = 1088
MLKEM_SEED = 64
PBKDF2_ITER = 1_000_000
HKDF_INFO = b"pqbox v1"
HEADER_LEN = 4 + 1 + 4 + 32 + X25519_SIZE + MLKEM_CT + NONCE_PREFIX
TAG = 16


# --------------------------------------------------------------------------
# keys
# --------------------------------------------------------------------------
class KeyError_(Exception):
    pass


@dataclass
class PublicKey:
    x: bytes
    mlkem: mlkem.MLKEM768PublicKey

    def raw(self) -> bytes:
        return self.x + self.mlkem.public_bytes_raw()

    def fingerprint(self) -> str:
        return hashlib.sha256(self.raw()).hexdigest()[:16]


@dataclass
class PrivateKey:
    x: bytes  # 32 bytes, X25519 private key
    seed: bytes  # 64 bytes, ML-KEM-768 seed

    @property
    def mlkem(self) -> mlkem.MLKEM768PrivateKey:
        return mlkem.MLKEM768PrivateKey.from_seed_bytes(self.seed)

    def raw(self) -> bytes:
        return self.x + self.seed


def new_keypair() -> tuple[PublicKey, PrivateKey]:
    xk = x25519.X25519PrivateKey.generate()
    seed = mlkem.MLKEM768PrivateKey.generate().private_bytes_raw()
    priv = PrivateKey(x=xk.private_bytes_raw(), seed=seed)
    return public_of(priv), priv


def public_of(priv: PrivateKey) -> PublicKey:
    return PublicKey(
        x=x25519.X25519PrivateKey.from_private_bytes(priv.x).public_key().public_bytes_raw(),
        mlkem=priv.mlkem.public_key(),
    )


def parse_public(raw: bytes) -> PublicKey:
    if len(raw) != X25519_SIZE + MLKEM_EK:
        raise KeyError_(f"public key: {len(raw)} bytes, expected {X25519_SIZE + MLKEM_EK}")
    return PublicKey(x=raw[:X25519_SIZE], mlkem=mlkem.MLKEM768PublicKey.from_public_bytes(raw[X25519_SIZE:]))


def parse_private(raw: bytes) -> PrivateKey:
    if len(raw) != X25519_SIZE + MLKEM_SEED:
        raise KeyError_(f"private key: {len(raw)} bytes, expected {X25519_SIZE + MLKEM_SEED}")
    return PrivateKey(x=raw[:X25519_SIZE], seed=raw[X25519_SIZE:])


def write_public(path: Path, pub: PublicKey) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{PUB_MAGIC}\n{base64.b64encode(pub.raw()).decode()}\n")
    path.chmod(0o644)


def load_public(path: Path) -> PublicKey:
    lines = path.read_text().strip().splitlines()
    if len(lines) != 2 or lines[0].strip() != PUB_MAGIC:
        raise KeyError_(f"{path}: unknown public key format")
    return parse_public(base64.b64decode(lines[1].strip()))


def seal_private(path: Path, priv: PrivateKey, passphrase: str) -> None:
    salt = os.urandom(32)
    nonce = os.urandom(12)
    kek = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=PBKDF2_ITER).derive(
        passphrase.encode()
    )
    ct = AESGCM(kek).encrypt(nonce, priv.raw(), KEY_MAGIC.encode())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                KEY_MAGIC,
                f"iter {PBKDF2_ITER}",
                f"salt {base64.b64encode(salt).decode()}",
                f"nonce {base64.b64encode(nonce).decode()}",
                f"data {base64.b64encode(ct).decode()}",
                "",
            ]
        )
    )
    path.chmod(0o600)


def unseal_private(path: Path, passphrase: str) -> PrivateKey:
    lines = path.read_text().strip().splitlines()
    if not lines or lines[0].strip() != KEY_MAGIC:
        raise KeyError_(f"{path}: unknown private key format")
    fields = {}
    for line in lines[1:]:
        parts = line.split(" ", 1)
        if len(parts) == 2:
            fields[parts[0]] = parts[1]
    try:
        iterations = int(fields["iter"])
        salt = base64.b64decode(fields["salt"])
        nonce = base64.b64decode(fields["nonce"])
        ct = base64.b64decode(fields["data"])
    except (KeyError, ValueError) as exc:
        raise KeyError_(f"{path}: unreadable key file ({exc})") from exc
    if iterations < 100_000:
        raise KeyError_("key file: suspicious number of iterations")
    kek = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=iterations).derive(
        passphrase.encode()
    )
    try:
        raw = AESGCM(kek).decrypt(nonce, ct, KEY_MAGIC.encode())
    except InvalidTag as exc:
        raise KeyError_("incorrect password or tampered key file") from exc
    return parse_private(raw)


# --------------------------------------------------------------------------
# archive
# --------------------------------------------------------------------------
@dataclass
class Header:
    chunk: int
    salt: bytes
    ephemeral: bytes
    kem_ct: bytes
    nonce_prefix: bytes
    raw: bytes = field(default=b"", repr=False)


def _derive_key(mlkem_ss: bytes, x25519_ss: bytes, salt: bytes) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(), length=32, salt=salt, info=HKDF_INFO
    ).derive(mlkem_ss + x25519_ss)


def _chunk_aad(header: bytes, index: int, last: bool) -> bytes:
    return header + index.to_bytes(4, "big") + (b"\x01" if last else b"\x00")


def _chunk_nonce(prefix: bytes, index: int) -> bytes:
    return prefix + index.to_bytes(4, "big")


def encrypt_stream(pub: PublicKey, src, dst) -> int:
    eph = x25519.X25519PrivateKey.generate()
    x25519_ss = eph.exchange(x25519.X25519PublicKey.from_public_bytes(pub.x))
    mlkem_ss, kem_ct = pub.mlkem.encapsulate()
    if len(kem_ct) != MLKEM_CT:
        raise RuntimeError(f"ML-KEM ciphertext of {len(kem_ct)} bytes, expected {MLKEM_CT}")
    salt = os.urandom(32)
    key = _derive_key(mlkem_ss, x25519_ss, salt)
    aead = AESGCM(key)
    prefix = os.urandom(NONCE_PREFIX)
    header = (
        MAGIC
        + bytes([SUITE])
        + CHUNK.to_bytes(4, "big")
        + salt
        + eph.public_key().public_bytes_raw()
        + kem_ct
        + prefix
    )
    assert len(header) == HEADER_LEN, (len(header), HEADER_LEN)
    dst.write(header)

    written = HEADER_LEN
    index = 0
    pending = None
    while True:
        block = src.read(CHUNK)
        if not block:
            if pending is None:
                blob = aead.encrypt(_chunk_nonce(prefix, index), b"", _chunk_aad(header, index, True))
                dst.write(blob)
                written += len(blob)
            else:
                blob = aead.encrypt(_chunk_nonce(prefix, index), pending, _chunk_aad(header, index, True))
                dst.write(blob)
                written += len(blob)
            return written
        if pending is not None:
            blob = aead.encrypt(_chunk_nonce(prefix, index), pending, _chunk_aad(header, index, False))
            dst.write(blob)
            written += len(blob)
            index += 1
        pending = block


def decrypt_stream(priv: PrivateKey, src, dst) -> int:
    header = src.read(HEADER_LEN)
    if len(header) != HEADER_LEN:
        raise ValueError("archive too short: incomplete header")
    if header[:4] != MAGIC:
        raise ValueError("this file is not a pqbox archive")
    if header[4] != SUITE:
        raise ValueError(f"unknown suite: {header[4]}")
    chunk = int.from_bytes(header[5:9], "big")
    if not 0 < chunk <= 64 << 20:
        raise ValueError(f"invalid chunk size: {chunk}")
    off = 9
    salt = header[off : off + 32]
    off += 32
    eph = header[off : off + X25519_SIZE]
    off += X25519_SIZE
    kem_ct = header[off : off + MLKEM_CT]
    off += MLKEM_CT
    prefix = header[off : off + NONCE_PREFIX]

    x25519_ss = x25519.X25519PrivateKey.from_private_bytes(priv.x).exchange(
        x25519.X25519PublicKey.from_public_bytes(eph)
    )
    mlkem_ss = priv.mlkem.decapsulate(kem_ct)
    aead = AESGCM(_derive_key(mlkem_ss, x25519_ss, salt))

    ct_size = chunk + TAG
    total = 0
    index = 0
    while True:
        blob = src.read(ct_size)
        if len(blob) == 0:
            raise ValueError("truncated archive: no final chunk")
        if len(blob) < ct_size:
            last = True
        else:
            probe = src.read(1)
            if probe == b"":
                last = True
            else:
                # put the byte back at the head for the next chunk
                src = _Unreader(src, probe)
                last = False
        if len(blob) < TAG:
            raise ValueError("invalid chunk")
        aad = _chunk_aad(header, index, last)
        try:
            plain = aead.decrypt(_chunk_nonce(prefix, index), blob, aad)
        except InvalidTag as exc:
            raise ValueError(
                f"authentication of chunk {index} failed (wrong key, tampered or truncated archive)"
            ) from exc
        dst.write(plain)
        total += len(plain)
        index += 1
        if last:
            if src.read(1) != b"":
                raise ValueError("data after the final chunk")
            return total


class _Unreader:
    """Puts one or more bytes back at the head of a stream (the next chunk must be read in full)."""

    def __init__(self, stream, *prefix: bytes):
        self._stream = stream
        self._buf = bytearray()
        for chunk in prefix:
            self._buf.extend(chunk)

    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            data = bytes(self._buf) + self._stream.read()
            self._buf.clear()
            return data
        if len(self._buf) >= size:
            out = bytes(self._buf[:size])
            del self._buf[:size]
            return out
        out = bytes(self._buf)
        self._buf.clear()
        rest = self._stream.read(size - len(out))
        return out + (rest or b"")


def encrypt_file(pub: PublicKey, src: Path, dst: Path) -> int:
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        return encrypt_stream(pub, fin, fout)


def decrypt_file(priv: PrivateKey, src: Path, dst: Path) -> int:
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        return decrypt_stream(priv, fin, fout)


# --------------------------------------------------------------------------
# SSH (paramiko), reading of ~/.ssh/config
# --------------------------------------------------------------------------
class RemoteError(Exception):
    pass


def parse_ssh_config(path: Path | None = None) -> dict[str, dict]:
    """Minimal parsing of ~/.ssh/config: Host/HostName/User/Port/IdentityFile/ProxyJump."""
    path = path or Path(os.environ.get("SSH_CONFIG", "~/.ssh/config")).expanduser()
    hosts: dict[str, dict] = {}
    current: list[str] = []
    if not path.exists():
        return hosts
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, _, value = line.partition(" ")
        key = key.strip().lower()
        value = value.strip().strip('"')
        if key == "host":
            current = value.split()
            for alias in current:
                hosts.setdefault(alias, {})
        elif current:
            for alias in current:
                if key == "hostname":
                    hosts[alias]["hostname"] = value
                elif key == "user":
                    hosts[alias]["user"] = value
                elif key == "port":
                    hosts[alias]["port"] = int(value)
                elif key == "identityfile":
                    hosts[alias]["identityfile"] = os.path.expanduser(value)
                elif key == "proxyjump":
                    hosts[alias]["proxyjump"] = value
                elif key == "hostkeyalias":
                    hosts[alias]["hostkeyalias"] = value
    return hosts


def resolve_host(alias: str, hosts: dict[str, dict] | None = None) -> dict:
    hosts = hosts if hosts is not None else parse_ssh_config()
    cfg = dict(hosts.get(alias, {}))
    cfg.setdefault("hostname", alias)
    cfg.setdefault("user", getpass.getuser())
    cfg.setdefault("port", 22)
    cfg.setdefault("identityfile", str(Path("~/.ssh/id_ed25519").expanduser()))
    cfg.setdefault("proxyjump", None)
    return cfg


class Remote:
    """Robust SSH connection: timeout, keepalive, retries, atomic upload."""

    def __init__(self, alias: str, path: str = "", accept_new: bool = False, retries: int = 3):
        self.alias = alias
        self.path = path
        self.accept_new = accept_new
        self.retries = retries
        self._client = None
        self._jump = None
        self._sftp = None

    # -- connection --------------------------------------------------------
    def _connect_once(self):
        cfg = resolve_host(self.alias)
        if cfg.get("proxyjump"):
            jump_cfg = resolve_host(cfg["proxyjump"])
            self._jump = self._open(jump_cfg)
            transport = self._jump.get_transport()
            channel = transport.open_channel(
                "direct-tcpip",
                (cfg["hostname"], cfg["port"]),
                (jump_cfg["hostname"], 0),
            )
            self._client = self._open(cfg, sock=channel)
        else:
            self._client = self._open(cfg)
        self._sftp = self._client.open_sftp()

    def _open(self, cfg: dict, sock=None):
        client = paramiko.SSHClient()
        client.load_system_host_keys()
        for known in (Path("~/.ssh/known_hosts").expanduser(),):
            with contextlib.suppress(OSError):
                client.load_host_keys(str(known))
        if self.accept_new:
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        else:
            client.set_missing_host_key_policy(paramiko.RejectPolicy())
        client.connect(
            hostname=cfg["hostname"],
            port=cfg.get("port", 22),
            username=cfg.get("user"),
            key_filename=cfg.get("identityfile"),
            timeout=15,
            banner_timeout=15,
            auth_timeout=15,
            sock=sock,
            allow_agent=False,
            look_for_keys=True,
        )
        client.get_transport().set_keepalive(30)
        return client

    def connect(self):
        last = None
        for attempt in range(1, self.retries + 1):
            try:
                self._connect_once()
                return self
            except Exception as exc:  # noqa: BLE001 - we want the real cause
                last = exc
                self.close()
                if attempt < self.retries:
                    time.sleep(3 * attempt)
        raise RemoteError(f"{self.alias}: connection failed ({last})")

    def close(self):
        for obj in (self._sftp, self._client, self._jump):
            with contextlib.suppress(Exception):
                obj.close()
        self._sftp = self._client = self._jump = None

    def __enter__(self):
        return self.connect()

    def __exit__(self, *exc):
        self.close()

    # -- operations --------------------------------------------------------
    def run(self, command: str) -> str:
        assert self._client is not None, "not connected"
        _, stdout, stderr = self._client.exec_command(command, timeout=300)
        out = stdout.read().decode(errors="replace")
        err = stderr.read().decode(errors="replace")
        code = stdout.channel.recv_exit_status()
        if code != 0:
            raise RemoteError(f"{self.alias}: `{command}` -> code {code}: {err.strip() or out.strip()}")
        return out

    def stream_to(self, command: str, target: Path, timeout: int = 7200) -> None:
        """Runs a remote command and writes its RAW OUTPUT into a local file.

        Used for the dumps (`pg_dump -Fp`) and the state (`tar -c`): nothing passes
        through the process memory, and the file is kept only if the command
        succeeds. stderr is drained in a thread so as not to block the channel
        when the command writes a lot on both streams.
        """
        assert self._client is not None, "not connected"
        _, stdout, stderr = self._client.exec_command(command, timeout=timeout)
        errbuf: list[bytes] = []
        reader = threading.Thread(target=lambda: errbuf.append(stderr.read()), daemon=True)
        reader.start()
        try:
            with open(target, "wb") as handle:
                while True:
                    chunk = stdout.read(1 << 20)
                    if not chunk:
                        break
                    handle.write(chunk)
        except BaseException:
            target.unlink(missing_ok=True)
            raise
        code = stdout.channel.recv_exit_status()
        reader.join(timeout=30)
        if code != 0:
            target.unlink(missing_ok=True)
            err = (b"".join(errbuf)).decode(errors="replace").strip().splitlines()
            raise RemoteError(
                f"{self.alias}: `{command}` -> code {code}: {err[-1] if err else 'no detail'}"
            )

    def remote_dir(self) -> str:
        return self.path

    def put(self, local: Path, name: str | None = None) -> str:
        """Atomic upload: temporary file then rename."""
        assert self._sftp is not None, "not connected"
        remote = f"{self.path.rstrip('/')}/{name or local.name}"
        tmp = f"{remote}.part-{os.getpid()}"
        self._sftp.put(str(local), tmp)
        self._sftp.posix_rename(tmp, remote)
        return remote

    def sha256_check(self, name: str) -> bool:
        try:
            out = self.run(f"cd {shlex.quote(self.path)} && sha256sum -c {shlex.quote(name + '.sha256')}")
        except RemoteError:
            return False
        return ": OK" in out

    def list_archives(self, tier: str) -> list[str]:
        out = self.run(f"ls -1t {self.path.rstrip('/')}/{tier}-*.pqbox 2>/dev/null || true")
        return [line.strip() for line in out.splitlines() if line.strip()]

    def prune(self, tier: str, keep: int) -> list[str]:
        names = self.list_archives(tier)
        removed = []
        for name in names[keep:]:
            base = os.path.basename(name)
            self.run(
                f"cd {shlex.quote(self.path)} && rm -f {shlex.quote(base)} {shlex.quote(base + '.sha256')}"
            )
            removed.append(base)
        return removed


# --------------------------------------------------------------------------
# backup tiers
# --------------------------------------------------------------------------
COEUR_DBS = [
    "nextcloud", "ffsync", "taskq", "postgres", "zitadel", "gitea", "vaultwarden",
    "windmill", "gotify", "hermes", "music", "website", "resume", "reactive-resume", "shlink",
]

# Databases that NO LONGER live on tower: we dump them remotely over ssh, and the
# local dump of the same name is ignored. Since 14/11/2026 the Vaultwarden
# vault (single source of truth) runs on the anywhere VPS; the tower
# database is now only an old copy (vw_old_*), backing it up would give
# false assurance.
REMOTE_DBS = {
    "vaultwarden": "root@rack",
}

# REMOTE execution: the expensive work (multi-database pg_dump, zstd -19 on
# ~1 GB) must be able to run on an idle machine (the laptop) while
# the data stays on tower. We do NOT connect to PostgreSQL over the
# network (its pg_hba refuses anything that is not 127.0.0.1): everything goes through
# SSH in streaming. Empty values = historical behavior, everything local.
PG_REMOTE_HOST = os.environ.get("PG_REMOTE_HOST", "").strip()
STATE_REMOTE_HOST = os.environ.get("STATE_REMOTE_HOST", "").strip()
HERMES_REMOTE_DIR = os.environ.get("HERMES_REMOTE_DIR", "/var/lib/hermes/.hermes")
# Hours. If an archive of the same tier is younger than that, we redo nothing: this is
# what makes tower a simple safety net behind the laptop.
SKIP_IF_FRESH = float(os.environ.get("SKIP_IF_FRESH", "0") or 0)
VOLUME_DBS = ["winnie", "matrix-synapse"]
VOLUME_HERMES = ["state.db", "attachments"]
MORTES_DBS = [
    "root", "wger", "matrix", "wallabag", "focalboard", "authentik", "etherpad",
    "matrix_whatsapp", "matrix_signal", "matrix_messenger", "matrix_slack",
    "matrix_facebook", "matrix_twitter", "matrix_gmessages", "matrix_meta",
    "matrix_discord", "nocodb", "appflowy", "invidious", "n8n", "outline", "strapi",
    "homeassistant", "etesync", "peertube", "grafana", "paperless", "udemy", "kutt",
    "heimdall", "dockerdash", "djankiserv", "mailu", "izitdone", "lorimer_eats",
    "rentscout", "gotrue", "fdroid", "linkwarden", "docuseal", "tokenserver",
    "syncstorage", "owncloud", "yourls", "wikijs", "bookstack", "template1",
]
COEUR_HERMES = [
    "config.yaml", "auth.json", "credentials", "cron", "skills", "sessions", "plugins", "profiles",
]

TIERS = {
    "coeur": dict(zstd=["-19", "--long=27", "-T8"], keep=30, keep_mirror=7, dbs=COEUR_DBS),
    "volume": dict(zstd=["-3", "-T16"], keep=3, keep_mirror=1, dbs=VOLUME_DBS),
    "mortes": dict(zstd=["-12", "-T16"], keep=2, keep_mirror=1, dbs=MORTES_DBS),
}


def _run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kw)


def sha256_file(path: Path, buf_size: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(buf_size)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def pg_databases(psql: str, host: str, user: str) -> list[tuple[str, str]]:
    out = _run(
        [psql, "-h", host, "-U", user, "-d", "postgres", "-tAc",
         "select datname || ' ' || pg_size_pretty(pg_database_size(datname)) "
         "from pg_database order by pg_database_size(datname) desc"],
        capture_output=True, text=True,
    ).stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(" ", 1)
        if len(parts) == 2:
            rows.append((parts[0], parts[1]))
    return rows


def remote_databases(remote: "Remote") -> list[tuple[str, str]]:
    """Remote equivalent of pg_databases (the source host does not expose PG on the network)."""
    sql = ("select datname || ' ' || pg_size_pretty(pg_database_size(datname)) "
           "from pg_database order by pg_database_size(datname) desc")
    out = remote.run(f"psql -h 127.0.0.1 -U root -d postgres -w -tAc {shlex.quote(sql)}")
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(" ", 1)
        if len(parts) == 2:
            rows.append((parts[0], parts[1]))
    return rows


def remote_existing(remote: "Remote", base: str, names: list[str]) -> list[str]:
    """Lists the names that REALLY exist on the remote host.

    The direct `tar -c` exits with code 2 if one of the names does not exist (observation:
    `auth.json` does not exist on tower) and with code 1 on an ignored socket
    (`profiles/discord-bridge/gateway.sock`), while the local branch silently
    ignores both. We reproduce this behavior: names filtered here,
    and `--warning=no-file-ignored` on the tar command.
    """
    listing = " ".join(shlex.quote(n) for n in names)
    cmd = (
        f"for n in {listing}; do [ -e {shlex.quote(base)}/\"$n\" ] && printf '%s\\n' \"$n\"; done; true"
    )
    return [line.strip() for line in remote.run(cmd).splitlines() if line.strip()]


def build_manifest(tier: str, stage: Path, cfg: dict, compression: str, psql: str) -> Path:
    entries = {}
    for path in sorted(stage.iterdir()):
        if path.name.startswith("MANIFEST") or path.name == "manifest.json":
            continue
        entries[path.name] = {"octets": path.stat().st_size, "sha256": sha256_file(path)}
    manifest = {
        "tier": tier,
        "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "host": os.uname().nodename,
        "outil": "pqbox 2.0.0 (python, cryptography + paramiko)",
        "chiffrement": "ML-KEM-768 + X25519, HKDF-SHA256, AES-256-GCM (chunks 1 MiB)",
        "compression": compression,
        "fichiers": entries,
        "bases": cfg.get("databases", []),
    }
    path = stage / "manifest.json"
    path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n")
    return path


def make_tar(stage: Path, out: Path) -> None:
    with tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as tar:
        for path in sorted(stage.iterdir()):
            tar.add(path, arcname=path.name)


def compress(src: Path, dst: Path, flags: list[str]) -> None:
    _run(["zstd", *flags, "-q", "-f", str(src), "-o", str(dst)])


def do_tier(tier: str, cfg: dict, outdir: Path, rack: str, mirror: str, no_rack: bool,
            keep_override: int | None, mirror_volume: bool, psql: str, pgdump: str, hermes: Path,
            accept_new: bool = False) -> Path:
    spec = TIERS[tier]
    keep = keep_override or int(os.environ.get(f"KEEP_{tier.upper()}", spec["keep"]))
    keep_mirror = int(os.environ.get("KEEP_MIRROR", spec["keep_mirror"]))
    # Safety net: this pass is pointless if an archive of the same tier
    # was just produced elsewhere (typically by the laptop).
    if SKIP_IF_FRESH > 0:
        recent = sorted(outdir.glob(f"{tier}-*.pqbox"), key=lambda p: p.stat().st_mtime, reverse=True)
        if recent:
            age_h = (time.time() - recent[0].stat().st_mtime) / 3600
            if age_h < SKIP_IF_FRESH:
                print(f"[{tier}] recent archive ({recent[0].name}, {age_h:.1f} h < {SKIP_IF_FRESH:g} h): nothing to do")
                return recent[0]
    stamp = time.strftime("%Y-%m-%dT%H%M")
    work = outdir / f".work-{tier}-{stamp}"
    stage = work / "stage"
    stage.mkdir(parents=True, exist_ok=True)
    pg_src = Remote(PG_REMOTE_HOST) if PG_REMOTE_HOST else None
    state_src = Remote(STATE_REMOTE_HOST) if STATE_REMOTE_HOST else None
    try:
        if pg_src is not None:
            print(f"[{tier}] remote PostgreSQL source: {PG_REMOTE_HOST}")
            pg_src.connect()
        if state_src is not None:
            print(f"[{tier}] remote Hermes state: {STATE_REMOTE_HOST}:{HERMES_REMOTE_DIR}")
            state_src.connect()
        print(f"[{tier}] dumping databases")
        dump_cfg = {}
        failed: list[str] = []
        for db in spec["dbs"]:
            target = stage / f"{db}.sql"
            # REMOTE_DBS BEFORE the remote source: `vaultwarden` no longer lives on
            # tower, and dumped from tower it would be the OLD copy (942
            # elements instead of the 1000 of the VPS instance).
            if db in REMOTE_DBS:
                remote = REMOTE_DBS[db]
                with open(target, "wb") as handle:
                    result = subprocess.run(
                        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", remote,
                         f"sudo -u postgres pg_dump -w -Fp --clean --if-exists -d {db}"],
                        stdout=handle, stderr=subprocess.PIPE, text=False,
                    )
                stderr = (result.stderr or b"").decode(errors="replace").strip()
                if result.returncode != 0:
                    target.unlink(missing_ok=True)
                    print(f"  !! {db} ({remote}): {stderr.splitlines()[-1] if stderr else 'failure'}")
                    failed.append(db)
                    continue
                print(f"  {db} ({remote}) {target.stat().st_size / 1e6:.1f} MB")
                continue
            if pg_src is not None:
                # everything comes from the remote host, in streaming, without exposing PG
                try:
                    pg_src.stream_to(
                        f"pg_dump -h 127.0.0.1 -U root -w -Fp --clean --if-exists -d {shlex.quote(db)}",
                        target,
                    )
                except RemoteError as exc:
                    print(f"  !! {db} ({PG_REMOTE_HOST}): {exc}")
                    failed.append(db)
                    continue
                print(f"  {db} ({PG_REMOTE_HOST}) {target.stat().st_size / 1e6:.1f} MB")
                continue
            result = subprocess.run(
                [pgdump, "-h", "127.0.0.1", "-U", "root", "-Fp", "--clean", "--if-exists",
                 "-f", str(target), db],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                target.unlink(missing_ok=True)
                print(f"  !! {db}: {result.stderr.strip().splitlines()[-1] if result.stderr else 'failure'}")
                failed.append(db)
                continue
            print(f"  {db} {target.stat().st_size / 1e6:.1f} MB")
        if failed:
            print(f"  !! WARNING: {len(failed)} database(s) missing from the archive: {', '.join(failed)}")
        dump_cfg["bases_en_echec"] = failed
        if tier == "coeur":
            if pg_src is not None:
                dump_cfg["databases"] = remote_databases(pg_src)
            else:
                dump_cfg["databases"] = pg_databases(psql, "127.0.0.1", "root")
        else:
            dump_cfg["databases"] = []

        if tier == "coeur":
            roles_sql = "select rolname, rolcanlogin, rolsuper from pg_roles order by 1"
            if pg_src is not None:
                (stage / "roles.txt").write_text(
                    pg_src.run(f"psql -h 127.0.0.1 -U root -d postgres -w -tAc {shlex.quote(roles_sql)}")
                )
            else:
                (stage / "roles.txt").write_text(
                    _run([psql, "-h", "127.0.0.1", "-U", "root", "-d", "postgres", "-tAc", roles_sql],
                         capture_output=True, text=True).stdout
                )
            if state_src is not None:
                present = remote_existing(state_src, HERMES_REMOTE_DIR, COEUR_HERMES)
                if present:
                    names = " ".join(shlex.quote(n) for n in present)
                    state_src.stream_to(
                        f"tar -C {shlex.quote(HERMES_REMOTE_DIR)} -c --warning=no-file-ignored {names}", stage / "hermes-etat.tar"
                    )
                else:
                    print(f"  !! empty Hermes state on {STATE_REMOTE_HOST}")
            else:
                with tarfile.open(stage / "hermes-etat.tar", "w") as tar:
                    for name in COEUR_HERMES:
                        path = hermes / name
                        if path.exists():
                            tar.add(path, arcname=name)
        elif tier == "volume":
            if state_src is not None:
                present = remote_existing(state_src, HERMES_REMOTE_DIR, VOLUME_HERMES)
                if present:
                    names = " ".join(shlex.quote(n) for n in present)
                    state_src.stream_to(
                        f"tar -C {shlex.quote(HERMES_REMOTE_DIR)} -c --warning=no-file-ignored {names}", stage / "hermes-lourd.tar"
                    )
                else:
                    print(f"  !! empty Hermes state on {STATE_REMOTE_HOST}")
            else:
                with tarfile.open(stage / "hermes-lourd.tar", "w") as tar:
                    for name in VOLUME_HERMES:
                        path = hermes / name
                        if path.exists():
                            tar.add(path, arcname=name)

        compression = " ".join(spec["zstd"])
        build_manifest(tier, stage, dump_cfg, f"zstd {compression}", psql)

        print(f"[{tier}] archive + encryption")
        tar_path = work / "payload.tar"
        make_tar(stage, tar_path)
        zst_path = work / "payload.tar.zst"
        compress(tar_path, zst_path, spec["zstd"])
        tar_path.unlink()
        archive = outdir / f"{tier}-{stamp}.pqbox"
        encrypt_file(load_public(PUB_PATH), zst_path, archive)
        archive.chmod(0o644)
        zst_path.unlink()
        digest = sha256_file(archive)
        (outdir / f"{archive.name}.sha256").write_text(f"{digest}  {archive.name}\n")
        print(f"  -> {archive} ({archive.stat().st_size / 1e6:.0f} MB)")
        print(f"     sha256 {digest}")

        # main destination
        if rack and not no_rack:
            _ship(rack, archive, accept_new, keep=keep, tier=tier, label="rack")
        # secondary mirror, best-effort
        if mirror and (tier != "volume" or mirror_volume):
            _ship(mirror, archive, accept_new, keep=keep_mirror, tier=tier, label="mirror",
                  best_effort=True)

        # local retention
        local = sorted(outdir.glob(f"{tier}-*.pqbox"), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in local[keep:]:
            print(f"     local retention: {old.name}")
            old.unlink()
            (outdir / f"{old.name}.sha256").unlink(missing_ok=True)
        return archive
    finally:
        for remote in (pg_src, state_src):
            if remote is not None:
                remote.close()
        shutil.rmtree(work, ignore_errors=True)


def _ship(target: str, archive: Path, accept_new: bool, keep: int, tier: str, label: str,
          best_effort: bool = False) -> None:
    alias, _, path = target.partition(":")
    if not alias:
        return
    path = path or "."
    try:
        with Remote(alias, path, accept_new=accept_new) as remote:
            remote.put(archive)
            remote.put(Path(str(archive) + ".sha256"))
            if remote.sha256_check(archive.name):
                print(f"     {label}: {archive.name} verified on {alias}")
            else:
                print(f"     {label}: copy made on {alias}, remote sha256 NOT verified")
                if not best_effort:
                    raise RemoteError(f"{alias}: invalid remote sha256")
            removed = remote.prune(tier, keep)
            for name in removed:
                print(f"     {label}: retention -> {name}")
    except RemoteError as exc:
        if best_effort:
            print(f"     {label}: {exc}")
            return
        raise


# --------------------------------------------------------------------------
# password
# --------------------------------------------------------------------------
def prompt_passphrase(prompt: str) -> str:
    if not sys.stdin.isatty():
        raise SystemExit("pqbox: password requested outside a terminal (use --insecure-passphrase-file)")
    return getpass.getpass(prompt)


def prompt_new_passphrase() -> str:
    first = prompt_passphrase("Password (not displayed): ")
    if len(first) < 12:
        raise SystemExit("pqbox: password too short (20 characters or 6 words minimum)")
    second = prompt_passphrase("Confirmation: ")
    if first != second:
        raise SystemExit("pqbox: the two entries differ")
    return first


def resolve_passphrase(args) -> str:
    insecure = getattr(args, "insecure_passphrase_file", None)
    if insecure:
        return Path(insecure).read_text().strip()
    return prompt_passphrase("Password: ")


# --------------------------------------------------------------------------
# selftest
# --------------------------------------------------------------------------
def selftest(go_binary: Path | None = None) -> None:
    def fail(message: str) -> None:
        print(f"FAILURE: {message}", file=sys.stderr)
        raise SystemExit(1)

    pub, priv = new_keypair()
    if parse_public(pub.raw()).raw() != pub.raw():
        fail("public key round-trip")
    with tempfile.TemporaryDirectory() as tmp:
        keyfile = Path(tmp) / "k.key"
        seal_private(keyfile, priv, "correct horse battery staple")
        if unseal_private(keyfile, "correct horse battery staple").raw() != priv.raw():
            fail("sealing/unsealing")
        try:
            unseal_private(keyfile, "wrong password")
            fail("a wrong password was accepted")
        except KeyError_:
            pass

        for size in (0, 1, 15, 1000, CHUNK - 1, CHUNK, CHUNK + 1, 3 * CHUNK + 7):
            plain = os.urandom(size)
            box = Path(tmp) / "a.pqbox"
            out = Path(tmp) / "a.out"
            with open(box, "wb") as handle:
                encrypt_stream(pub, _BytesIO(plain), handle)
            with open(out, "wb") as handle:
                decrypt_stream(priv, open(box, "rb"), handle)
            if out.read_bytes() != plain:
                fail(f"round-trip {size} bytes")
            if size:
                blob = bytearray(box.read_bytes())
                blob[HEADER_LEN + size // 2] ^= 0x01
                try:
                    decrypt_stream(priv, _BytesIO(bytes(blob)), _Discard())
                    fail(f"tampering not detected ({size})")
                except ValueError:
                    pass
            if box.stat().st_size > HEADER_LEN + 1:
                try:
                    decrypt_stream(priv, _BytesIO(box.read_bytes()[:-1]), _Discard())
                    fail(f"truncation not detected ({size})")
                except ValueError:
                    pass
            other_pub, other_priv = new_keypair()
            del other_pub
            try:
                decrypt_stream(other_priv, _BytesIO(box.read_bytes()), _Discard())
                fail("decryption accepted with a wrong key")
            except ValueError:
                pass

    if go_binary and go_binary.exists():
        _selftest_interop(go_binary, fail)

    print("selftest OK: ML-KEM-768 + X25519, chunked AES-256-GCM, PBKDF2 sealing,")
    print("             tampering/truncation/wrong key refused")
    if go_binary:
        print("             binary compatibility with the Go version (round-trip in both directions)")


def _selftest_interop(go_binary: Path, fail) -> None:
    """An archive produced by one implementation must be readable by the other."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        passfile = tmp / "pass"
        passfile.write_text("interop passphrase\n")
        subprocess.run(
            [str(go_binary), "keygen", "--pub", str(tmp / "go.pub"), "--key", str(tmp / "go.key"),
             "--insecure-passphrase-file", str(passfile)], check=True, capture_output=True,
        )
        go_pub = load_public(tmp / "go.pub")
        go_priv = unseal_private(tmp / "go.key", "interop passphrase")
        if public_of(go_priv).raw() != go_pub.raw():
            fail("Go public key != key derived from the Go private key")
        payload = os.urandom(2 * CHUNK + 333)
        # Python encrypts -> Go decrypts
        py_box = tmp / "py.pqbox"
        with open(py_box, "wb") as handle:
            encrypt_stream(go_pub, _BytesIO(payload), handle)
        result = subprocess.run(
            [str(go_binary), "decrypt", "--key", str(tmp / "go.key"), "--in", str(py_box),
             "--out", str(tmp / "py.out"), "--insecure-passphrase-file", str(passfile)],
            capture_output=True,
        )
        if result.returncode != 0 or (tmp / "py.out").read_bytes() != payload:
            fail(f"Go could not decrypt a Python archive ({result.stderr.decode()[:200]})")
        # Go encrypts -> Python decrypts
        (tmp / "payload.bin").write_bytes(payload)
        go_box = tmp / "go.pqbox"
        result = subprocess.run(
            [str(go_binary), "encrypt", "--recipient", str(tmp / "go.pub"),
             "--in", str(tmp / "payload.bin"), "--out", str(go_box)],
            capture_output=True,
        )
        if result.returncode != 0:
            fail(f"Go could not encrypt ({result.stderr.decode()[:200]})")
        with open(go_box, "rb") as src, open(tmp / "go.out", "wb") as handle:
            decrypt_stream(go_priv, src, handle)
        if (tmp / "go.out").read_bytes() != payload:
            fail("Python could not decrypt a Go archive")


class _BytesIO:
    def __init__(self, data: bytes):
        self._data = data
        self._pos = 0
        self._extra = bytearray()

    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            out = self._data[self._pos:] + bytes(self._extra)
            self._pos = len(self._data)
            self._extra.clear()
            return out
        out = self._data[self._pos:self._pos + size]
        self._pos += len(out)
        if len(out) < size and self._extra:
            need = size - len(out)
            out += bytes(self._extra[:need])
            del self._extra[:need]
        return out

    def write(self, data: bytes) -> int:
        self._extra.extend(data)
        return len(data)

    def value(self) -> bytes:
        return self._data[self._pos:] + bytes(self._extra)


class _Discard:
    def write(self, data: bytes) -> int:
        return len(data)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
# The public file is deployed next to the script in the store, but when the
# script is copied ALONE (pqbox.py is a dedicated store path, without a
# neighboring backup.pub), HERE/"backup.pub" equals /nix/store/backup.pub and EVERY
# encryption fails with FileNotFoundError AFTER the full dump: verified on
# 14/11/2026, the coeur passes of the 12th, 13th and 14th burned ~21 min of dump
# then failed. The PUB variable set by the systemd module must therefore win.
PUB_PATH = Path(os.environ.get("PUB") or (HERE / "backup.pub"))
DEFAULT_OUTDIR = Path("/var/lib/hermes/backups/pqbox")
DEFAULT_RACK = "rack:/var/backups/pqbox"
DEFAULT_MIRROR = "mac:backups-pqbox"
HERMES = Path("/var/lib/hermes/.hermes")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pqbox", description=__doc__.splitlines()[0])
    parser.add_argument("--pub", default=os.environ.get("PUB", str(PUB_PATH)),
                        help="public key file (default: %(default)s)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("keygen", help="creates the key pair and seals the private key")
    p.add_argument("--pub", dest="pub_out", default="backup.pub")
    p.add_argument("--key", dest="key_out", default=None)
    p.add_argument("--force", action="store_true")
    p.add_argument("--insecure-passphrase-file", default=None)

    p = sub.add_parser("seal", help="seals a plaintext private key")
    p.add_argument("--in", dest="src", required=True)
    p.add_argument("--out", dest="dst", required=True)
    p.add_argument("--insecure-passphrase-file", default=None)

    p = sub.add_parser("reseal", help="changes the password of a sealed key")
    p.add_argument("--key", required=True)
    p.add_argument("--out", default=None)

    p = sub.add_parser("pub", help="re-displays the public key of a sealed key")
    p.add_argument("--key", required=True)

    p = sub.add_parser("encrypt", help="encrypts a file to a public key")
    p.add_argument("--recipient", default=None)
    p.add_argument("--in", dest="src", default="-")
    p.add_argument("--out", dest="dst", default="-")

    p = sub.add_parser("decrypt", help="decrypts an archive")
    p.add_argument("--key", required=True)
    p.add_argument("--in", dest="src", default="-")
    p.add_argument("--out", dest="dst", default="-")
    p.add_argument("--insecure-passphrase-file", default=None)

    p = sub.add_parser("inspect", help="displays the header of an archive")
    p.add_argument("--in", dest="src", default="-")

    p = sub.add_parser("selftest", help="encryption, tampering and interop tests")
    p.add_argument("--go-binary", default=os.environ.get("PQBOX_GO", ""))

    p = sub.add_parser("backup", help="builds and publishes a tier")
    p.add_argument("tier", choices=["coeur", "volume", "mortes", "all"])
    p.add_argument("--outdir", default=os.environ.get("OUTDIR", str(DEFAULT_OUTDIR)))
    p.add_argument("--rack", default=os.environ.get("RACK", DEFAULT_RACK))
    p.add_argument("--mirror", default=os.environ.get("MIRROR", DEFAULT_MIRROR))
    p.add_argument("--keep", type=int, default=None)
    p.add_argument("--no-rack", action="store_true", default=os.environ.get("NO_RACK") == "1")
    p.add_argument("--mirror-volume", action="store_true", default=os.environ.get("MIRROR_VOLUME") == "1")
    p.add_argument("--hermes", default=str(HERMES))
    p.add_argument("--psql", default=os.environ.get("PSQL", "psql"))
    p.add_argument("--pg-dump", default=os.environ.get("PG_DUMP", "pg_dump"))
    p.add_argument("--ssh-accept-new", action="store_true")

    p = sub.add_parser("check", help="verifies the sha256 of a remote destination")
    p.add_argument("target", help="alias:chemin (ex: rack:/var/backups/pqbox)")
    p.add_argument("--tier", default=None)
    p.add_argument("--ssh-accept-new", action="store_true")

    p = sub.add_parser("test-ssh", help="tests a destination: mkdir, upload, sha256, deletion")
    p.add_argument("target")
    p.add_argument("--ssh-accept-new", action="store_true")

    args = parser.parse_args(argv)

    if args.command == "keygen":
        key_path = Path(args.key_out or str(Path(args.pub_out).with_suffix("")) + ".key")
        if not args.force:
            for path in (Path(args.pub_out), key_path):
                if path.exists():
                    raise SystemExit(f"pqbox: {path} already exists (--force to overwrite)")
        pub, priv = new_keypair()
        passphrase = (
            Path(args.insecure_passphrase_file).read_text().strip()
            if args.insecure_passphrase_file
            else prompt_new_passphrase()
        )
        seal_private(key_path, priv, passphrase)
        write_public(Path(args.pub_out), pub)
        print(f"public key : {args.pub_out}")
        print(f"private key  : {key_path} (sealed, 0600)")
        print(f"fingerprint  : {pub.fingerprint()}")
        return 0

    if args.command == "seal":
        raw = base64.b64decode(Path(args.src).read_text().strip())
        priv = parse_private(raw)
        passphrase = (
            Path(args.insecure_passphrase_file).read_text().strip()
            if args.insecure_passphrase_file
            else prompt_new_passphrase()
        )
        seal_private(Path(args.dst), priv, passphrase)
        print(f"sealed key: {args.dst}")
        return 0

    if args.command == "reseal":
        old = prompt_passphrase("Old password: ")
        priv = unseal_private(Path(args.key), old)
        new = prompt_new_passphrase()
        seal_private(Path(args.out or args.key), priv, new)
        print(f"resealed key: {args.out or args.key}")
        return 0

    if args.command == "pub":
        priv = unseal_private(Path(args.key), prompt_passphrase("Password: "))
        print(f"{PUB_MAGIC}\n{base64.b64encode(public_of(priv).raw()).decode()}")

    if args.command == "encrypt":
        pub = load_public(Path(args.recipient or args.pub))
        src = sys.stdin.buffer if args.src == "-" else open(args.src, "rb")
        if args.dst == "-":
            encrypt_stream(pub, src, sys.stdout.buffer)
        else:
            with open(args.dst, "wb") as handle:
                encrypt_stream(pub, src, handle)
        return 0

    if args.command == "decrypt":
        priv = unseal_private(Path(args.key), resolve_passphrase(args))
        src = sys.stdin.buffer if args.src == "-" else open(args.src, "rb")
        if args.dst == "-":
            decrypt_stream(priv, src, sys.stdout.buffer)
        else:
            with open(args.dst, "wb") as handle:
                decrypt_stream(priv, src, handle)
        return 0

    if args.command == "inspect":
        src = sys.stdin.buffer if args.src == "-" else open(args.src, "rb")
        header = src.read(HEADER_LEN)
        if header[:4] != MAGIC:
            raise SystemExit("pqbox: not a pqbox archive")
        print(f"magic   : {MAGIC.decode()}")
        print(f"suite   : {header[4]} (ML-KEM-768 + X25519, HKDF-SHA256, AES-256-GCM)")
        print(f"chunk   : {int.from_bytes(header[5:9], 'big')} bytes")
        print(f"header  : {HEADER_LEN} bytes")
        return 0

    if args.command == "selftest":
        go = Path(args.go_binary) if args.go_binary else None
        selftest(go)
        return 0

    if args.command == "backup":
        outdir = Path(args.outdir)
        outdir.mkdir(parents=True, exist_ok=True)
        tiers = ["coeur", "volume", "mortes"] if args.tier == "all" else [args.tier]
        for tier in tiers:
            do_tier(
                tier,
                cfg={},
                outdir=outdir,
                rack=args.rack,
                mirror=args.mirror,
                no_rack=args.no_rack,
                keep_override=args.keep,
                mirror_volume=args.mirror_volume,
                psql=args.psql,
                pgdump=args.pg_dump,
                hermes=Path(args.hermes),
                accept_new=args.ssh_accept_new,
            )
        print(f"done: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}")
        return 0

    if args.command == "check":
        alias, _, path = args.target.partition(":")
        with Remote(alias, path, accept_new=args.ssh_accept_new) as remote:
            names = remote.list_archives(args.tier) if args.tier else None
            if names is None:
                out = remote.run(f"ls -1 {shlex.quote(path)}/*.pqbox 2>/dev/null || true")
                names = [os.path.basename(line.strip()) for line in out.splitlines() if line.strip()]
            else:
                names = [os.path.basename(n) for n in names]
            for name in names:
                print(f"{'OK ' if remote.sha256_check(name) else 'KO '} {name}")
        return 0

    if args.command == "test-ssh":
        alias, _, path = args.target.partition(":")
        with Remote(alias, path, accept_new=args.ssh_accept_new) as remote:
            with tempfile.TemporaryDirectory() as tmp:
                sample = Path(tmp) / "pqbox-ssh-test.txt"
                sample.write_text("pqbox ssh test\n")
                digest = sha256_file(sample)
                (Path(tmp) / "pqbox-ssh-test.txt.sha256").write_text(
                    f"{digest}  pqbox-ssh-test.txt\n"
                )
                remote.put(sample)
                remote.put(Path(tmp) / "pqbox-ssh-test.txt.sha256")
                ok = remote.sha256_check("pqbox-ssh-test.txt")
                remote.run(f"cd {shlex.quote(path)} && rm -f pqbox-ssh-test.txt pqbox-ssh-test.txt.sha256")
                print(f"{alias}:{path} -> {'OK' if ok else 'invalid remote sha256'}")
                return 0 if ok else 1

    return 2


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        sys.exit(main())
