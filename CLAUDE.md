# Homelab NixOS configuration

Flake-based NixOS configuration for all of the user's NixOS devices, starting with the homelab. **Current scope: ARBITER only.** It is installed and running phase 1 (essentials) plus ntfy, WireGuard and the Claude Code microVM. Caddy (reverse proxy, wildcard cert), ntfy over HTTPS, ContextForge (PII-scrubbing MCP gateway, internet-facing) and fail2ban are deployed and in use; operator notes in `CADDY.md` and `CONTEXTFORGE.md`. The structure should allow more hosts later, but don't build for them now.

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

- **nixpkgs:** stable channel only, currently `nixos-26.05` (EOL 2026-12-31). Moving to 26.11 is its own change: read the release notes first. Never use unstable on servers unless the user asks.
- **Flake inputs:** only `nixpkgs`, `disko`, `sops-nix` and `microvm`. Ask before adding any input, and explain why a nixpkgs module can't do the job. Make every input follow `nixpkgs` where possible.
- **Verify options against the pinned nixpkgs, not memory.** Options get renamed and removed between releases. Check with `nix eval`, the module source in the pinned nixpkgs, or search.nixos.org set to the matching release.
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
└── modules/
    ├── base.nix         # locale, time, journald, minimal packages
    ├── nix.nix          # nix settings, gc, store optimisation
    ├── users.nix        # immutable users, admin account
    ├── ssh.nix          # hardened sshd
    ├── networking.nix   # networkd + nftables firewall
    ├── nvidia.nix       # headless NVIDIA driver (legacy 580 branch)
    ├── auto-upgrade.nix  # unattended updates
    ├── failure-alert.nix # ntfy alert when a watched unit fails (auto-upgrade, certificate renewal, merge-test)
    ├── merge-test/       # tests each new master commit on ARBITER behind a dead man's switch; VM test
    ├── wireguard.nix     # WireGuard VPN into the home LAN (wg0, NAT)
    ├── claude-vm.nix     # host side of the Claude Code microVM (tap, NAT, firewall)
    ├── claude-vm-guest.nix # the microVM's own NixOS config
    ├── fail2ban.nix      # shared ban policy; each exposed service adds its jail
    └── services/
        ├── caddy.nix     # Caddy reverse proxy, wildcard cert via ACME DNS-01; homelab.domain
        ├── ntfy.nix      # ntfy server on localhost behind Caddy; all ntfy users and ACLs
        ├── contextforge.nix # MCP gateway (rootless podman) with PII plugins; public vhost + decoy catch-all + jail
        └── contextforge/    # our plugins: ScopedFilter and LlmDetector (core, framework wrapper, unit tests each)
