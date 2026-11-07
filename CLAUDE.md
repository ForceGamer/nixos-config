# Homelab NixOS configuration

Flake-based NixOS configuration for the homelab. **Current scope: ARBITER only, phase 1 (essentials).** The structure should allow more hosts later, but don't build for them now.

## Priorities (in order; use them to break ties)

1. **Minimal supply-chain risk.** Few flake inputs, official nixpkgs modules first, nothing pulled at runtime that isn't pinned.
2. **Timely automatic security updates.**
3. **Fully declarative.** No imperative state that isn't captured here, except secrets and data.
4. **Principle of least privilege.**
5. **Low maintenance.**

Apply Ockham's razor throughout. Prefer the boring, documented NixOS way over clever abstractions. Do not add frameworks (flake-parts, flake-utils, snowfall, etc.) to save a few lines.

## Environment

- **Operator workstation:** Kubuntu with Nix (flakes enabled), editing in Zed with nixd and nil.
- `nixos-rebuild` is not installed on the workstation. Use `nix run nixpkgs#nixos-rebuild -- …`.
- **Network:** a UniFi Dream Router 7 handles DHCP, DNS and VLANs. Host addressing is done with DHCP reservations in UniFi, not static IPs in Nix (one source of truth).
- **Other devices** (not managed by this repo):
  - UGREEN NASync DH4300 Plus: future storage and backup target.
  - Home Assistant Green: standalone.

## Hosts

### ARBITER (`nixosConfigurations.arbiter`, `networking.hostName = "arbiter"`)

- **Hardware:** AMD Ryzen, 64 GB RAM, NVIDIA GTX 980 Ti (Maxwell). Wired Ethernet.
- **Currently runs Proxmox,** which will be wiped and replaced by NixOS. The old Home Assistant VM on it is not needed. Confirm with the user that nothing else on it needs backing up before any destructive step.
- **Future role:** main service host. Phase 1 does not include any services.
- **GPU:** leave it unconfigured in phase 1 (headless). Before adding the NVIDIA driver later, verify which driver branch still supports Maxwell; newer branches have dropped it.

## Rules

