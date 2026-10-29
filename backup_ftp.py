#!/usr/bin/env python3
"""Quota-aware FTP rotation that always preserves a verified remote backup."""
import argparse
from datetime import datetime, timezone
import ftplib
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import socket
import tempfile


def configuration(path):
    keys = {"SERVER_NAME", "FTP_HOST", "FTP_PORT", "FTP_USER", "FTP_PASS", "FTP_BASE_DIR", "FTP_PROTOCOL", "FTP_QUOTA_BYTES", "FTP_RESERVE_BYTES", "KEEP_DAILY", "KEEP_WEEKLY", "KEEP_MONTHLY", "KEEP_YEARLY", "KEEP_LOCAL", "WORK_DIR"}
    result = {"SERVER_NAME": socket.gethostname().split('.')[0], "FTP_PORT": "21",
              "FTP_BASE_DIR": "/backups", "FTP_PROTOCOL": "ftps",
              "FTP_QUOTA_BYTES": "0", "FTP_RESERVE_BYTES": "10000000000",
              "KEEP_DAILY": "7", "KEEP_WEEKLY": "4", "KEEP_MONTHLY": "6", "KEEP_YEARLY": "2",
              "KEEP_LOCAL": "1", "WORK_DIR": "/var/backups/server-backup"}
    # Parse quoted assignments, including several separated by semicolons,
    # without sourcing a shell or executing substitutions from the config.
    lexer = shlex.shlex(Path(path).read_text(), posix=True, punctuation_chars=';')
    lexer.whitespace_split = True
    for token in lexer:
        key, separator, value = token.partition('=')
        if separator and key in keys:
            result[key] = value
    return result


def connect(c):
    if c["FTP_PROTOCOL"] not in ("ftp", "ftps"):
        raise RuntimeError("Capacity verification supports FTP and explicit FTPS only")
    ftp = ftplib.FTP_TLS(timeout=45) if c["FTP_PROTOCOL"] == "ftps" else ftplib.FTP(timeout=45)
    ftp.connect(c["FTP_HOST"], int(c["FTP_PORT"]))
    ftp.login(c["FTP_USER"], c["FTP_PASS"])
    if isinstance(ftp, ftplib.FTP_TLS):
        ftp.prot_p()
    # This provider uses separate control and passive data hosts.
    ftp.trust_server_pasv_ipv4_address = True
    return ftp


def inventory(ftp):
    pending, visited, files = ["/"], set(), {}
    while pending:
        parent = pending.pop()
        if parent in visited:
            continue
        visited.add(parent)
        lines = []
        ftp.retrlines("LIST " + parent, lines.append)
        for line in lines:
            fields = line.split(maxsplit=8)
            if line.startswith("total "):
                continue
            if len(fields) != 9 or not fields[4].isdigit():
                raise RuntimeError("Unrecognised FTP listing; cannot certify occupied space")
            name = fields[8]
            if name in (".", ".."):
                continue
            if any(ord(c) < 32 for c in name) or "/" in name:
                raise RuntimeError("Unsafe FTP filename; inventory stopped")
            path = parent.rstrip("/") + "/" + name
            if fields[0].startswith("d"):
                pending.append(path)
            elif fields[0].startswith("-"):
                files[path] = int(fields[4])
            else:
                raise RuntimeError("Unsupported FTP entry type; capacity calculation stopped")
        if len(files) > 50000 or len(visited) > 10000:
            raise RuntimeError("FTP inventory bounds exceeded")
    return files


def archive_prefix(c):
    if c["SERVER_NAME"] in (".", "..") or not re.fullmatch(r"[A-Za-z0-9_.-]+", c["SERVER_NAME"]):
        raise RuntimeError("Unsafe server name")
    base = c["FTP_BASE_DIR"]
    if not base.startswith("/") or any(p in (".", "..") for p in base.split("/")) or any(ord(ch) < 32 for ch in base):
        raise RuntimeError("Unsafe FTP base directory")
    return base.rstrip("/") + "/" + c["SERVER_NAME"] + "/"


def owned_archives(c, files):
    prefix = archive_prefix(c)
    pattern = re.compile(re.escape(c["SERVER_NAME"]) + r"_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}|latest)\.tar\.(?:zst|gz)$")
    result = []
    for path in files:
        if path.startswith(prefix) and pattern.fullmatch(path[len(prefix):]):
            result.append(path)
    return sorted(result)


