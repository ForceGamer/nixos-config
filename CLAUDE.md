# Homelab NixOS configuration

Flake-based NixOS configuration for all of the user's NixOS devices, starting with the homelab. **Current scope: ARBITER only.** It is installed and running phase 1 (essentials) plus ntfy, WireGuard, and T3 Code with its coding agents (the `agent` user). Caddy (reverse proxy, wildcard cert), ntfy over HTTPS, ContextForge (PII-scrubbing MCP gateway, internet-facing) and fail2ban are deployed and in use; operator notes in `CADDY.md` and `CONTEXTFORGE.md`. Bichon (e-mail archive, backups to the NAS over NFS) is written but not yet deployed; operator notes in `BICHON.md`. The structure should allow more hosts later, but don't build for them now.

## Priorities (in order; use them to break ties)

1. **Minimal supply-chain risk.** Few flake inputs, official nixpkgs modules first, nothing pulled at runtime that isn't pinned.
2. **Timely automatic security updates.**
3. **Fully declarative.** No imperative state that isn't captured here, except secrets and data.
4. **Principle of least privilege.**
5. **Low maintenance.**

Apply Ockham's razor throughout. Prefer the boring, documented NixOS way over clever abstractions. Do not add frameworks (flake-parts, flake-utils, snowfall, etc.) to save a few lines.

## Environment

- **Operator workstation (TEMPLAR):** Kubuntu with Nix (flakes enabled), editing in Zed with nixd and nil.
- `nixos-rebuild` is not installed on the workstation. Use `nix run nixpkgs#nixos-rebuild -- …`.
- **Network:** a UniFi Dream Router 7 handles DHCP, DNS and VLANs. Host addressing is done with DHCP reservations in UniFi, not static IPs in Nix (one source of truth).
- **Other devices** (not managed by this repo):
  - UGREEN NASync DH4300 Plus: future storage and backup target.
  - Home Assistant Green: standalone.

## Hosts

### ARBITER (`nixosConfigurations.arbiter`, `networking.hostName = "arbiter"`)

- **Hardware:** AMD Ryzen, 64 GB RAM, NVIDIA GTX 980 Ti (Maxwell). Wired Ethernet. One disk: a 1 TB Samsung 980 PRO NVMe.
- **Installed** on 2026-11-08 from the NixOS 26.05 ISO, replacing Proxmox. Its address comes from an existing UniFi DHCP reservation.
- **Role:** main service host. Services are added in later phases, one at a time.
- **GPU:** proprietary driver, headless (see Decisions made).

## Rules

