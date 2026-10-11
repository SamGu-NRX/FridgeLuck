"""Safe, strictly read-only access to the two fixture files.

Refusals are raised as InputRejected with a stable code; the CLI maps codes
to fixed, path-free explanations. This module never creates, repairs, or
migrates anything: inputs are opened with SQLite ``mode=ro`` and an extra
``PRAGMA query_only`` guard, and every refusal listed in the project brief is
checked before the database engine touches the file.
"""

import os
import sqlite3
import stat
from urllib.parse import quote

_SQLITE_MAGIC = b"SQLite format 3\x00"
_SIDECAR_SUFFIXES = ("-wal", "-shm", "-journal")


class InputRejected(Exception):
    """The named input is refused before any comparison happens."""

    def __init__(self, code, detail=""):
        self.code = code
        self.detail = detail
        super().__init__(f"{code}: {detail}" if detail else code)


def validate_input(path):
    """Validate a fixture path and return its absolute form.

    Refused codes: ``escape`` (parent traversal in the path), ``symlink``
    (final path component is a symlink), ``missing`` (nonexistent; never
    created), ``not_regular`` (directory, FIFO, device...), ``sidecar``
    (an active ``-wal``/``-shm``/``-journal`` sidecar exists), ``not_sqlite``
    (header magic mismatch), ``wal_mode`` (header declares WAL; the file
    alone may not represent committed state, so the host-dependent read is
    refused even when no sidecar is visible).
    """
    p = os.fspath(path)
    if not p:
        raise InputRejected("missing")
    if ".." in p.split(os.sep):
        raise InputRejected("escape")
    if os.path.islink(p):
        raise InputRejected("symlink")
    if not os.path.lexists(p):
        raise InputRejected("missing")
    st = os.lstat(p)
    if not stat.S_ISREG(st.st_mode):
        raise InputRejected("not_regular")
    for suffix in _SIDECAR_SUFFIXES:
        if os.path.lexists(p + suffix):
            raise InputRejected("sidecar")
    with open(p, "rb") as fh:
        header = fh.read(100)
    if len(header) < 100 or not header.startswith(_SQLITE_MAGIC):
        raise InputRejected("not_sqlite")
    if header[18] == 2 or header[19] == 2:
        raise InputRejected("wal_mode")
    return os.path.abspath(p)


def open_database_ro(path):
    """Open a validated fixture strictly read-only and return the connection.

    The path is percent-escaped into a ``file:...?mode=ro`` URI so hostile
    names (spaces, ``?``, ``#``, ``%``) cannot alter URI semantics. Reads on
    the returned connection never mutate the input file or its directory.
    """
    abspath = validate_input(path)
    uri = "file:" + quote(abspath, safe="/") + "?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, isolation_level=None)
    except sqlite3.Error:
        raise InputRejected("unreadable")
    try:
        conn.execute("PRAGMA query_only = ON")
        try:
            conn.execute("PRAGMA trusted_schema = OFF")
        except sqlite3.Error:
            pass  # older SQLite without trusted_schema; reads stay safe
    except sqlite3.Error:
        conn.close()
        raise InputRejected("unreadable")
    return conn
