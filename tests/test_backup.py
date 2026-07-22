#!/usr/bin/env python3
"""
Offline tests for files/scripts/backup.py
Usage: python3 tests/test_backup.py

Proves the thing that actually matters: a database copied while the app is
writing to it restores intact. A plain file copy passes casual inspection and
fails only at restore time, so this is tested explicitly.
"""
import os
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT_SRC = ROOT / "files" / "scripts" / "backup.py"

fails = []


def check(ok, msg):
    print(("PASS  " if ok else "FAIL  ") + msg)
    if not ok:
        fails.append(msg)


def make_db(path, rows, wal=False):
    con = sqlite3.connect(path)
    if wal:
        con.execute("PRAGMA journal_mode=WAL")
    con.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, v TEXT)")
    con.executemany("INSERT INTO items(v) VALUES(?)", [(f"r{i}",) for i in range(rows)])
    con.commit()
    return con


def run(script, configs, dest, apps, **env):
    e = dict(os.environ, BACKUP_DIR=str(dest), APPS=" ".join(apps),
             KEEP_BACKUPS=env.pop("keep", "14"), WEBHOOK_URL="")
    e.update(env)
    return subprocess.run([sys.executable, str(script)], env=e,
                          capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        configs = tmp / "configs"
        (configs / "sonarr").mkdir(parents=True)
        (configs / "sonarr" / "logs").mkdir()
        dest = tmp / "backups"

        # point the script's /configs at our fixture dir
        script = tmp / "backup.py"
        script.write_text(SCRIPT_SRC.read_text().replace('"/configs"', f'"{configs}"'))

        con = make_db(configs / "sonarr" / "sonarr.db", 1000)
        wal = make_db(configs / "sonarr" / "logs.db", 500, wal=True)
        (configs / "sonarr" / "config.xml").write_text("<Config><ApiKey>secret</ApiKey></Config>")
        (configs / "sonarr" / "logs" / "app.txt").write_text("x" * 10000)

        # 1. basic run
        r = run(script, configs, dest, ["sonarr"])
        check(r.returncode == 0, "backup exits 0")
        archives = list((dest / "sonarr").glob("*.tar.gz"))
        check(len(archives) == 1, "one archive produced")

        # 2. contents restore correctly
        out = tmp / "restore"
        out.mkdir()
        with tarfile.open(archives[0]) as t:
            t.extractall(out)
        db = out / "sonarr.db"
        check(db.exists(), "database present in archive")
        c = sqlite3.connect(db)
        check(c.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
              "restored database passes integrity_check")
        check(c.execute("SELECT count(*) FROM items").fetchone()[0] == 1000,
              "restored database has all rows")
        c.close()
        c = sqlite3.connect(out / "logs.db")
        check(c.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
              "WAL-mode database restores intact")
        c.close()
        check("secret" in (out / "config.xml").read_text(), "non-database files preserved")
        check(not (out / "logs" / "app.txt").exists(), "volatile logs/ excluded")
        check(not list(out.glob("*-wal")) and not list(out.glob("*-shm")),
              "sqlite sidecar files excluded")

        # 2b. WAL-mode database from a READ-ONLY source directory — the exact
        #     production failure (config PVCs are mounted readOnly, and SQLite
        #     cannot open a WAL db from a read-only dir without staging it).
        rocfg = configs / "roapp"
        rocfg.mkdir()
        wc = make_db(rocfg / "main.db", 300, wal=True)
        # keep a writer's WAL/shm live, then lock the directory read-only
        wc.execute("INSERT INTO items(v) VALUES('x')")
        wc.commit()
        os.chmod(rocfg, 0o555)
        try:
            rr = run(script, configs, tmp / "ro", ["roapp"])
            check(rr.returncode == 0, "read-only WAL source: backup succeeds")
            roout = tmp / "rorestore"
            roout.mkdir()
            with tarfile.open(next((tmp / "ro" / "roapp").glob("*.tar.gz"))) as tf:
                tf.extractall(roout)
            check((roout / "main.db").exists(),
                  "read-only WAL source: database present in archive (not skipped)")
            rc = sqlite3.connect(roout / "main.db")
            check(rc.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
                  "read-only WAL source: restored database intact")
            check(rc.execute("SELECT count(*) FROM items").fetchone()[0] >= 300,
                  "read-only WAL source: all rows captured")
            rc.close()
        finally:
            os.chmod(rocfg, 0o755)
            wc.close()

        # 3. hot copy: database written continuously during the backup
        stop = threading.Event()
        errs = []

        def writer():
            w = sqlite3.connect(configs / "sonarr" / "sonarr.db", timeout=30)
            i = 0
            while not stop.is_set():
                try:
                    w.execute("INSERT INTO items(v) VALUES(?)", (f"live{i}",))
                    w.commit()
                    i += 1
                except Exception as exc:
                    errs.append(str(exc))
                time.sleep(0.001)
            w.close()

        th = threading.Thread(target=writer)
        th.start()
        time.sleep(0.2)
        hot = tmp / "hot"
        r = run(script, configs, hot, ["sonarr"])
        stop.set()
        th.join()
        check(r.returncode == 0, "backup succeeds while the app writes")
        check(not errs, "the running app is never locked out")
        hotdir = tmp / "hotrestore"
        hotdir.mkdir()
        with tarfile.open(next((hot / "sonarr").glob("*.tar.gz"))) as t:
            t.extractall(hotdir)
        c = sqlite3.connect(hotdir / "sonarr.db")
        check(c.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
              "hot-copied database is consistent, not torn")
        c.close()

        # 4. retention
        rdest = tmp / "retention"
        (rdest / "sonarr").mkdir(parents=True)
        for n in range(6):
            f = rdest / "sonarr" / f"sonarr-2026-01-0{n}_0000.tar.gz"
            f.write_bytes(b"x")
            os.utime(f, (time.time() - n * 3600, time.time() - n * 3600))
        run(script, configs, rdest, ["sonarr"], keep="3")
        check(len(list((rdest / "sonarr").glob("*.tar.gz"))) == 3,
              "retention keeps exactly KEEP_BACKUPS archives")

        # 5. failure modes
        r = run(script, configs, Path("/proc/definitely-not-writable"), ["sonarr"])
        check(r.returncode == 1, "unwritable destination exits non-zero")
        r = run(script, configs, tmp / "d2", [])
        check(r.returncode == 0, "no apps configured is a clean no-op")
        r = run(script, configs, tmp / "d3", ["ghost"])
        check(r.returncode == 0, "missing config mount is skipped, not fatal")

        con.close()
        wal.close()

    print()
    if fails:
        print(f"{len(fails)} FAILURES")
        return 1
    print("ALL BACKUP TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