- **nixpkgs:** `nixos-unstable` since 2026-11-14 (the user's choice; was `nixos-26.05`). Unstable takes breaking changes at any time, not once per release: when bumping the lock, read the new entries in the pinned nixpkgs' `nixos/doc/manual/release-notes/rl-<next>.section.md` and fix every removed or renamed option the build reports. Don't move back to a stable channel unless the user asks, and never below the current release (a downgrade can break state that services already migrated).
- **Flake inputs:** only `nixpkgs`, `disko` and `sops-nix`. Ask before adding any input, and explain why a nixpkgs module can't do the job. Make every input follow `nixpkgs` where possible.
- **Verify options against the pinned nixpkgs, not memory.** Options get renamed and removed between releases. Check with `nix eval`, the module source in the pinned nixpkgs, or search.nixos.org set to the matching release.
- **Look up upstream docs with Context7, not memory.** Do this for any software's own configuration, API or CLI: Caddy, ntfy, ContextForge, podman, systemd, lego, sops, Python libraries and so on. Use the `find-docs` skill: `ctx7 library <name> "<query>"`, then `ctx7 docs <id> "<query>"`.
  - Context7 indexes upstream, usually the latest release. When versions matter, check the version nixpkgs pins and use a version-specific ID; where the two disagree, the pinned package's source wins.
  - NixOS options still come from the pinned nixpkgs (rule above).
  - Queries go to context7.com: no PII, hostnames, domains or secrets in them.
  - As `agent` on ARBITER, `ctx7` is on PATH and the skill is in `~/.claude/skills`. On TEMPLAR there is no skill: run `CTX7_TELEMETRY_DISABLED=1 nix run nixpkgs#ctx7 -- …`, if the sandbox's domain allowlist lets `context7.com` through (not verified).
- **Services (later phases):**
  - Prefer native NixOS modules.
  - Use OCI containers (podman via `virtualisation.oci-containers`) only when no module exists, with images pinned by digest.
  - Each service runs as its own user with systemd hardening.
  - Services listen on localhost or a socket behind the reverse proxy.
  - Open firewall ports only per service and only as needed.
- **Secrets:** never in plaintext in the repo. Use sops-nix: encrypted values in `hosts/<host>/secrets.yaml`, recipients in `.sops.yaml`, decrypted on the host with its SSH host key. Hand secrets to services via `sops.templates` or `LoadCredential`, never in argv or the Nix store.
- **No PII** in the repo, commit messages, or comments:
  - No real names, emails, or addresses.
  - Use placeholders (`<ADMIN_USER>`, `<ADMIN_SSH_PUBKEY>`) wherever the user hasn't supplied a value.
  - Don't read files outside this repo unless asked.
- **No actions against the real machine without explicit approval each time.** This covers deploy, partitioning, disko, `nixos-install`, and SSH to ARBITER. Local evaluation and builds are always fine. Claude never runs `test.sh` or `deploy.sh`. Testing on ARBITER happens through merge-test once the user merges a pull request (see Decisions made).
- **Never change `system.stateVersion`** once it's set at install.
- **Before calling a change done:** format with `nix fmt`, make sure `nix flake check` passes, and build the toplevel locally (`nix flake check` doesn't build far enough to catch everything, e.g. missing sops files).
- **Comments explain why, not what.** Keep modules small and single-purpose.

## Layout

```
.
├── flake.nix
├── flake.lock
├── CLAUDE.md
├── CADDY.md                           # operator steps to finish the Caddy/ntfy rollout
├── CONTEXTFORGE.md                    # what the MCP gateway scrubs (and doesn't); operator steps
├── BICHON.md                          # e-mail archive: NAS share, secret, first login, backup settings, restore
├── deploy.sh                          # nixos-rebuild switch against ARBITER
├── test.sh                            # nixos-rebuild test against ARBITER (a reboot undoes it)
├── .gitmodules                        # empty on purpose: the Claude Code sandbox needs a real file here
├── add-pii.sh                         # put a name into sops for the gateway's rule files
├── tools/
│   ├── pii-survey.py                  # report of identifiers the rules miss, as shape masks; Ollama optional
│   └── fixtures/                      # redacted Fastmail tool results the survey check runs on
├── .sops.yaml                         # who can decrypt secrets (age recipients)
├── hosts/
│   └── arbiter/
│       ├── default.nix                # host-specific config, imports modules
│       ├── hardware-configuration.nix # generated; filesystems come from disko
│       ├── disko.nix                  # declarative disk layout
│       ├── secrets.yaml               # sops-encrypted secrets
│       └── pii/                       # ContextForge rule groups, one file each, filename order; with examples
│           └── servers/fastmail/      # Fastmail's own list: the per-sender groups
└── modules/
    ├── base.nix         # locale, time, journald, minimal packages
    ├── nix.nix          # nix settings, gc, store optimisation
    ├── users.nix        # immutable users, admin account
    ├── ssh.nix          # hardened sshd
    ├── networking.nix   # networkd + nftables firewall
    ├── nvidia.nix       # headless NVIDIA driver (legacy 580 branch)
    ├── auto-upgrade.nix  # unattended updates
    ├── failure-alert.nix # ntfy alert when a watched unit fails (auto-upgrade, certificate renewal, merge-test, Bichon backup age)
    ├── merge-test/       # tests each new master commit on ARBITER behind a dead man's switch, announces Claude's pull requests on ntfy; VM test
    ├── wireguard.nix     # WireGuard VPN into the home LAN (wg0, NAT)
    ├── t3-code.nix       # T3 Code and coding agents as the `agent` user (unconfined; internet only, memory cap, Caddy site, t3-pair)
    ├── fail2ban.nix      # shared ban policy; each exposed service adds its jail
    └── services/
        ├── caddy.nix     # Caddy reverse proxy, wildcard cert via ACME DNS-01; homelab.domain
        ├── ntfy.nix      # ntfy server on localhost behind Caddy; all ntfy users and ACLs
        ├── contextforge.nix # MCP gateway (rootless podman) with PII plugins; public vhost + decoy catch-all + jail
        ├── bichon.nix    # Bichon e-mail archiver (2.4.3 override while nixpkgs is older); NFS backup target; daily backup-age check
        └── contextforge/    # our plugins: ScopedFilter (rules + detectors) and LlmDetector; pseudonym store; cores, wrappers, unit tests
```

## Phase 1 scope: ARBITER essentials

1. **Flake skeleton:**
   - Inputs `nixpkgs` (nixos-26.05 then; now nixos-unstable, see Rules) and `disko`.
   - One output, `nixosConfigurations.arbiter`.
   - A `formatter` output pointing to `nixfmt`.
2. **Disks:** `disko.nix` with an EFI system partition plus root. Disk IDs come from `/dev/disk/by-id`.
3. **Boot:**
   - systemd-boot, EFI, `configurationLimit = 10`.
   - Default (LTS) kernel.
   - AMD microcode and `hardware.enableRedistributableFirmware`.
4. **Networking:**
   - `systemd-networkd` with DHCP on the wired NIC (match by MAC or `en*`).
   - nftables firewall enabled; only TCP 22 open (UDP 51820 for WireGuard was added later).
5. **Users:**
   - `users.mutableUsers = false`.
   - One admin user `<ADMIN_USER>` in `wheel`, authenticated with `<ADMIN_SSH_PUBKEY>`.
   - Root has no password and no SSH login.
6. **SSH:**
   - Key-only: `PasswordAuthentication = false`, `KbdInteractiveAuthentication = false`.
   - `PermitRootLogin = "no"`, `AllowUsers` set to the admin, X11 forwarding off.
7. **sudo:** `security.sudo.execWheelOnly = true`. Passwordless wheel (see Decisions made).
8. **Nix:**
   - Flakes enabled.
   - `allowed-users = [ "@wheel" ]`.
   - `trusted-users = [ "root" "<ADMIN_USER>" ]`, which is needed for pushing closures from the workstation.
   - Weekly GC deleting generations older than 14 days.
   - Automatic store optimisation.
   - Disable channels (`nix.channel.enable = false`); the system is flake-only.
9. **Auto-upgrade:**
   - `system.autoUpgrade` runs weekly (Sunday 03:15), with `allowReboot = true` and a reboot window of roughly 03:00–05:00 so kernel fixes actually apply.
   - New nixpkgs revisions come from option (b) (see Decisions made).
10. **Base:**
    - `time.timeZone = "Europe/Oslo"`, `i18n.defaultLocale = "en_GB.UTF-8"` (English with non-US date and number formats), console keymap `no`.
    - Default timesyncd.
    - journald `SystemMaxUse=1G`.
    - Only a handful of system packages (e.g. `git`, `htop`, `smartmontools`).

**Out of scope for phase 1:** all services, VPN, NAS mounts, backups, monitoring, intrusion detection, GPU drivers, secrets management, and VLAN-specific config.

## Install procedure (needs user approval at each destructive step)

Used for the first install; kept for reinstalls. A reinstall wipes the disk, so confirm with the user that nothing on it needs keeping.

1. Confirm nothing on the existing install still needs to be kept.
2. Boot the official NixOS 26.05 minimal ISO and verify its checksum. Set a temporary password (`sudo passwd` for root was used the first time), then SSH in from the workstation.
3. Collect hardware facts:
   - `ls -l /dev/disk/by-id`
   - `ip link` (MAC address for the UniFi DHCP reservation)
   - `nixos-generate-config --no-filesystems --show-hardware-config`, saved to `hosts/arbiter/hardware-configuration.nix`
4. Fill in `disko.nix`. Run disko from the pinned flake input (check the current `--mode` names for that disko version), which partitions and mounts `/mnt`.
5. Give ARBITER its SSH host key before install, so it can decrypt secrets on first boot:
   - On the installer: `mkdir -p /mnt/etc/ssh && ssh-keygen -t ed25519 -N "" -f /mnt/etc/ssh/ssh_host_ed25519_key`.
   - On the workstation: convert its public key with `nix run --inputs-from . nixpkgs#ssh-to-age`, add it as `&arbiter` to `.sops.yaml` (replacing the old one on a reinstall), run `sops updatekeys hosts/arbiter/secrets.yaml`, and commit.
   - If this is skipped, ntfy can't start (its env file is missing); everything else still works.
   - Then run `nixos-install --flake .#arbiter --no-root-passwd`.
6. Reboot, remove the ISO, clear the installer's entry from `known_hosts`, and verify SSH key login, sudo, `systemctl --failed`, firewall (`nft list ruleset`), timers (`systemctl list-timers`), `nvidia-smi`, and T3 Code (`https://code.<domain>`).

nixos-anywhere is intentionally not used, to avoid an extra tool. Suggest it only if the ISO route causes problems.

## Commands

```sh
nix flake check
nix fmt
nix build .#nixosConfigurations.arbiter.config.system.build.toplevel   # local build, no deploy

# Deploy (only with approval). Builds on the workstation, copies to ARBITER.
# Check the sudo flag name for the nixos-rebuild version (--sudo vs older --use-remote-sudo).
nix run nixpkgs#nixos-rebuild -- test   --flake .#arbiter --target-host admin@arbiter --sudo  # try, no boot default
nix run nixpkgs#nixos-rebuild -- switch --flake .#arbiter --target-host admin@arbiter --sudo

nix flake update nixpkgs   # bump nixpkgs pin
```

**Rollback:** `sudo nixos-rebuild switch --rollback` on the host, or pick an older generation in the boot menu. Use `test` before `switch` for anything touching networking, SSH or the firewall. A reboot undoes a bad `test`.

## Decisions made

- **NVIDIA:** `modules/nvidia.nix`, proprietary closed modules from the `legacy_580` branch. The default branch (595+) dropped Maxwell; 580 is supported until August 2028, after which the card needs replacing or stays on an unpatched driver. Headless: `videoDrivers` only switches the module on, no X server. `nvidia-persistenced` keeps the idle GPU in a low power state. It is not restarted on switch/test (`restartIfChanged = false`): after a driver bump the loaded kernel module stays the old version until reboot, and a new-version daemon fails against it (seen 2026-11-14, 580.178.04 → 580.196.07 with the move to unstable). Unfree is allowed only for the driver packages by name. The nixpkgs module makes `/dev/nvidia*` world-accessible (mode 666), so any local user or unsandboxed service can use the GPU; restrict services with `DeviceAllow`/`PrivateDevices` as needed. cache.nixos.org doesn't serve unfree builds, so the driver and its kernel module are compiled locally, including on ARBITER after each kernel bump. Verified with `nvidia-smi` after install.
- **Filesystem:** ext4, no encryption (unattended auto-upgrade reboots must come back without intervention). Root disk is the 1 TB Samsung 980 PRO NVMe (ID in `disko.nix`), ARBITER's only disk. Bulk data will live on the NAS.
- **Updates:** option (b). `modules/auto-upgrade.nix` rebuilds the deployed source (`self`, in the store) with `--override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable`. Keep that URL in sync with `flake.nix`. Runs weekly (Sunday 03:15) rather than nightly: less churn, at the cost of up to a week of security-fix latency. On unstable an upstream rename or removal makes the weekly build fail rather than switch; `failure-alert` reports it on ntfy and the old generation keeps running until the repo is fixed and deployed.
- **sudo:** passwordless wheel (`wheelNeedsPassword = false`), since SSH is key-only.
- **Admin user:** `admin`, set via `homelab.admin.name` in `hosts/arbiter/default.nix`. Authenticated by TEMPLAR's ed25519 key (`templar`), which also logs in as `agent`.
- **Secrets:** sops-nix (added as a flake input, since nixpkgs has no module that decrypts repo-committed secrets). Operator age key lives on the workstation at `~/.config/sops/age/keys.txt`.
- **ntfy:** native `services.ntfy-sh`, listening on `127.0.0.1:2586`, `deny-all` by default with declarative users/tokens from sops. Served as `https://ntfy.gameforce.me` through Caddy (`base-url` set to that, `behind-proxy` on). Every identity and its access is in `modules/services/ntfy.nix`: `upgrade-notifier` (write-only on `arbiter-alerts` and `claude`, token), `phone` (read-only on both, password, because the iOS app has no token field) and `laptop` (REVENANT, same access, password, for the web app's per-topic login).
  - Web push (2026-11-14, the user's choice, for REVENANT's web app/PWA): VAPID keys and the contact address in sops (`ntfy/web-push-*`), subscriptions in `/var/lib/ntfy-sh/webpush.db`. The browser vendor's push service carries each message end-to-end encrypted to the browser (ntfy accepts only Google, Mozilla, Apple and Microsoft endpoints and checks read access), so it arrives with the app closed and without WireGuard; the service sees timing, size and the contact address.
  - iOS push: `upstream-base-url = "https://ntfy.sh"`. iOS suspends the app, so only Apple push wakes it, and only ntfy.sh can send that for the ntfy app. Per message ntfy.sh gets the message id, a SHA-256 of `base-url/topic`, and ARBITER's WAN address; never the title or body (checked against a local listener). The phone then fetches the message from ARBITER, so it must be on the LAN or WireGuard; otherwise it shows a bare "New message". `base-url` must equal the server URL entered in the app, or no push arrives.
  - ntfy's sandbox therefore allows the internet and localhost and denies every private range (ntfy.sh's addresses can't be pinned in `IPAddressAllow`).
  - Alerts: `modules/failure-alert.nix` is a template unit, `failure-alert@<unit>.service`, hooked with `onFailure` to the units in its `watched` list (`nixos-upgrade`, `acme-order-renew-wildcard`, `merge-test`, `bichon-backup-check`). The renewal unit fails only once the certificate is in the last third of its lifetime and still can't renew. `systemctl start failure-alert@test.service` sends a test message.
  - Outside this repo: the `ntfy/*` sops secrets and the app setup on the phone and laptop. See `CADDY.md`.
- **Domain and exposure:** `homelab.domain = "gameforce.me"`, DNS at Cloudflare. `tun.gameforce.me` → WAN IP via DDNS (WireGuard endpoint); the apex and `*.gameforce.me` → ARBITER's LAN IP in public DNS, all DNS-only (not proxied). **Exposed: WireGuard and the ContextForge MCP endpoint only**, both on `tun.gameforce.me` (UniFi forwards UDP 51820 → 51820 and TCP 443 → ARBITER 47231; no other public DNS name); every other service is for the LAN and WireGuard peers.
- **Reverse proxy:** native `services.caddy`, TCP 443 only (no port 80, HTTP/3 off), accepted only from private IPv4 sources (`extraInputRules`, so it holds on the host even if UniFi ever forwards 443). Each service module adds its own `services.caddy.virtualHosts` entry on a subdomain of `homelab.domain` with `useACMEHost = "wildcard"`.
  - Other LAN devices (2026-11-16, the user's request): `files.<domain>` → `https://192.168.1.152:9443` (UGOS's HTTPS port), in `hosts/arbiter/default.nix` since the address is the host's business. The device's certificate is self-signed, so `tls_insecure_skip_verify`; pinning it with `tls_trust_pool file` would authenticate the LAN hop. The address must be a UniFi DHCP reservation.
  - Certificates: `security.acme.certs.wildcard` (`*.gameforce.me`, lego from nixpkgs) with Cloudflare DNS-01; token `cloudflare/dns-api-token` in sops, passed via `credentialFiles` (LoadCredential). Not Caddy's own ACME: stock Caddy lacks the Cloudflare plugin and a plugin build means extra Go modules compiled locally. Propagation checked against `1.1.1.1:53`.
  - Caddy's admin API is a `0600` unix socket in `/run/caddy`, not TCP `localhost:2019`. Capabilities reduced to `CAP_NET_BIND_SERVICE`.
  - `strict_sni_host on` (Host must equal SNI, else 421) and `default_sni`/`fallback_sni = decoy.invalid`: clients with no or unknown SNI get a self-signed `CN=localhost` decoy (`homelab.caddy.decoyCert`, generated at build time, key in the store on purpose) instead of the wildcard, so a port scan doesn't reveal the domain. Verified against the real binary: without this, an empty SNI is handed the wildcard, and an HTTP/2 request with a foreign `:authority` bypasses every site's host matcher and gets an empty 200. Side effect: `https://<LAN-IP>/` shows the decoy and a 421.
  - Outside this repo: the Cloudflare DNS records and API token. See `CADDY.md`.
- **WireGuard:** terminated on ARBITER (`modules/wireguard.nix`), UDP 51820, tunnel `10.100.0.0/24` with ARBITER `.1`, iPhone `.2`, laptop (REVENANT) `.3`, per-peer preshared keys in sops. Peers reach the whole home LAN masqueraded as ARBITER; the forward chain drops anything from `wg0` that isn't RFC 1918, and LAN hosts can't open connections into the VPN.
  - Built as a raw networkd netdev with `PrivateKeyFile=`, not `networking.wireguard`: that backend passes keys to systemd-networkd via `LoadCredential`, so a missing secret would stop networkd and cut SSH. Keep it that way.
  - Outside this repo: UniFi port forward UDP 51820 → ARBITER, and DDNS keeping `tun.gameforce.me` (clients' `Endpoint`) on the WAN IP.
- **T3 Code and the coding agents:** `modules/t3-code.nix` (2026-11-17, the user's choice; replaced the Claude Code microVM, and with it the `microvm` input). They run directly on ARBITER as the `agent` user, **unconfined by design, a risk the user accepted**: agents can read the store and every world-readable file, see all processes (no `hidepid`) and use the GPU (`/dev/nvidia*` is 0666). The microVM's volumes stay in `/var/lib/microvms/claude/` until deleted by hand.
  - User `agent`: uid 1001 (static because the nftables rules match on it), the admin's SSH key (`ssh agent@arbiter`), no sudo, home 0700, which keeps other users out of the installed agents, their logins and `~/src` (the admin's home is 0700 too). Nix daemon as an allowed, not trusted, user. `programs.nix-ld` and `~/.local/bin` on PATH for the installers' generic-Linux binaries. Toolchain (`ctx7`, `gh`, `uv`, `pnpm`, `t3-pair`, …) in `users.users.agent.packages`, so only on agent's PATH.
  - Installed by hand as `agent` with upstream's one-liners (T3 Code, Claude Code, Codex, Grok; the commands are in the module), all self-updating and unpinned. T3 Code isn't taken from nixpkgs: the user's rule is nixpkgs only if it keeps pace with upstream, and it doesn't (0.1.8 there vs. 0.1.10 upstream on 2026-11-17; upstream ships several releases a week). The logins (`gh auth login` and each agent's own) live in `/home/agent`, not in the repo. Prefer a fine-grained GitHub token limited to the repos the agents should touch.
  - Network: the `t3-code` nftables table rejects new connections from uid 1001, and from Nix build users (gid `nixbld`: a fixed-output derivation the agent asks the daemon for has the host's network), to RFC 1918/CGNAT/link-local/multicast, to any IPv6 but loopback (the LAN's global prefix isn't known in the repo), and to ARBITER's service ports over `lo` (`hostPorts`: SSH, 443, the ContextForge public port, ntfy, ContextForge, Bichon). **A new service listening on localhost must be added to `hostPorts`.** Other loopback ports stay open for agents' own dev servers. Verified on the rendered table in an unprivileged user+network namespace (`unshare -rn`, uid swapped for 0), 2026-11-17.
  - Resources: a `user-1001.slice` drop-in, `MemoryMax=56G` (the user asked for a generous cap that still leaves the services room). No CPU cap: every service, the ContextForge container (`podman-contextforge.service`) and Nix builds are in `system.slice`, which gets at least half the CPU under contention. Builds the agent requests run in the daemon, outside the cap.
  - Context7 (2026-11-14, the user's request): `ctx7` from nixpkgs, telemetry off by env, used by a user-level skill at `~/.claude/skills/find-docs/SKILL.md` (adapted from upstream's, written by hand, not in the repo). Not upstream's `npx ctx7@latest` or `ctx7 setup` (unpinned npm at every call). Anonymous, no API key; queries go to context7.com, so the skill forbids personal data in them.
  - T3 Code (2026-11-14, the user's choice; replaced Claude Code's Remote Control): `t3 serve` as the `t3code` user service (lingering, login shell for the agents' PATH, `~/src`), bound to `127.0.0.1:3773`. Caddy serves it as `https://code.<domain>` (443, so LAN and WireGuard only). Telemetry off (env + managed policy); `/etc/t3code/policy.json` sets the default permission mode to `auto`, unlocked, and no `maxRuntimeMode` (that would make every provider's launch settings ours). Providers are whatever CLIs are on PATH and logged in; restart the service after adding one. Devices pair with `t3-pair [label]`: `t3 pair` can't set the address, so the script rewrites the link to `https://code.<domain>/pair#token=…` and prints a QR code; `t3 auth session list|revoke` manages them. Verified in a scratch run (t3 0.1.9 behind a Caddy test instance): the web app pairs and its websocket connects over HTTPS; over plain HTTP at a non-loopback address the headless browser could not pair (likely no secure context for its crypto), so always go through Caddy.
- **ContextForge:** `modules/services/contextforge.nix`, IBM's MCP gateway as the PII-scrubbing hop between MCP servers with personal data and AI clients. `ghcr.io/ibm/mcp-context-forge` v1.1.0 pinned by digest (no nixpkgs package), rootless podman under `contextforge` (uid 380, linger, `--userns=keep-id`), read-only rootfs, no capabilities, SQLite in `/var/lib/contextforge/data`, `127.0.0.1:4444`. Rootless rather than root podman for least privilege; the static uid is what the oci-containers module needs for `/run/user/<uid>`.
  - Scrubbing is in ContextForge's plugin framework on `tool_post_invoke` and `prompt_post_fetch` only: our own `ScopedFilter` plugin (`modules/services/contextforge/`, mounted into the image at `plugins/custom`; rule groups from `hosts/arbiter/pii/*.nix` via `homelab.contextforge.rulesDir`, filename order; a group is global or scoped by sender/subject regexes, and where no email is recognisable every group applies, so scoping only ever adds rules; a rule's `secret` names a sops key whose value is matched literally, case-insensitive, whole-word, and the module declares the secret; `./add-pii.sh` stores the value regex-escaped; longer values go first; every rule gets `(?i)` unless it opens with its own flag group; `checks.x86_64-linux.contextforge-filter` runs the plugin's unit tests and each file's `examples` against the rendered rules, with secrets replaced by `SECRET_<KEY>` stand-ins. Written instead of the stock `regex_filter` because that has no scoping and silently drops a regex that doesn't compile; ours refuses to load), then, in the same plugin, generic detectors (`detectors_core.py`: e-mail, phone, card, IBAN/account, DOB, Norwegian ID → `[HASH:16hex]`; IPv4/IPv6 → `[IP:16hex]`). Regex-based, no NER; resources aren't filtered, so virtual servers get tools only. Presidio would mean the external LLMGuard plugin container (downloads models at start), rejected under priority 1.
  - Stable pseudonyms (2026-11-14, the user's request; replaced IBM's `cpex_pii_filter`): HMAC-SHA256 under sops `contextforge/pseudonym-key` (mounted read-only at `/etc/mcpgateway/pseudonym.key`, never in env), first 16 hex; trimmed, e-mail and LLM findings lower-cased (`pseudonym_core.py`). Why: `cpex_pii_filter` 0.3.9 salts with a random UUID per plugin *instance* and never reads `hash_salt` from config, and the gateway builds one plugin manager per `team::tool` context, cached 30 s (`gateway_plugin_manager.TenantPluginManagerFactory`), so tokens differed between tools and minutes. Every pseudonym is recorded (`/data/pseudonyms.db`, SQLite 0600, 180-day TTL from last use) before the result leaves; `tool_pre_invoke` on ScopedFilter restores known ones in tool arguments (the user accepted that originals then reach the upstream, including in anything a send tool would send). Organisation addresses stay readable (machine local parts; `hosts/arbiter/pii/allow-domains.txt`, subdomains included); `homelab.domain` and sops `contextforge/own-domain` are always hashed. `messageId`/`inReplyTo`/`references` get literal (sops-secret) rules only. Rules with `urls = false` (numbers, amounts) and the numeric detectors skip URL spans. Parity with the old filter checked on a synthetic corpus: differences only where intended (allowlist, `+47` 3-2-3, account label kept, IPs, URLs; a four-part version number now reads as an IP).
  - **cpex 0.1.4 ignores the YAML's `plugin_settings`** ("runtime settings are read from env vars via settings.py"): the old `fail_on_plugin_error = true` and `plugin_timeout` there never applied. They are now `PLUGINS_FAIL_ON_PLUGIN_ERROR=true` and `PLUGINS_PLUGIN_TIMEOUT` on the container. Without the first, a plugin that fails to *load* is skipped and calls run without it (verified with the real `PluginManager`); with it, the tool's manager build raises and the call fails. Per-call errors fail the call via each plugin's `on_error` (default `fail`, now stated).
  - Rule lists: the global list is `hosts/arbiter/pii/*.nix`; `homelab.contextforge.servers.<name> = { id; rulesDir; }` adds a list for one upstream MCP server (groups tagged `server`, run after the global ones). The id is the **upstream** server's (admin UI → Gateways): in v1.1.0 the gateway overwrites a tool call's `GlobalContext.server_id` with the upstream id (`tool_service._apply_tool_payload_to_global_context`; the middleware leaves it unset), so a plugin can't see the virtual server. Checked in the v1.1.0 source and against cpex 0.1.4 (the version its `uv.lock` pins). An id not in `servers` gets every server's groups, so a wrong id over-filters. On ARBITER (2026-11-13, the user's request): every sender-scoped group lives in `pii/servers/fastmail/`; people, links, identifiers, money and the parked timestamps stay global. Order is unchanged (global 10–40, then Fastmail 50–90), so Fastmail results get exactly the same rules as before; verified by comparing the rendered groups.
  - `LlmDetector` (`modules/services/contextforge/llm_detector*.py`, priority 60, after ScopedFilter; `homelab.contextforge.llm`): Ollama on **TEMPLAR** (the user's choice, 2026-11-13: TEMPLAR has the GPU; ARBITER's Maxwell card was the alternative). Every tool except `llm.excludeTools` (the user wants a blacklist, 2026-11-13; empty so far): the plugin checks the tool name the client called itself, exact match, since ContextForge `conditions` can only allow-list. So while TEMPLAR is unreachable every tool call fails. Enabled on ARBITER with TEMPLAR's address (192.168.1.145) in the URL; it must be a UniFi DHCP reservation, or a new lease breaks every tool call. Each email in a result is one request, sent as `field: value` lines, never the raw JSON; ids untouched; text outside emails is one more request; long units split at line breaks. The model only lists findings; code masks those that occur verbatim (≥3 chars, not a mask; whole word except for the user's own values) as `[PII:16hex]` (same key and store as the rule layer), inside that email only. It is asked for the user's own values (every literal rule's secret, unescaped, in the system prompt: they travel to TEMPLAR with each request, the user's choice), places tied to the user, addresses, contact/account/ID numbers and IPs; not other people's names or handles (the user's choice, 2026-11-14). Placeholders are cut out of what it is sent. Fail closed: any Ollama error, per-request timeout or the per-call deadline fails the call; the deadline also stops the worker thread from starting new requests. Stdlib `urllib` in `asyncio.to_thread` (one gunicorn worker). cpex 0.1.4 has one global `plugin_timeout`; it becomes `llm.timeout + 15` when the detector is on. The post-invoke hook runs outside the gateway's tool timeout. Verified against a real cpex 0.1.4 `PluginManager`: tool exclusion, server scoping, and an Ollama failure turning into `PluginError`. Outside this repo: Ollama on TEMPLAR listening on the LAN, reachable from ARBITER only (no auth in Ollama), the model pulled (unpinned; ARBITER uses `oamazonasgabriel/qwen3.6-35b-a3b:q4-24gbGPU`, a personal upload on ollama.com rather than an official library model, the user's choice). Plain HTTP on the LAN.
  - The plugin YAML is a `sops.templates` file (it carries sops placeholders), mounted read-only into the container; secrets reach it through a second template as podman's `--env-file`. Both owned by `contextforge`, mode 0400.
  - Three Caddy sites: `mcp-admin.<domain>` on 443 (LAN/WireGuard, full gateway and admin UI); `tun.<domain>:<publicPort>` (internet: `/servers/*` only, and only when an `Authorization: Bearer` header is present, 2 MB bodies, `Server` header stripped; anything else is `abort`ed, i.e. the connection is closed with no response); and a catch-all `:<publicPort>` that serves the decoy certificate and aborts. The hostname is the WireGuard one (`tun`), already public on the WAN IP, so no DNS record hints at a web service. On the host it is `homelab.contextforge.publicPort` (47231): a separate port rather than relaxing 443 keeps the private-source rule on ARBITER's 443 intact. Externally it is 443: **claude.ai custom connectors cannot reach a non-standard port** (tested 2026-11-09: "Couldn't connect", no packet arrived; same URL on 443 worked), so the router maps WAN 443 → 47231 and the "out of mass scans" benefit is gone; the decoy, the silent drops and fail2ban remain. Caddy checks only that a bearer header exists (stock Caddy can't validate JWTs); the gateway validates it. Clients use expiring JWT bearer tokens from the admin UI; claude.ai connectors send them as a request header.
  - Facts learned in operation: the Fastmail tools return `{results: [email…]}` or one email, `from` as `[{name,email}]`, JSON in `content[0].text` plus `structuredContent`; the JMAP `id` is what the read tool takes and passes through intact; `messageId` (an RFC 822 Message-ID) was hashed by the old e-mail detector until 2026-11-14 and now passes through (literal rules only). ScopedFilter runs before the PII filter, so `when.from` sees the raw sender; by the time anything else (the survey tool, the client) sees it, the address is a hash and only the display name remains, so scopes match on the name or domain, never on a full address. `linger-users.service` failed on the first activation that created the `contextforge` user and worked after a restart; cause not captured.
  - `tools/pii-survey.py` is how new rules get found: it reports shape masks and anchors, not values. A report still shows words around a candidate, so a name or address no secret covers yet *will* appear in it. Read reports before pasting them anywhere; the first real run exposed exactly that and the chat had to be discarded. Rule files follow the survey, one scoped group per sender in `pii/servers/fastmail/`, with the report's masked snippets as `examples`. Text versions of HTML mail glue table cells together (`Customer Name<first> <last>Invoice Number…`), which defeats every whole-word rule, the name secrets included: the global label and money rules tolerate a glued label, a glued name needs a scoped rule on the labels around it (`servers/fastmail/75-battlenet.nix`), and the second survey report showed one in clear. Links carrying a long opaque token are cut at the token for every sender (`15-links.nix`). A new rule file must be `git add`ed before `nix flake check`, or the flake doesn't see it and the check passes without it.
  - Outside this repo: the `contextforge/*` sops secrets, now including `pseudonym-key` and `own-domain` (the gateway validates `DEFAULT_USER_PASSWORD` at start even with registration off, so it is a secret too), the UniFi forward TCP 443 → ARBITER 47231, and the upstream servers/virtual servers/tokens configured in the UI (stored in its SQLite). See `CONTEXTFORGE.md`.
- **merge-test:** `modules/merge-test/`. Merging a pull request on GitHub is the approval to test it on ARBITER; nobody runs `test.sh` for that.
  - Every 2 minutes ARBITER fetches `master` over SSH with a read-only deploy key it generated itself (`/var/lib/merge-test/deploy-key`, root only; GitHub's host key is pinned). A new commit is recorded first, so it is tried once, then built by exact commit hash from a local bare clone.
  - `activate.sh` is the dead man's switch. It arms a transient timer (15 min) that re-activates the boot default, activates the build with `switch-to-configuration test` in a transient unit as nixos-rebuild does, waits 60 s and checks: activation succeeded, no newly failed units, sshd and networkd still active if they were, the default route and `wg0` still there, and `git ls-remote` to GitHub works. Pass: the timer is cancelled. Fail: rollback at once, waited on through the unit's own state (a rollback that changes systemd or `system.conf` re-executes PID 1, which cuts `systemctl start` short; first seen on unstable, 2026-11-14). If the script dies, the timer rolls back. The VM test `checks.x86_64-linux.merge-test` covers all of that, including the transient timer surviving activation.
  - It never switches. The boot default stays the last `deploy.sh`, so a reboot or the weekly upgrade also ends a test, and a `deploy.sh` during the window turns the rollback into a no-op. It skips a tick while `nixos-upgrade` runs.
  - Claude's ntfy channel (2026-11-14, the user's request): topic `claude`. Each poll, after fetching, runs `merge-test-prs` (`modules/merge-test/prs.sh`): `git ls-remote` lists `refs/pull/N/head` (the deploy key can, no API token needed), a PR is matched to its branch by commit, and one from a `claude/` branch numbered above `$STATE_DIRECTORY/last-pr` is published as "PR #N opened" with the subject of its first commit (≈ the title) and a Click link to the PR. The first run only records. Failures there never stop the merge test. Up to 2 minutes late; a PR whose branch is deleted before the next poll is skipped. Test: `checks.x86_64-linux.merge-test-prs` (local stand-in for GitHub, no VM). Messages Claude itself starts would need `agent` to reach ntfy, which `t3-code` blocks (not built).
  - Results go to ntfy `arbiter-alerts`: testing, active, rolled back with the reasons, doesn't build, and fetch failing or working again (each once).
  - `master` has to build as committed: a secret key that exists only in a working copy on TEMPLAR makes every merge fail to build.
  - Runs as root, unconfined: it activates whole systems, so a sandbox around it would be decorative. Whoever can change `master` gets root on ARBITER.
  - Outside this repo: the deploy key, added to the GitHub repo as read-only. The first run publishes its public key to ntfy.
- **Bichon:** `modules/services/bichon.nix` (2026-11-18, the user's request), the e-mail archive in the flow mail host →IMAP→ Bichon →its own incremental backup→ NAS →restic, encrypted→ B2 (restic: a later PR, on ARBITER via `services.restic.backups`, the user's choice).
  - Package: nixpkgs' recipe with a newer source (2.4.3; nixpkgs had 2.2.0, upstream releases several times a week, 2.3.1 fixed a crash recovery that could poison a backup object). Guarded by `lib.versionAtLeast pkgs.bichon.version pinned`, so the weekly upgrade switches to nixpkgs' build once it catches up (the user's condition for overriding at all: it can't auto-follow upstream, since every version needs pinned hashes). The web UI's pnpm lockfile was unchanged from 2.2.0, so only `src` and `cargoHash` are overridden.
  - Own `bichon` user, systemd hardening, `127.0.0.1:15630`, `https://bichon.<domain>` (LAN/WireGuard), internet and localhost only (NFS is kernel traffic, outside the cgroup). `BICHON_ENCRYPT_PASSWORD_FILE` from sops `bichon/encrypt-password` via `LoadCredential`; 2.4.3 reads the file before the always-defaulted password option, despite its `--help`. The default login `admin`/`admin@bichon` is changed by hand.
  - Live data stays on the NVMe (`/var/lib/bichon`; upstream warns against NFS for it). Backups: Bichon's local-directory target at `/mnt/bichon/nas`, an NFSv4 automount (hard, `nosuid,nodev,noexec`) of `homelab.bichon.backupNfs` = the NAS's `/volume1/Email`, under a `0700 bichon` parent so other local users (agents included) can't reach the share. The NAS squashes all users (UGOS "Map all users to admin", the user's choice, 2026-11-18: Bichon's uid doesn't exist on the NAS, and root on ARBITER must not be root on the share; restic will read it the same way). NFS support turns on `rpcbind` (port 111, not opened in the firewall). Smoke-tested 2026-11-18 as a transient user unit with the service's sandbox: starts, serves the UI, a local-target backup writes `bichon-backup/v1/meta/LATEST`, the check's `find` matches it and misses a 3-day-old one, and the documented `bichon-admin restore` works. IMAP accounts and the backup target, schedule and retention are Bichon UI settings in its own database, not declarative.
  - Bichon's scheduler runs inside the server, so `bichon-backup-check` (daily 09:00, watched by failure-alert) fails when `<prefix>/v1/meta/LATEST` on the share is older than 48 h; every run, changed or not, rewrites it. It also fails until the first backup exists.
  - Outside this repo: the sops secret, the UGOS NFS rule, the first login and the UI settings. See `BICHON.md`.
- **fail2ban:** `modules/fail2ban.nix` for policy (private ranges never banned, 5 tries / 10 min, 1 h doubling to a week, `nftables-allports`), jails live with their service. Jail `contextforge` reads Caddy's JSON access log for the public port (status 0 = aborted by Caddy, 421 = Host/SNI mismatch, 401/403/404 = rejected by the gateway; `datepattern ^.*"ts":{EPOCH}`, filter verified with `fail2ban-regex`). A client disconnecting before any response also logs status 0, but a real client always sends the bearer header and gets a 200 before streaming, so this hasn't bitten. CrowdSec was rejected: it pulls hub configs and blocklists at runtime (priority 1). The module's default `sshd` jail stays on; it's harmless.
- **Repo:** private GitHub repo `nixos-config` (`origin`). The workstation checkout is the only place the config is edited; push after committing. Commits use the GitHub noreply email (set in this repo's `.git/config`).
- **Claude Code on TEMPLAR:** runs in Claude Code's sandbox (bubblewrap) with the user's global settings (read block outside the working directories, strict sandbox, domain allowlist) plus an untracked `.claude/settings.local.json` that is deliberately not in the repo. Facts, verified with Claude Code's own sandbox on 2026-11-11:
  - Runs outside the sandbox, unattended: `git fetch [origin …]`, `git push [-u] origin claude/…`, and `gh pr create|view|list|diff|checks`. Everything else is sandboxed, where git and gh have no credentials, so `git pull` fails: fetch, then merge or rebase. Push to master, force pushes and deleting branches are denied.
  - `gh pr create` stays sandboxed, so it fails, when the call has a heredoc, a redirect or `$(…)`. Write the description to `.pr-body.md` (gitignored) and pass `--body-file .pr-body.md`; absolute, `~` and `..` paths are denied.
  - Claude can't write `test.sh`, `deploy.sh`, `.sops.yaml`, `hosts/arbiter/secrets.yaml` or `.gitmodules`, and has no sops access. Secrets are the user's.
  - Nix works sandboxed: the daemon socket is reachable because Unix sockets are allowed, while `/run/user`, `/run/dbus`, the X11 and ssh-agent socket directories are hidden (with the session bus reachable, `systemd-run --user` starts programs outside the sandbox). `.gitmodules` must stay a real file: the sandbox masks a missing one with a `/dev/null` device, and Nix's git fetcher then can't evaluate the flake.
  - The PII survey runs sandboxed, but its Ollama step can't reach `127.0.0.1` there and falls back to heuristic labels.
- **Formatter:** `nixfmt-tree` (nixfmt's own `nix fmt` wrapper) with `tree-root-file = "flake.nix"` so it never walks outside the repo.

## Open decisions (ask the user; don't choose silently)

1. **Moving updates to option (a)** (merge-test already fetches `master` with a deploy key; option (a) could reuse it, but must only pull commits that passed merge-test): a scheduled CI job bumps `flake.lock` and checks the build, and ARBITER's autoUpgrade pulls the repo. Fully declarative, unlike the current option (b), where the running system drifts from the committed lock. Needs CI, and a read-only deploy key generated on ARBITER and never committed.
2. **VLAN:** ARBITER has a UniFi DHCP reservation; whether to move it to a dedicated server VLAN.
3. **Values for the placeholders:** The `cloudflare/dns-api-token` and the `contextforge/*` sops secrets, `pseudonym-key` and `own-domain` included (the build fails until they exist).
4. **ContextForge follow-ups:** which MCP servers to put behind it and how (remote URL vs. a stdio server that needs its own wrapper service); whether to alert (ntfy) on fail2ban bans; which existing rule files belong in a per-server list rather than the global one.

## Later phases (context only; do not implement until asked)

These need decisions of their own first:

- NAS mounts
- Backups to the NAS
- Monitoring and alerting
- Intrusion detection
- Seafile, Immich, Paperless (data on the NAS)
- Plex under strict least privilege
- A calendar server
- A Rust Discord→Gotify forwarder