- **nixpkgs:** stable channel only, currently `nixos-26.05` (EOL 2026-12-31). Moving to 26.11 is its own change: read the release notes first. Never use unstable on servers unless the user asks.
- **Flake inputs:** only `nixpkgs`, `disko` and `sops-nix`. Ask before adding any input, and explain why a nixpkgs module can't do the job. Make every input follow `nixpkgs` where possible.
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
- **No actions against the real machine without explicit approval each time.** This covers deploy, partitioning, disko, `nixos-install`, and SSH to ARBITER. Local evaluation and builds are always fine.
- **Never change `system.stateVersion`** once it's set at install.
- **Before calling a change done:** format with `nix fmt`, make sure `nix flake check` passes, and build the toplevel locally (`nix flake check` doesn't build far enough to catch everything, e.g. missing sops files).
- **Comments explain why, not what.** Keep modules small and single-purpose.

## Layout

```
.
├── flake.nix
├── flake.lock
├── CLAUDE.md
├── .sops.yaml                         # who can decrypt secrets (age recipients)
├── hosts/
│   └── arbiter/
│       ├── default.nix                # host-specific config, imports modules
│       ├── hardware-configuration.nix # generated; filesystems come from disko
│       ├── disko.nix                  # declarative disk layout
│       └── secrets.yaml               # sops-encrypted secrets
└── modules/
    ├── base.nix         # locale, time, journald, minimal packages
    ├── nix.nix          # nix settings, gc, store optimisation
    ├── users.nix        # immutable users, admin account
    ├── ssh.nix          # hardened sshd
    ├── networking.nix   # networkd + nftables firewall
    ├── auto-upgrade.nix  # unattended updates
    ├── upgrade-alert.nix # ntfy alert when auto-upgrade fails
    ├── wireguard.nix     # WireGuard VPN into the home LAN (wg0, NAT)
    └── services/
        └── ntfy.nix      # ntfy server, localhost-only; all ntfy users and ACLs
```

## Phase 1 scope: ARBITER essentials

1. **Flake skeleton:**
   - Inputs `nixpkgs` (nixos-26.05) and `disko`.
   - One output, `nixosConfigurations.arbiter`.
   - A `formatter` output pointing to `nixfmt`.
2. **Disks:** `disko.nix` with an EFI system partition plus root. Disk IDs come from `/dev/disk/by-id` (see open decisions).
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
7. **sudo:** `security.sudo.execWheelOnly = true`. Whether wheel needs a password is an open decision.
8. **Nix:**
   - Flakes enabled.
   - `allowed-users = [ "@wheel" ]`.
   - `trusted-users = [ "root" "<ADMIN_USER>" ]`, which is needed for pushing closures from the workstation.
   - Weekly GC deleting generations older than 14 days.
   - Automatic store optimisation.
   - Disable channels (`nix.channel.enable = false`); the system is flake-only.
9. **Auto-upgrade:**
   - `system.autoUpgrade` runs weekly (Sunday 03:15), with `allowReboot = true` and a reboot window of roughly 03:00–05:00 so kernel fixes actually apply.
   - Where it gets new nixpkgs revisions from is an open decision.
10. **Base:**
    - `time.timeZone = "Europe/Oslo"`, `i18n.defaultLocale = "en_US.UTF-8"`, console keymap `no`.
    - Default timesyncd.
    - journald `SystemMaxUse=1G`.
    - Only a handful of system packages (e.g. `git`, `htop`, `smartmontools`).

**Out of scope for phase 1:** all services, VPN, NAS mounts, backups, monitoring, intrusion detection, GPU drivers, secrets management, and VLAN-specific config.

## First install procedure (needs user approval at each destructive step)

1. Confirm nothing on the Proxmox install still needs to be kept.
2. Boot the official NixOS 26.05 minimal ISO and verify its checksum. Set a temporary password for the `nixos` user, then SSH in from the workstation.
3. Collect hardware facts:
   - `ls -l /dev/disk/by-id`
   - `ip link` (MAC address for the UniFi DHCP reservation)
   - `nixos-generate-config --no-filesystems --show-hardware-config`, saved to `hosts/arbiter/hardware-configuration.nix`
4. Fill in `disko.nix`. Run disko from the pinned flake input (check the current `--mode` names for that disko version), which partitions and mounts `/mnt`.
5. Give ARBITER its SSH host key before install, so it can decrypt secrets on first boot:
   - On the installer: `mkdir -p /mnt/etc/ssh && ssh-keygen -t ed25519 -N "" -f /mnt/etc/ssh/ssh_host_ed25519_key`.
   - On the workstation: convert its public key with `nix run --inputs-from . nixpkgs#ssh-to-age`, add it as `&arbiter` to `.sops.yaml`, run `sops updatekeys hosts/arbiter/secrets.yaml`, and commit.
   - If this is skipped, ntfy can't start (its env file is missing); everything else still works.
   - Then run `nixos-install --flake .#arbiter --no-root-passwd`.
6. Reboot, remove the ISO, and verify SSH key login, sudo, firewall (`nft list ruleset`), and timers (`systemctl list-timers`).

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

- **Filesystem:** ext4, no encryption (unattended auto-upgrade reboots must come back without intervention). Which disk(s) to wipe is still open (see 1).
- **Updates:** option (b). `modules/auto-upgrade.nix` rebuilds the deployed source (`self`, in the store) with `--override-input nixpkgs github:NixOS/nixpkgs/nixos-26.05`. Keep that URL in sync with `flake.nix`. Runs weekly (Sunday 03:15) rather than nightly: less churn, at the cost of up to a week of security-fix latency.
- **sudo:** passwordless wheel (`wheelNeedsPassword = false`), since SSH is key-only.
- **Admin user:** `admin`, set via `homelab.admin.name` in `hosts/arbiter/default.nix`. `<ADMIN_SSH_PUBKEY>` is still a placeholder.
- **Secrets:** sops-nix (added as a flake input, since nixpkgs has no module that decrypts repo-committed secrets). Operator age key lives on the workstation at `~/.config/sops/age/keys.txt`.
- **ntfy:** native `services.ntfy-sh`, localhost-only on `127.0.0.1:2586`, `deny-all` by default with declarative users/tokens from sops. One identity so far: `upgrade-notifier`, write-only on `arbiter-alerts`. Exposing it (reverse proxy, real `base-url`, iOS upstream) is still open.
- **WireGuard:** terminated on ARBITER (`modules/wireguard.nix`), UDP 51820, tunnel `10.100.0.0/24` with ARBITER `.1`, iPhone `.2`, laptop `.3`, per-peer preshared keys in sops. Peers reach the whole home LAN masqueraded as ARBITER; the forward chain drops anything from `wg0` that isn't RFC 1918, and LAN hosts can't open connections into the VPN.
  - Built as a raw networkd netdev with `PrivateKeyFile=`, not `networking.wireguard`: that backend passes keys to systemd-networkd via `LoadCredential`, so a missing secret would stop networkd and cut SSH. Keep it that way.
  - Outside this repo: UniFi port forward UDP 51820 → ARBITER, and a public address or DDNS name for clients' `Endpoint`.
- **Formatter:** `nixfmt-tree` (nixfmt's own `nix fmt` wrapper) with `tree-root-file = "flake.nix"` so it never walks outside the repo.

## Open decisions (ask the user; don't choose silently)

1. **Disks and filesystem.**
   - Which disks are in ARBITER, and should all of them be wiped?
   - Filesystem: ext4 (lowest maintenance) or btrfs (snapshots)?
   - Encryption: none, LUKS with TPM2 auto-unlock (`systemd-cryptenroll`), or LUKS with SSH unlock in the initrd?
2. **Where the repo lives** (private GitHub, self-hosted Forgejo, …). A private remote means ARBITER needs a read-only deploy key, generated on the host and never committed.
3. **How updates reach ARBITER:**
   - **(a)** A scheduled CI job bumps `flake.lock` and checks the build; ARBITER's autoUpgrade pulls the repo. Fully declarative, but needs repo hosting and CI.
   - **(b)** ARBITER bumps its own `nixpkgs` input on each autoUpgrade. Simplest and timely, but the running system drifts from the committed lock.
   - Default suggestion: (b) until (a) is set up.
4. **sudo password.** Either a yescrypt hash in the repo (`mkpasswd -m yescrypt`, private repo only; moves to the secrets tool later), or passwordless wheel since SSH is key-only.
5. **VLAN and DHCP reservation** for ARBITER in UniFi.
6. **Values for the placeholders:** `<ADMIN_SSH_PUBKEY>`, `<DISK_ID>`, `<IPHONE_WG_PUBKEY>`, `<LAPTOP_WG_PUBKEY>`.
7. **Exposing ntfy:** reverse proxy (not nginx), hostname and TLS, and whether to set `upstream-base-url = "https://ntfy.sh"` for instant iOS push (ntfy.sh then sees message IDs, not content). Then a read-only phone user on `arbiter-alerts`.

## Later phases (context only; do not implement until asked)

These need decisions of their own first:

- Reverse proxy (not nginx)
- NAS mounts
- Backups to the NAS
- Monitoring and alerting
- Intrusion detection
- Notifications to iOS (ntfy runs; exposing it to the phone is open decision 7)
- Seafile, Immich, Paperless (data on the NAS)
- Plex under strict least privilege
- A calendar server
- A Rust Discord→Gotify forwarder
