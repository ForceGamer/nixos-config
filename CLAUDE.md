# Homelab NixOS configuration

Flake-based NixOS configuration for all of the user's NixOS devices, starting with the homelab. **Current scope: ARBITER only.** It is installed and running phase 1 (essentials) plus ntfy, WireGuard and the Claude Code microVM. The structure should allow more hosts later, but don't build for them now.

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
    ├── nvidia.nix       # headless NVIDIA driver (legacy 580 branch)
    ├── auto-upgrade.nix  # unattended updates
    ├── upgrade-alert.nix # ntfy alert when auto-upgrade fails
    ├── wireguard.nix     # WireGuard VPN into the home LAN (wg0, NAT)
    ├── claude-vm.nix     # host side of the Claude Code microVM (tap, NAT, firewall)
    ├── claude-vm-guest.nix # the microVM's own NixOS config
    └── services/
        └── ntfy.nix      # ntfy server, localhost-only; all ntfy users and ACLs
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
- **ntfy:** native `services.ntfy-sh`, localhost-only on `127.0.0.1:2586`, `deny-all` by default with declarative users/tokens from sops. One identity so far: `upgrade-notifier`, write-only on `arbiter-alerts`. Exposing it (reverse proxy, real `base-url`, iOS upstream) is still open.
- **WireGuard:** terminated on ARBITER (`modules/wireguard.nix`), UDP 51820, tunnel `10.100.0.0/24` with ARBITER `.1`, iPhone `.2`, laptop `.3`, per-peer preshared keys in sops. Peers reach the whole home LAN masqueraded as ARBITER; the forward chain drops anything from `wg0` that isn't RFC 1918, and LAN hosts can't open connections into the VPN.
  - Built as a raw networkd netdev with `PrivateKeyFile=`, not `networking.wireguard`: that backend passes keys to systemd-networkd via `LoadCredential`, so a missing secret would stop networkd and cut SSH. Keep it that way.
  - Outside this repo: UniFi port forward UDP 51820 → ARBITER, and a public address or DDNS name for clients' `Endpoint`.
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
- **Repo:** private GitHub repo `nixos-config` (`origin`). The workstation checkout is the only place the config is edited; push after committing. Commits use the GitHub noreply email (set in this repo's `.git/config`).
- **Formatter:** `nixfmt-tree` (nixfmt's own `nix fmt` wrapper) with `tree-root-file = "flake.nix"` so it never walks outside the repo.

## Open decisions (ask the user; don't choose silently)

1. **Moving updates to option (a):** a scheduled CI job bumps `flake.lock` and checks the build, and ARBITER's autoUpgrade pulls the repo. Fully declarative, unlike the current option (b), where the running system drifts from the committed lock. Needs CI, and a read-only deploy key generated on ARBITER and never committed.
2. **VLAN:** ARBITER has a UniFi DHCP reservation; whether to move it to a dedicated server VLAN.
3. **Value for the placeholder:** `<LAPTOP_WG_PUBKEY>`.
4. **Exposing ntfy:** reverse proxy (not nginx), hostname and TLS, and whether to set `upstream-base-url = "https://ntfy.sh"` for instant iOS push (ntfy.sh then sees message IDs, not content). Then a read-only phone user on `arbiter-alerts`.

## Later phases (context only; do not implement until asked)

These need decisions of their own first:

- Reverse proxy (not nginx)
- NAS mounts
- Backups to the NAS
- Monitoring and alerting
- Intrusion detection
- Notifications to iOS (ntfy runs; exposing it to the phone is open decision 4)
- Seafile, Immich, Paperless (data on the NAS)
- Plex under strict least privilege
- A calendar server
- A Rust Discord→Gotify forwarder
