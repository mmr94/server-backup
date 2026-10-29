#!/usr/bin/env python3
"""Read-only FTP inventory, capacity guard, and uploaded-file verification."""
import argparse
import ftplib
import hashlib
import json
from pathlib import Path
import re
import shlex


def configuration(path):
    keys = {"SERVER_NAME", "FTP_HOST", "FTP_PORT", "FTP_USER", "FTP_PASS", "FTP_BASE_DIR", "FTP_PROTOCOL", "FTP_QUOTA_BYTES", "FTP_RESERVE_BYTES", "KEEP_DAILY", "KEEP_WEEKLY", "KEEP_MONTHLY", "KEEP_YEARLY"}
    result = {}
    for line in Path(path).read_text().splitlines():
        m = re.match(r"^([A-Z_]+)=(.*)$", line)
        if m and m[1] in keys:
            v = shlex.split(m[2], comments=True)
            result[m[1]] = v[0] if v else ""
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


def capacity(c, files, archive_size):
    quota = int(c["FTP_QUOTA_BYTES"])
    reserve = int(c["FTP_RESERVE_BYTES"])
    count = sum(int(c[k]) for k in ("KEEP_DAILY", "KEEP_WEEKLY", "KEEP_MONTHLY", "KEEP_YEARLY"))
    prefix = c["FTP_BASE_DIR"].rstrip("/") + "/" + c["SERVER_NAME"] + "/"
    other = sum(size for path, size in files.items() if not path.startswith(prefix))
    used = sum(files.values())
    # Include the incoming archive BEFORE rotation, plus 20% archive growth.
    # The newest backup is protected even on a tier whose retention is zero.
    extra_latest = int(any(int(c[k]) == 0 for k in ("KEEP_DAILY", "KEEP_WEEKLY", "KEEP_MONTHLY", "KEEP_YEARLY")))
    peak = other + (count + 1 + extra_latest) * ((archive_size * 120 + 99) // 100 + 65)
    incoming = used + archive_size + 65
    result = {"quota_bytes": quota, "reserve_bytes": reserve, "used_bytes": used, "other_bytes": other, "archive_bytes": archive_size, "retention_archives": count, "protected_latest_extra": extra_latest, "upload_peak_bytes": incoming, "retention_peak_with_20pct_growth_bytes": peak}
    result["allowed"] = max(peak, incoming) + reserve <= quota
    return result


def verify(ftp, remote_path, local_path):
    local = Path(local_path)
    ftp.voidcmd("TYPE I")
    if ftp.size(remote_path) != local.stat().st_size:
        raise RuntimeError("Uploaded archive size differs")
    expected = local.with_name(local.name + ".sha256").read_text().strip()
    sidecar = []
    ftp.retrlines("RETR " + remote_path + ".sha256", sidecar.append)
    if not sidecar or sidecar[0].strip() != expected:
        raise RuntimeError("Remote checksum sidecar differs")
    digest, received = hashlib.sha256(), 0

    def consume(block):
        nonlocal received
        digest.update(block)
        received += len(block)

    ftp.retrbinary("RETR " + remote_path, consume, blocksize=1024 * 1024)
    if digest.hexdigest() != expected:
        raise RuntimeError("Uploaded archive checksum differs; rotation must not run")
    print(json.dumps({"remote_read_bytes": received, "sha256_match": True}), flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("operation", choices=["inventory", "capacity", "verify"])
    p.add_argument("--config", required=True)
    p.add_argument("--archive")
    a = p.parse_args()
    c = configuration(a.config)
    ftp = connect(c)
    try:
        if a.operation == "verify":
            remote = c["FTP_BASE_DIR"].rstrip("/") + "/" + c["SERVER_NAME"] + "/" + Path(a.archive).name
            verify(ftp, remote, a.archive)
        else:
            files = inventory(ftp)
            if a.operation == "inventory":
                print(json.dumps({"total_bytes": sum(files.values()), "files": files}), flush=True)
            else:
                result = capacity(c, files, Path(a.archive).stat().st_size)
                print(json.dumps(result), flush=True)
                if not result["allowed"]:
                    raise SystemExit("FTP capacity guard refused upload; reduce retention or increase capacity")
    finally:
        ftp.quit()
