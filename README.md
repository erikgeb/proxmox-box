# Requirements

- ansible

Run `ansible-galaxy collection install -r requirements.yaml`

# How to run

After a fresh proxmox install, when you only have the root account and its password:

```
# Create a dedicated ssh key, with no passphrase for automations
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ansible -C "ansible-automation-key"

# You will need to add the host key fingerprint to known_hosts
ansible-playbook ansible/bootstrap/01_bootstrap_and_harden.yaml -i '192.168.0.xxx,' -e "target_host=192.168.0.xxx" --ask-pass

# No longer show message about subscriptions - your browser cache may prevent seeing the change at first
ansible-playbook ansible/bootstrap/02_remove_nag_msg.yaml

# Warning: this will wipe the targeted disk
ansible-playbook ansible/bootstrap/03_setup_encrypted_disks.yaml -e "target_disk=/dev/sdX"

# Provision the docker host LXC (runs pct as root over SSH; the encrypted storage
# must be mounted first so the bind mount points at the encrypted volume).
# The playbook downloads the Debian OS template on demand (pveam), but it is pinned
# to a specific point release (ostemplate_name in the playbook). Proxmox's catalog
# only keeps the current build, so before running, confirm the pinned version still
# exists in the catalog (otherwise the download fails with "no such template"):
#   ssh ansible-worker@<host> 'sudo pveam update && pveam available --section system | grep debian-13'
# If the listed filename differs, update ostemplate_name in 04_provision_docker_lxc.yaml
# (and 06_provision_vaultwarden_lxc.yaml) to match.
# Override the defaults with -e if needed, e.g.
#   -e "container_id=100 rootfs_storage=local-lvm docker_host_ip_suffix=53"
ansible-playbook ansible/bootstrap/04_provision_docker_lxc.yaml

# After every reboot: unlock the encrypted storage and start the dependent containers.
# Prompts for the LUKS passphrase. Use the same disk you passed to 03_setup_encrypted_disks.yaml.
ansible-playbook ansible/unlock_storage.yaml -e "target_disk=/dev/sdX"

# Before deploying: set up in-home HTTPS (Caddy reverse proxy + Let's Encrypt).
# Caddy fronts the media apps and obtains a *.<base-domain> wildcard cert via the
# ACME DNS-01 challenge (the box has no inbound HTTP — LAN-only) using the OVH DNS
# provider, and auto-renews it. Copy the example env and fill in the OVH API
# credentials + your base domain:
#   cp ansible/resources/caddy.env.example ansible/resources/caddy.env   # then edit (gitignored)
# Create the OVH credential at https://api.ovh.com/createToken/ with rights
# GET/POST/PUT/DELETE on /domain/zone/* (so Caddy can write the _acme-challenge TXT records).
#
# Prerequisite (manual — depends on your LAN DNS, not automated here): make
# *.<base-domain> (or at least immich.<base-domain> / syncthing.<base-domain>)
# resolve to the docker LXC's IP (192.168.0.53 by default) on your LAN — e.g. on
# the router, a Pi-hole, or a hosts file. DNS-01 itself only needs OVH API access.

# Deploy the application stack into the docker LXC. Installs Docker CE in the
# container (if needed), generates resources/.env -> the container's .env with a
# strong DB_PASSWORD on first run (never rotated after), pushes the Caddy
# resources (fails if caddy.env is missing), then `docker compose up -d` (builds
# the custom Caddy image with the OVH DNS module on first run).
# Requires the encrypted storage to be mounted first (run unlock_storage.yaml),
# else the bind mount captures an empty dir and Postgres inits on the root disk.
ansible-playbook ansible/bootstrap/05_deploy_docker_stack.yaml

# Verify HTTPS from a LAN client (once DNS resolves the names to the LXC):
#   https://immich.<base-domain>  and  https://syncthing.<base-domain>  with a valid Let's Encrypt cert.
# Check issuance/renewal: pct exec 100 -- docker compose -f /opt/docker-stack/docker-compose.yml logs caddy
#
# Configure Syncthing folders (in the web UI at https://syncthing.<base-domain>):
# user-synced data lives on the encrypted volume at /mnt/storage/syncthing_share,
# bind-mounted into the container as /data. Set every sync Folder Path UNDER /data
# (NOT /config, which is Syncthing's own state). Canonical paths:
#   /data/personal       -> /mnt/pve/secure-storage/syncthing_share/personal      (your files)
#   /data/vault_backups  -> /mnt/pve/secure-storage/syncthing_share/vault_backups (VaultWarden .age archives)
# Create the folder in the UI first so Syncthing owns it (it writes a .stfolder
# marker); the vault-backup playbook below then drops files into it as host root.
#
# Optional once the wildcard cert is issued: reuse it for the Proxmox web UI itself
# (replaces its self-signed cert) — ansible/update_proxmox_cert.yaml. NOTE the
# wildcard does NOT cover the apex/bare IP, so browse Proxmox at a SUBDOMAIN
# (https://pve.<base-domain>:8006). See "Maintenance & upgrades (recurrent)" below.

# Provision the VaultWarden LXC (id 101) — its own trust zone, isolated from the
# media stack. Unprivileged, NO nesting, NO Docker; rootfs on local-lvm; only the
# vaultwarden_data subdir of the encrypted volume is bind-mounted in. Requires the
# encrypted storage mounted first (run unlock_storage.yaml).
ansible-playbook ansible/bootstrap/06_provision_vaultwarden_lxc.yaml

# Deploy VaultWarden as a NATIVE binary into LXC 101. Extracts the binary +
# web-vault from the pinned official vaultwarden/server image using the Docker
# engine in LXC 100 (so 100 must be up — run 05 first), installs the runtime
# libs, writes /etc/vaultwarden/vaultwarden.env (DOMAIN derived from caddy.env's
# BASE_DOMAIN; signups disabled), generates a strong /admin token ON FIRST RUN
# (prints it ONCE — save it), and starts the hardened systemd service.
ansible-playbook ansible/bootstrap/07_deploy_vaultwarden.yaml

# The @vault block in caddy/Caddyfile (vault.<base-domain> -> 192.168.0.54:8000)
# is already enabled, so a fresh `05` run serves it. If you deployed Caddy before
# enabling it, re-run 05 to push the updated Caddyfile, then reload Caddy:
#   ansible-playbook ansible/bootstrap/05_deploy_docker_stack.yaml
#   pct exec 100 -- docker compose -f /opt/docker-stack/docker-compose.yml exec caddy caddy reload --config /etc/caddy/Caddyfile
#
# Prerequisite (manual, like the other hostnames): make vault.<base-domain>
# resolve to the docker/Caddy LXC's IP (192.168.0.53 by default) on your LAN.
#
# Then browse to https://vault.<base-domain>. Signups are disabled, so create the
# owner account from the /admin panel (https://vault.<base-domain>/admin) using
# the printed ADMIN_TOKEN -> User invitations.

# Upgrading VaultWarden (recurrent task — ansible/update_vaultwarden.yaml):
#   ansible-playbook ansible/update_vaultwarden.yaml                          # to the latest stable release
#   ansible-playbook ansible/update_vaultwarden.yaml -e target_version=1.33.0 # or pin a version
# It is a no-op if already on the target. Otherwise it snapshots the vault data
# AND the current binary/web-vault to the encrypted volume, re-extracts the
# target from the official image, runs the `ldd` guard, restarts, and health-
# checks https/alive — automatically rolling back the binary + web-vault + data
# if the new version fails to come up. Roll back deliberately with
# `-e target_version=<previous>`. There is no apt/auto-update for a native binary,
# so this is the upgrade path; schedule it (e.g. cron on the controller) if you
# want it to run regularly. (Snapshots are on-volume — they guard against a bad
# upgrade, not disk loss; off-box backup of the photo library/DB is tracked as
# P1 in BACKLOG.md.)

# Remote access (VPN) — reach the LAN services from outside the home
#
# Self-hosted WireGuard in its own LXC (id 102), acting as a subnet router for
# 192.168.0.0/24 — so a phone/laptop with WireGuard reaches Immich/Syncthing
# (192.168.0.53), VaultWarden (192.168.0.54) and the Proxmox UI as if on the LAN.
# This is the ONE deliberate inbound exposure on the box (see the threat model in
# CLAUDE.md): a single, port-scan-silent WireGuard UDP port.
#
# Because the ISP uses CGNAT (no public IPv4), the tunnel runs over IPv6: the LXC
# gets a global v6 address (GUA) via SLAAC, and the tunnel is reached at that
# address. Inside the tunnel everything is IPv4 to the LAN. Caveat: a client can
# only connect when ITS network has IPv6 (cellular: almost always; IPv4-only
# Wi-Fi: no).
#
# Unlike 100/101, this LXC is onboot=1 and keeps its keys on the UNENCRYPTED
# rootfs, so it autostarts after any reboot WITHOUT the manual LUKS unlock. That
# is intentional: if family power-cycles the box while you are away, the VPN comes
# back on its own and you can VPN in to run unlock_storage.yaml REMOTELY (and any
# other admin). Trade-off: a stolen box leaks the WG keys + peer list (low value
# vs. the still-encrypted photos/vault; the keys are cheap to regenerate).

# Provision the WireGuard LXC (id 102). Loads the wireguard kernel module on the
# host, then creates an unprivileged, no-nesting, onboot=1 container with a static
# v4 IP (.55) and ip6=auto. No encrypted-storage dependency.
ansible-playbook ansible/bootstrap/09_provision_wireguard_lxc.yaml

# Deploy WireGuard into LXC 102. Installs wireguard-tools/iptables/qrencode,
# generates the server keypair + wg0.conf (with MASQUERADE so LAN hosts can reply
# to VPN clients), enables wg-quick@wg0, and health-checks the interface + that
# the container has a global IPv6 address.
ansible-playbook ansible/bootstrap/10_deploy_wireguard.yaml

# Manual prerequisites (outside Ansible, like the LAN-DNS step):
#   1. On the ROUTER: open an inbound IPv6 firewall pinhole for udp/51820 to the
#      LXC's GUA. There is NO port-forward/DNAT — IPv6 is not NATed.
#   2. Confirm the ISP delegates a routable IPv6 prefix (the deploy play warns if
#      the LXC has no GUA). If it does not, the v6 path cannot work and the
#      documented fallback is a relay (Tailscale / a cheap VPS).

# Point vpn.<base-domain>'s AAAA at the LXC's GUA (reuses the OVH creds from
# caddy.env). The prefix is treated as static, so run this ONCE; if a future ISP
# change makes the prefix rotate, put it on a cron to keep the record fresh.
ansible-playbook ansible/update_wireguard_ddns.yaml

# Enrol a device (prints the client config + a scannable QR code; hot-reloads the
# running interface so existing peers are not dropped). peer_name + wg_endpoint
# are required; an IP is auto-allocated.
ansible-playbook ansible/add_wireguard_peer.yaml -e peer_name=phone -e wg_endpoint=vpn.<base-domain>

# Revoke a device (e.g. lost phone): strips its peer block and drops it live.
ansible-playbook ansible/remove_wireguard_peer.yaml -e peer_name=phone

# Backups
#
# LUKS only protects against disk theft — NOT deletion, corruption, or a bad
# migration on the live, unlocked box. Backup strategy:
#
#   * Syncthing files: covered OFF the box by the owner's existing pipeline —
#     Syncthing replicates them to a personal machine and an rsync script copies
#     them to two USB drives (one refreshed weekly on-site, one taken off-site every
#     few months for fire/theft protection). Nothing on the box to run.
#
#   * Immich photos: Immich's MANAGED library is its source of truth (so mobile
#     auto-backup and deduplication work — these need the managed library, not an
#     external one), which means the originals live only on the box. Pull them into
#     the USB routine with a ONE-WAY, read-only rsync from the box — NEVER a two-way
#     sync (Immich's docs warn against external tools modifying the managed library;
#     bidirectional sync corrupts the DB<->file mapping). Run from the personal
#     machine after the storage is unlocked:
#       rsync -aH --info=progress2 --rsync-path="sudo rsync" \
#         --exclude=thumbs/ --exclude=encoded-video/ \
#         ansible-worker@<box>:/mnt/pve/secure-storage/immich_data/ /your/local/immich-backup/
#     then the existing script copies it to the two USB drives. The pull only reads
#     the source, so it cannot touch the library; originals are write-once, so it is
#     safe with the server running (no stop, no DB dump, no moving files on the box).
#     thumbs/ and encoded-video/ are excluded (Immich regenerates them on restore);
#     backups/ is KEPT — that is where Immich's optional built-in DB backup writes,
#     so enabling that feature later carries the catalog off-box via this same rsync.
#
#   * VaultWarden vault (the highest-value asset; lives only on the box): backed up
#     by ansible/backup_vaultwarden.yaml. It takes a consistent snapshot (briefly
#     stops the service), encrypts it with `age`, and drops a vault-<ts>.age archive
#     into a Syncthing-shared folder so it rides the same personal-machine -> USB
#     pipeline. Pass the host path of that shared folder via -e (the canonical one
#     set up during deploy is syncthing_share/vault_backups):
#       ansible-playbook ansible/backup_vaultwarden.yaml -e syncthing_drop_dir=/mnt/pve/secure-storage/syncthing_share/vault_backups
#       ansible-playbook ansible/backup_vaultwarden.yaml -e syncthing_drop_dir=... -e keep_backups=14
#     Requires the encrypted storage mounted (run unlock_storage.yaml first).
#
#     ENCRYPTION KEY (read once): on its FIRST run the playbook generates an age
#     keypair, keeps only the PUBLIC key on the box (so future runs encrypt with no
#     prompt) and PRINTS THE PRIVATE KEY ONCE. Store that private key OFFLINE
#     immediately — write it down / keep it with the off-site USB / put it in a
#     second password manager. It is the ONLY thing that can decrypt the backups
#     and is NOT recoverable. (Do not store it on the box or with the archives —
#     that would defeat the off-box protection.) An attacker who steals the box AND
#     a USB drive still cannot read the vault.
#
#     Schedule it for regular runs on the controller (run it MANUALLY once first,
#     so you can capture and store the age private key it prints — scheduled runs
#     are then fully non-interactive). Example: every Monday at 12:00 (noon), i.e.
#     cron's `0 12 * * 1` (day-of-week 1 = Monday). cron runs with a minimal PATH,
#     so use the ABSOLUTE ansible-playbook path — find it with `which ansible-playbook`.
#
#       LINUX — add with `crontab -e`:
#         0 12 * * 1 cd /path/to/proxmox-box && /usr/bin/ansible-playbook ansible/backup_vaultwarden.yaml -e syncthing_drop_dir=/mnt/pve/secure-storage/syncthing_share/vault_backups >> "$HOME/proxmox-backup.log" 2>&1
#
#       macOS — add with `crontab -e` (cron still works; homebrew installs
#       ansible-playbook under /opt/homebrew/bin on Apple Silicon, /usr/local/bin on Intel):
#         0 12 * * 1 cd /path/to/proxmox-box && /opt/homebrew/bin/ansible-playbook ansible/backup_vaultwarden.yaml -e syncthing_drop_dir=/mnt/pve/secure-storage/syncthing_share/vault_backups >> "$HOME/proxmox-backup.log" 2>&1
#       macOS caveats: the Mac must be AWAKE at 12:00 Monday (cron does not wake it);
#       if runs fail silently, grant `cron` Full Disk Access in System Settings >
#       Privacy & Security. To survive sleep, prefer a launchd LaunchAgent with a
#       StartCalendarInterval of { Weekday = 1; Hour = 12; Minute = 0; } instead of cron.
#
#     RESTORE (automated — ansible/recovery/recover_vaultwarden.yaml): this is
#     DESTRUCTIVE (the live vault is overwritten and every change since the backup
#     is lost), so it asks for confirmation (type RESTORE) before swapping data. It
#     stops container 101, snapshots the CURRENT vault to vaultwarden_backups/
#     pre-restore-<ts> first (so the restore itself is reversible), swaps in the
#     backup, restarts, and health-checks /alive — auto-rolling the pre-restore
#     snapshot back if the restored vault fails to come up. backup_path is a HOST
#     path; for an encrypted archive also pass the OFFLINE private key (a controller
#     path — it is copied to a transient 0600 file on the box and shredded after):
#       ansible-playbook ansible/recovery/recover_vaultwarden.yaml \
#         -e backup_path=/mnt/pve/secure-storage/syncthing_share/vault_backups/vault-<ts>.age \
#         -e age_identity_file=~/secrets/vaultwarden-age-key.txt
#     It also restores an unencrypted pre-upgrade snapshot from update_vaultwarden.yaml
#     (no key needed): -e backup_path=/mnt/pve/secure-storage/vaultwarden_backups/<ts>_<ver>/data
#     If the .age archive is only on a USB drive / your laptop, copy it onto the box
#     first (e.g. into the Syncthing folder) and point backup_path at that host path.
#
#   * Immich database (optional, recommended): the DB holds the CURATED metadata —
#     albums, manual tags, named people (faces are re-detected on restore, but the
#     names you assigned are lost), favorites/archive flags, descriptions, stacks,
#     shared links. Everything else (thumbnails, transcodes, face detection, search
#     embeddings) is regenerated from the originals on restore, so it is lower
#     priority than the photos themselves. Turn on Immich's built-in periodic DB
#     backup with the optional playbook below — it writes pg_dumps into
#     immich_data/backups/, which the photo rsync above already carries to USB, so
#     the catalog gets off-box for free. The dump is metadata only (no photos), so
#     it stays small (hundreds of MB to ~1-2 GB even for a large library — it scales
#     with asset/face count, not photo bytes).
#       # one-time: create an Immich ADMIN API key (Account Settings -> API Keys),
#       # then copy ansible/resources/immich.env.example -> immich.env and paste it in.
#       ansible-playbook ansible/bootstrap/99_optional_immich_db_backup.yaml
#     Defaults: Saturday 23:00 (cron `0 23 * * 6`), keep the last 8 dumps. Override
#     with -e backup_cron='...' / -e keep_amount=N. It is non-destructive (GET ->
#     merge only backup.database -> PUT) and leaves the Settings UI editable.

# Maintenance & upgrades (recurrent)
#
# All of these require the encrypted storage to be mounted first (run
# unlock_storage.yaml) where they touch the apps/vault data.
#
#   * Host + guest OS updates (deliberate, owner-initiated full upgrade):
#       ansible-playbook ansible/update_proxmox.yaml
#     apt update + dist-upgrade on the Proxmox host AND inside the running LXC
#     guests (100/101/102; this also bumps docker-ce in 100). It does NOT reboot —
#     it only reports if a reboot is pending (a reboot needs a manual LUKS
#     unlock afterwards). Run it on whatever cadence you like.
#
#   * Automatic security patches (one-time host setup):
#       ansible-playbook ansible/bootstrap/08_enable_unattended_upgrades.yaml
#     Enables Debian unattended-upgrades scoped to the SECURITY origin only,
#     with NO auto-reboot, via the standard apt-daily-upgrade.timer. PVE/Ceph
#     upgrades are deliberately left to update_proxmox.yaml above.
#       Verify: sudo unattended-upgrade --dry-run --debug
#               systemctl status apt-daily-upgrade.timer
#
#   * Check for available Docker-stack updates (read-only — mutates nothing):
#       ansible-playbook ansible/check_updates.yaml
#     Reports, as a table, which apps in LXC 100 (Immich, postgres, valkey,
#     syncthing, caddy) have a newer upstream version than what is deployed.
#     Reads the DEPLOYED versions live off the box (Immich from the live .env,
#     the rest from the deployed docker-compose.yml) and fetches LATEST from
#     upstream — Immich/caddy from their GitHub releases, syncthing's full
#     vX.Y.Z-lsNNN tag from the LinuxServer.io API (so a -lsNNN-only rebuild,
#     which carries base-OS/security fixes, is caught — not just app-version
#     bumps), and the postgres/valkey targets from Immich's OWN compose at its
#     latest release tag (those images track Immich, so they bump alongside it).
#     caddy is a floating major-2 build, so only a new MAJOR is flagged. Requires LXC 100
#     running (unlock_storage.yaml first); does NOT need storage mounted and
#     never starts the container. Good cron candidate. Then apply with
#     update_docker_stack.yaml below.
#
#   * Docker application stack upgrades (Immich, Syncthing, Caddy, Postgres, Valkey):
#       ansible-playbook ansible/update_docker_stack.yaml                          # pull repo-pinned tags + recreate
#       ansible-playbook ansible/update_docker_stack.yaml -e immich_version=v2.8.0 \
#         -e syncthing_drop_dir=/mnt/pve/secure-storage/syncthing_share/immich_db_backups   # snapshot+encrypt DB, then bump
#     For Syncthing/Caddy/Postgres/Valkey: bump the tag in
#     ansible/resources/docker-compose.yml, then run the playbook (it re-pushes
#     the compose file and `docker compose pull && up -d`). For Immich the version
#     pin (IMMICH_VERSION) lives in the generate-once .env, so a repo edit will
#     NOT propagate — pass -e immich_version=vX.Y.Z to rewrite it in place. Always
#     check the upstream Immich release notes (and bump the postgres/valkey tags in
#     docker-compose.yml to match) before a major bump.
#     SAFETY: passing -e immich_version= REQUIRES -e syncthing_drop_dir= and first
#     takes a logical pg_dumpall of the Immich DB, age-ENCRYPTS it, and drops it
#     into that Syncthing-shared folder (so it auto-syncs off-box, like the vault
#     backup); the bump aborts if the dump fails. This guards the IRREVERSIBLE
#     DB migration an Immich major can run (e.g. 2.x -> 3.0 pgvecto.rs ->
#     VectorChord). It does NOT auto-roll back; the success output prints the
#     manual restore. First run prints an age PRIVATE key ONCE — store it OFFLINE
#     (decrypts every Immich DB dump; restore: age -d -i <key> ... | gunzip | psql).
#     Create the Syncthing folder in the UI first so Syncthing owns it.
#
#   * VaultWarden upgrades: ansible/update_vaultwarden.yaml (see above).
#
#   * VPN peers + endpoint DNS (see "Remote access (VPN)" above):
#       ansible-playbook ansible/add_wireguard_peer.yaml -e peer_name=<name> -e wg_endpoint=vpn.<base-domain>
#       ansible-playbook ansible/remove_wireguard_peer.yaml -e peer_name=<name>
#       ansible-playbook ansible/update_wireguard_ddns.yaml   # refresh the AAAA; cron only if the v6 prefix rotates
#     The WireGuard LXC (102) autostarts on boot (onboot=1) and is independent of
#     the LUKS unlock, so nothing VPN-related needs running after a reboot.
#
#   * Trusted HTTPS for the Proxmox web UI (reuse Caddy's wildcard cert):
#       ansible-playbook ansible/update_proxmox_cert.yaml
#     By default the Proxmox UI serves a self-signed cert. This play finds the
#     *.<base-domain> wildcard cert Caddy already obtained (on the encrypted
#     volume) and installs it for pveproxy via `pvenode cert set`, so the UI is
#     trusted on the LAN too. It does NOT re-issue anything — it reuses Caddy's
#     cert. If Caddy hasn't issued the cert yet it reports that and leaves
#     Proxmox's cert untouched; it is idempotent (only restarts pveproxy when the
#     cert actually changed), so it is safe to re-run / cron.
#
#     IMPORTANT — a wildcard *.<base-domain> does NOT cover the apex
#     <base-domain> itself, nor the raw IP. You MUST reach the Proxmox UI at a
#     SUBDOMAIN, e.g. https://pve.<base-domain>:8006, and (manual, like the other
#     hostnames) make that DNS name resolve to the PROXMOX HOST's IP on your LAN
#     — NOT the docker LXC (192.168.0.53). Browsing by IP or by the bare apex will
#     still show a name-mismatch warning; that is expected.
#
#     Switching from the apex to the subdomain is PURELY a DNS + browser-URL
#     change — it is low-risk and trivially reversible (delete the DNS record to
#     revert). Do NOT rename the PVE node hostname/FQDN to match: the node's
#     internal identity (its /etc/pve/nodes/<name> dir, internal pve-ssl cert,
#     /etc/hosts self-mapping for quorum) is unrelated to the URL you browse to,
#     and renaming it is the genuinely risky operation. Leave it as-is. Just add
#     the subdomain DNS record and browse there; nothing inside Proxmox changes.
#
#     Caddy auto-renews (~every 60 days) and the copy installed here is a
#     snapshot, so RE-RUN this periodically to refresh it (re-runs are no-ops
#     until the cert rotates). Requires the encrypted storage mounted (the cert
#     lives on it — run unlock_storage.yaml first). Schedule it on the controller
#     the same way as the other recurrent plays, e.g. monthly: `0 4 1 * *`.

```

# Backlog

Planned improvements are tracked in [BACKLOG.md](BACKLOG.md), ordered by priority
(P1 is the most important). It is the single source of truth for open work on the
project.
