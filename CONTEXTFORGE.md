# ContextForge: PII-scrubbing MCP gateway

`modules/services/contextforge.nix` runs IBM's ContextForge (MCP gateway) on
ARBITER so that MCP servers which return personal data (Fastmail, Obsidian, …)
can be used by AI clients without the AI ever seeing the raw values. Nothing
has been deployed. The steps below are the parts only you can do.

## What it does

```
claude.ai / Claude Code ──TLS 443 (router) → ARBITER:8443──▶ Caddy ──▶ ContextForge ──▶ Fastmail MCP
                                                               only /servers/*        │          Obsidian MCP
                                                                                      ▼
                                                                         tool result → Pseudonyms → PIIFilter → client
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
- **Exposure:** two Caddy sites, one upstream.
  - `https://mcp-admin.gameforce.me` (port 443, LAN and WireGuard only, as all
    443 traffic): the full gateway, including the admin UI at `/admin`.
  - `https://mcp.gameforce.me:8443` (internet): only `/servers/*` is proxied
    (the per-virtual-server MCP endpoints); every other path gets a 404 from
    Caddy and never reaches the gateway. Request bodies capped at 2 MB. Access
    log in `/var/log/caddy/access-mcp.gameforce.me.log`.
  - Clients authenticate with a ContextForge bearer token (JWT, expiring,
    created in the admin UI). The gateway refuses everything unauthenticated
    (`AUTH_REQUIRED`, `MCP_CLIENT_AUTH_ENABLED`); self-registration is off.
  - **fail2ban** (`modules/fail2ban.nix`, jail `contextforge`): 5 responses of
    401/403/404 from one address within 10 minutes on the public port bans it
    on all ports for 1 h, doubling on repeats up to a week. Private sources
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
    admin-password: <a long password; you'll type it into the admin UI>
    school-name: <the school's name as it appears in mail and notes>
```

- Hex keeps the env file free of characters podman's `--env-file` would
  mangle. Don't reuse one value for both keys.
- `school-name` is used as a Python regex (`(?i)\b<name>\b`). Plain words are
  fine; escape `.`, `(` and the like with a backslash if the name has them.
  Add more rules to `homelab.contextforge.pseudonyms` the same way; each one
  needs its own sops key.
- The build fails until all four keys exist (sops-nix checks the file at build
  time), same as the pending `cloudflare/dns-api-token`.

## 2. DNS and the router

- **Cloudflare:** add an `A` record `mcp.gameforce.me` pointing at the WAN IP,
  DNS-only (grey cloud). Let your DDNS updater keep it current, like `tun`.
  Don't rely on the wildcard: that points at the LAN address, which the
  internet can't reach. `mcp-admin.gameforce.me` is covered by the wildcard.
- **UniFi:** add a port forward **TCP 443 (WAN) → ARBITER TCP 8443**. 443 on the
  outside keeps the client URL free of a port and gets through restrictive
  networks; 8443 on the inside keeps ARBITER's own 443 LAN-only exactly as
  before. (Forwarding WAN 8443 → 8443 also works; then every client URL needs
  `:8443`.)
- From inside the LAN, `mcp.gameforce.me` resolves to the WAN IP and comes
  back in through UniFi's hairpin NAT. That's expected; use `mcp-admin` for
  the admin UI.

This is the second thing exposed, after WireGuard. The certificate is the
existing wildcard, so nothing changes in Certificate Transparency.

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
  `https://mcp.gameforce.me/servers/<UUID>/mcp`, and under *Request headers*
  add `Authorization` with the value `Bearer <token>` (the `Bearer ` prefix is
  required). No OAuth needed.
- **Claude Code:** `claude mcp add --transport http fastmail https://mcp.gameforce.me/servers/<UUID>/mcp --header "Authorization: Bearer <token>"`.

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
