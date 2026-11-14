# Unit tests for the generic detectors. Run by `nix flake check`. All data
# here is synthetic (example.* domains, documentation IP ranges, test cards).
import re
import unittest

from detectors_core import URL, Detectors
from pseudonym_core import Pseudonymizer

KEY = b"k" * 32
CONFIG = {
    "own_domains": ["mine.example", "SECRET_OWN_DOMAIN"],
    "allow_domains": ["github.com", "prisjakt.no"],
    "custom_patterns": [
        {"name": "no-id", "pattern": r"\b(?:[04][1-9]|[1256]\d|[37][01])(?:0[1-9]|1[0-2])\d{2} ?\d{5}\b", "label": "HASH", "urls": False},
        {
            "name": "no-phone",
            "pattern": r"(?<![\w+])(?:\+|00)47[  ]?(?:\d{2}[  ]?\d{2}[  ]?\d{2}[  ]?\d{2}|\d{3}[  ]?\d{2}[  ]?\d{3})\b"
            r"|\b[49]\d{7}\b|\b[49]\d{2}[  ]\d{2}[  ]\d{3}\b"
            r"|(?<!\d)(?<!\d )(?<!\d )\d{2}[  ]\d{2}[  ]\d{2}[  ]\d{2}(?![  ]?\d)",
            "label": "HASH",
            "urls": False,
        },
    ],
}
HASH = r"\[HASH:[0-9a-f]{16}\]"
IP = r"\[IP:[0-9a-f]{16}\]"


def det(config=CONFIG):
    return Detectors(config, Pseudonymizer(KEY))


class Email(unittest.TestCase):
    def test_personal_address_hashed(self):
        self.assertRegex(det().apply("from kari@example.org"), rf"^from {HASH}$")

    def test_machine_local_parts_readable(self):
        for a in ("noreply@shop.example", "no-reply@shop.example", "donotreply@x.example", "notifications@x.example",
                  "support+abc@x.example", "kundeservice@butikk.example", "newsletter@x.example", "mailer-daemon@x.example",
                  "noreply-alerts@x.example", "NoReply@Shop.Example"):
            with self.subTest(a=a):
                self.assertEqual(det().apply(a), a)

    def test_lookalike_local_part_still_hashed(self):
        for a in ("supporter@x.example", "kari.support@x.example", "replyto@x.example"):
            with self.subTest(a=a):
                self.assertRegex(det().apply(a), rf"^{HASH}$")

    def test_allowlisted_domain_and_subdomain_readable(self):
        for a in ("kari@github.com", "noreply@notifications.github.com", "deals@prisjakt.no"):
            with self.subTest(a=a):
                self.assertEqual(det().apply(a), a)

    def test_suffix_is_not_a_subdomain(self):
        self.assertRegex(det().apply("x@evilgithub.com"), rf"^{HASH}$")

    def test_own_domain_wins_over_every_allow_rule(self):
        cfg = dict(CONFIG, allow_domains=CONFIG["allow_domains"] + ["mine.example"])
        for a in ("kari@mine.example", "noreply@mine.example", "support@mail.mine.example"):
            with self.subTest(a=a):
                self.assertRegex(det(cfg).apply(a), rf"^{HASH}$")

    def test_own_domain_from_sops_value(self):
        cfg = dict(CONFIG, own_domains=["private.example"])
        self.assertRegex(det(cfg).apply("noreply@private.example"), rf"^{HASH}$")


class IpAddresses(unittest.TestCase):
    def test_v4_and_v6(self):
        out = det().apply("Login from 203.0.113.7 and 2001:db8::1 and 2001:0db8:0000:0000:0000:ff00:0042:8329.")
        self.assertRegex(out, rf"^Login from {IP} and {IP} and {IP}\.$")

    def test_ip_in_url_masked(self):
        self.assertRegex(det().apply("http://198.51.100.20:8080/x"), rf"^http://{IP}:8080/x$")

    def test_not_ips(self):
        for t in ("10:30", "12:34:56", "v2.0", "1.2.3", "300.1.1.1", "120.0.6099.109", "00:1a:2b:3c:4d:5e", "a::b", "dead::beef", "std::vector", "::"):
            with self.subTest(t=t):
                self.assertNotRegex(det().apply(t), IP)

    def test_same_ip_same_token(self):
        a, b = det().apply("203.0.113.7"), det().apply("203.0.113.7")
        self.assertEqual(a, b)


