#!/usr/bin/env python3
"""
Back up every app's /config volume to the media share.

SQLite databases are copied with the online backup API (sqlite3.Connection
.backup), not as plain files: a database written to mid-copy produces an
archive that looks valid and fails only when you try to restore it. Everything
else is copied normally.

Pure standard library on purpose, so the job runs on a stock python image with
a read-only root filesystem and no package installs.

Layout on the share:
    <BACKUP_DIR>/<app>/<app>-YYYY-MM-DD_HHMM.tar.gz
"""
import json
import os
import shutil
import sqlite3
import sys
import tarfile
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BACKUP_DIR = Path(os.environ.get("BACKUP_DIR", "/mnt/media/.backups"))
KEEP = int(os.environ.get("KEEP_BACKUPS", "14"))
APPS = os.environ.get("APPS", "").split()
NOTIFY_OK = os.environ.get("NOTIFY_ON_SUCCESS", "false").lower() == "true"
WEBHOOK = os.environ.get("WEBHOOK_URL", "").strip()
NOTIFY_TYPE = os.environ.get("NOTIFICATION_TYPE", "ntfy").strip()
STAMP = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d_%H%M")

DB_SUFFIXES = (".db", ".sqlite", ".sqlite3")
# Volatile or huge directories that are regenerated rather than restored.
SKIP_DIRS = {"logs", "Cache", "Crash Reports", "Diagnostics", "Codecs",
             "Media", "Metadata", "Updates", "MediaCover"}


def log(msg):
    print(f"[backup] {msg}", flush=True)


def notify(title, body, urgent=False):
    if not WEBHOOK:
        return
    try:
        if NOTIFY_TYPE == "ntfy":
            req = urllib.request.Request(
                WEBHOOK, data=body.encode(),
                headers={"Title": title,
                         "Priority": "urgent" if urgent else "default"})
        elif NOTIFY_TYPE == "discord":
            req = urllib.request.Request(
                WEBHOOK, data=json.dumps({"content": f"**{title}**\n{body}"}).encode(),
                headers={"Content-Type": "application/json"})
        elif NOTIFY_TYPE == "slack":
            req = urllib.request.Request(
                WEBHOOK, data=json.dumps({"text": f"*{title}*\n{body}"}).encode(),
                headers={"Content-Type": "application/json"})
        else:
            req = urllib.request.Request(
                WEBHOOK, data=f"{title}: {body}".encode(),
                headers={"Content-Type": "text/plain"})
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as exc:                      # notification must never fail the job
        log(f"  notification failed: {exc}")


def is_sqlite(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(16) == b"SQLite format 3\x00"
    except OSError:
        return False


def copy_database(src, dest):
    """Consistent copy of a live SQLite database. Returns True on success."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        # immutable=1 would skip locking but also miss WAL content; a normal
        # read-only connection plus .backup() gives a consistent snapshot.
        source = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=30)
        try:
            target = sqlite3.connect(str(dest))
            try:
                source.backup(target)
            finally:
                target.close()
        finally:
            source.close()
        return True
    except sqlite3.Error as exc:
        log(f"    sqlite backup failed for {src.name}: {exc}")
        return False


def stage_app(src_root, stage):
    """Copy an app's config into a staging dir. Returns (files, databases)."""
    files = dbs = 0
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        rel_dir = Path(dirpath).relative_to(src_root)
        for name in filenames:
            src = Path(dirpath) / name
            if name.endswith(("-shm", "-wal", "-journal")):
                continue          # transient; rebuilt from the backed-up database
            dest = stage / rel_dir / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            if src.suffix in DB_SUFFIXES and is_sqlite(src):
                if copy_database(src, dest):
                    dbs += 1
                    continue
                # fall through to a plain copy if the API refused
            try:
                shutil.copy2(src, dest)
                files += 1
            except FileNotFoundError:
                pass              # vanished between listing and copy; harmless
            except OSError as exc:
                log(f"    skip {rel_dir / name}: {exc}")
    return files, dbs


def prune(dest_dir):
    archives = sorted(dest_dir.glob("*.tar.gz"), key=lambda p: p.stat().st_mtime,
                      reverse=True)
    for old in archives[KEEP:]:
        try:
            old.unlink()
            log(f"  pruned {old.name}")
        except OSError as exc:
            log(f"  could not prune {old.name}: {exc}")


def main():
    if not APPS:
        log("No apps configured — nothing to do.")
        return 0

    try:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        probe = BACKUP_DIR / ".write-test"
        probe.write_text("ok")
        probe.unlink()
    except OSError as exc:
        log(f"ERROR: {BACKUP_DIR} is not writable: {exc}")
        notify("Backup failed", f"Cannot write to {BACKUP_DIR}: {exc}", urgent=True)
        return 1

    failures, done = [], []
    for app in APPS:
        src = Path("/configs") / app
        if not src.is_dir():
            log(f"SKIP {app}: {src} not mounted")
            continue

        log(f"── {app} ──")
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            stage = Path(tmp) / app
            stage.mkdir(parents=True)
            files, dbs = stage_app(src, stage)

            dest_dir = BACKUP_DIR / app
            dest_dir.mkdir(parents=True, exist_ok=True)
            archive = dest_dir / f"{app}-{STAMP}.tar.gz"
            try:
                with tarfile.open(archive, "w:gz") as tar:
                    tar.add(stage, arcname=".")
            except Exception as exc:
                log(f"  ERROR: archive failed: {exc}")
                archive.unlink(missing_ok=True)
                failures.append(app)
                continue

            size_mb = archive.stat().st_size / (1024 * 1024)
            log(f"  → {archive.name} ({size_mb:.1f} MiB, {files} file(s), {dbs} database(s))")
            done.append(app)
            prune(dest_dir)

    log(f"Done: {len(done)} succeeded, {len(failures)} failed at "
        f"{datetime.now().strftime('%Y-%m-%d %H:%M')}")

    if failures:
        notify(f"Config backup: {len(failures)} failure(s)",
               f"Failed: {', '.join(failures)}\nDestination: {BACKUP_DIR}",
               urgent=True)
        return 1
    if NOTIFY_OK:
        notify("Config backup complete",
               f"{len(done)} app(s) backed up to {BACKUP_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
