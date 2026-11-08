# Caddy and ntfy over HTTPS: what you need to do

This branch adds Caddy as the reverse proxy on ARBITER and routes
`https://ntfy.<DOMAIN>` to ntfy. Nothing has been deployed. The steps below
are the parts only you can do.

## What the config does

- **Certificates:** the NixOS ACME module (lego, from nixpkgs) gets one wildcard
  certificate, `*.<DOMAIN>`, from Let's Encrypt with a Cloudflare DNS-01
  challenge. It renews automatically (checked daily, renewed about 30 days
  before expiry) and reloads Caddy afterwards.
  - Why not Caddy's own ACME: stock Caddy has no Cloudflare DNS plugin. A custom
    build pulls third-party Go modules and compiles on ARBITER after every bump.
  - Why DNS-01: no inbound port 80, and it works even if ntfy is never exposed
    to the internet.
  - Why a wildcard: service hostnames don't show up in public Certificate
    Transparency logs, and later services (Immich, Paperless, …) need no new
    certificate.
- **Caddy** (`modules/services/caddy.nix`) listens on TCP 443 only: no port 80,
  no HTTP/3 (so no UDP 443). Its admin API is a socket only the `caddy` user
  can open, instead of `localhost:2019`, which any local process could use.
  Its sandbox is tightened like ntfy's.
- **ntfy** (`modules/services/ntfy.nix`) still listens on `127.0.0.1:2586`.
  Caddy proxies `ntfy.<DOMAIN>` to it. `base-url` is now
  `https://ntfy.<DOMAIN>` and `behind-proxy` is on, so rate limiting uses the
  real client address. The access log (`/var/log/caddy/`) strips ntfy's
  `?auth=` query parameter, so tokens never land on disk.
- **Firewall:** TCP 443 opened on ARBITER (not to the Claude microVM, whose
  input rules still drop everything but DNS). Whether 443 is reachable from the
  internet is decided by UniFi, not by this repo (step 4).

## 1. Fill in the domain

In `hosts/arbiter/default.nix`, replace the placeholder:

```nix
homelab.domain = "<DOMAIN>";   # e.g. "example.net", without "ntfy."
```

That is the only place the domain appears. ntfy becomes `ntfy.<DOMAIN>`.

## 2. Create a Cloudflare API token

Cloudflare dashboard → **My Profile → API Tokens → Create Token** → template
**Edit zone DNS**:

