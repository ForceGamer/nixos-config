# ContextForge: PII-scrubbing MCP gateway

`modules/services/contextforge.nix` runs IBM's ContextForge (MCP gateway) on
ARBITER so that MCP servers which return personal data (Fastmail, Obsidian, …)
can be used by AI clients without the AI ever seeing the raw values. Nothing
has been deployed. The steps below are the parts only you can do.

## What it does

```
claude.ai / Claude Code ──TLS tun.gameforce.me:443 (router → ARBITER:47231)──▶ Caddy ──▶ ContextForge ──▶ Fastmail MCP
                                                      /servers/* + Bearer   │          Obsidian MCP
                                                      header only; all      ▼
                                                      else dropped    tool result → ScopedFilter (rules + detectors) → LlmDetector → client
                                                                      tool arguments ← pseudonyms restored ← client
```

- **Gateway:** `ghcr.io/ibm/mcp-context-forge`, v1.1.0, pinned by digest, as a
  rootless podman container under the `contextforge` user (uid 380). Read-only
  root filesystem, all capabilities dropped, SQLite state in
  `/var/lib/contextforge/data`. Listens on `127.0.0.1:4444` only.
- **Scrubbing** happens in ContextForge's plugin framework, on every tool
  result and rendered prompt (`tool_post_invoke`, `prompt_post_fetch`), before
  it leaves the gateway:
  1. **ScopedFilter**, the rule layer (our own plugin,
     `modules/services/contextforge/`):
     - your search-and-replace rules, one group per file in
       `hosts/arbiter/pii/`, applied in filename order. A group is global or
       scoped to an email's sender/subject (see "Rule files" below). Names and
       places come from sops secrets (`contextforge/school-name`, …), so they
       never appear in the repo or the Nix store; the rule replaces them with
       a label like `[SCHOOL]`;
     - then detectors for e-mail addresses, phone numbers (US, `+<cc>…`, and
       Norwegian with or without `+47`), credit cards (Luhn-checked), IBANs and
       "account <digits>", dates of birth, Norwegian fødselsnummer/D-nummer
       (`[HASH:16hex]`) and IPv4/IPv6 addresses (`[IP:16hex]`). Ported from
       IBM's `cpex_pii_filter`, which this replaced (see "Stable pseudonyms").
  2. **LlmDetector** (ours, optional, for every tool not in
     `homelab.contextforge.llm.excludeTools`): a local model on TEMPLAR
     (Ollama) reads what the rule layer left, one email at a time, and lists
     your own values, places tied to you, addresses, contact and account data
     still in it; the plugin masks each finding as `[PII:16hex]`. Other
     people's names and handles are left alone. See "LLM safety net".
  - **Pseudonyms are stable:** `[HASH:…]`, `[IP:…]` and `[PII:…]` are an HMAC
    of the value under a persistent key, so the same sender is the same token
    in a search and a read, today and after a restart.
  - **And reversible for tools:** each one handed out is recorded, and a
    `tool_pre_invoke` hook puts the original back into tool arguments, so the
    AI can search `from:[HASH:…]` or reply to a sender it only knows by token.
  - Rule lists come in two kinds: the **global** list (`hosts/arbiter/pii/`)
    applies to every result, and a **per-server** list
    (`homelab.contextforge.servers.<name>.rulesDir`) adds rules for one
    upstream MCP server. See "Rule lists per server".
  - A plugin error fails the tool call, so a broken plugin can never let a
    raw result through. That includes the LLM host being off or slow (every
    tool that isn't excluded fails until it's back), a missing key, and an
    unusable pseudonym store.
