# Stable pseudonyms and the store that maps them back. No gateway imports, so
# `nix flake check` can test it; both plugins (scoped_filter, llm_detector)
# use it, and Python's module cache makes them share one store per path.
#
# A pseudonym is `[KIND:<16 hex>]`: the first 16 hex characters of
# HMAC-SHA256(key, normalised value). The key is a persistent secret, so the
# same value gets the same pseudonym across calls and restarts. Normalising:
# trim; e-mail addresses and LLM findings are also lower-cased.
#
# Every pseudonym written to a result is recorded (pseudonym → original) in a
# SQLite file, mode 0600, so tool *arguments* can carry it back: the agent
# can search `from:[HASH:…]`. Entries expire `ttl_days` after last use.
import hashlib
import hmac
import logging
import os
import re
import sqlite3
import threading
import time

logger = logging.getLogger(__name__)

PSEUDONYM = re.compile(r"\[(HASH|PII|IP):([0-9a-f]{16})\]")
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+$")


class PseudonymError(RuntimeError):
    """Pseudonymising failed; the call must fail rather than pass the original."""


def load_key(path):
    """The HMAC key, from a file only root and the gateway can read. Never
    logged, and a missing or short key stops the plugin from starting."""
    try:
        with open(path, "rb") as f:
            key = f.read().strip()
    except OSError as e:
        raise PseudonymError(f"pseudonym key {path}: {e.strerror}") from e
    if len(key) < 32:
        raise PseudonymError(f"pseudonym key {path}: shorter than 32 bytes")
    return key


def normalise(kind, value):
    value = value.strip()
    if kind == "PII" or _EMAIL.match(value):
        value = value.casefold()
    return value


class Pseudonymizer:
    """Turns values into pseudonyms and remembers which, until `flush`."""

    def __init__(self, key, store=None):
        self._key = key
        self.store = store
        self._pending = {}
        self._lock = threading.Lock()

    def token(self, kind, value):
        digest = hmac.new(self._key, normalise(kind, value).encode(), hashlib.sha256).hexdigest()
        placeholder = f"[{kind}:{digest[:16]}]"
        with self._lock:
            self._pending.setdefault(placeholder, value.strip())
        return placeholder

    def flush(self):
        """Record what was handed out since the last flush. Raises on a store
        error, so a result is never returned with pseudonyms that can't be
        resolved later, nor without being recorded."""
        with self._lock:
            pending, self._pending = self._pending, {}
        if pending and self.store is not None:
            self.store.put(pending)


class Store:
    def __init__(self, path, ttl_days=180):
        self.path = path
        self.ttl = int(ttl_days * 86400)
        self._lock = threading.Lock()
        try:
            # Created 0600 before SQLite opens it; its journal files copy the
            # mode. The directory is the gateway's own (0700).
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
            os.close(fd)
            os.chmod(path, 0o600)
            self._db = sqlite3.connect(path, check_same_thread=False, timeout=10)
            self._db.execute(
                "CREATE TABLE IF NOT EXISTS pseudonyms ("
                " placeholder TEXT PRIMARY KEY, original TEXT NOT NULL, last_seen INTEGER NOT NULL)"
            )
            self._db.commit()
        except (OSError, sqlite3.Error) as e:
            raise PseudonymError(f"pseudonym store {path}: {e}") from e
        self._last_expiry = 0
        self.expire()

    def put(self, mapping):
        now = int(time.time())
        try:
            with self._lock, self._db:
                self._db.executemany(
                    "INSERT INTO pseudonyms (placeholder, original, last_seen) VALUES (?, ?, ?)"
                    " ON CONFLICT(placeholder) DO UPDATE SET last_seen = excluded.last_seen",
                    [(p, o, now) for p, o in mapping.items()],
                )
        except sqlite3.Error as e:
            raise PseudonymError(f"pseudonym store: {e}") from e
        if now - self._last_expiry > 3600:
            self.expire()

    def get(self, placeholders):
        """{placeholder: original} for those known; refreshes their age."""
        placeholders = list(dict.fromkeys(placeholders))
        if not placeholders:
            return {}
        now = int(time.time())
        marks = ",".join("?" * len(placeholders))
        try:
            with self._lock, self._db:
                rows = self._db.execute(
                    f"SELECT placeholder, original FROM pseudonyms WHERE placeholder IN ({marks})", placeholders
                ).fetchall()
                self._db.execute(f"UPDATE pseudonyms SET last_seen = ? WHERE placeholder IN ({marks})", [now, *placeholders])
        except sqlite3.Error as e:
            raise PseudonymError(f"pseudonym store: {e}") from e
        return dict(rows)

    def close(self):
        with self._lock:
            self._db.close()

    def expire(self):
        now = int(time.time())
        try:
            with self._lock, self._db:
                n = self._db.execute("DELETE FROM pseudonyms WHERE last_seen < ?", (now - self.ttl,)).rowcount
        except sqlite3.Error as e:
            raise PseudonymError(f"pseudonym store: {e}") from e
        self._last_expiry = now
        if n:
            logger.info("pseudonym store: expired %d entr%s", n, "y" if n == 1 else "ies")


_stores = {}
_stores_lock = threading.Lock()


def open_store(path, ttl_days=180):
    """One Store per path in this process, shared by both plugins."""
    with _stores_lock:
        if path not in _stores:
            _stores[path] = Store(path, ttl_days)
        return _stores[path]


def restore(value, store):
    """Replace known pseudonyms in a tool argument (any JSON shape) with the
    originals. Unknown ones stay as they are; only their tokens are logged."""
    found = set()

    def collect(node):
        if isinstance(node, str):
            found.update(m.group(0) for m in PSEUDONYM.finditer(node))
        elif isinstance(node, dict):
            for v in node.values():
                collect(v)
        elif isinstance(node, list):
            for v in node:
                collect(v)

    collect(value)
    if not found:
        return value
    known = store.get(found)
    unknown = sorted(found - known.keys())
    if unknown:
        logger.info("pseudonym restore: %d unknown, passed through: %s", len(unknown), " ".join(unknown))

    def rewrite(node):
        if isinstance(node, str):
            return PSEUDONYM.sub(lambda m: known.get(m.group(0), m.group(0)), node)
        if isinstance(node, dict):
            return {k: rewrite(v) for k, v in node.items()}
        if isinstance(node, list):
            return [rewrite(v) for v in node]
        return node

    return rewrite(value)