```

## Phase 1 scope: ARBITER essentials

1. **Flake skeleton:**
   - Inputs `nixpkgs` (nixos-26.05) and `disko`.
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
6. Reboot, remove the ISO, clear the installer's entry from `known_hosts`, and verify SSH key login, sudo, `systemctl --failed`, firewall (`nft list ruleset`), timers (`systemctl list-timers`), `nvidia-smi`, and the microVM.

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

- **NVIDIA:** `modules/nvidia.nix`, proprietary closed modules from the `legacy_580` branch. The default branch (595+) dropped Maxwell; 580 is supported until August 2028, after which the card needs replacing or stays on an unpatched driver. Headless: `videoDrivers` only switches the module on, no X server. `nvidia-persistenced` keeps the idle GPU in a low power state. Unfree is allowed only for the driver packages by name. The nixpkgs module makes `/dev/nvidia*` world-accessible (mode 666), so any local user or unsandboxed service can use the GPU; restrict services with `DeviceAllow`/`PrivateDevices` as needed. cache.nixos.org doesn't serve unfree builds, so the driver and its kernel module are compiled locally, including on ARBITER after each kernel bump. Verified with `nvidia-smi` after install.
- **Filesystem:** ext4, no encryption (unattended auto-upgrade reboots must come back without intervention). Root disk is the 1 TB Samsung 980 PRO NVMe (ID in `disko.nix`), ARBITER's only disk. Bulk data will live on the NAS.
- **Updates:** option (b). `modules/auto-upgrade.nix` rebuilds the deployed source (`self`, in the store) with `--override-input nixpkgs github:NixOS/nixpkgs/nixos-26.05`. Keep that URL in sync with `flake.nix`. Runs weekly (Sunday 03:15) rather than nightly: less churn, at the cost of up to a week of security-fix latency.
- **sudo:** passwordless wheel (`wheelNeedsPassword = false`), since SSH is key-only.
- **Admin user:** `admin`, set via `homelab.admin.name` in `hosts/arbiter/default.nix`. Authenticated by TEMPLAR's ed25519 key (`templar`), which also reaches the Claude microVM.
- **Secrets:** sops-nix (added as a flake input, since nixpkgs has no module that decrypts repo-committed secrets). Operator age key lives on the workstation at `~/.config/sops/age/keys.txt`.
- **ntfy:** native `services.ntfy-sh`, listening on `127.0.0.1:2586`, `deny-all` by default with declarative users/tokens from sops. Served as `https://ntfy.gameforce.me` through Caddy (`base-url` set to that, `behind-proxy` on). Every identity and its access is in `modules/services/ntfy.nix`: `upgrade-notifier` (write-only on `arbiter-alerts`, token) and `phone` (read-only on `arbiter-alerts`, password, because the iOS app has no token field).
  - iOS push: `upstream-base-url = "https://ntfy.sh"`. iOS suspends the app, so only Apple push wakes it, and only ntfy.sh can send that for the ntfy app. Per message ntfy.sh gets the message id, a SHA-256 of `base-url/topic`, and ARBITER's WAN address; never the title or body (checked against a local listener). The phone then fetches the message from ARBITER, so it must be on the LAN or WireGuard; otherwise it shows a bare "New message". `base-url` must equal the server URL entered in the app, or no push arrives.
  - ntfy's sandbox therefore allows the internet and localhost and denies every private range (ntfy.sh's addresses can't be pinned in `IPAddressAllow`).
  - Alerts: `modules/failure-alert.nix` is a template unit, `failure-alert@<unit>.service`, hooked with `onFailure` to the units in its `watched` list (`nixos-upgrade`, `acme-order-renew-wildcard`). The renewal unit fails only once the certificate is in the last third of its lifetime and still can't renew. `systemctl start failure-alert@test.service` sends a test message.
  - Outside this repo: the `ntfy/*` sops secrets and the app setup on the phone. See `CADDY.md`.
- **Domain and exposure:** `homelab.domain = "gameforce.me"`, DNS at Cloudflare. `tun.gameforce.me` → WAN IP via DDNS (WireGuard endpoint); the apex and `*.gameforce.me` → ARBITER's LAN IP in public DNS, all DNS-only (not proxied). **Exposed: WireGuard and the ContextForge MCP endpoint only**, both on `tun.gameforce.me` (UniFi forwards UDP 51820 → 51820 and TCP 443 → ARBITER 47231; no other public DNS name); every other service is for the LAN and WireGuard peers.
- **Reverse proxy:** native `services.caddy`, TCP 443 only (no port 80, HTTP/3 off), accepted only from private IPv4 sources (`extraInputRules`, so it holds on the host even if UniFi ever forwards 443). Each service module adds its own `services.caddy.virtualHosts` entry on a subdomain of `homelab.domain` with `useACMEHost = "wildcard"`.
  - Certificates: `security.acme.certs.wildcard` (`*.gameforce.me`, lego from nixpkgs) with Cloudflare DNS-01; token `cloudflare/dns-api-token` in sops, passed via `credentialFiles` (LoadCredential). Not Caddy's own ACME: stock Caddy lacks the Cloudflare plugin and a plugin build means extra Go modules compiled locally. Propagation checked against `1.1.1.1:53`.
  - Caddy's admin API is a `0600` unix socket in `/run/caddy`, not TCP `localhost:2019`. Capabilities reduced to `CAP_NET_BIND_SERVICE`.
  - `strict_sni_host on` (Host must equal SNI, else 421) and `default_sni`/`fallback_sni = decoy.invalid`: clients with no or unknown SNI get a self-signed `CN=localhost` decoy (`homelab.caddy.decoyCert`, generated at build time, key in the store on purpose) instead of the wildcard, so a port scan doesn't reveal the domain. Verified against the real binary: without this, an empty SNI is handed the wildcard, and an HTTP/2 request with a foreign `:authority` bypasses every site's host matcher and gets an empty 200. Side effect: `https://<LAN-IP>/` shows the decoy and a 421.
  - Outside this repo: the Cloudflare DNS records and API token. See `CADDY.md`.
