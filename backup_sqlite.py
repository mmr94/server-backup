#!/usr/bin/env python3
"""Consistent online SQLite snapshots; the source connections are read-only."""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import time

SKIP = {"node_modules", ".git", ".next", ".nuxt", ".output", ".cache", "__pycache__", ".venv", "venv"}


def snapshots(root, staging, exclusions):
    root, staging = Path(root).resolve(), Path(staging).resolve()
    blocked = {str(Path(p).resolve()) for p in exclusions if p.startswith("/")}
    target = staging / "_sqlite"
    target.mkdir(mode=0o700, parents=True, exist_ok=True)
    entries, excluded, skipped = [], [], []
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in SKIP and str((Path(base) / d).resolve()) not in blocked and not (Path(base) / d).is_symlink())
        for name in sorted(files):
            if not name.endswith((".db", ".sqlite", ".sqlite3")):
                continue
            src = Path(base) / name
            if src.is_symlink():
                raise RuntimeError("SQLite candidate is a symlink: " + str(src))
            with src.open("rb") as fp:
                if fp.read(16) != b"SQLite format 3\x00":
                    skipped.append(str(src))
                    continue
            info = src.stat()
            relative = src.relative_to(root)
            dst = target / "databases" / relative
            dst.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            started = time.monotonic()

            def progress(status, remaining, total):
                if time.monotonic() - started > 300:
                    raise TimeoutError("SQLite snapshot exceeded 300 seconds: " + str(src))

            with closing(sqlite3.connect(src.as_uri() + "?mode=ro", uri=True, timeout=10)) as source:
                with closing(sqlite3.connect(dst)) as destination:
                    # This is disposable staging, verified before archiving and
                    # again after upload; avoid synchronous commits on busy RAID.
                    destination.execute("PRAGMA synchronous=OFF")
                    destination.execute("PRAGMA journal_mode=MEMORY")
                    source.backup(destination, pages=256, progress=progress, sleep=0.05)
                    destination.commit()
                    # Export a standalone DB, never a main file depending on WAL.
                    mode = destination.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
                    if mode.lower() != "delete":
                        raise RuntimeError("Snapshot could not be made standalone: " + str(src))
                    result = [row[0] for row in destination.execute("PRAGMA quick_check")]
                    if result != ["ok"]:
                        raise RuntimeError("SQLite integrity check failed: " + str(src))
            with closing(sqlite3.connect(dst.as_uri() + "?mode=ro&immutable=1", uri=True)) as check:
                if [r[0] for r in check.execute("PRAGMA quick_check")] != ["ok"]:
                    raise RuntimeError("Standalone SQLite snapshot is not readable: " + str(src))
            if any(Path(str(dst) + suffix).exists() for suffix in ("-wal", "-shm", "-journal")):
                raise RuntimeError("Snapshot still has journal sidecars: " + str(dst))
            os.chmod(dst, 0o600)
            digest = hashlib.sha256(dst.read_bytes()).hexdigest()
            entries.append({"source": str(src), "archive": str(dst.relative_to(staging)), "uid": info.st_uid, "gid": info.st_gid, "mode": oct(stat.S_IMODE(info.st_mode)), "bytes": dst.stat().st_size, "sha256": digest, "quick_check": "ok"})
            for suffix in ("", "-wal", "-shm", "-journal"):
                excluded.append(str(src).lstrip("/") + suffix)
            print("SQLITE_SNAPSHOT", relative, dst.stat().st_size, "quick_check=ok", flush=True)
    (target / "manifest.json").write_text(json.dumps({"format": 1, "databases": entries, "skipped_non_sqlite": skipped}, indent=2) + "\n")
    (target / "exclude-live.txt").write_text("\n".join(excluded) + "\n")
    # Recording Git identity uses no optional locks and does not refresh indexes.
    projects = []
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    for project in sorted(root.iterdir()):
        if not project.is_dir() or project.is_symlink() or not (project / ".git").exists():
            continue
        item = {"path": str(project)}
        for key, args in [("commit", ["rev-parse", "HEAD"]), ("branch", ["symbolic-ref", "--short", "HEAD"])]:
            r = subprocess.run(["git", "-C", str(project)] + args, env=env, capture_output=True, text=True, timeout=20)
            item[key] = r.stdout.strip() if r.returncode == 0 else None
        projects.append(item)
    (target / "projects.json").write_text(json.dumps(projects, indent=2) + "\n")
    print("SQLITE_TOTAL", len(entries), "BYTES", sum(e["bytes"] for e in entries), flush=True)
    return entries


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--root", required=True)
    p.add_argument("--staging", required=True)
    p.add_argument("--exclude-file", required=True)
    a = p.parse_args()
    exclusions = Path(a.exclude_file).read_text().splitlines()
    snapshots(a.root, a.staging, exclusions)
