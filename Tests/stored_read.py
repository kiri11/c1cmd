"""Lock-free reads of a Capture One database that may be open.

A SQLite reader's shared lock held while Capture One saves makes Capture One drop that save
and every later change to the document (#43). Read through `immutable=1`, which takes no lock,
and keep a result only when no save started or finished during the read.
"""
import sqlite3
import time
from contextlib import closing
from pathlib import Path


def stamp(database):
    """(header change counter, size, mtime_ns), or None while a -journal shows a commit in progress."""
    database = Path(database)
    if Path(str(database) + '-journal').exists():
        return None
    with open(database, 'rb') as file:
        header = file.read(28)
    if Path(str(database) + '-wal').exists() or header[18:20] != b'\x01\x01':
        raise RuntimeError(f'{database} is not in rollback-journal mode')
    status = database.stat()
    return header[24:28], status.st_size, status.st_mtime_ns


def read(database, query, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        before = stamp(database)
        if before is None:
            time.sleep(.05)
            continue
        error = None
        try:
            with closing(sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro&immutable=1', uri=True)) as connection:
                result = query(connection)
        except sqlite3.DatabaseError as raised:
            error = raised
        if stamp(database) == before:
            if error:
                raise error
            return result
    raise TimeoutError(f'{database} kept changing for {seconds} s')