- **Not covered, by design (know this before you rely on it):**
  - The rule layer is **regex-based, not NER**. Free-text names, street
    addresses and anything without a fixed shape pass through unless a rule
    names them or the LLM layer catches them. ContextForge's Presidio/NER
    option is the external LLMGuard plugin, a second container that downloads
    spaCy models at start; not added (priority 1).
  - **Resources** aren't filtered: neither plugin has resource hooks. Build
    virtual servers from **tools only**.
  - **Tool arguments get originals back.** Whatever the AI passes through a
    pseudonym reaches the upstream server in clear: a search finds the real
    sender, and a tool that sends mail would send to the real address or put
    the real value in a body. The AI still never sees the value.
  - Partial leaks via tool *input*: the AI can still ask a tool to search for
    "mail from <name>" and get pseudonymised results back. The gateway hides
    values, not the existence of data.
  - Stable pseudonyms link across chats: the same person is the same token
    in every conversation, until the key changes.
- **Exposure:** three Caddy sites, one upstream. Built to look like nothing
  from the outside; every claim below was checked against the real Caddy
  binary.
  - `https://mcp-admin.gameforce.me` (port 443, LAN and WireGuard only, as all
    443 traffic): the full gateway, including the admin UI at `/admin`.
  - `https://tun.gameforce.me` (internet, WAN 443 → ARBITER 47231): the
    WireGuard hostname, which is already public on the WAN IP. On the host it
    is `homelab.contextforge.publicPort`; externally it has to be 443 because
    claude.ai's connector backend can't reach any other port (tested).
    Only `/servers/*` (the
    per-virtual-server MCP endpoints) is proxied, and only when the request
    carries an `Authorization: Bearer …` header at all. Everything else is
    **aborted**: Caddy closes the connection without sending a byte, so a
    probe doesn't even learn that an HTTP server is there. Caddy checks only
    that a bearer header exists (stock Caddy can't validate JWTs); the gateway
    validates it and answers 401 for a bad one. Request bodies capped at 2 MB;
    the `Server` header is stripped. Access log in
    `/var/log/caddy/access-tun.gameforce.me.log`.
  - A **catch-all** on the same port for any other SNI, or none: it presents a
    self-signed `CN=localhost` decoy certificate (generated at build time)
    instead of the wildcard, and aborts. Without it Caddy hands the wildcard
    to anyone who connects, which would reveal the domain to a port scan.
    Globally, `strict_sni_host` makes Caddy answer 421 when the `Host` header
    doesn't match the SNI; that closes an HTTP/2 path where a request with the
    right SNI and a foreign `:authority` otherwise bypassed every site and got
    an empty 200. What a scanner sees: a TLS port with a `localhost` cert that
    resets connections. What someone who guesses the hostname sees: the same,
    unless they also send a bearer header, in which case the gateway's 401.
  - Clients authenticate with a ContextForge bearer token (JWT, expiring,
    created in the admin UI). The gateway refuses everything unauthenticated
    (`AUTH_REQUIRED`, `MCP_CLIENT_AUTH_ENABLED`); self-registration is off.
  - **fail2ban** (`modules/fail2ban.nix`, jail `contextforge`): 5 junk
    requests from one address within 10 minutes on the public port bans it
    on all ports for 1 h, doubling on repeats up to a week. Junk = status 0
    (aborted by Caddy), 421 (Host/SNI mismatch), or 401/403/404 from the
    gateway. Private sources
    (LAN, WireGuard peers, the Claude VM) are never banned. Chosen over
    CrowdSec because it fetches nothing at runtime and is one native daemon.
    NixOS also enables its default `sshd` jail; harmless, SSH isn't exposed.
  - ContextForge has no rate limiter of its own, and stock Caddy has none
    either. fail2ban covers abuse; a legitimate client is never throttled.

## 1. Generate the secrets

On TEMPLAR, in the repo:

```sh
sops hosts/arbiter/secrets.yaml
```

Add at the top level (4-space indent, like the rest of the file):

```yaml
contextforge:
    jwt-secret-key: <64 hex chars, e.g. `openssl rand -hex 32`>
    auth-encryption-secret: <64 hex chars, another `openssl rand -hex 32`>
    admin-password: <12+ chars with upper, lower and a symbol; you'll type it into the admin UI>
    default-user-password: <64 hex chars, `openssl rand -hex 32`; never typed anywhere>
    school-name: <the school's name as it appears in mail and notes>
    pseudonym-key: <64 hex chars, `openssl rand -hex 32`; the key behind every pseudonym>
    own-domain: <your own mail domain, bare, e.g. example.no>
```

- Hex keeps the env file free of characters podman's `--env-file` would
  mangle. Don't reuse one value for two keys. In passwords avoid `"`, `'`,
  `$`, `\` and `#` for the same reason.
- `default-user-password` is the gateway's initial password for accounts
  created in the UI. No account gets one here (registration is off), but the
  gateway refuses to start unless it passes the same 12-character check as
  the admin password; its built-in default doesn't.
- `school-name` is matched case-insensitively as whole words wherever it
  appears in a tool result. Set it with `./add-pii.sh school-name "[SCHOOL]"`
  rather than by hand: the script reads the value from the terminal (so it
  stays out of shell history) and escapes regex metacharacters, so a name
  like `St. Olav (Oslo)` matches literally.
- `pseudonym-key` makes `[HASH:…]`, `[IP:…]` and `[PII:…]` stable. Changing
  it changes every pseudonym, and the store's old entries stop resolving
  (they expire on their own). It reaches the container as a read-only file,
  never as an environment variable.
- `own-domain`: addresses at this domain are always hashed, even
  `noreply@` ones; `homelab.domain` is treated the same way.
- The build fails until every key exists (sops-nix checks the file at build
  time), same as the pending `cloudflare/dns-api-token`.

### Adding another name later

```sh
./add-pii.sh employer "[EMPLOYER]"     # prompts for the value
```

Then add the entry it prints to the right group in `hosts/arbiter/pii/`
(`10-people.nix` for a person or place):

```nix
{
  secret = "employer";
  replace = "[EMPLOYER]";
}
```

The module declares the sops secret and builds the regex from it. Commit,
push, `nixos-rebuild test`, and check a tool result in the admin UI shows the
label. Hash pseudonyms reset when the container restarts for the new config.
To store a regex instead of a literal name, use `./add-pii.sh -r <key>`.

### Rule files

`hosts/arbiter/pii/*.nix` (the global list, `homelab.contextforge.rulesDir`)
and `hosts/arbiter/pii/servers/<name>/*.nix` (one server's list, see "Rule
lists per server"), one rule group each, loaded in filename order. Groups
scoped to one sender go in the list of the server their mail comes from
(`servers/fastmail/`). A file looks like:

```nix
{
  name = "shop-x";                        # label in test output
  when = {                                # null = global, always applied
    from = "@shop-x\\.example$";          # regex on the sender (any, if null)
    subject = null;                       # regex on the subject (any, if null)
  };
  rules = [
    { search = ">[0-9]+</div>"; replace = ">[ORDER_ID]</div>"; }   # Python regex
    { secret = "shop-x-customer-no"; replace = "[CUSTOMER_NO]"; } # from sops
  ];
  examples = [                            # run by `nix flake check`
    { from = "orders@shop-x.example"; input = "<div>4471023</div>"; expect = "<div>[ORDER_ID]</div>"; }
    { from = "friend@mail.example";   input = "<div>4471023</div>"; expect = "<div>4471023</div>"; }
  ];
}
```

How scoping behaves, and the one rule that keeps it safe:

- A scoped group applies to an email whose sender *and* subject match its
  regexes. The plugin finds them in structured results (`from`/`subject`
  keys, also inside JSON carried in a text block, each email in a list on
  its own) and in plain text with `From:`/`Subject:` lines.
- **Where it can't recognise an email, every group applies.** Scoping may
  add aggressive rules to a known context; it never removes protection from
  an unknown one. So put everything that protects a *person* in a global
  group; scope only precision rules (merchant layouts, order ids, amounts)
  that would misfire elsewhere.
- **Order matters.** Groups run in filename order and rules top to bottom,
  each on the previous output. A value that contains another must come first
  (full name before surname, long employer name before its abbreviation,
  address before town), or the shorter rule fires first and the longer one
  never matches, leaving the rest visible.
- **Text versions of HTML mail glue table cells together**
  (`Customer Name<first> <last>Invoice Number<digits>Order Status…`). A
  whole-word rule, which every `secret` is, can't fire on a glued value, and
  a label rule can't see a glued label. The global label and money rules
  accept a glued label (a capital followed by a lower-case letter counts as
  a start); a glued *name* needs a sender-scoped rule on the labels around
  it, as in `servers/fastmail/75-battlenet.nix`. The survey shows such a name in a snippet.
- **Links with a long opaque token** (click tracking, receipt and invoice
  links, signed parameters) are cut at the token by the global `links`
  group: `https://host/path/[TOKEN]`. The AI can say that there was a link
  and where it pointed, not hand it back in working order. Readable slugs,
  short ids and git commit ids survive; a long id in a link you do want
  (a shared document, say) does not.
- **Everything is tested at build time.** `nix flake check` runs the
  plugin's unit tests and then every `examples` entry through the real rule
  set (with each secret replaced by `SECRET_` + its key in UPPER_SNAKE, e.g.
  `SECRET_HOME_FULL`; use that spelling in examples, never real data). A
  regex that doesn't compile fails the check, and would also stop the gateway
  from starting; the stock plugin would have skipped it silently. Remember
  Nix string escaping: `\\b`, `\\d`, `\\.`, `\\$` (a bare `$` is the
  end-of-line anchor). Every rule is case-insensitive unless it opens with
  its own `(?...)` flags; `(?-i:…)` makes one part case-sensitive. The flake
  only sees files git knows about: `git add` a new rule file first, or the
  check passes without it.

### Rule lists per server

The files in `hosts/arbiter/pii/` are the global list. An upstream MCP server
can have its own list on top:

```nix
homelab.contextforge.servers.fastmail = {
  id = "<gateway id>";                 # admin UI → Gateways → the server's ID
  rulesDir = ./pii/servers/fastmail;   # same file format as above
};
```

On ARBITER, Fastmail's list holds the per-sender groups (Bring, Stripe,
Elkjøp, …); the global list keeps people, links, identifiers and amounts,
which can turn up in any server's text.

- **The id is the upstream server's (Gateways), not the virtual server's.**
  In v1.1.0 a plugin can't tell which virtual server a tool call came
  through: the gateway sets the call's `server_id` to the upstream server's
  id (`tool_service._apply_tool_payload_to_global_context`). So a list
  belongs to Fastmail, Obsidian, …, whichever virtual servers expose their
  tools.
- A server's list **adds** to the global one; nothing can switch a global
  rule off. Groups run global first, then each server's, each directory in
  filename order. `when` scoping works inside a server's list as usual.
- **A wrong or missing id over-filters, never under-filters:** a result
  from an id that isn't in `servers` gets every server's rules, the same
  "unknown context gets everything" rule as for senders. Rendered prompts
  carry no server, so they get everything too.
- A server's `examples` are tested in that server's context; global
  examples in an unknown one (every group applies, as before).
- Registering the upstream server again gives it a new id; update `id` then,
  or the server falls back to "unknown" (all lists).

### Stable pseudonyms and tool arguments

Every `[HASH:…]`, `[IP:…]` and `[PII:…]` is `[KIND:` + the first 16 hex
characters of HMAC-SHA256(`pseudonym-key`, value) + `]`. Values are trimmed;
e-mail addresses and LLM findings are lower-cased first. So the same value
gives the same token in every call, after restarts and in every chat.

- **Why not IBM's filter any more:** `cpex_pii_filter` hashes with a salt it
  draws at random whenever a plugin instance is created, and the gateway
  creates instances often: one plugin manager per tool (search and read are
  different tools), rebuilt every 30 s. The same sender came out as two
  tokens a minute apart. The salt can't be configured (`hash_salt` exists in
  its config struct; the loader never reads it). Its patterns, Luhn check
  and overlap rule live on in `detectors_core.py` (Apache-2.0).
