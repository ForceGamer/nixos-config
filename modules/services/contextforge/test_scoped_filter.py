# Unit tests for the rule engine, plus the examples from the host's rule
# files (passed as $EXAMPLES, a JSON file) against the rendered config
# ($CONFIG). Run by `nix flake check`. All data here is synthetic.
import json
import os
import re
import tempfile
import unittest

from detectors_core import URL, Detectors
from pseudonym_core import Pseudonymizer, Store
from scoped_filter_core import ScopedFilter

KEY = b"k" * 32
HASH = r"\[HASH:[0-9a-f]{16}\]"

CFG = {
    "groups": [
        {"name": "names", "when": None, "rules": [{"search": r"\bAda Lovelace\b", "replace": "[NAME]"}]},
        {
            "name": "shop",
            "when": {"from": r"@shop\.example$", "subject": None},
            "rules": [{"search": r">[0-9]+</div>", "replace": ">[ORDER_ID]</div>"}],
        },
        {
            "name": "bank",
            "when": {"from": r"@bank\.example$", "subject": r"statement"},
            "rules": [{"search": r"\bACC-[0-9]+\b", "replace": "[ACCOUNT]"}],
        },
    ]
}
SHOP_HTML = "<div>Order</div><div>4471023</div>"


class ScopingTests(unittest.TestCase):
    def setUp(self):
        self.f = ScopedFilter(CFG)

    def test_global_rule_always_applies(self):
        self.assertEqual(self.f.filter_text("Hi ada lovelace!"), "Hi [NAME]!")

    def test_scoped_rule_applies_to_matching_sender(self):
        out = self.f.filter_result({"from": "noreply@shop.example", "subject": "Receipt", "body": SHOP_HTML})
        self.assertIn("[ORDER_ID]", out["body"])

    def test_scoped_rule_skipped_for_other_sender(self):
        out = self.f.filter_result({"from": "friend@mail.example", "subject": "Hi", "body": SHOP_HTML})
        self.assertEqual(out["body"], SHOP_HTML)

    def test_both_when_fields_must_match(self):
        bank = {"from": "x@bank.example", "subject": "Your card", "body": "ACC-123"}
        self.assertEqual(self.f.filter_result(bank)["body"], "ACC-123")
        bank["subject"] = "Monthly statement"
        self.assertEqual(self.f.filter_result(bank)["body"], "[ACCOUNT]")

    def test_unknown_shape_applies_everything(self):
        out = self.f.filter_result({"data": SHOP_HTML + " ACC-9 Ada Lovelace"})
        self.assertEqual(out["data"], "<div>Order</div><div>[ORDER_ID]</div> [ACCOUNT] [NAME]")

    def test_list_of_emails_scoped_individually(self):
        out = self.f.filter_result(
            [
                {"from": "a@shop.example", "subject": "s", "body": SHOP_HTML},
                {"from": "b@other.example", "subject": "s", "body": SHOP_HTML},
            ]
        )
        self.assertIn("[ORDER_ID]", out[0]["body"])
        self.assertEqual(out[1]["body"], SHOP_HTML)

    def test_from_as_object(self):
        out = self.f.filter_result({"from": {"name": "Shop", "email": "x@shop.example"}, "body": SHOP_HTML})
        self.assertIn("[ORDER_ID]", out["body"])

    def test_json_in_text_block_is_scrubbed_structurally(self):
        payload = {"content": [{"type": "text", "text": json.dumps({"from": "a@shop.example", "body": SHOP_HTML})}]}
        out = self.f.filter_result(payload)
        inner = json.loads(out["content"][0]["text"])
        self.assertIn("[ORDER_ID]", inner["body"])

    def test_plain_text_email_with_headers(self):
        text = "From: a@shop.example\nSubject: Receipt\n\n" + SHOP_HTML
        self.assertIn("[ORDER_ID]", self.f.filter_result(text))
        text = "From: a@other.example\nSubject: Receipt\n\n" + SHOP_HTML
        self.assertNotIn("[ORDER_ID]", self.f.filter_result(text))

    def test_plain_text_without_headers_applies_everything(self):
        self.assertIn("[ORDER_ID]", self.f.filter_result(SHOP_HTML))

    def test_non_string_leaves_untouched(self):
        self.assertEqual(self.f.filter_result({"n": 4471023, "ok": True}), {"n": 4471023, "ok": True})

    def test_bad_regex_fails_at_load(self):
        with self.assertRaises(Exception):
            ScopedFilter({"groups": [{"name": "x", "when": None, "rules": [{"search": "(", "replace": ""}]}]})

    def test_bad_backreference_fails_at_load(self):
        with self.assertRaises(Exception):
            ScopedFilter({"groups": [{"name": "x", "when": None, "rules": [{"search": "a", "replace": r"\2"}]}]})

    def test_colon_group_typo_rejected(self):
        with self.assertRaisesRegex(Exception, r"\(\?:"):
            ScopedFilter({"groups": [{"name": "x", "when": None, "rules": [{"search": "(:?a|b)", "replace": "_"}]}]})

    def test_load_error_names_the_rule(self):
        with self.assertRaisesRegex(Exception, r"group 'x' rule 2"):
            ScopedFilter({"groups": [{"name": "x", "when": None, "rules": [{"search": "a", "replace": "_"}, {"search": "b", "replace": r"\1"}]}]})

    def test_own_flags_respected(self):
        f = ScopedFilter({"groups": [{"name": "x", "when": None, "rules": [{"search": "(?-i:ABC)", "replace": "_"}]}]})
        self.assertEqual(f.filter_text("abc ABC"), "abc _")