- **WireGuard:** terminated on ARBITER (`modules/wireguard.nix`), UDP 51820, tunnel `10.100.0.0/24` with ARBITER `.1`, iPhone `.2`, laptop `.3`, per-peer preshared keys in sops. Peers reach the whole home LAN masqueraded as ARBITER; the forward chain drops anything from `wg0` that isn't RFC 1918, and LAN hosts can't open connections into the VPN.
  - Built as a raw networkd netdev with `PrivateKeyFile=`, not `networking.wireguard`: that backend passes keys to systemd-networkd via `LoadCredential`, so a missing secret would stop networkd and cut SSH. Keep it that way.
  - Outside this repo: UniFi port forward UDP 51820 → ARBITER, and DDNS keeping `tun.gameforce.me` (clients' `Endpoint`) on the WAN IP.
- **Claude Code microVM:** `microvm.vms.claude` via microvm.nix (nixpkgs has no declarative-VM module). Internet only.
  - QEMU, running as the unprivileged `microvm` user. No host directories are shared (no virtiofsd, which runs as root): the store is a read-only image (`storeOnDisk`) and state lives on volumes in `/var/lib/microvms/claude/` (`var.img`, `home.img`, `nix-rw-store.img`). `qemu-bridge-helper` is disabled on the host.
  - Network: tap `vm-claude`, host `10.101.0.1`, guest `10.101.0.2`, NAT out the wired NIC. Forwarding to RFC 1918/CGNAT/link-local is dropped; the VM can reach only the host's DNS stub (resolved `DNSStubListenerExtra`) on ARBITER itself.
  - Guest user `claude` with the admin's SSH key, no sudo, no root login. Reach it with `ssh -J admin@arbiter claude@10.101.0.2`.
  - Nix inside the VM uses a writable store overlay; its `nixpkgs` registry is pinned to ARBITER's nixpkgs.
  - Claude Code is installed by hand with Anthropic's native installer (the user's choice: self-updating, so not pinned). `gh auth login` and Claude's login are interactive; their tokens live on `home.img`, not in the repo. Prefer a fine-grained GitHub token limited to the repos Claude should touch.
  - The VM restarts when its config changes (so on weekly upgrades that touch it).
  - Remote Control: a `claude` user service (lingering, so it runs from boot) runs `claude remote-control --name claude-vm --spawn same-dir` in `~/src` through a login shell, so new sessions can be started from the desktop app, claude.ai or the phone without SSH. Outbound only. It's skipped until `~/.local/bin/claude` exists, and needs one interactive `claude remote-control` run in `~/src` to accept the trust and enable prompts; until then it fails and retries every minute. Transcripts pass through Anthropic while connected, and anyone with the claude.ai account can steer sessions.
  - Testing: the Nix build sandbox here has no `/dev/kvm`, so NixOS VM tests run under TCG and a nested microVM is far too slow to boot. Test host-side rules with a network namespace on a veth named `vm-claude`, and the guest by building `microvm.vms.claude.config.config.microvm.declaredRunner` with user-mode networking and running it directly as the user (who has KVM).
  - Never give the QEMU guest exactly 2048 MB of memory; it hangs at boot (microvm.nix issue 171).