- **The store:** each pseudonym handed out is recorded with its original in
  `/var/lib/contextforge/data/pseudonyms.db` (SQLite, 0600, in the gateway's
  0700 data directory), before the result leaves. Entries are deleted
  `pseudonymTtlDays` (180) after last use. It holds every address, number and
  LLM finding the AI has been shown, in clear, on ARBITER's unencrypted disk.
- **Tool arguments:** `tool_pre_invoke` replaces every known pseudonym in a
  call's arguments with the original before the call goes upstream:
  `from:[HASH:…]` searches the real address. An unknown or expired token
  passes through unchanged; only the token is logged.
- **Not hashed:** e-mail addresses of organisations stay readable: local
  parts `noreply`, `no-reply`, `donotreply`, `do-not-reply`,
  `notification(s)`, `support`, `kundeservice`, `newsletter(s)`,
  `mailer-daemon`, `postmaster` (also with a `+tag` or `-suffix`), and any
  address at a domain (or subdomain) in `hosts/arbiter/pii/allow-domains.txt`.
  Your own domains (`homelab.domain` and the `own-domain` secret) are hashed
  regardless. GitHub handles aren't masked by anything.
- **Message-IDs** (`messageId`, `inReplyTo`, `references`) get only the
  literal rules (your sops values); no generic rule or detector touches them,
  so threading works.
