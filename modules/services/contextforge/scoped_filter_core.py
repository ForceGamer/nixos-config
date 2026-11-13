# Rule engine for the scoped PII filter. No gateway imports, so it can be
# unit-tested in `nix flake check`; scoped_filter.py wraps it as a plugin.
#
# Config shape (rendered by contextforge.nix from hosts/<host>/pii/*.nix):
#   groups: [ { name, server: name|null,
#               when: null | { from: regex|null, subject: regex|null },
#               rules: [ { search, replace } ] } ]
#   servers: { <upstream server id>: <name> }  the gateway's ids for the
#   upstream MCP servers that have their own rule groups.
#   from_keys / subject_keys: dict keys that identify an email's sender and
#   subject when a tool returns structured data.
#
# Semantics, in order of importance:
#   1. A group with `server: null` and `when: null` is global and always
#      applies.
#   2. A group with a `server` applies to results from that upstream server.
#   3. A scoped group applies to an email whose sender and subject both match
#      its regexes (a missing `from` or `subject` in `when` matches anything).
#   4. Where the server or the email can't be recognised, the groups scoped
#      to it apply as if it matched: an id missing from `servers` gets every
#      server's groups. Scoping may add rules to a known context; it never
#      removes protection from an unknown one.
# Rules within a group, and groups themselves, run in order, each on the
# output of the previous one.
import json
import re

DEFAULT_FROM_KEYS = ("from", "sender", "From", "Sender")
DEFAULT_SUBJECT_KEYS = ("subject", "Subject")

# Plain-text results: "From: ..." / "Subject: ..." lines (RFC 822 style, or a
# markdown rendering of them).
_TEXT_FROM = re.compile(r"^\W{0,3}from:\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE)
_TEXT_SUBJECT = re.compile(r"^\W{0,3}subject:\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE)

_FLAG_GROUP = re.compile(r"\(\?[a-zA-Z]+\)")


class RuleError(ValueError):
    """A rule that can't be loaded. Names the group and rule, since Python's
    own message doesn't say where the regex came from."""


def _compile(search, where):
    """Every rule is case-insensitive unless it opens with its own flags."""
    if "(:?" in search:
        # A capturing group starting with an optional colon: never what the
        # author meant, and it silently renumbers \1.
        raise RuleError(f"{where}: '(:?' in {search!r}; a non-capturing group is '(?:'")
    if not _FLAG_GROUP.match(search):
        search = "(?i)" + search
    try:
        return re.compile(search)
    except re.error as e:
        raise RuleError(f"{where}: {search!r}: {e}") from e


class Group:
    def __init__(self, spec):
        self.name = spec.get("name", "?")
        self.server = spec.get("server")
        when = spec.get("when")
        self.scoped = when is not None
        where = f"group {self.name!r}"
        self.when_from = _compile(when["from"], where + " when.from") if when and when.get("from") else None
        self.when_subject = _compile(when["subject"], where + " when.subject") if when and when.get("subject") else None
        self.rules = []
        for i, r in enumerate(spec["rules"]):
            pattern = _compile(r["search"], f"{where} rule {i + 1}")
            try:
                # Fail at load time on a bad backreference, not on the first email.
                pattern.sub(r["replace"], "probe")
            except re.error as e:
                raise RuleError(f"{where} rule {i + 1}: replace {r['replace']!r} for {r['search']!r}: {e}") from e
            self.rules.append((pattern, r["replace"]))

    def matches(self, sender, subject, server=None):
        """Only a *known* server, sender or subject that fails excludes the
        group; an unknown one (None) never does. That is what makes an
        unrecognised result get every rule."""
        if self.server is not None and server is not None and self.server != server:
            return False
        if not self.scoped:
            return True
        if self.when_from is not None and sender is not None and not self.when_from.search(sender):
            return False
        if self.when_subject is not None and subject is not None and not self.when_subject.search(subject):
            return False
        return True

    def apply(self, text):
        for pattern, replace in self.rules:
            text = pattern.sub(replace, text)
        return text


def _as_text(value):
    """Sender/subject fields may be strings, {name,email} objects or lists of
    either; flatten to the strings they contain, space-separated, so a
    `when.from` regex sees `Shop <x@shop.example>`-like text."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return " ".join(_as_text(v) for v in value.values())
    if isinstance(value, list):
        return " ".join(_as_text(v) for v in value)
    return str(value)


class ScopedFilter:
    def __init__(self, config):
        self.groups = [Group(g) for g in config.get("groups", [])]
        self.servers = dict(config.get("servers") or {})
        known = set(self.servers.values())
        for g in self.groups:
            if g.server is not None and g.server not in known:
                raise RuleError(f"group {g.name!r}: server {g.server!r} has no id in `servers`")
        self.from_keys = tuple(config.get("from_keys", DEFAULT_FROM_KEYS))
        self.subject_keys = tuple(config.get("subject_keys", DEFAULT_SUBJECT_KEYS))

    # -- public entry points ------------------------------------------------

    def server_name(self, server_id):
        """The configured name for a gateway server id, None if unknown."""
        return self.servers.get(server_id) if server_id is not None else None

    def filter_text(self, text, sender=None, subject=None, server=None):
        """Apply the groups that match this context (all of them if none)."""
        for group in self.groups:
            if group.matches(sender, subject, server):
                text = group.apply(text)
        return text

    def filter_result(self, result, server_id=None):
        """Scrub a tool result of any shape; returns the same shape.
        `server_id` is the gateway's id of the upstream server it came from."""
        server = self.server_name(server_id)
        if isinstance(result, str):
            return self._filter_string(result, server=server)
        if isinstance(result, (dict, list)):
            return self._walk(result, sender=None, subject=None, server=server)
        return result

    # -- internals ----------------------------------------------------------

    def _first(self, mapping, keys):
        for key in keys:
            if key in mapping:
                return _as_text(mapping[key])
        return None

    def _walk(self, node, sender, subject, server):
        if isinstance(node, dict):
            # A dict carrying a sender or subject is an email: everything
            # inside it is scoped to that email, including nested parts.
            own_sender = self._first(node, self.from_keys)
            own_subject = self._first(node, self.subject_keys)
            if own_sender is not None or own_subject is not None:
                sender, subject = own_sender, own_subject
            return {k: self._walk(v, sender, subject, server) for k, v in node.items()}
        if isinstance(node, list):
            return [self._walk(v, sender, subject, server) for v in node]
        if isinstance(node, str):
            return self._filter_string(node, sender, subject, server)
        return node

    def _filter_string(self, text, sender=None, subject=None, server=None):
        # Many MCP servers return JSON as a text block. Scrub it structurally
        # so per-email scoping still works, and write it back the same way.
        stripped = text.lstrip()
        if stripped[:1] in "{[":
            try:
                parsed = json.loads(text)
            except ValueError:
                parsed = None
            if isinstance(parsed, (dict, list)):
                # Compact, like the JSON MCP servers emit, so the text block
                # differs from the original only by the replacements.
                return json.dumps(self._walk(parsed, sender, subject, server), ensure_ascii=False, separators=(",", ":"))
        if sender is None and subject is None:
            # Plain text: an email rendered with header lines, perhaps.
            m = _TEXT_FROM.search(text)
            sender = m.group(1) if m else None
            m = _TEXT_SUBJECT.search(text)
            subject = m.group(1) if m else None
        return self.filter_text(text, sender, subject, server)