def capacity(c, files, archive_size, incoming_name=None):
    quota = int(c["FTP_QUOTA_BYTES"])
    reserve = int(c["FTP_RESERVE_BYTES"])
    count = sum(int(c[k]) for k in ("KEEP_DAILY", "KEEP_WEEKLY", "KEEP_MONTHLY", "KEEP_YEARLY"))
    if quota < 0 or reserve < 0 or archive_size < 0 or (quota and reserve >= quota):
        raise RuntimeError("Invalid quota, reserve or archive size")
    prefix = archive_prefix(c)
    other = sum(size for path, size in files.items() if not path.startswith(prefix))
    used = sum(files.values())
    # Only actual upload occupancy blocks a transfer. A prediction of future
    # retention/growth must never prevent today's backup when it already fits.
    incoming = used + archive_size + 65
    result = {"quota_bytes": quota, "reserve_bytes": reserve, "used_bytes": used, "other_bytes": other, "archive_bytes": archive_size, "retention_archives": count, "upload_peak_bytes": incoming}
    result["allowed"] = not quota or incoming + reserve <= quota
    archives = owned_archives(c, files)
    dated = [path for path in archives if "_latest.tar." not in path]
    protected = dated[-1] if dated else (archives[-1] if archives else None)
    remaining = incoming
    deletions = []
    for path in dated:
        if not quota or remaining + reserve <= quota:
            break
        if path == protected or (incoming_name and path == prefix + incoming_name):
            continue
        deletions.append(path)
        remaining -= files[path] + files.get(path + ".sha256", 0)
    result.update({"protected_latest": protected, "delete_before_upload": deletions,
                   "upload_peak_after_deletion_bytes": remaining,
                   "can_make_room": bool(protected) and (not quota or remaining + reserve <= quota)})
    return result


def read_remote_checksum(ftp, remote_path):
    sidecar = []
    ftp.retrlines("RETR " + remote_path + ".sha256", sidecar.append)
    if len(sidecar) != 1 or not re.fullmatch(r"[0-9a-f]{64}", sidecar[0].strip()):
        raise RuntimeError("Remote checksum sidecar is absent or malformed")
    return sidecar[0].strip()


def verify_remote(ftp, remote_path, expected=None, expected_size=None):
    ftp.voidcmd("TYPE I")
    size = ftp.size(remote_path)
    if expected_size is not None and size != expected_size:
        raise RuntimeError("Uploaded archive size differs")
    sidecar = read_remote_checksum(ftp, remote_path)
    if expected is not None and sidecar != expected:
        raise RuntimeError("Remote checksum sidecar differs")
    expected = expected or sidecar
    digest, received = hashlib.sha256(), 0

    def consume(block):
        nonlocal received
        digest.update(block)
        received += len(block)

    ftp.retrbinary("RETR " + remote_path, consume, blocksize=1024 * 1024)
    if received != size or digest.hexdigest() != expected:
        raise RuntimeError("Uploaded archive checksum differs; rotation must not run")
    return {"remote_read_bytes": received, "sha256": expected, "sha256_match": True}


def local_checksum(local):
    local = Path(local)
    if local.is_symlink() or not local.is_file():
        raise RuntimeError("Local archive must be a regular file")
    expected = local.with_name(local.name + ".sha256").read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise RuntimeError("Local checksum sidecar is malformed")
    return expected


def verify_local(local):
    expected = local_checksum(local)
    digest = hashlib.sha256()
    with Path(local).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise RuntimeError("Local archive checksum differs; no backup may be removed")
    return expected


def endpoint(c):
    keys = ["FTP_HOST", "FTP_PORT", "FTP_USER", "FTP_BASE_DIR", "FTP_PROTOCOL", "SERVER_NAME"]
    return hashlib.sha256(json.dumps({key: c[key] for key in keys}, sort_keys=True).encode()).hexdigest()


def verify(ftp, remote_path, local_path, c=None):
    local = Path(local_path)
    result = verify_remote(ftp, remote_path, local_checksum(local), local.stat().st_size)
    if c is not None:
        # Private receipt for bounded local cleanup after a later failed upload.
        receipt = {**result, "endpoint": endpoint(c), "archive": local.name,
                   "verified_at": datetime.now(timezone.utc).isoformat()}
        fd, name = tempfile.mkstemp(prefix=".verified-", dir=local.parent)
        try:
            with os.fdopen(fd, "w") as handle:
                os.fchmod(handle.fileno(), 0o600)
                json.dump(receipt, handle)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(name, local.parent / ".last-verified.json")
        finally:
            if os.path.exists(name):
                os.unlink(name)
    print(json.dumps(result), flush=True)
    return result