- **URLs:** number, amount, phone, card and ID rules and detectors skip
  everything inside a URL; link-token rules, sender-specific link rules,
  literal rules, e-mail, IP and UUID rules still apply there. A rule opts out
  of URLs with `urls = false;`. Side effect of the IP detector: a
  four-part version number (`1.2.3.4`) is masked as an IP.

### LLM safety net

The rule layer only catches what has a shape or is on a list. For every
tool, a local model reads each result *after* it and lists what's still
personal; the plugin, not the model, replaces each finding with a stable
`[PII:…]`. The model runs on TEMPLAR, which has the GPU for it.

```nix
homelab.contextforge.llm = {
  enable = true;
  url = "http://<TEMPLAR address>:11434";
  model = "qwen3.6:35b-a3b";
  excludeTools = [ ];                  # tools that skip it, exactly as the client calls them
};
```

- **Which tools:** all of them, except those in `excludeTools` (a
  blacklist). The plugin checks the name itself; ContextForge's `conditions`
  can only allow-list. An excluded tool skips the model and keeps working
  when TEMPLAR is off; every other tool fails then. Names are the ones the
  client calls, which include the gateway's prefix for the upstream server;
  the journal shows each as `Invoking tool: <name>`
  (`journalctl -u podman-contextforge | grep 'Invoking tool'`). Only exact
  names are excluded, so a misspelt one still goes through the model.