- **ContextForge:** `modules/services/contextforge.nix`, IBM's MCP gateway as the PII-scrubbing hop between MCP servers with personal data and AI clients. `ghcr.io/ibm/mcp-context-forge` v1.1.0 pinned by digest (no nixpkgs package), rootless podman under `contextforge` (uid 380, linger, `--userns=keep-id`), read-only rootfs, no capabilities, SQLite in `/var/lib/contextforge/data`, `127.0.0.1:4444`. Rootless rather than root podman for least privilege; the static uid is what the oci-containers module needs for `/run/user/<uid>`.
  - Scrubbing is in ContextForge's plugin framework on `tool_post_invoke` and `prompt_post_fetch` only: our own `ScopedFilter` plugin (`modules/services/contextforge/`, mounted into the image at `plugins/custom`; rule groups from `hosts/arbiter/pii/*.nix` via `homelab.contextforge.rulesDir`, filename order; a group is global or scoped by sender/subject regexes, and where no email is recognisable every group applies, so scoping only ever adds rules; a rule's `secret` names a sops key whose value is matched literally, case-insensitive, whole-word, and the module declares the secret; `./add-pii.sh` stores the value regex-escaped; longer values go first; every rule gets `(?i)` unless it opens with its own flag group; `checks.x86_64-linux.contextforge-filter` runs the plugin's unit tests and each file's `examples` against the rendered rules, with secrets replaced by `SECRET_<KEY>` stand-ins. Written instead of the stock `regex_filter` because that has no scoping and silently drops a regex that doesn't compile; ours refuses to start) then `cpex_pii_filter` with `hash` masking (consistent per value within one process; `GUNICORN_WORKERS=1`). `fail_on_plugin_error = true`: a plugin failure fails the call. Regex-based, no NER; resources and tool arguments aren't filtered, so virtual servers get tools only. Presidio would mean the external LLMGuard plugin container (downloads models at start), rejected under priority 1.
  - Rule lists: the global list is `hosts/arbiter/pii/*.nix`; `homelab.contextforge.servers.<name> = { id; rulesDir; }` adds a list for one upstream MCP server (groups tagged `server`, run after the global ones). The id is the **upstream** server's (admin UI → Gateways): in v1.1.0 the gateway overwrites a tool call's `GlobalContext.server_id` with the upstream id (`tool_service._apply_tool_payload_to_global_context`; the middleware leaves it unset), so a plugin can't see the virtual server. Checked in the v1.1.0 source and against cpex 0.1.4 (the version its `uv.lock` pins). An id not in `servers` gets every server's groups, so a wrong id over-filters.
  - `LlmDetector` (`modules/services/contextforge/llm_detector*.py`, priority 60, after PIIFilter; `homelab.contextforge.llm`): Ollama on **TEMPLAR** (the user's choice, 2026-11-13: TEMPLAR has the GPU; ARBITER's Maxwell card was the alternative). Only for `llm.tools`, via the plugin's ContextForge `conditions` (matched on the tool name the client called). Each email in a result is one request, sent as `field: value` lines, never the raw JSON; ids untouched; text outside emails is one more request; long units split at line breaks. The model only lists findings; code masks those that occur verbatim (whole word, ≥3 chars, not a mask) as `[PII:12hex]` (HMAC, per-process salt), inside that email only. Fail closed: any Ollama error, per-request timeout or the per-call deadline fails the call; the deadline also stops the worker thread from starting new requests. Stdlib `urllib` in `asyncio.to_thread` (one gunicorn worker). cpex 0.1.4 has one global `plugin_timeout`; it becomes `llm.timeout + 15` when the detector is on. The post-invoke hook runs outside the gateway's tool timeout. Verified against a real cpex 0.1.4 `PluginManager`: tool conditions, server scoping, and an Ollama failure turning into `PluginError`. Outside this repo: Ollama on TEMPLAR listening on the LAN, reachable from ARBITER only (no auth in Ollama), the model pulled (unpinned). Plain HTTP on the LAN.
  - The plugin YAML is a `sops.templates` file (it carries sops placeholders), mounted read-only into the container; secrets reach it through a second template as podman's `--env-file`. Both owned by `contextforge`, mode 0400.
  - Three Caddy sites: `mcp-admin.<domain>` on 443 (LAN/WireGuard, full gateway and admin UI); `tun.<domain>:<publicPort>` (internet: `/servers/*` only, and only when an `Authorization: Bearer` header is present, 2 MB bodies, `Server` header stripped; anything else is `abort`ed, i.e. the connection is closed with no response); and a catch-all `:<publicPort>` that serves the decoy certificate and aborts. The hostname is the WireGuard one (`tun`), already public on the WAN IP, so no DNS record hints at a web service. On the host it is `homelab.contextforge.publicPort` (47231): a separate port rather than relaxing 443 keeps the private-source rule on ARBITER's 443 intact. Externally it is 443: **claude.ai custom connectors cannot reach a non-standard port** (tested 2026-11-09: "Couldn't connect", no packet arrived; same URL on 443 worked), so the router maps WAN 443 → 47231 and the "out of mass scans" benefit is gone; the decoy, the silent drops and fail2ban remain. Caddy checks only that a bearer header exists (stock Caddy can't validate JWTs); the gateway validates it. Clients use expiring JWT bearer tokens from the admin UI; claude.ai connectors send them as a request header.
  - Facts learned in operation: the Fastmail tools return `{results: [email…]}` or one email, `from` as `[{name,email}]`, JSON in `content[0].text` plus `structuredContent`; the JMAP `id` is what the read tool takes and passes through intact, while `messageId` (an RFC 822 Message-ID) gets hashed by the email detector, harmlessly. ScopedFilter runs before the PII filter, so `when.from` sees the raw sender; by the time anything else (the survey tool, the client) sees it, the address is a hash and only the display name remains, so scopes match on the name or domain, never on a full address. `linger-users.service` failed on the first activation that created the `contextforge` user and worked after a restart; cause not captured.
  - `tools/pii-survey.py` is how new rules get found: it reports shape masks and anchors, not values. A report still shows words around a candidate, so a name or address no secret covers yet *will* appear in it. Read reports before pasting them anywhere; the first real run exposed exactly that and the chat had to be discarded. Rule files follow the survey, one scoped group per sender, with the report's masked snippets as `examples`. Text versions of HTML mail glue table cells together (`Customer Name<first> <last>Invoice Number…`), which defeats every whole-word rule, the name secrets included: the global label and money rules tolerate a glued label, a glued name needs a scoped rule on the labels around it (`75-battlenet.nix`), and the second survey report showed one in clear. Links carrying a long opaque token are cut at the token for every sender (`15-links.nix`). A new rule file must be `git add`ed before `nix flake check`, or the flake doesn't see it and the check passes without it.
  - Outside this repo: five `contextforge/*` sops secrets (the gateway validates `DEFAULT_USER_PASSWORD` at start even with registration off, so it is a secret too), the UniFi forward TCP 443 → ARBITER 47231, and the upstream servers/virtual servers/tokens configured in the UI (stored in its SQLite). See `CONTEXTFORGE.md`.