- Permissions: `Zone` / `DNS` / `Edit` (the template's default; nothing else).
- Zone Resources: `Include` / `Specific zone` / `<DOMAIN>`.
- Client IP filtering: leave empty. Your public IP changes (that's why you use
  DDNS), and a stale filter would silently break renewals.
- TTL: leave empty. An expiring token breaks renewals with no one noticing.

Copy the token; Cloudflare shows it once.

Don't reuse the token your DDNS updater uses. This one lives on ARBITER and
needs DNS edit on this zone only.

## 3. Add the token to sops

On TEMPLAR, in the repo:

```sh
sops hosts/arbiter/secrets.yaml
```

Add this at the top level, next to `ntfy:` and `wireguard:` (4-space indent,
as in the rest of the file):

```yaml
cloudflare:
    dns-api-token: <CLOUDFLARE_DNS_API_TOKEN>
```

Save and quit; sops re-encrypts on exit.

**The build fails until this key exists**: sops-nix checks at build time that
every declared secret is in `secrets.yaml`. That's intended.

## 4. DNS record and reachability

Choose how the phone reaches ntfy.

### Option A: public (needed to get notifications without the VPN)

1. In Cloudflare DNS for `<DOMAIN>`, add `ntfy` as a **CNAME** to the hostname
   your DDNS updater keeps current (or an `A` record to your public IP if the
   DDNS updater manages `ntfy` itself).
   - **Proxy status: DNS only (grey cloud).** With the orange cloud, Cloudflare
     terminates TLS and sees every notification in plaintext.
2. In UniFi: **Settings → Routing → Port Forwarding** (wording varies by
   version), forward **TCP 443** from WAN to ARBITER's reserved address,
   port 443. Not UDP, not port 80.
3. For devices at home, add a UniFi local DNS record (**Settings → Routing →
   DNS → Local DNS Records**, or similar): `ntfy.<DOMAIN>` → ARBITER's LAN
   address. Without it, LAN clients go out and back through hairpin NAT, which
   usually works on the UDR7 but is one more thing to break.

With the port open, only the ntfy web app and API are reachable, and with
`deny-all`, nothing can be read or published without an ntfy account.

### Option B: home LAN and WireGuard only

1. No port forward and no public DNS record.
2. Add the UniFi local DNS record from A.3. WireGuard peers use it if their
   tunnel config uses the router (or ARBITER) as their DNS server and sends that
   address through the tunnel.
3. The certificate still works: DNS-01 doesn't need ARBITER to be reachable.

You can start with B and switch to A later; the Nix config is the same.

### CAA records

If `<DOMAIN>` has CAA records, one of them must allow `letsencrypt.org`. If it
has none, there's nothing to do.

## 5. Build, test, deploy

On TEMPLAR:

```sh
nix fmt
nix flake check
nix build .#nixosConfigurations.arbiter.config.system.build.toplevel

# This changes the firewall, so `test` first (a reboot undoes it).
nix run nixpkgs#nixos-rebuild -- test   --flake .#arbiter --target-host admin@arbiter --sudo
```

Activation runs `acme-wildcard.service`, which puts a self-signed placeholder
in place so Caddy can start, then triggers `acme-order-renew-wildcard.service`
(lego) for the real certificate. Check on ARBITER:

```sh
systemctl status acme-order-renew-wildcard.service caddy.service ntfy-sh.service
journalctl -u acme-order-renew-wildcard.service -b   # lego's DNS-01 log
systemctl list-timers acme-renew-wildcard.timer
```

Then from TEMPLAR (or the phone):

```sh
curl -sS https://ntfy.<DOMAIN>/v1/health   # expect {"healthy":true}
```

If that works and SSH still does, make it permanent:

```sh
nix run nixpkgs#nixos-rebuild -- switch --flake .#arbiter --target-host admin@arbiter --sudo
```

### If the certificate fails

- `403`/`Invalid access token` in the lego log: wrong token, wrong zone, or
  missing DNS edit permission (step 2).
- `time limit exceeded` / propagation errors: lego checks against `1.1.1.1`. A
  firewall that blocks outbound DNS from ARBITER would cause this.
- Let's Encrypt allows 5 failed validations per hostname per hour. Fix the
  cause before retrying with
  `sudo systemctl start acme-order-renew-wildcard.service`.

## 6. Not done yet (open decision 4)

These need decisions from you; ask Claude to do them once you've chosen:

- **A read-only phone user** on `arbiter-alerts`. Until it exists the phone can
  reach ntfy but has no account to subscribe with. It needs a bcrypt hash and a
  token in `secrets.yaml`, like `upgrade-notifier`.
- **iOS background push:** `upstream-base-url = "https://ntfy.sh"`. Apple only
  delivers push through ntfy.sh's APNs account, so without it the iOS app gets
  notifications only while it's open. With it, ntfy.sh sees message IDs and
  hashed topic names (not content), and ntfy needs outbound access to ntfy.sh
  (its sandbox currently allows only localhost).
- **Alert on failed renewals:** a failing
  `acme-order-renew-wildcard.service` is silent, like `nixos-upgrade` was before `upgrade-alert`. There are about 30 days of
  margin before expiry, so it's worth hooking the same ntfy alert to it.

## Rollback

`sudo nixos-rebuild switch --rollback` on ARBITER, or reboot after `test`.
Removing the UniFi port forward closes external access immediately, whatever
the Nix config says.