class Numbers(unittest.TestCase):
    def test_card_needs_luhn_and_prefix(self):
        self.assertRegex(det().apply("card 4111 1111 1111 1111"), rf"^card {HASH}$")
        self.assertEqual(det().apply("ref 4111 1111 1111 1112"), "ref 4111 1111 1111 1112")

    def test_norwegian_phone_and_id(self):
        out = det().apply("Ring +47 912 34 567 eller 91234567. Fnr 01019012345.")
        self.assertRegex(out, rf"^Ring {HASH} eller {HASH}\. Fnr {HASH}\.$")

    def test_norwegian_phone_2222_without_prefix(self):
        self.assertRegex(det().apply("\nKontakt: 12 34 56 78\n"), rf"^\nKontakt: {HASH}\n$")
        self.assertEqual(det().apply("12 34 56 78 90"), "12 34 56 78 90")

    def test_account_label_kept(self):
        self.assertRegex(det().apply("Account number 12345678901"), rf"^Account number {HASH}$")

    def test_iban(self):
        self.assertRegex(det().apply("IBAN NO9386011117947"), rf"^IBAN {HASH}$")

    def test_international_phone_needs_boundary(self):
        self.assertRegex(det().apply("call +4479460000001"), rf"^call {HASH}$")
        self.assertEqual(det().apply("x+4479460000001"), "x+4479460000001")


class Urls(unittest.TestCase):
    def test_numbers_inside_urls_untouched(self):
        for url in (
            "https://help.example.com/hc/en-us/articles/41234567-what-is-happening",
            "https://example.no/call/+4791234567",
            "https://pay.example/r/4111111111111111",
            "https://x.example/p?id=01019012345&n=91234567",
            "https://shop.example/s/[TRACKING]?ref=91234567",
        ):
            with self.subTest(url=url):
                self.assertEqual(det().apply(f"See {url} now"), f"See {url} now")

    def test_numbers_around_urls_still_masked(self):
        out = det().apply("91234567 https://a.example/41234567 91234567")
        self.assertRegex(out, rf"^{HASH} https://a\.example/41234567 {HASH}$")

    def test_email_inside_url_still_hashed(self):
        self.assertRegex(det().apply("https://a.example/unsub?e=kari@example.org"), rf"^https://a\.example/unsub\?e={HASH}$")

    def test_placeholder_does_not_end_url(self):
        m = URL.search("https://bring.example/s/[TRACKING]?x=1 tail")
        self.assertEqual(m.group(0), "https://bring.example/s/[TRACKING]?x=1")


class Mechanics(unittest.TestCase):
    def test_placeholders_never_redetected(self):
        text = "[HASH:0123456789abcdef] [IP:0123456789abcdef] [ORDER]"
        self.assertEqual(det().apply(text), text)

    def test_overlap_longest_earliest_wins(self):
        # The card run contains an 8-digit "phone"; the card wins, once.
        self.assertRegex(det().apply("4111111111111111"), rf"^{HASH}$")

    def test_counts_by_kind_only(self):
        counts = {}
        det().apply("kari@example.org 91234567 203.0.113.7 noreply@x.example", counts)
        self.assertEqual(counts, {"email": 1, "no-phone": 1, "ipv4": 1})

    def test_bad_label_refused(self):
        with self.assertRaises(ValueError):
            Detectors(dict(CONFIG, custom_patterns=[{"pattern": "x", "label": "NAME"}]), Pseudonymizer(KEY))


if __name__ == "__main__":
    unittest.main()