SERVER_CFG = {
    "servers": {"id-mail": "mail", "id-notes": "notes"},
    "groups": [
        {"name": "global", "when": None, "rules": [{"search": r"\bAda\b", "replace": "[NAME]"}]},
        {"name": "mail", "server": "mail", "when": None, "rules": [{"search": r"\bACC-[0-9]+\b", "replace": "[ACCOUNT]"}]},
        {
            "name": "mail-shop",
            "server": "mail",
            "when": {"from": r"@shop\.example$", "subject": None},
            "rules": [{"search": r"\bORD-[0-9]+\b", "replace": "[ORDER]"}],
        },
        {"name": "notes", "server": "notes", "when": None, "rules": [{"search": r"\bPIN [0-9]{4}\b", "replace": "PIN [PIN]"}]},
    ],
}
SERVER_TEXT = "Ada ACC-12 PIN 1234"


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.f = ScopedFilter(SERVER_CFG)

    def test_server_groups_add_to_global(self):
        self.assertEqual(self.f.filter_result(SERVER_TEXT, "id-mail"), "[NAME] [ACCOUNT] PIN 1234")
        self.assertEqual(self.f.filter_result(SERVER_TEXT, "id-notes"), "[NAME] ACC-12 PIN [PIN]")

    def test_unknown_server_gets_every_group(self):
        # A wrong or missing id over-filters; it never drops a server's rules.
        for sid in ("id-other", "unknown", None):
            with self.subTest(server_id=sid):
                self.assertEqual(self.f.filter_result(SERVER_TEXT, sid), "[NAME] [ACCOUNT] PIN [PIN]")

    def test_server_and_sender_scopes_combine(self):
        email = {"from": "x@shop.example", "subject": "s", "body": "ORD-7 ACC-1"}
        self.assertEqual(self.f.filter_result(email, "id-mail")["body"], "[ORDER] [ACCOUNT]")
        self.assertEqual(self.f.filter_result(email, "id-notes")["body"], "ORD-7 ACC-1")
        email["from"] = "x@other.example"
        self.assertEqual(self.f.filter_result(email, "id-mail")["body"], "ORD-7 [ACCOUNT]")

    def test_json_text_block_keeps_server_scope(self):
        payload = {"content": [{"type": "text", "text": json.dumps({"from": "a@x.example", "body": SERVER_TEXT})}]}
        inner = json.loads(self.f.filter_result(payload, "id-notes")["content"][0]["text"])
        self.assertEqual(inner["body"], "[NAME] ACC-12 PIN [PIN]")

    def test_group_for_undeclared_server_fails_at_load(self):
        cfg = {"servers": {}, "groups": [{"name": "x", "server": "mail", "when": None, "rules": []}]}
        with self.assertRaisesRegex(Exception, r"server 'mail' has no id"):
            ScopedFilter(cfg)


