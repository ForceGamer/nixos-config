# Unit tests for stable pseudonyms and the reverse store. Run by `nix flake
# check`. All data here is synthetic.
import os
import sqlite3
import stat
import tempfile
import time
import unittest

from pseudonym_core import PSEUDONYM, Pseudonymizer, PseudonymError, Store as _Store, load_key, restore

KEY = b"k" * 32
_open = []


def Store(*a, **kw):
    s = _Store(*a, **kw)
    _open.append(s)
    return s


def tearDownModule():
    for s in _open:
        s.close()


def _write(path, text):
    with open(path, "w") as f:
        f.write(text)


class Tokens(unittest.TestCase):
    def test_format_is_16_hex(self):
        self.assertRegex(Pseudonymizer(KEY).token("HASH", "kari@example.org"), r"^\[HASH:[0-9a-f]{16}\]$")

    def test_same_value_same_token_across_instances(self):
        # A restart is a new instance with the same key.
        a = Pseudonymizer(KEY).token("HASH", "kari@example.org")
        b = Pseudonymizer(KEY).token("HASH", "kari@example.org")
        self.assertEqual(a, b)

    def test_key_matters(self):
        self.assertNotEqual(
            Pseudonymizer(KEY).token("HASH", "kari@example.org"), Pseudonymizer(b"x" * 32).token("HASH", "kari@example.org")
        )

    def test_trimmed_and_email_lowercased(self):
        p = Pseudonymizer(KEY)
        self.assertEqual(p.token("HASH", " Kari@Example.ORG "), p.token("HASH", "kari@example.org"))

    def test_other_values_keep_case(self):
        p = Pseudonymizer(KEY)
        self.assertNotEqual(p.token("HASH", "AB12CD"), p.token("HASH", "ab12cd"))

    def test_llm_findings_case_folded(self):
        p = Pseudonymizer(KEY)
        self.assertEqual(p.token("PII", "KARI NORDMANN"), p.token("PII", "Kari Nordmann"))

    def test_kind_is_the_prefix_only(self):
        p = Pseudonymizer(KEY)
        self.assertEqual(p.token("HASH", "10.1.2.3")[6:], p.token("IP", "10.1.2.3")[4:])


class Keys(unittest.TestCase):
    def test_missing_or_short_key_refused(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(PseudonymError):
                load_key(os.path.join(d, "absent"))
            short = os.path.join(d, "short")
            _write(short, "too short\n")
            with self.assertRaises(PseudonymError):
                load_key(short)
            good = os.path.join(d, "good")
            _write(good, "a" * 64 + "\n")
            self.assertEqual(load_key(good), b"a" * 64)

    def test_error_never_contains_the_key(self):
        with tempfile.TemporaryDirectory() as d:
            short = os.path.join(d, "short")
            _write(short, "SECRETVALUE")
            with self.assertRaises(PseudonymError) as cm:
                load_key(short)
            self.assertNotIn("SECRETVALUE", str(cm.exception))


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "p.db")

    def tearDown(self):
        self.dir.cleanup()

    def test_file_is_0600(self):
        Store(self.path)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)

    def test_flush_then_lookup_survives_reopen(self):
        p = Pseudonymizer(KEY, Store(self.path))
        tok = p.token("HASH", "kari@example.org")
        p.flush()
        self.assertEqual(Store(self.path).get([tok]), {tok: "kari@example.org"})

    def test_nothing_recorded_before_flush(self):
        p = Pseudonymizer(KEY, Store(self.path))
        tok = p.token("HASH", "kari@example.org")
        self.assertEqual(Store(self.path).get([tok]), {})

    def test_expiry(self):
        s = Store(self.path, ttl_days=1)
        s.put({"[HASH:00000000000000aa]": "old", "[HASH:00000000000000bb]": "new"})
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE pseudonyms SET last_seen = ? WHERE original = 'old'", (int(time.time()) - 2 * 86400,))
        s.expire()
        self.assertEqual(s.get(["[HASH:00000000000000aa]", "[HASH:00000000000000bb]"]), {"[HASH:00000000000000bb]": "new"})

    def test_lookup_refreshes_age(self):
        s = Store(self.path, ttl_days=1)
        s.put({"[HASH:00000000000000aa]": "v"})
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE pseudonyms SET last_seen = ?", (int(time.time()) - 2 * 86400,))
        s.get(["[HASH:00000000000000aa]"])
        s.expire()
        self.assertEqual(s.get(["[HASH:00000000000000aa]"]), {"[HASH:00000000000000aa]": "v"})

    def test_unusable_store_fails(self):
        with self.assertRaises(PseudonymError):
            Store(os.path.join(self.dir.name, "missing-dir", "p.db"))
        s = Store(self.path)
        with sqlite3.connect(self.path) as db:
            db.execute("DROP TABLE pseudonyms")
        with self.assertRaises(PseudonymError):
            s.put({"[HASH:00000000000000aa]": "v"})
        with self.assertRaises(PseudonymError):
            s.get(["[HASH:00000000000000aa]"])


class Restore(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = Store(os.path.join(self.dir.name, "p.db"))
        self.p = Pseudonymizer(KEY, self.store)

    def tearDown(self):
        self.dir.cleanup()

    def test_round_trip_in_any_argument_shape(self):
        tok = self.p.token("HASH", "kari@example.org")
        ip = self.p.token("IP", "203.0.113.7")
        self.p.flush()
        args = {"query": f"from:{tok}", "to": [tok], "nested": {"note": f"login from {ip}"}, "limit": 5}
        self.assertEqual(
            restore(args, self.store),
            {"query": "from:kari@example.org", "to": ["kari@example.org"], "nested": {"note": "login from 203.0.113.7"}, "limit": 5},
        )

    def test_unknown_passes_through_and_only_token_is_logged(self):
        tok = self.p.token("HASH", "kari@example.org")
        self.p.flush()
        unknown = "[HASH:0123456789abcdef]"
        with self.assertLogs("pseudonym_core", level="INFO") as logs:
            out = restore({"q": f"{tok} {unknown}"}, self.store)
        self.assertEqual(out, {"q": f"kari@example.org {unknown}"})
        self.assertIn(unknown, logs.output[0])
        self.assertNotIn("kari", "".join(logs.output))

    def test_labels_are_not_pseudonyms(self):
        self.assertEqual(restore({"q": "[NAME] [ORDER] [HASH:short]"}, self.store), {"q": "[NAME] [ORDER] [HASH:short]"})
        self.assertIsNone(PSEUDONYM.search("[ORDER]"))


if __name__ == "__main__":
    unittest.main()
