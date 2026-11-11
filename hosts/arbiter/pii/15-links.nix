# Links that carry a long opaque token: newsletter click tracking
# (email.mail.<list>/c/<token>, customeriomail.com/e/c/<token>), receipt and
# invoice links (dashboard.stripe.com/receipts/payment/<token>,
# pay.stripe.com/invoice/<acct>/<token>), signed parameters (?sparams=<token>).
# The token identifies the recipient or grants access to the document, and
# no sender-specific pattern is needed to see that. Global, and before the
# identifiers group so that UUID and long-number rules don't cut a token in
# two first.
{
  name = "links";
  when = null;
  rules = [
    {
      # Inside an http(s) URL, a path segment or parameter value of 40+
      # [A-Za-z0-9_-] that is not a readable slug: either it mixes an
      # upper-case letter with a digit, or it has a digit and no hyphen in
      # its first 41 characters. Everything from there to the end of the URL
      # goes: what follows is usually a second token or a signature.
      #
      # Kept on purpose: lower-case hyphenated slugs of any length, and a
      # 40-hex git commit id (hence 41, not 40, in the second test). The
      # http(s) prefix keeps base64 bodies and DKIM values out of it.
      search = "(https?://[^\\s\"'<>)\\]]*?(?:[/=]|%2F|%3D))(?:(?=[a-z0-9_-]{40})(?=(?-i:[a-z0-9_-]*[A-Z]))(?=[a-z_-]*[0-9])|(?=[a-z0-9_]{41})(?=[a-z_]*[0-9]))[^\\s\"'<>)\\]]*";
      replace = "\\1[TOKEN]";
    }
  ];
  examples = [
    {
      # Click tracking in a newsletter, as "text [url]".
      input = "Read more [https://email.mail.list.example/c/eJw1zT0KwjAYBuDT5GsRk7xpMmYoQvEQxZ9ChSo0be9vXZyf4Rk9gAhkq2fPe7t_3L9t7Zx9X8Zh__-Q] and enjoy";
      expect = "Read more [https://email.mail.list.example/c/[TOKEN]] and enjoy";
    }
    {
      # Two tokens in one link: the first takes the rest of the URL with it.
      input = "( https://e.customeriomail.example/e/c/eyJlbWFpbF9pZCI6ImRnVHh0d1VEQUpLNUJaSzVCUUdhN1ZxVE5n/5f2b8a1c9d3e4f60718293a4b5c6d7e8f9012a3b4c5d6e7f8091a2b3c4d5e6f7 ).";
      expect = "( https://e.customeriomail.example/e/c/[TOKEN] ).";
    }
    {
      # A signed query parameter; the sentence's full stop goes with it.
      input = "https://store.shop.example/email/Receipt?sparams=eJxVjs0KwjAQhF9lyblIfpqk9SZ4EDyJL1CSbWtoTSRNiyK-u6kn&check=0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0. Cheers";
      expect = "https://store.shop.example/email/Receipt?sparams=[TOKEN] Cheers";
    }
    {
      # 64 lower-case hex characters: no upper case, but no hyphen either.
      input = "<https://files.example/d/0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0>";
      expect = "<https://files.example/d/[TOKEN]>";
    }
    {
      # Readable slugs, short ids and a git commit id stay usable.
      input = "https://blog.example/2026/how-to-build-your-ultimate-storage-server-in-2026-part-2?utm_source=newsletter and https://github.com/NixOS/nixpkgs/commit/0123456789abcdef0123456789abcdef01234567";
      expect = "https://blog.example/2026/how-to-build-your-ultimate-storage-server-in-2026-part-2?utm_source=newsletter and https://github.com/NixOS/nixpkgs/commit/0123456789abcdef0123456789abcdef01234567";
    }
    {
      # Not in a URL: left alone (base64 bodies, signatures).
      input = "b=eJw1zT0KwjAYBuDT5GsRk7xpMmYoQvEQxZ9ChSo0be9vXZyf4Rk9gAhkq2fPe7t/abc";
      expect = "b=eJw1zT0KwjAYBuDT5GsRk7xpMmYoQvEQxZ9ChSo0be9vXZyf4Rk9gAhkq2fPe7t/abc";
    }
  ];
}