def make_room(ftp, c, local_path):
    local = Path(local_path)
    files = inventory(ftp)
    prefix = archive_prefix(c)
    if prefix + local.name not in owned_archives(c, {prefix + local.name: 0}):
        raise RuntimeError("Incoming archive is not owned by this backup job")
    plan = capacity(c, files, local.stat().st_size, local.name)
    if plan["allowed"]:
        return {**plan, "deleted": []}
    if not plan["can_make_room"]:
        raise RuntimeError("Not enough room while preserving the newest remote backup; nothing deleted")
    # Before any deletion, prove that both the incoming local copy and the
    # newest existing remote backup are intact. Never delete the sole copy.
    verify_local(local)
    protected = plan["protected_latest"]
    print(json.dumps({"checking_protected_remote_backup": protected, "bytes": files[protected]}), flush=True)
    protected_proof = verify_remote(ftp, protected, expected_size=files[protected])
    deleted = []
    for path in plan["delete_before_upload"]:
        current = inventory(ftp)
        if capacity(c, current, local.stat().st_size, local.name)["allowed"]:
            break
        if current.get(protected) != protected_proof["remote_read_bytes"] or read_remote_checksum(ftp, protected) != protected_proof["sha256"]:
            raise RuntimeError("Protected remote backup changed; deletion stopped")
        if path not in owned_archives(c, current) or path == protected or path == prefix + local.name:
            raise RuntimeError("Unsafe deletion candidate")
        # The list was completely planned before the first mutation. Unknown
        # files, other servers, snapshot archives and the newest backup stay.
        ftp.delete(path)
        if path + ".sha256" in current:
            ftp.delete(path + ".sha256")
        deleted.append(path)
    result = capacity(c, inventory(ftp), local.stat().st_size, local.name)
    if not result["allowed"]:
        raise RuntimeError("Capacity changed during cleanup; protected backup retained")
    return {**result, "deleted": deleted, "protected_backup_verified": protected}


def trim_local_pending(c, local_path):
    """After a failed upload, keep the newest ready copy AND last verified one."""
    directory = Path(c["WORK_DIR"]).resolve()
    local = Path(local_path).absolute()
    if local.parent.resolve() != directory or local.is_symlink():
        raise RuntimeError("Pending archive is outside WORK_DIR")
    local = directory / local.name
    try:
        receipt = json.loads((directory / ".last-verified.json").read_text())
    except FileNotFoundError:
        return {"local_deleted": [], "reason": "No verified remote backup receipt; all local copies retained"}
    if receipt.get("endpoint") != endpoint(c) or not re.fullmatch(r"[0-9a-f]{64}", receipt.get("sha256", "")):
        raise RuntimeError("Local verification receipt does not match this FTP account")
    prefix = archive_prefix(c)
    if not isinstance(receipt.get("archive"), str) or prefix + receipt["archive"] not in owned_archives(c, {prefix + receipt["archive"]: 0}):
        raise RuntimeError("Unsafe archive name in verification receipt")
    verify_local(local)
    candidates = {str(path): path.stat().st_size for path in directory.iterdir() if path.is_file() and not path.is_symlink()}
    names = owned_archives(c, {prefix + Path(path).name: size for path, size in candidates.items()})
    ready = [directory / path[len(prefix):] for path in names]
    keep = set(ready[-max(1, int(c["KEEP_LOCAL"])):]) | {local, directory / receipt["archive"]}
    deleted = []
    for path in ready:
        if path in keep:
            continue
        path.unlink()
        path.with_name(path.name + ".sha256").unlink(missing_ok=True)
        deleted.append(path.name)
    return {"local_deleted": deleted, "protected_local": sorted(path.name for path in keep)}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("operation", choices=["inventory", "capacity", "make-room", "verify", "trim-local"])
    p.add_argument("--config", required=True)
    p.add_argument("--archive")
    a = p.parse_args()
    c = configuration(a.config)
    if a.operation != "inventory" and not a.archive:
        p.error("--archive is required for this operation")
    if a.operation == "trim-local":
        print(json.dumps(trim_local_pending(c, a.archive)), flush=True)
        raise SystemExit(0)
    ftp = connect(c)
    try:
        if a.operation == "verify":
            remote = archive_prefix(c) + Path(a.archive).name
            verify(ftp, remote, a.archive, c)
        elif a.operation == "make-room":
            print(json.dumps(make_room(ftp, c, a.archive)), flush=True)
        else:
            files = inventory(ftp)
            if a.operation == "inventory":
                print(json.dumps({"total_bytes": sum(files.values()), "files": files}), flush=True)
            else:
                result = capacity(c, files, Path(a.archive).stat().st_size, Path(a.archive).name)
                print(json.dumps(result), flush=True)
                if not result["allowed"]:
                    raise SystemExit("Upload needs space; use make-room to preserve the newest verified backup")
    finally:
        ftp.quit()
