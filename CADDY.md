# Caddy and ntfy over HTTPS: what you need to do

This branch adds Caddy as the reverse proxy on ARBITER and routes
`https://ntfy.gameforce.me` to ntfy. Nothing has been deployed. The steps below
are the parts only you can do.

## Target layout

| Name | Points at | Reachable from |
| --- | --- | --- |
| `tun.gameforce.me` | WAN IP (DDNS) | Internet, UDP 51820 → ARBITER WireGuard; TCP 443 → ARBITER 47231, ContextForge (see `CONTEXTFORGE.md`) |
| `gameforce.me` | ARBITER's LAN IP | LAN and WireGuard peers |
| `*.gameforce.me` | ARBITER's LAN IP | LAN and WireGuard peers |

WireGuard and the ContextForge MCP endpoint are the only things exposed.
Everything else needs you to be at home or on the VPN.

## What the config does

- **Certificates:** the NixOS ACME module (lego, from nixpkgs) gets one wildcard
  certificate, `*.gameforce.me`, from Let's Encrypt with a Cloudflare DNS-01
  challenge. It renews automatically (checked daily, renewed about 30 days
  before expiry) and reloads Caddy afterwards.
  - Why DNS-01: Let's Encrypt never has to reach ARBITER, so it works with
    nothing but WireGuard exposed.
  - Why not Caddy's own ACME: stock Caddy has no Cloudflare DNS plugin. A custom
    build pulls third-party Go modules and compiles on ARBITER after every bump.
  - Why a wildcard: service hostnames don't show up in public Certificate
    Transparency logs, and later services (Immich, Paperless, …) need no new
    certificate.
  - The apex `gameforce.me` isn't on the certificate, since nothing is served
    there. Add it (`extraDomainNames`) when something is.
- **Caddy** (`modules/services/caddy.nix`) listens on TCP 443 only: no port 80,
  no HTTP/3 (so no UDP 443). Its admin API is a socket only the `caddy` user
  can open, instead of `localhost:2019`, which any local process could use.
  Its sandbox is tightened like ntfy's.
- **ntfy** (`modules/services/ntfy.nix`) still listens on `127.0.0.1:2586`.
  Caddy proxies `ntfy.gameforce.me` to it. `base-url` is now
  `https://ntfy.gameforce.me` and `behind-proxy` is on, so rate limiting uses
  the real client address. The access log (`/var/log/caddy/`) strips ntfy's
  `?auth=` query parameter, so tokens never land on disk.
- **Firewall:** ARBITER accepts TCP 443 only from private IPv4 sources (home
  LAN, WireGuard peers in `10.100.0.0/24`). This holds on the host itself: a
  UniFi port forward keeps the public source address, so even an accidental
  forward of 443 would be dropped. The Claude microVM still can't reach it.

## 1. Create a Cloudflare API token

Cloudflare dashboard → **My Profile → API Tokens → Create Token** → template
**Edit zone DNS**:

- Permissions: `Zone` / `DNS` / `Edit` (the template's default; nothing else).
- Zone Resources: `Include` / `Specific zone` / `gameforce.me`.
- Client IP filtering: leave empty. Your WAN IP changes, and a stale filter
  would silently break renewals.
- TTL: leave empty. An expiring token breaks renewals with no one noticing.

Copy the token; Cloudflare shows it once.

Don't reuse the token your DDNS updater uses. Each lives on a different device,
so a separate token can be revoked on its own.

## 2. Add the token to sops

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

## 3. DNS records at Cloudflare

In **DNS → Records** for `gameforce.me`. All three are **DNS only (grey
cloud)**: Cloudflare can't proxy WireGuard's UDP or a private address.

| Type | Name | Content |
| --- | --- | --- |
| `A` | `tun` | your WAN IP, kept current by the DDNS updater |
| `A` | `@` | `<ARBITER_LAN_IP>` |
| `A` | `*` | `<ARBITER_LAN_IP>` |

- Point your DDNS updater at `tun.gameforce.me` only. If it currently updates
  another name, move it; the apex and wildcard must stay on the LAN IP.
- `<ARBITER_LAN_IP>` is the address of ARBITER's UniFi DHCP reservation.
- Records you already have (e.g. for mail or other subdomains) take precedence
  over `*`, so they keep working. An existing apex `A`/`AAAA` record must be
  replaced by the one above.
- Publishing a private address in public DNS only reveals your LAN numbering;
  nothing on it is reachable from outside.

No UniFi local DNS records are needed: public DNS gives the same answer at home
and on the VPN.

### UniFi

- Port forwarding: only **UDP 51820 → ARBITER**, as now. Remove any forward for
  TCP 443 or 80 if one exists.
- If `ntfy.gameforce.me` resolves from outside but not at home, something is
  filtering private addresses out of public DNS answers (DNS rebinding
  protection, or an ad-blocking DNS service). Allow `gameforce.me` there.

### WireGuard clients

- `Endpoint = tun.gameforce.me:51820`.
- `AllowedIPs` must include the home LAN subnet (it already does if peers reach
  the LAN today), so traffic to `<ARBITER_LAN_IP>` goes through the tunnel.
- On the iPhone, turn on **On-Demand** for cellular and untrusted Wi-Fi in the
  WireGuard app, so ntfy stays reachable away from home.

### CAA records

If `gameforce.me` has CAA records, one of them must allow `letsencrypt.org`. If
it has none, there's nothing to do.

## 4. Build, test, deploy

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
sudo nft list chain inet nixos-fw input-allow       # the 443 rule
```

Then, from TEMPLAR and from the phone on WireGuard:

```sh
curl -sS https://ntfy.gameforce.me/v1/health   # expect {"healthy":true}
```

From the phone on cellular with WireGuard off, it should time out.

If all that works and SSH still does, make it permanent:

```sh
nix run nixpkgs#nixos-rebuild -- switch --flake .#arbiter --target-host admin@arbiter --sudo
```

### If the certificate fails

- `403`/`Invalid access token` in the lego log: wrong token, wrong zone, or
  missing DNS edit permission (step 1).
- `time limit exceeded` / propagation errors: lego checks against `1.1.1.1`. A
  firewall that blocks outbound DNS from ARBITER would cause this.
- Let's Encrypt allows 5 failed validations per hostname per hour. Fix the
  cause before retrying with
  `sudo systemctl start acme-order-renew-wildcard.service`.

## 5. Not done yet (open decision 4)

These need decisions from you; ask Claude to do them once you've chosen:

- **A read-only phone user** on `arbiter-alerts`. Until it exists the phone can
  reach ntfy but has no account to subscribe with. It needs a bcrypt hash and a
  token in `secrets.yaml`, like `upgrade-notifier`.
- **iOS background push:** `upstream-base-url = "https://ntfy.sh"`. Apple only
  delivers push through ntfy.sh's APNs account, so without it the iOS app gets
  notifications only while it's open. With it, ntfy.sh sees message IDs and
  hashed topic names (not content) and wakes the app, which then fetches the
  message from ARBITER, so this still needs WireGuard up. ntfy also needs
  outbound access to ntfy.sh (its sandbox currently allows only localhost).
- **Alert on failed renewals:** a failing `acme-order-renew-wildcard.service`
  is silent, like `nixos-upgrade` was before `upgrade-alert`. There are about
  30 days of margin before expiry, so it's worth hooking the same ntfy alert to
  it.

## Rollback

`sudo nixos-rebuild switch --rollback` on ARBITER, or reboot after `test`.
