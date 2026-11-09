# ContextForge: PII-scrubbing MCP gateway

`modules/services/contextforge.nix` runs IBM's ContextForge (MCP gateway) on
ARBITER so that MCP servers which return personal data (Fastmail, Obsidian, …)
can be used by AI clients without the AI ever seeing the raw values. Nothing
has been deployed. The steps below are the parts only you can do.

## What it does

```
claude.ai / Claude Code ──TLS tun.gameforce.me:47231──▶ Caddy ──▶ ContextForge ──▶ Fastmail MCP
                                                      /servers/* + Bearer   │          Obsidian MCP
                                                      header only; all      ▼
                                                      else dropped    tool result → Pseudonyms → PIIFilter → client
```

- **Gateway:** `ghcr.io/ibm/mcp-context-forge`, v1.1.0, pinned by digest, as a
  rootless podman container under the `contextforge` user (uid 380). Read-only
  root filesystem, all capabilities dropped, SQLite state in
  `/var/lib/contextforge/data`. Listens on `127.0.0.1:4444` only.
- **Scrubbing** happens in ContextForge's plugin framework, on every tool
  result and rendered prompt (`tool_post_invoke`, `prompt_post_fetch`), before
  it leaves the gateway:
  1. **Pseudonyms** (`regex_filter` plugin): your own search-and-replace list,
     set in `hosts/arbiter/default.nix` under `homelab.contextforge.pseudonyms`.
     The shipped example replaces a school's name with `[SCHOOL]`; the name
     itself is the sops secret `contextforge/school-name`, so it never appears
     in the repo or the Nix store.
  2. **PIIFilter** (`cpex_pii_filter`, Rust): e-mail addresses, phone numbers
     (US, `+<cc>…`, and Norwegian 8-digit with or without `+47`), credit cards
     (Luhn-checked), IBANs and "account <digits>", dates of birth, and
     Norwegian fødselsnummer/D-nummer. Masked with the `hash` strategy: the
     same value always becomes the same `[HASH:16hex]`, so the model can tell
     two people apart but learns neither.
  - A plugin error fails the tool call (`fail_on_plugin_error`), so a broken
    plugin can never let a raw result through.
- **Not covered, by design of the plugins (know this before you rely on it):**
  - Detection is **regex-based, not NER**. Free-text names, street addresses
    and anything without a fixed shape pass through unless you list them under
    `pseudonyms`. ContextForge's Presidio/NER option is the external LLMGuard
    plugin, a second container that downloads spaCy models at start; not added
    (priority 1).
  - **Resources and tool *arguments*** aren't filtered: neither plugin has
    resource hooks, and masking arguments would break lookups. Build virtual
    servers from **tools only**.
  - Hash pseudonyms are consistent only within one gateway process
    (`GUNICORN_WORKERS=1`, random salt per start). After a restart the same
    e-mail gets a new token. That's fine for a chat; it isn't a stable
    identifier.
  - Partial leaks via tool *input*: the AI can still ask a tool to search for
    "mail from <name>" and get hashed results back. The gateway hides values,
    not the existence of data.
- **Exposure:** three Caddy sites, one upstream. Built to look like nothing
  from the outside; every claim below was checked against the real Caddy
  binary.
  - `https://mcp-admin.gameforce.me` (port 443, LAN and WireGuard only, as all
    443 traffic): the full gateway, including the admin UI at `/admin`.
  - `https://tun.gameforce.me:47231` (internet): the WireGuard hostname, which
    is already public on the WAN IP, on a non-standard port
    (`homelab.contextforge.publicPort`). Only `/servers/*` (the
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
- The build fails until all five keys exist (sops-nix checks the file at build
  time), same as the pending `cloudflare/dns-api-token`.

### Adding another name later

```sh
./add-pii.sh employer "[EMPLOYER]"     # prompts for the value
```

Then add the entry it prints to `homelab.contextforge.pseudonyms` in
`hosts/arbiter/default.nix`:

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

## 2. DNS and the router

- **Cloudflare:** nothing to add. `tun.gameforce.me` already points at the WAN
  IP via DDNS, and the wildcard certificate covers it (and `mcp-admin`). No
  new name appears in public DNS or in Certificate Transparency.
- **UniFi:** add a port forward **TCP 47231 (WAN) → ARBITER TCP 47231**, next
  to the existing UDP 51820 one. Same port on both sides, so there is one
  number to remember; if you change `homelab.contextforge.publicPort`, change
  the forward too. The clients here are Anthropic's servers and your own
  machines, so a non-standard port costs nothing in reachability; it just
  keeps the port out of mass scans of the usual HTTPS ports.
- From inside the LAN, `tun.gameforce.me:47231` resolves to the WAN IP and
  comes back in through UniFi's hairpin NAT. That's expected; use `mcp-admin`
  for the admin UI.

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
openssl s_client -connect tun.gameforce.me:47231 -noservername </dev/null 2>/dev/null | grep subject=   # CN=localhost (decoy)
openssl s_client -connect tun.gameforce.me:47231 </dev/null 2>/dev/null | grep subject=                 # CN=*.gameforce.me
curl -sSi https://tun.gameforce.me:47231/servers/x/mcp; echo "exit=$?"                                 # no response; exit 92 (h2) or 52/56 (h1): dropped
curl -sSi -H 'Authorization: Bearer x' https://tun.gameforce.me:47231/servers/x/mcp | head -1          # HTTP/2 401 (gateway)
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
   service first; that's a separate change.
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
  `https://tun.gameforce.me:47231/servers/<UUID>/mcp`, and under *Request
  headers* add `Authorization` with the value `Bearer <token>` (the `Bearer `
  prefix is required; without the header Caddy drops the connection before
  the gateway ever sees it). No OAuth needed.
- **Claude Code:** `claude mcp add --transport http fastmail https://tun.gameforce.me:47231/servers/<UUID>/mcp --header "Authorization: Bearer <token>"`.

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