- **One email per request:** a result's emails (any object with a sender or
  subject, also inside JSON in a text block) are sent one at a time, each as
  `field: value` lines of its text fields, never as the tool's raw JSON. Ids
  (`id`, `messageId`, `threadId`, …) are neither sent nor changed. Text
  outside any email goes as one more request; an email longer than
  `maxChars` is split at line breaks, never truncated. The same email twice
  in one result (the text block and `structuredContent`) is asked once.
- **What it looks for:** your own values (every sops secret the literal
  rules use, sent with each request, unescaped) in any form, glued to other
  words, inflected or misspelt; places tied to you (where a login happened,
  where you live); a person's street address; phone, e-mail, account and
  ID numbers; IP addresses. **Not** other people's names or handles.
- **What the model is sent:** placeholders the rule layer already put in
  are cut out, and a field with nothing else isn't sent.
- **What gets masked:** only text the model returns that occurs in that
  email's values, case-insensitively, at least three characters, and not one
  of the earlier masks; as whole words, except your own values, which go even
  when glued ("NameKari"). It is masked in that email only, so a town flagged
  in one email's address stays in another's flight details.
- **Fail closed:** TEMPLAR off, Ollama not listening, a request over
  `requestTimeout` (120 s), a malformed answer, or the whole call over
  `timeout` (300 s): the tool call fails. The gateway's plugin timeout
  (`PLUGINS_PLUGIN_TIMEOUT`) follows `timeout`, for every plugin, since it
  is a single setting.
