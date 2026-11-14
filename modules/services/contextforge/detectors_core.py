# Generic PII detectors: e-mail, phone, card, IBAN/account, date of birth,
# IP, plus custom patterns from the config (Norwegian ID and phone numbers).
# Replaces IBM's cpex_pii_filter 0.3.9, whose hash salt is random per plugin
# instance and can't be configured, so its [HASH:…] changed on every restart.
# Built-in patterns, case-insensitivity, Luhn and card-prefix checks and the
# overlap rule (earliest start, then longest, wins) are ported from it
# (Apache-2.0). Ours: pseudonyms from pseudonym_core (stable, keyed), IP
# addresses, an allowlist for non-personal e-mail addresses, and numeric
# detectors skip URLs.
#
# Config (rendered by contextforge.nix):
#   own_domains        e-mail domains that are always hashed, allowlist or not
#   allow_domains      domains (and their subdomains) whose addresses stay readable
#   custom_patterns    [ { pattern, label, urls } ]  label "HASH" or "IP";
#                      urls=false skips URLs
import ipaddress
import logging
import re

logger = logging.getLogger(__name__)

# A URL, allowing our own placeholders inside it (`…/s/[TRACKING]?x=1`), so a
# rule's label doesn't end the URL early and expose the rest to number rules.
URL = re.compile(r"""https?://(?:[^\s"'<>()\[\]]|\[[A-Z_]+(?::[0-9a-f]{16})?\]|\([^\s"'<>()]*\))+""")
# Any placeholder, ours or a rule's label: never re-detected.
PLACEHOLDER = re.compile(r"\[[A-Z][A-Z_]*(?::[0-9a-f]{16})?\]")

# Local parts that are machines, not people (also with a +tag or suffix).
MACHINE_LOCAL = re.compile(
    r"^(?:no-?reply|do-?not-?reply|notifications?|support|kundeservice|newsletters?|mailer-daemon|postmaster)(?:[+._-].*)?$",
    re.IGNORECASE,
)


def _luhn_card(value):
    digits = [int(c) for c in value if c.isdigit()]
    n = len(digits)
    if not 13 <= n <= 19:
        return False
    total = 0
    parity = n % 2
    for i, d in enumerate(digits):
        if i % 2 == parity:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    if total % 10:
        return False
    s = "".join(map(str, digits))
    p2, p3, p4 = int(s[:2]), int(s[:3]), int(s[:4])
    return (
        (s[0] == "4" and n in (13, 16, 19))
        or (s[:2] in ("34", "37") and n == 15)
        or (s[:4] == "6011" and n in (16, 19))
        or (s[:2] == "65" and n in (16, 19))
        or (p2 == 62 and 16 <= n <= 19)
        or (p2 == 67 and 12 <= n <= 19)
        or (s[:2] in ("36", "38", "39") and n == 14)
        or (300 <= p3 <= 305 and n == 14)
        or (51 <= p2 <= 55 and n == 16)
        or (2221 <= p4 <= 2720 and n == 16)
        or (3528 <= p4 <= 3589 and n == 16)
    )


def _ip(value):
    # A bare "::" parses but says nothing about anyone, and an IPv6 address
    # without a digit is more likely a word pair ("dead::beef").
    if not re.search(r"\d", value):
        return False
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return False
    return True


# (name, label, regex, group to mask, validator, runs inside URLs)
BUILTIN = [
    ("email", "HASH", r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b", 0, None, True),
    ("ipv4", "IP", r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])", 0, _ip, True),
    # Candidates only; ipaddress decides (rejects 12:34:56, MAC-like runs).
    ("ipv6", "IP", r"(?<![\w:.])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![\w:])", 0, _ip, True),
    ("card", "HASH", r"\b(?:\d[-\s]?){12,18}\d\b", 0, _luhn_card, False),
    ("iban", "HASH", r"\b[A-Z]{2}\d{2}[A-Z0-9]{4}\d{7}(?:\d{3})?\b", 0, None, False),
    # The label stays readable; only the number is masked.
    (
        "account",
        "HASH",
        r"\b(?:Account|Acct|Bank\s+Account|Account\s+Number|Routing\s+Account)[#:\s-]*(\d{8,17})\b",
        1,
        None,
        False,
    ),
    ("dob", "HASH", r"\b(?:DOB|Date of Birth|Born|Birthday)[:\s]+\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b", 0, None, False),
    ("dob", "HASH", r"\b(?:0[1-9]|1[0-2])[-/](?:0[1-9]|[12]\d|3[01])[-/](?:19|20)\d{2}\b", 0, None, False),
    ("phone", "HASH", r"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b", 0, None, False),
    ("phone", "HASH", r"(?<![\w+])\+[1-9]\d{9,14}\b", 0, None, False),
]


def _domain_in(domain, domains):
    return any(domain == d or domain.endswith("." + d) for d in domains)


class Detectors:
    def __init__(self, config, pseudonymizer):
        self.p = pseudonymizer
        self.own = {d.strip().lower() for d in config.get("own_domains", []) if d.strip()}
        self.allow = {d.strip().lower() for d in config.get("allow_domains", []) if d.strip()}
        self.patterns = []
        specs = list(BUILTIN) + [
            (c.get("name", "custom"), c.get("label", "HASH"), c["pattern"], 0, None, c.get("urls", True))
            for c in config.get("custom_patterns", [])
        ]
        for name, label, pattern, group, check, urls in specs:
            if label not in ("HASH", "IP"):
                raise ValueError(f"detector {name}: label must be HASH or IP, not {label!r}")
            self.patterns.append((name, label, re.compile(pattern, re.IGNORECASE), group, check, urls))

    def readable_email(self, address):
        local, _, domain = address.rpartition("@")
        domain = domain.lower()
        if _domain_in(domain, self.own):
            return False
        return bool(MACHINE_LOCAL.match(local)) or _domain_in(domain, self.allow)

    def apply(self, text, counts=None):
        """Mask every detection in `text`. `counts` (a dict) collects
        detections per name, for logging; never values."""
        blocked = [m.span() for m in PLACEHOLDER.finditer(text)]
        urls = [m.span() for m in URL.finditer(text)]

        def inside(span, spans):
            return any(s <= span[0] and span[1] <= e for s, e in spans)

        def overlaps(span, spans):
            return any(span[0] < e and s < span[1] for s, e in spans)

        candidates = []
        for idx, (name, label, regex, group, check, in_urls) in enumerate(self.patterns):
            for m in regex.finditer(text):
                span = m.span(group)
                if span[0] == span[1] or overlaps(span, blocked):
                    continue
                if not in_urls and overlaps(span, urls):
                    continue
                value = m.group(group)
                if check is not None and not check(value):
                    continue
                candidates.append((span[0], -span[1], idx, name, label, value))
        candidates.sort()

        out, cursor = [], 0
        for start, neg_end, _, name, label, value in candidates:
            end = -neg_end
            if start < cursor:
                continue
            if name == "email" and self.readable_email(value):
                # Claims the span (no other detector cuts into it), unchanged.
                masked = value
            else:
                masked = self.p.token(label, value)
                if counts is not None:
                    counts[name] = counts.get(name, 0) + 1
            out.append(text[cursor:start])
            out.append(masked)
            cursor = end
        out.append(text[cursor:])
        return "".join(out)
