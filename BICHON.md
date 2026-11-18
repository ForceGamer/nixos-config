# Bichon: e-mail archive and its backups

`modules/services/bichon.nix` runs Bichon on ARBITER. It archives the
mailboxes over IMAP, indexes them for search and backs the archive up to the
NAS. Nothing has been deployed. The steps below are the parts only you can do.

## What it does

```
mail host ──IMAP──▶ Bichon on ARBITER ──incremental backup──▶ NAS /volume1/Email ──restic, encrypted──▶ Backblaze B2
                    /var/lib/bichon        (NFS, its own          (NFS share)           (not built yet)
                    (live data, NVMe)       scheduler)
```

- **Server:** `bichon-server` 2.4.3, built from source with nixpkgs' recipe.
  nixpkgs itself has 2.2.0, which lacks later backup fixes. The override
  applies only while nixpkgs is older than 2.4.3, so the weekly auto-upgrade
  switches to nixpkgs' build by itself once nixpkgs catches up. Before then, a
  newer upstream release needs a PR that bumps `pinned` and the hashes.
- **Sandbox:** runs as its own `bichon` user with systemd hardening, on
  `127.0.0.1:15630`. Outbound it reaches the internet (IMAP; also a GitHub
  release check when the UI loads notifications) but no private address.
  Caddy serves it as `https://bichon.gameforce.me` on 443, so only from the
  LAN and WireGuard. Agents running as `agent` can't reach its port.
- **Data:** `/var/lib/bichon` on ARBITER's NVMe. Upstream warns against
  putting the live data on NFS, so only the backups go to the NAS. The stored
  IMAP passwords are encrypted with the sops secret `bichon/encrypt-password`.
  The mail itself is not encrypted, neither on ARBITER nor on the NAS.
- **Backups:** Bichon's own scheduler writes content-addressed restore points
  to `/mnt/bichon/nas`, an NFS automount of `192.168.1.152:/volume1/Email`.
  Only `bichon` (and root) can open `/mnt/bichon`. The NFS traffic is
  unencrypted on the LAN.
- **Alert:** `bichon-backup-check` runs daily at 09:00. It fails when no
  restore point on the NAS is newer than 48 h, or when the NAS doesn't answer
  within 5 minutes. A failure is published to the ntfy topic `arbiter-alerts`.
  It also fires every day until the first backup has run.

## 1. The secret

Add a long random value as `bichon/encrypt-password` to
`hosts/arbiter/secrets.yaml`:

```sh
openssl rand -base64 32        # copy the output
sops hosts/arbiter/secrets.yaml
# bichon:
#     encrypt-password: <paste>
```

Commit it on this branch before merging. The build checks that the key
exists, so a merge without it fails merge-test's build.

If this value changes, the stored IMAP passwords can't be decrypted any more:
re-enter them in the UI. Restoring a backup on a new install also needs the
same value.

## 2. The NFS share on the NAS

In UGOS, enable the NFS service and add an NFS rule to the `Email` shared
folder:

- **Host:** ARBITER's LAN address only, not a subnet.
- **Access:** read/write.
- **Squash:** "Map all users to admin". Every request from ARBITER, root
  included, then reaches the NAS as its admin account. That account is
  limited to this share, which NFS exports to ARBITER only. Bichon's uid
  doesn't exist on the NAS, so "No mapping" and "Map root to …" leave it
  unable to write; "No mapping" would also make root on ARBITER root on the
  share. "Map all users to guest" needs guest enabled with write access,
  which SMB would then share.
- **Version:** NFSv4 (the mount asks for v4 and takes the highest minor
  version the NAS offers).

Nothing else on ARBITER mounts the share, and the rule allows no other host.
After deploying, check from ARBITER:

```sh
sudo -u bichon ls /mnt/bichon/nas            # triggers the mount
sudo -u bichon touch /mnt/bichon/nas/.probe && sudo -u bichon rm /mnt/bichon/nas/.probe
```

## 3. Deploy and first login

1. Merge (merge-test tries it) or deploy, then open `https://bichon.gameforce.me`.
2. Log in as `admin` / `admin@bichon` and **change the password at once**
   (Settings → Profile). Until you do, anyone on the LAN or VPN can log in
   with the public default.
3. Add the IMAP account(s). Use an app password limited to IMAP if your mail
   host offers one.

## 4. Configure the backup (web UI)

These settings live in Bichon's database, not in this repo.

- **Target:** Local directory, `/mnt/bichon/nas`.
- **Prefix:** the default `bichon-backup` is fine. The check finds any prefix.
- **Schedule:** daily. The default `0 0 3 * * *` (03:00) fits the 09:00
  check.
- **Retention:** your choice. restic adds its own history on B2 later.

Run a backup by hand once, then on ARBITER:
`sudo systemctl start bichon-backup-check && journalctl -u bichon-backup-check -n 3`.

## Restore

`bichon-admin` is on the system PATH, from the same build as the server. It
restores into an empty directory and refuses to touch the live data. Run it
as `bichon`, so the restored files are already owned correctly:

```sh
d=$(sudo -u bichon mktemp -d) && sudo -u bichon mkdir "$d/restored"
echo '{"target_type": "local", "local_dir": "/mnt/bichon/nas"}' | sudo -u bichon tee "$d/restore.json" >/dev/null
sudo -u bichon bichon-admin restore --config "$d/restore.json" --into "$d/restored" --point LATEST
```

Then stop `bichon`, swap the restored tree in for `/var/lib/bichon` and start
it again. The IMAP passwords decrypt only with the same
`bichon/encrypt-password`.

## Later

- restic from the NAS share to Backblaze B2, on ARBITER
  (`services.restic.backups`), with its own failure alert.
