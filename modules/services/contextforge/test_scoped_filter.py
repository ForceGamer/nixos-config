# Unit tests for the rule engine, plus the examples from the host's rule
# files (passed as $EXAMPLES, a JSON file) against the rendered config
# ($CONFIG). Run by `nix flake check`. All data here is synthetic.
import json
import os
import unittest

from scoped_filter_core import ScopedFilter

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


class HostExamples(unittest.TestCase):
    """Examples declared next to the host's rules, run through the real
    rendered config. Secret placeholders are replaced by SECRET_ plus the
    secret's key in UPPER_SNAKE (see contextforge.nix)."""

    def test_examples(self):
        if "CONFIG" not in os.environ:
            self.skipTest("no rendered config given")
        f = ScopedFilter(json.load(open(os.environ["CONFIG"])))
        examples = json.load(open(os.environ["EXAMPLES"]))
        for ex in examples:
            with self.subTest(group=ex["group"], input=ex["input"]):
                got = f.filter_text(ex["input"], ex.get("from"), ex.get("subject"))
                self.assertEqual(got, ex["expect"])


if __name__ == "__main__":
    unittest.main()
