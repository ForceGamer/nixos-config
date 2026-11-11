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

## 5. ntfy on the iPhone

What the config does:

- **A `phone` user** that can read `arbiter-alerts` and nothing else. It can't
  publish. The iOS app logs in with username and password, so this user has a
  password hash and no token.
- **Push through ntfy.sh** (`upstream-base-url`). iOS suspends the app, so only
  Apple push can wake it, and only ntfy.sh can send that for the ntfy app. For
  each message ARBITER sends ntfy.sh an empty request carrying the message id
  and a SHA-256 of `https://ntfy.gameforce.me/<topic>`. ntfy.sh also sees your
  WAN address and when alerts happen. It never gets the title or the text. The
  phone is woken and fetches the message from ARBITER itself, so it has to be
  at home or on WireGuard at that moment.
  - The hash doesn't hide a topic name someone can guess. Knowing it gives no
    access to the alerts: reading them takes the phone's account on ARBITER.
- **ntfy's sandbox** now allows outbound connections to the internet (ntfy.sh's
  addresses can't be pinned) and still denies every private range, so ntfy
  can't reach the LAN.
- **Alerts** come from one template unit, `failure-alert@<unit>.service`
  (`modules/failure-alert.nix`). It fires when `nixos-upgrade` fails, and when
  `acme-order-renew-wildcard` fails. The renewal unit only fails once the
  certificate is in the last third of its lifetime (30 days for a 90-day
  certificate) and still can't be renewed; from then on it alerts once a day.

### 5.1 Put the phone's password hash in sops

Pick a password for the phone, then on TEMPLAR, in the repo:

```sh
nix run --inputs-from . nixpkgs#ntfy-sh -- user hash   # asks twice, prints the bcrypt hash
sops hosts/arbiter/secrets.yaml
```

Add one line under the existing `ntfy:` key:

```yaml
ntfy:
    phone-hash: <BCRYPT_HASH>
```

**The build fails until this key exists**, as with the other secrets. An unused
key is harmless, so it can be committed before this change is merged.

### 5.2 Deploy and check

Build and deploy as in step 4 (`switch` is enough; the firewall is unchanged).
Then:

```sh
systemctl status ntfy-sh.service               # on ARBITER
curl -sS https://ntfy.gameforce.me/v1/health   # from TEMPLAR; expect {"healthy":true}
```

A malformed hash stops ntfy from starting; the status output names it
(`invalid auth-users`).

### 5.3 Set up the app

Install **ntfy** from the App Store, then in the app:

1. **Settings → Default server:** `https://ntfy.gameforce.me`. It must be
   exactly this, with no trailing slash: the push topic is derived from it.
2. **Settings → Users → Add user:** service URL `https://ntfy.gameforce.me`,
   username `phone`, and the password from 5.1.
3. **Add subscription:** topic `arbiter-alerts`.
4. Allow notifications when iOS asks.

WireGuard's **On-Demand** (step 3) is what makes this work away from home.

### 5.4 Test

Lock the phone, then on ARBITER:

```sh
sudo systemctl start failure-alert@test.service
```

A notification titled "test failed on arbiter" should show up. Repeat on
cellular with WireGuard on.

- **A notification that only says "New message":** the push arrived but the
  phone couldn't reach ARBITER. Check WireGuard, and that
  `https://ntfy.gameforce.me/v1/health` opens in Safari.
- **Nothing at all, but the message is there when you open the app:** the push
  didn't arrive. Look for `Unable to publish poll request` in
  `journalctl -u ntfy-sh.service`, check the default server from 5.3, and
  remove and re-add the subscription (ntfy's own advice for this case).
- **The app says login failed:** the password doesn't match the hash in sops.
  Redo 5.1 and deploy again.

### Still open

- **Alerting on fail2ban bans** (open decision 4 in `CLAUDE.md`).

## Rollback

`sudo nixos-rebuild switch --rollback` on ARBITER, or reboot after `test`.