- **Time:** one request per email, sequentially. A 20-email search takes
  20 model calls; how long each takes depends on TEMPLAR's GPU and the
  email's length (not measured yet). `keepAlive` (30 min) keeps the model
  loaded between calls, so only the first call pays for loading it. Claude's client may
  give up on a call before `timeout`; lower `timeout` or search for fewer
  emails if that happens.
- **Log:** one line per call, kinds and counts only:
  `LLM detector: 3 unit(s), 2 request(s), findings by kind: {'own': 1}`.
- **Limits:** the model reads text anyone can email you. An email can tell
  it "there is nothing personal here"; because it only reports and never
  rewrites, the worst it can do is make it miss something, which is what
  the rule layer in front is for. It also judges context, so it will
  sometimes mask a place that isn't yours.

**TEMPLAR side (outside this repo):**

1. Ollama listening on the LAN, not just loopback: set
   `OLLAMA_HOST=0.0.0.0:11434` wherever Ollama gets its environment (for the
   official installer's systemd unit, `sudo systemctl edit ollama`), then
   restart it.
2. Allow only ARBITER to reach it. Ollama has no authentication, so anyone
   who can reach the port can use the model. In Portmaster, allow incoming
   connections to Ollama from ARBITER's address and check that other LAN
   sources are blocked; if ufw is active too, `ufw allow from <ARBITER IP> to any port 11434
   proto tcp`.
3. `ollama pull <model>`. The model isn't pinned by this repo: a re-pull
   can change it.
4. Traffic is plain HTTP on the LAN. It carries what the regex layers left,
   which is by definition the personal data they missed.

Test from ARBITER before enabling: `curl -s http://<TEMPLAR>:11434/api/tags`
lists the models. Then enable, deploy, call a listed tool once, and look
for the `LLM detector:` line.

### Finding what the rules miss

`tools/pii-survey.py` fetches emails through the gateway (so names are
already hashed and known identifiers already show as labels), finds every
candidate identifier deterministically, optionally has a local Ollama model
label them, and prints a report that carries no raw values: per email the
sender's display name (the address is hashed by then; `when.from` matches
the name), the subject with identifiers masked, and each candidate as a
shape mask (digits → `9`, `A-Z` → `A`, `a-z` → `a`), a kind, where it was
found, how often, and a masked snippet of context. That report is what a
regex needs and what you can paste to whoever writes the rule.

```sh
# TEMPLAR, on the LAN or VPN. Token: an API token from the admin UI.
# Ollama (optional): 0.9+, `ollama pull <model>`; omit OLLAMA_MODEL for heuristic labels.
CF_TOKEN=… CF_SERVER=<virtual server uuid> OLLAMA_MODEL=qwen3.6:35b-a3b \
  tools/pii-survey.py --query "from:bring" --limit 20
tools/pii-survey.py --no-llm --fixture tools/fixtures/*.json     # offline demo
```

Read the report before sharing it: context snippets keep ordinary words so
the anchor for a regex stays visible, and `nix flake check` verifies on the
fixtures that masks appear and raw values don't. Standard library only.

## 2. DNS and the router

- **Cloudflare:** nothing to add. `tun.gameforce.me` already points at the WAN
  IP via DDNS, and the wildcard certificate covers it (and `mcp-admin`). No
  new name appears in public DNS or in Certificate Transparency.
- **UniFi:** a port forward **TCP 443 (WAN) → ARBITER TCP 47231**, next to
  the existing UDP 51820 one. A non-standard external port would keep the
  service out of mass scans, but claude.ai custom connectors refuse to
  connect to anything but 443 ("Couldn't connect", and no packet ever
  arrives), so 443 it is; the decoy certificate, the silent drops and
  fail2ban still apply. If you change `homelab.contextforge.publicPort`,
  change the forward's internal port too.
- From inside the LAN, `tun.gameforce.me` resolves to the WAN IP and comes
  back in through UniFi's hairpin NAT. That's expected; use `mcp-admin` for
  the admin UI.

This is the second thing exposed, after WireGuard, on the same hostname.