DETECTORS = {
    "own_domains": ["mine.example"],
    "allow_domains": ["github.com"],
    "custom_patterns": [
        {"name": "no-phone", "pattern": r"\b[49]\d{7}\b", "label": "HASH", "urls": False},
    ],
}
PIPE_CFG = {
    "detectors": DETECTORS,
    "groups": [
        {"name": "people", "when": None, "rules": [{"search": r"\bAda Lovelace\b", "replace": "[NAME]", "literal": True}]},
        {
            "name": "money",
            "when": None,
            "rules": [{"search": r"[0-9]+\s?kr", "replace": "[AMOUNT]", "urls": False}],
        },
        {
            "name": "links",
            "when": None,
            "rules": [{"search": r"(https?://[^\s]*/c/)[A-Za-z0-9_-]{40,}", "replace": r"\1[TOKEN]"}],
        },
        {"name": "uuid", "when": None, "rules": [{"search": r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", "replace": "[UUID]"}]},
    ],
}
EMAIL = {
    "id": "M1",
    "messageId": ["<ada.lovelace.91234567@mail.mine.example>"],
    "from": [{"name": "Ada Lovelace", "email": "ada@example.org"}],
    "to": [{"name": "Me", "email": "me@mine.example"}],
    "subject": "Order 499 kr",
    "preview": "Call me on 91234567. Paid 499 kr. https://help.example.com/articles/41234567-why-499kr",
}


def result(email):
    obj = {"results": [email]}
    return {"content": [{"type": "text", "text": json.dumps(obj)}], "structuredContent": obj, "isError": False}


class Pipeline(unittest.TestCase):
    """Rules, then detectors, as the plugin runs them."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "p.db")
        self.stores = []

    def tearDown(self):
        for s in self.stores:
            s.close()
        self.dir.cleanup()

    def fresh(self):
        # What a gateway restart amounts to: new instances, same key and file.
        self.stores.append(Store(self.path))
        return ScopedFilter(PIPE_CFG, Pseudonymizer(KEY, self.stores[-1]))

    def test_deterministic_across_calls_and_restart(self):
        f = self.fresh()
        first = json.dumps(f.filter_result(result(EMAIL), "srv"), sort_keys=True)
        second = json.dumps(f.filter_result(result(EMAIL), "srv"), sort_keys=True)
        after_restart = json.dumps(self.fresh().filter_result(result(EMAIL), "srv"), sort_keys=True)
        self.assertEqual(first, second)
        self.assertEqual(first, after_restart)
        self.assertRegex(first, HASH)

    def test_search_and_read_agree(self):
        # The same sender in a search result and in a single-email read.
        f = self.fresh()
        search = f.filter_result(result(EMAIL))["structuredContent"]["results"][0]["from"][0]["email"]
        read = self.fresh().filter_result(json.dumps(EMAIL))
        self.assertIn(search, read)

    def test_message_id_gets_literal_rules_only(self):
        out = self.fresh().filter_result(EMAIL)
        self.assertEqual(out["messageId"], ["<ada.lovelace.91234567@mail.mine.example>"])
        cfg = json.loads(json.dumps(PIPE_CFG))
        cfg["groups"][0]["rules"][0]["search"] = r"ada\.lovelace"
        out = ScopedFilter(cfg, Pseudonymizer(KEY)).filter_result(EMAIL)
        self.assertEqual(out["messageId"], ["<[NAME].91234567@mail.mine.example>"])

    def test_allowlist_and_own_address(self):
        email = dict(EMAIL, **{"from": [{"name": "GitHub", "email": "noreply@github.com"}]})
        out = self.fresh().filter_result(email)
        self.assertEqual(out["from"][0]["email"], "noreply@github.com")
        self.assertRegex(out["to"][0]["email"], f"^{HASH}$")
        self.assertRegex(self.fresh().filter_text("support@mine.example"), f"^{HASH}$")

    def test_detectors_need_a_pseudonymizer(self):
        with self.assertRaisesRegex(Exception, "pseudonymizer"):
            ScopedFilter(PIPE_CFG)


# Synthetic URLs shaped like the false positives seen in operation: a
# tracking token with digits and "kr" in it, an article slug with an 8-digit
# id, numbers in query strings, a card-shaped path, a long tracking token.
URL_FIXTURES = [
    "https://click.mail.example/ls/click?upn=u001.AbC49krBfqqhTNGuVuXX_d0a1b2c3d4e5f6g7h8i9j0kLmNoPqRsTuV-WxYz",
    "https://help.example.com/hc/en-us/articles/41234567-what-is-happening-to-my-order",
    "https://shop.example/p/kr1299?qty=2&tel=91234567&amount=49kr",
    "https://pay.example/r/4111111111111111/receipt",
    "https://tracking.example/c/AbCdEfGh1234567890IjKlMnOpQrStUvWxYz0123456789",
    "https://news.example/2026/11/14/99-kr-deals-12345678901234567",
]
# Inside a URL these may appear only where a URL rule put them.
NUMERIC_TAGS = re.compile(r"\[(?:AMOUNT|CRYPTO_AMOUNT|LONG_ID|ORDER|ORDER_ID|VOUCHER|CUSTOMER_NO)\]|\[HASH:")


class UrlFixtures(unittest.TestCase):
    """No number, amount or phone tags inside URLs, with the synthetic
    pipeline and, in the flake check, with the host's real rules."""

    def filters(self):
        yield "synthetic", ScopedFilter(PIPE_CFG, Pseudonymizer(KEY))
        if "CONFIG" in os.environ:
            with open(os.environ["CONFIG"]) as fh:
                yield "host rules", ScopedFilter(json.load(fh), Pseudonymizer(KEY))

    def test_no_numeric_tags_inside_urls(self):
        for name, f in self.filters():
            for url in URL_FIXTURES:
                text = f"Total 499 kr, ring 91234567: {url} . Kort 4111 1111 1111 1111."
                with self.subTest(rules=name, url=url):
                    out = f.filter_text(text)
                    urls = URL.findall(out)
                    self.assertEqual(len(urls), 1, out)
                    self.assertIsNone(NUMERIC_TAGS.search(urls[0]), urls[0])
                    # Outside the URL the same rules still work.
                    outside = out.replace(urls[0], "")
                    self.assertNotIn("91234567", outside)
                    self.assertNotIn("4111 1111", outside)
                    self.assertNotIn("499", outside)

    def test_token_rule_still_applies_in_urls(self):
        out = ScopedFilter(PIPE_CFG, Pseudonymizer(KEY)).filter_text(URL_FIXTURES[4])
        self.assertEqual(out, "https://tracking.example/c/[TOKEN]")


class HostPhoneFormats(unittest.TestCase):
    """The host's real detector config (flake check only): phone formats
    seen in mail are masked; digit groups that aren't phone numbers stay."""

    NBSP = "\u00a0"
    MASKED = [
        "\nKontakt: 12 34 56 78\n",
        "Tlf. 22 33 44 55.",
        "tlf:22 33 44 55",
        "(22 33 44 55)",
        f"12{NBSP}34{NBSP}56{NBSP}78",
        "+47 12 34 56 78",
        f"+47{NBSP}912{NBSP}34{NBSP}567",
        f"412{NBSP}34{NBSP}567",
        "Ring 91234567",
        "0047 41234567",
    ]
    KEPT = ["Org.nr 912 345 678", "12 34 56 78 90", "Kontonr 1234 56 78903", "kl. 12 34", "2026 11 14", "1 22 33 44 55"]

    def detectors(self):
        if "CONFIG" not in os.environ:
            self.skipTest("no rendered config given")
        with open(os.environ["CONFIG"]) as fh:
            return Detectors(json.load(fh)["detectors"], Pseudonymizer(KEY))

    def test_masked(self):
        d = self.detectors()
        for text in self.MASKED:
            with self.subTest(text=text):
                out = d.apply(text)
                self.assertRegex(out, HASH)
                self.assertNotRegex(re.sub(HASH, "", out), r"\d{2}[ \u00a0]?\d{2}")

    def test_kept(self):
        d = self.detectors()
        for text in self.KEPT:
            with self.subTest(text=text):
                self.assertEqual(d.apply(text), text)


class HostExamples(unittest.TestCase):
    """Examples declared next to the host's rules, run through the real
    rendered config. Secret placeholders are replaced by SECRET_ plus the
    secret's key in UPPER_SNAKE (see contextforge.nix)."""

    def test_examples(self):
        if "CONFIG" not in os.environ:
            self.skipTest("no rendered config given")
        with open(os.environ["CONFIG"]) as fh:
            config = json.load(fh)
        # Examples document the rules; the detectors have their own tests.
        config.pop("detectors", None)
        f = ScopedFilter(config)
        with open(os.environ["EXAMPLES"]) as fh:
            examples = json.load(fh)
        for ex in examples:
            with self.subTest(group=ex["group"], input=ex["input"]):
                # A server's examples run in that server's context; global
                # ones in an unknown context, where every group applies.
                got = f.filter_text(ex["input"], ex.get("from"), ex.get("subject"), ex.get("server"))
                self.assertEqual(got, ex["expect"])


if __name__ == "__main__":
    unittest.main()
