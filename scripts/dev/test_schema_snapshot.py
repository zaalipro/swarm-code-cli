#!/usr/bin/env python3
"""Ordinary disposable native snapshot contract and SQLite integrity checks."""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("SCHEMA_SNAPSHOT_BINARY", ROOT / "_build/schema-snapshot/swarm-schema-snapshot"))


class SqliteOwner:
    """Keep SQLite locks outside the process that hashes source descriptors."""
    def __init__(self, path):
        self.process = subprocess.Popen([sys.executable, "-u", __file__, "--owner", str(path)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        if self.process.stdout.readline() != "ready\n":
            raise RuntimeError("fixture owner did not start")

    def request(self, operation, sql=None):
        self.process.stdin.write(json.dumps([operation, sql]) + "\n")
        self.process.stdin.flush()
        response = json.loads(self.process.stdout.readline())
        if response[0] != "ok":
            raise RuntimeError(response[1])
        return response[1]

    def execute(self, sql):
        return self.request("execute", sql)

    def commit(self):
        return self.request("commit")

    def rollback(self):
        return self.request("rollback")

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
            self.process.wait(timeout=10)
            self.process.stdout.close()


def run_owner(path):
    connection = sqlite3.connect(path, timeout=0)
    print("ready", flush=True)
    try:
        for line in sys.stdin:
            operation, sql = json.loads(line)
            try:
                if operation == "execute":
                    result = connection.execute(sql).fetchall()
                else:
                    getattr(connection, operation)()
                    result = None
                print(json.dumps(["ok", result]), flush=True)
            except sqlite3.Error as error:
                print(json.dumps(["error", str(error)]), flush=True)
    finally:
        connection.close()


def identity(path):
    info = path.stat()
    return [str(info.st_dev), str(info.st_ino)]


def fingerprint(path):
    if not path.exists():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return identity(path), path.stat().st_size, digest.hexdigest()


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(BINARY.is_file(), "native snapshot helper has not been implemented/built")
        self.temp = tempfile.TemporaryDirectory(prefix="schema-snapshot-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source_dir = self.base / "source"
        self.source_dir.mkdir(mode=0o700)
        self.source = self.source_dir / "source.db"
        self.connection = SqliteOwner(self.source)
        self.source.chmod(0o600)
        self.connection.execute("CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT)")
        self.connection.execute("INSERT INTO records VALUES (1, 'main value')")
        self.connection.commit()
        self.addCleanup(self.connection.close)

    def wal(self):
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA wal_autocheckpoint=0")
        self.connection.execute("INSERT INTO records VALUES (2, 'committed WAL value')")
        self.connection.commit()
        for suffix in ("-wal", "-shm"):
            Path(str(self.source) + suffix).chmod(0o600)

    def destination(self):
        path = self.base / ("copy-" + str(len(list(self.base.glob("copy-*")))))
        path.mkdir(mode=0o700)
        for name in ("snapshot.db", "snapshot.db-wal", "snapshot.db-shm"):
            fd = os.open(path / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        return path

    def arguments(self, dest, timeout=5000, cap=16777216):
        optional = []
        for suffix in ("-wal", "-shm"):
            path = Path(str(self.source) + suffix)
            optional.extend(identity(path) if path.exists() else ["-", "-"])
        return ["v1", str(self.source_dir), self.source.name, *identity(self.source_dir),
                str(os.getuid()), *identity(self.source), *optional,
                *identity(dest / "snapshot.db"), *identity(dest / "snapshot.db-wal"),
                *identity(dest), str(timeout), str(cap)]

    def run_copy(self, dest, args=None, eof=False):
        process = subprocess.Popen([str(BINARY), *(args or self.arguments(dest))], cwd=dest,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            if eof:
                process.stdin.close()
            process.wait(timeout=10)
            return process.returncode, process.stdout.read(), process.stderr.read()
        finally:
            if not process.stdin.closed:
                process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def source_state(self):
        return [fingerprint(Path(str(self.source) + suffix)) for suffix in ("", "-wal", "-shm")]

    def assert_copy(self, expected_rows):
        before = self.source_state()
        dest = self.destination()
        result = self.run_copy(dest)
        self.assertEqual(result, (0, f"snapshot-v1 {before[0][1]} {before[1][1] if before[1] else 0} {int(before[1] is not None)}\n".encode(), b""))
        for suffix, record in zip(("", "-wal"), before):
            if record:
                self.assertEqual(fingerprint(dest / ("snapshot.db" + suffix))[1:], record[1:])
        self.assertEqual(self.source_state(), before)
        with sqlite3.connect(dest / "snapshot.db") as reader:
            self.assertEqual(reader.execute("SELECT * FROM records ORDER BY id").fetchall(), expected_rows)
            self.assertEqual(reader.execute("PRAGMA integrity_check").fetchall(), [("ok",)])
        self.assertEqual(self.source_state(), before)
        return dest

    def test_main_only_exact_rows_and_source_bytes(self):
        self.connection.close()
        self.assert_copy([(1, "main value")])

    def test_live_wal_exact_rows_and_source_bytes(self):
        self.wal()
        self.assert_copy([(1, "main value"), (2, "committed WAL value")])

    def test_unopened_copy_with_missing_shm(self):
        self.wal()
        dest = self.destination()
        self.assertEqual(self.run_copy(dest)[0], 0)
        # A legitimate unopened copied pair provides a missing-SHM source.
        pair = self.base / "unopened"
        pair.mkdir(mode=0o700)
        for suffix in ("", "-wal"):
            with (dest / ("snapshot.db" + suffix)).open("rb") as src:
                fd = os.open(pair / ("source.db" + suffix), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(fd, "wb") as out:
                    for chunk in iter(lambda: src.read(65536), b""):
                        out.write(chunk)
        self.source_dir, self.source = pair, pair / "source.db"
        self.assert_copy([(1, "main value"), (2, "committed WAL value")])

    def assert_refusal(self, dest, args=None, eof=False):
        before = self.source_state()
        code, stdout, stderr = self.run_copy(dest, args, eof)
        self.assertNotEqual(code, 0)
        self.assertEqual((stdout, stderr), (b"", b""))
        self.assertEqual(self.source_state(), before)
        self.assertEqual(sorted(p.name for p in dest.iterdir()), ["snapshot.db", "snapshot.db-shm", "snapshot.db-wal"])

    def test_writer_contention_refuses_without_copying(self):
        self.wal()
        self.connection.execute("BEGIN IMMEDIATE")
        self.connection.execute("UPDATE records SET value='uncommitted' WHERE id=1")
        dest = self.destination()
        self.assert_refusal(dest)
        self.assertEqual((dest / "snapshot.db").stat().st_size, 0)
        self.connection.rollback()
        self.assert_copy([(1, "main value"), (2, "committed WAL value")])

    def test_closed_stdin_cancels_and_releases_locks(self):
        self.connection.close()
        self.assert_refusal(self.destination(), eof=True)
        self.assert_copy([(1, "main value")])

    def test_invalid_arguments_and_expected_identity_refuse(self):
        dest = self.destination()
        cases = [(0, "v2"), (3, "00"), (3, "18446744073709551616"), (7, "0"),
                 (8, "0"), (13, "0"), (18, "0"), (18, "300001"), (19, "0"), (19, "9223372036854775808")]
        for index, value in cases:
            with self.subTest(index=index, value=value):
                args = self.arguments(dest)
                args[index] = value
                self.assert_refusal(dest, args)
        self.assert_refusal(dest, self.arguments(dest)[:-1])

    def test_nonempty_output_and_size_cap_refuse(self):
        dest = self.destination()
        self.assert_refusal(dest, self.arguments(dest, cap=1))
        (dest / "snapshot.db").write_bytes(b"owned sentinel")
        self.assert_refusal(dest)
        self.assertEqual((dest / "snapshot.db").read_bytes(), b"owned sentinel")

    def test_source_directory_must_remain_private(self):
        self.connection.close()
        dest = self.destination()
        self.source_dir.chmod(0o755)
        self.assert_refusal(dest)
        self.assertEqual((dest / "snapshot.db").stat().st_size, 0)

    def test_deadline_limits_large_ordinary_copy(self):
        self.connection.close()
        # A sparse disposable main file makes a 1ms budget insufficient without large allocations.
        with self.source.open("ab") as stream:
            stream.truncate(256 * 1024 * 1024)
        dest = self.destination()
        started = time.monotonic()
        self.assert_refusal(dest, self.arguments(dest, timeout=1, cap=512 * 1024 * 1024))
        self.assertLess(time.monotonic() - started, 5)
        # Outputs remain caller-owned on partial failure and may be cleaned up normally.
        for path in dest.iterdir():
            path.unlink()
        dest.rmdir()
        self.assertFalse(dest.exists())


class DmsLockTest(unittest.TestCase):
    """Exercise the production lock function with real ordinary POSIX holders.

    The test wrapper retains locks behind a normal stdin barrier. It adds no
    runtime command or test hook to the shipped executable.
    """
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="schema-dms-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        wrapper = cls.base / "dms.c"
        wrapper.write_text(
            '#define main snapshot_command_main\n'
            f'#include {json.dumps(str(ROOT / "native/schema_snapshot/main.c"))}\n'
            '#undef main\n'
            'int main(int argc, char **argv) {\n'
            '    if (argc != 2 || !start_control(5000)) return 2;\n'
            '    int fd = open(argv[1], O_RDWR | O_NOFOLLOW);\n'
            '    if (fd < 0 || !lock_shm(fd)) return 2;\n'
            '    if (write(STDOUT_FILENO, "locked\\n", 7) != 7) return 2;\n'
            '    char byte;\n'
            '    (void)read(STDIN_FILENO, &byte, 1);\n'
            '    return close(fd) == 0 ? 0 : 2;\n'
            '}\n'
        )
        cls.binary = cls.base / "dms"
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra",
                        "-Werror", "-O2", str(wrapper), "-o", str(cls.binary)], check=True)

    def setUp(self):
        self.path = self.base / self._testMethodName
        self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
        self.addCleanup(os.close, self.fd)

    def start_helper(self):
        process = subprocess.Popen([str(self.binary), str(self.path)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        def close():
            process.stdin.close()
            process.wait(timeout=10)
            process.stdout.close()
            process.stderr.close()

        self.addCleanup(close)
        return process

    def test_no_dms_holder_retains_exclusive_lock(self):
        process = self.start_helper()
        self.assertEqual(process.stdout.readline(), b"locked\n")
        with self.assertRaises(BlockingIOError):
            fcntl.lockf(self.fd, fcntl.LOCK_SH | fcntl.LOCK_NB, 1, 128)

    def test_shared_dms_holder_is_joined(self):
        fcntl.lockf(self.fd, fcntl.LOCK_SH | fcntl.LOCK_NB, 1, 128)
        process = self.start_helper()
        self.assertEqual(process.stdout.readline(), b"locked\n")
        # The helper must itself retain shared DMS, so our upgrade cannot succeed.
        with self.assertRaises(BlockingIOError):
            fcntl.lockf(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 128)

    def test_exclusive_dms_holder_refuses(self):
        fcntl.lockf(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 128)
        process = self.start_helper()
        process.wait(timeout=10)
        self.assertEqual(process.returncode, 2)
        self.assertEqual((process.stdout.read(), process.stderr.read()), (b"", b""))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--owner":
        run_owner(sys.argv[2])
    else:
        unittest.main()