## 3. Deploy and first login

```sh
nix run nixpkgs#nixos-rebuild -- test   --flake .#arbiter --target-host admin@arbiter --sudo
```

The first start pulls about 1 GB from ghcr.io (by digest), creates the SQLite
database and the platform admin. Check:

```sh
ssh admin@arbiter systemctl status podman-contextforge fail2ban caddy
ssh admin@arbiter journalctl -u podman-contextforge -n 50
ssh admin@arbiter sudo fail2ban-client status contextforge
```

If the container exits on a read-only filesystem error, the image started
writing somewhere new; the knob is `--read-only` in `extraOptions`. Then
`switch`.

From TEMPLAR, confirm the outside view (each command's expected result in
the comment; the first three go through the router's hairpin NAT):

```sh
openssl s_client -connect tun.gameforce.me:443 -noservername </dev/null 2>/dev/null | grep subject=   # CN=localhost (decoy)
openssl s_client -connect tun.gameforce.me:443 </dev/null 2>/dev/null | grep subject=                 # CN=*.gameforce.me
curl -sSi https://tun.gameforce.me/servers/x/mcp; echo "exit=$?"                                     # no response; exit 92 (h2) or 52/56 (h1): dropped
curl -sSi -H 'Authorization: Bearer x' https://tun.gameforce.me/servers/x/mcp | head -1              # HTTP/2 401 (gateway)
curl -sS https://mcp-admin.gameforce.me/health                                                         # ok
```

A few of those probes count as junk for fail2ban, but TEMPLAR is a private
source and can't be banned.

Open `https://mcp-admin.gameforce.me/admin`, log in as `admin@gameforce.me`
with `admin-password`.

## 4. Add an upstream MCP server and a virtual server

In the admin UI:

1. **Gateways → Add:** the upstream MCP server's URL and its own credentials
   (for a remote server such as Fastmail's: its URL and OAuth or token;
   ContextForge stores them encrypted with `AUTH_ENCRYPTION_SECRET`). A stdio
   server has to be wrapped with `mcpgateway.translate` or run as its own
   service first; that's a separate change. Note the gateway's ID if the
   server gets its own rule list (`homelab.contextforge.servers`).
2. **Virtual Servers → Add:** pick the **tools** you want the AI to have.
   Leave resources and prompts out (see "Not covered"). Note the server's UUID.
3. **Tokens:** create an API token for the client, scoped to that server if
   the UI offers it, with an expiry. Copy it once.

Test the scrubbing before handing the URL to any AI: in the UI's tool tester,
or with curl against the LAN side, call a tool that returns an address you
know and confirm the result shows `[HASH:…]` and `[SCHOOL]`. The journal logs
each detection as a type and count, never the value:
`journalctl -u podman-contextforge | grep -i pii`.

## 5. Connect a client

- **claude.ai → Settings → Connectors → Add custom connector:** URL
  `https://tun.gameforce.me/servers/<UUID>/mcp` (no port: claude.ai only
  reaches servers on 443, which is why the router maps 443 → 47231), and under *Request
  headers* add `Authorization` with the value `Bearer <token>` (the `Bearer `
  prefix is required; without the header Caddy drops the connection before
  the gateway ever sees it). No OAuth needed.
- **Claude Code:** `claude mcp add --transport http fastmail https://tun.gameforce.me/servers/<UUID>/mcp --header "Authorization: Bearer <token>"`.

Anyone holding the token can call the tools as you, so treat it like a
password and rotate it from the admin UI if in doubt.

## Updates and rollback

- The image is pinned by digest in `modules/services/contextforge.nix`, so the
  weekly auto-upgrade doesn't move it. Bump it yourself after reading the
  release notes: `skopeo inspect docker://ghcr.io/ibm/mcp-context-forge:vX.Y.Z`
  gives the index digest. Database migrations run on start.
- Rollback is the usual `nixos-rebuild switch --rollback`; the SQLite file is
  forward-migrated, so keep a copy of `/var/lib/contextforge/data/mcp.db`
  before a major bump.