- **merge-test:** `modules/merge-test/`. Merging a pull request on GitHub is the approval to test it on ARBITER; nobody runs `test.sh` for that.
  - Every 2 minutes ARBITER fetches `master` over SSH with a read-only deploy key it generated itself (`/var/lib/merge-test/deploy-key`, root only; GitHub's host key is pinned). A new commit is recorded first, so it is tried once, then built by exact commit hash from a local bare clone.
  - `activate.sh` is the dead man's switch. It arms a transient timer (15 min) that re-activates the boot default, activates the build with `switch-to-configuration test` in a transient unit as nixos-rebuild does, waits 60 s and checks: activation succeeded, no newly failed units, sshd and networkd still active if they were, the default route and `wg0` still there, and `git ls-remote` to GitHub works. Pass: the timer is cancelled. Fail: rollback at once. If the script dies, the timer rolls back. The VM test `checks.x86_64-linux.merge-test` covers all of that, including the transient timer surviving activation.
  - It never switches. The boot default stays the last `deploy.sh`, so a reboot or the weekly upgrade also ends a test, and a `deploy.sh` during the window turns the rollback into a no-op. It skips a tick while `nixos-upgrade` runs.
  - Results go to ntfy `arbiter-alerts`: testing, active, rolled back with the reasons, doesn't build, and fetch failing or working again (each once).
  - `master` has to build as committed: a secret key that exists only in a working copy on TEMPLAR makes every merge fail to build.
  - Runs as root, unconfined: it activates whole systems, so a sandbox around it would be decorative. Whoever can change `master` gets root on ARBITER.
  - Outside this repo: the deploy key, added to the GitHub repo as read-only. The first run publishes its public key to ntfy.
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
3. **Values for the placeholders:** `<LAPTOP_WG_PUBKEY>`, and the `cloudflare/dns-api-token` and five `contextforge/*` sops secrets (the build fails until they exist).
4. **ContextForge follow-ups:** which MCP servers to put behind it and how (remote URL vs. a stdio server that needs its own wrapper service); whether to alert (ntfy) on fail2ban bans; which existing rule files belong in a per-server list rather than the global one; whether to whitelist `messageId` in the PII filter if a tool ever needs it.

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
