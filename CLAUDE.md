# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure-as-code for bootstrapping a single home-server Proxmox VE 9 (Debian "trixie") box from a fresh install into a hardened host running a self-hosted application stack (Immich, Syncthing, a Caddy reverse proxy doing Let's Encrypt wildcard TLS, planned VaultWarden) backed by encrypted storage. There is no application source code here — only Ansible playbooks that drive an external Proxmox host over SSH (as root via sudo). IaC here is for documentation and possible future reproducibility; it is not a production-grade reproducible build.

The README's `# How to run` section is the canonical end-to-end runbook and ordered sequence of commands. The live backlog is `BACKLOG.md` at the repo root (prioritized P1–P5 plus nice-to-haves) — treat it as the single source of truth for open work; the README's `# Backlog` section links to it.

## Intent & threat model

- **Single home box, owner-operated.** This serves one household; the owner is physically present often, so availability is not critical — manual steps at boot (unlocking storage) are acceptable, not a defect to automate away.
- **Not exposed to the internet (deliberate, for now).** All services are reachable only on the home LAN. There is no inbound port forwarding / reverse proxy to the outside world. Syncthing reconciles data while devices are on the home network; the owner is there often enough that this is acceptable. Do not add public exposure without an explicit decision — keep new services LAN-only by default.
- **Encryption protects against physical theft, not a live compromise.** The data disk is LUKS2-encrypted so a stolen drive/box leaks nothing at rest. It is unlocked manually after every boot (`unlock_storage.yaml`) — there is intentionally no stored key or auto-unlock, since that would defeat the theft protection. A running, unlocked box offers no at-rest protection; that is an accepted limitation given the LAN-only posture.
- **The Let's Encrypt certs are for in-home HTTPS** (trusted certs on LAN hostnames), not because anything is public. Issuance/renewal is handled by Caddy in LXC 100 via the **ACME DNS-01** challenge (OVH provider) — chosen because there is no inbound HTTP reachability — and Caddy auto-renews. A single wildcard cert (`*.<base-domain>`) covers all services, including the future VaultWarden host.

## Service topology (intended)

- **`docker-srv` LXC (id 100) — shared Docker host** running Immich (+ machine-learning) and Syncthing via `docker compose` (`ansible/resources/docker-compose.yml`). These are media/sync apps that benefit from the iGPU passthrough and share the encrypted volume; co-locating them in one Docker LXC is the convenience tier.
- **VaultWarden LXC (id 101) — isolated, security tier.** Kept in its own container, separate from the media stack, because it holds the password vault — the highest-value secret on the box. The goal is blast-radius isolation: a compromise of the larger media stack should not reach the vault. Treat 100 and 101 as different trust zones. **Decision: run VaultWarden as a native binary in the LXC, NOT via Docker** — this avoids enabling `nesting` (which loosens LXC confinement) on the one container that most needs to stay tight.
- **TLS / reverse proxy: Caddy in the Docker LXC (100)** terminates HTTPS for the LAN and routes by hostname to the local media apps (and, once it exists, across to VaultWarden on 101). It is a service in the same compose project (`ansible/resources/docker-compose.yml`, built from `ansible/resources/caddy/Dockerfile` because the stock image lacks DNS plugins), configured by `ansible/resources/caddy/Caddyfile`, with its OVH DNS-01 credentials + base domain in `ansible/resources/caddy.env` (gitignored; template `caddy.env.example`). Cert/account keys live on the encrypted volume (`/mnt/storage/caddy_data`). Proxying 101's traffic through a proxy in the weaker trust zone is acceptable for LAN-only, but keep the VaultWarden admin path in mind when hardening. **LAN DNS must point the hostnames at LXC 100's IP** — that part is manual (router/Pi-hole/hosts), not automated here.

`ansible/resources/docker-compose.yml` runs the full Immich stack — `immich-server`, `immich-machine-learning`, `database` (vector-enabled PostgreSQL, data in `/mnt/storage/immich_db`), `redis` (Valkey) — plus Syncthing and the Caddy reverse proxy. The DB password is read from a `.env` file beside the compose file; `05_deploy_docker_stack.yaml` generates it from `.env.example` with a strong random `DB_PASSWORD` directly inside the container on first deploy (it is never regenerated, since Postgres bakes it into its data dir on init). Caddy reads `caddy.env` (user-supplied OVH credentials, pushed in by the deploy playbook — not generated). The postgres/valkey image tags track upstream and may need bumping against the current official Immich release compose.

## Tooling

- **Ansible** is the only tool — it drives all host-level config *and* guest provisioning over SSH. There is no OpenTofu/Terraform: the Docker LXC is created with `pct` run as root, because Proxmox restricts bind mounts and device passthrough to `root@pam` and a privsep API token cannot perform them — running `pct` locally as root sidesteps the API entirely.
- Install Ansible collection deps once: `ansible-galaxy collection install -r requirements.yaml`. Note `requirements.yaml` lists only `community.proxmox`, but playbooks also use `community.general`, `community.crypto`, and `ansible.posix` — these must be available too. (Guest provisioning uses raw `pct`/`pvesm` via `ansible.builtin.command`, not the `community.proxmox` API module, to keep root-only operations working.)
- `ansible.cfg` sets the default inventory to `./inventory.ini` and pins `interpreter_python = /usr/bin/python3`.

## Commands

```bash
# One-time: install Ansible collections
ansible-galaxy collection install -r requirements.yaml

# Bootstrap a brand-new host (only root + password exist). target_host is REQUIRED via -e.
# Uses --ask-pass because no key is trusted yet; switches APT to no-subscription,
# creates the ansible-worker service account, installs the key, disables root SSH.
ansible-playbook ansible/bootstrap/01_bootstrap_and_harden.yaml -i '192.168.0.xxx,' -e "target_host=192.168.0.xxx" --ask-pass

# All later playbooks run against the `proxmox` inventory group as ansible-worker.
# Copy inventory.ini.example -> inventory.ini and fill in the host first.
ansible-playbook ansible/bootstrap/02_remove_nag_msg.yaml                   # removes subscription nag (persisted via APT hook)
ansible-playbook ansible/bootstrap/03_setup_encrypted_disks.yaml -e "target_disk=/dev/sdX"  # WIPES the disk
ansible-playbook ansible/bootstrap/04_provision_docker_lxc.yaml                       # creates the Docker LXC via pct (requires storage mounted)
ansible-playbook ansible/bootstrap/05_deploy_docker_stack.yaml                        # installs Docker in the LXC + docker compose up -d (requires storage mounted + container 100)
ansible-playbook ansible/bootstrap/06_provision_vaultwarden_lxc.yaml                  # creates the isolated VaultWarden LXC (id 101) via pct (requires storage mounted)
ansible-playbook ansible/bootstrap/07_deploy_vaultwarden.yaml                         # installs VaultWarden as a native binary in 101 (requires storage mounted + containers 100 & 101)
ansible-playbook ansible/bootstrap/08_enable_unattended_upgrades.yaml                 # one-time: Debian SECURITY-only unattended-upgrades on the host (no auto-reboot)
ansible-playbook ansible/unlock_storage.yaml -e "target_disk=/dev/sdX"   # post-reboot: unlock LUKS + start the existing/stopped dependent containers

# Recurrent: full apt dist-upgrade of the host AND the running LXC guests (100/101).
# Reports a pending reboot but never reboots (a reboot needs a manual LUKS unlock).
ansible-playbook ansible/update_proxmox.yaml

# Recurrent: upgrade the Docker app stack (Immich/Syncthing/Caddy/Postgres/Valkey).
# Bump tags in docker-compose.yml for everything except Immich; pass -e immich_version=
# to bump Immich (its pin lives in the generate-once .env, so a repo edit won't propagate).
ansible-playbook ansible/update_docker_stack.yaml                          # pull repo-pinned tags + recreate
ansible-playbook ansible/update_docker_stack.yaml -e immich_version=v2.8.0 # also bump Immich

# Recurrent: upgrade VaultWarden (latest stable, or -e target_version=X.Y.Z); snapshots + auto-rollback on failure.
ansible-playbook ansible/update_vaultwarden.yaml

# Recurrent: encrypted off-box backup of the vault. Snapshots (brief stop), age-encrypts,
# drops vault-<ts>.age into a Syncthing-shared folder so it rides the personal-machine -> USB pipeline.
# syncthing_drop_dir is REQUIRED via -e; prints the age PRIVATE key ONCE on first run (store it offline).
ansible-playbook ansible/backup_vaultwarden.yaml -e syncthing_drop_dir=/mnt/pve/secure-storage/<shared-folder>

# Optional, one-time: enable Immich's built-in periodic DB backup via the Immich admin API
# (non-destructive; UI stays editable). Needs an admin API key in ansible/resources/immich.env.
# Targets localhost (talks to Immich's HTTP API over the LAN), not the proxmox host.
ansible-playbook ansible/bootstrap/99_optional_immich_db_backup.yaml
```

There is no test/lint/build step. Validate Ansible changes with `ansible-playbook --check --diff <playbook>`. (Note: `04_provision_docker_lxc.yaml` uses raw `pct` commands, so `--check` will skip them rather than simulate.)

## Architecture & sequencing

The setup is a strict ordered pipeline; steps depend on artifacts created by earlier steps:

1. **`01_bootstrap_and_harden.yaml`** — the only playbook that targets a raw root login. It runs over `ansible.builtin.raw` (no Python on the host yet), rewrites APT to the free `pve-no-subscription` repos, installs Python + proxmoxer, creates the `ansible-worker` user with passwordless sudo and your `~/.ssh/id_ed25519_ansible.pub` key, then disables root SSH. **Every subsequent playbook assumes this user exists** (`remote_user: ansible-worker`, `become: yes`) and connects via the `proxmox` inventory group.
2. **`03_setup_encrypted_disks.yaml`** — destructive. Wipes `target_disk`, creates one GPT partition, a LUKS2 (argon2id) container `ssdcrypt_data`, ext4, mounts at `/mnt/pve/secure-storage` with `noauto` (so a missing passphrase never blocks boot), creates `immich_data`/`immich_db`/`syncthing_data`/`vaultwarden_data`/`caddy_data` dirs (`immich_db` holds the Immich PostgreSQL data, `caddy_data` the ACME account + cert keys), and registers it as Proxmox storage `secure-storage` with `--is_mountpoint 1` (so PVE refuses to write to the unencrypted root disk when the volume is unmounted).
3. **`04_provision_docker_lxc.yaml`** — creates the `docker-srv` LXC (id `100`) via `pct` run as root: unprivileged, nesting enabled, rootfs on `local-lvm` (NOT the encrypted volume), `--onboot 0`, bind-mounts `secure-storage` to `/mnt/storage` (`--mp0`), and passes through `/dev/dri/renderD128` (Intel iGPU) for transcoding (`--dev0`, skipped with a warning if the device is absent). Guards: fails fast if `/mnt/pve/secure-storage` isn't currently mounted (else the bind mount would capture the empty unencrypted dir); `pct create` is gated on a `pct status` existence check; `mp0`/`dev0` are reconciled every run via idempotent `pct set`. It also `chown`s the Docker data dirs (`immich_data`/`immich_db`/`syncthing_data`/`caddy_data`) to `100000:100000` (host uid that this unprivileged LXC's root maps to) so the bind-mounted, otherwise-`nobody` dirs are writable; each image's root-stage entrypoint then sub-chowns to its own uid (e.g. Postgres → host `100999`, syncthing → host `100911`). The claim is gated on the dir still being owned by host root (`uid == 0`), so it runs only pre-first-run and is a no-op on re-runs once a service has taken a dir over — forcing `immich_db` back to `100000` would otherwise break an initialized Postgres ("data directory has wrong ownership"). (`vaultwarden_data` is left to `06`.)
4. **`05_deploy_docker_stack.yaml`** — deploys the app stack into the Docker LXC (id `100`) over `pct push`/`pct exec` (not SSH-into-guest, matching the root-only `pct` convention). Guards that `/mnt/pve/secure-storage` is mounted and the container is running (starts it if not). Installs Docker CE + the compose plugin from Docker's apt repo inside the container, gated on a `command -v docker` probe. Pushes `docker-compose.yml` + `.env.example` to `/opt/docker-stack`; on first run only, generates `/opt/docker-stack/.env` from the example with a strong random `DB_PASSWORD` (never rotated afterward — Postgres bakes it into its data dir on init, so re-running must not change it). Also pushes the Caddy resources (`caddy/Dockerfile`, `caddy/Caddyfile`, and the user-supplied `caddy.env` at mode 600) — failing fast if `caddy.env` is absent — and ensures `/mnt/storage/caddy_data` exists. Then `docker compose up -d` (which builds the custom Caddy image on first run).
5. **`06_provision_vaultwarden_lxc.yaml`** — creates the `vaultwarden` LXC (id `101`) via `pct` run as root: unprivileged, **nesting NOT enabled** (kept tight — this is the security tier), no GPU, rootfs on `local-lvm`, `--onboot 0`, and bind-mounts **only** the `vaultwarden_data` subdir of `secure-storage` to `/var/lib/vaultwarden` (`--mp0`) so 101 cannot see the media data. Same mount/existence guards as `04`; also `chown`s the host data dir to `101000:101000` so the in-container service user (uid 1000, default unprivileged id-shift) can write.
6. **`07_deploy_vaultwarden.yaml`** — deploys VaultWarden as a **native binary** (no Docker, no nesting) into LXC `101` over `pct push`/`pct exec`. Extracts the `vaultwarden` binary + matched `web-vault` from the pinned official `vaultwarden/server:<ver>` image using LXC `100`'s Docker engine (deploy-time-only dependency), version-gated by a `VERSION` stamp. Installs the dynamically-linked libs (`libssl3`/`libpq5`/`libmariadb3`/`ca-certificates`) and verifies with `ldd` (fails on `not found`). Creates the `vaultwarden` user (uid/gid 1000), writes `/etc/vaultwarden/vaultwarden.env` (signups off; `DOMAIN` derived from `caddy.env`'s `BASE_DOMAIN`; `ADMIN_TOKEN` generated once as an Argon2id hash, plaintext printed once), and installs a hardened systemd unit (`ansible/resources/vaultwarden/vaultwarden.service`).
7. **`unlock_storage.yaml`** — run after every reboot. Prompts for the LUKS passphrase, reopens + mounts `secure-storage` (`-e target_disk=...`, same NVMe-aware partition derivation as setup), then `pct start`s the dependent containers (Docker `100`, VaultWarden `101`) — each gated on a `pct status` probe, so a not-yet-provisioned (or already-running) container is skipped instead of erroring.
8. **`update_vaultwarden.yaml`** — recurrent (lives in `ansible/` root like `unlock_storage.yaml`, self-contained). Upgrades the native VaultWarden binary: resolves the target version (latest GitHub release, or `-e target_version=`), no-ops if already installed, snapshots the vault data + current binary/web-vault to `secure-storage/vaultwarden_backups/`, re-extracts the target (same path as `07`), `ldd`-guards, restarts, and health-checks `/alive` — **auto-rolling back** binary + web-vault + data via a `block`/`rescue` if the new version fails to come up. The Caddy `@vault` block in `caddy/Caddyfile` routes `vault.<base-domain>` to `192.168.0.54:8000` (cross-zone by IP); applied by re-running `05` + reloading Caddy.
9. **`backup_vaultwarden.yaml`** — recurrent (lives in `ansible/` root, self-contained). The only data backup in the repo, and it covers the vault. The rest is backed up off-box by the owner's personal-machine → 2×USB routine (not automated here): Syncthing files via normal replication, and Immich photo originals via a **one-way, read-only `rsync` pull** of the managed library from the box (Immich stays the source of truth — mobile auto-backup and dedup require the managed library, and a two-way sync would corrupt the DB↔file mapping). The Immich DB (`immich_db`) — only curated metadata like albums/tags/named-people; everything else regenerates from originals — is handled by the optional `bootstrap/99_optional_immich_db_backup.yaml`, which turns on Immich's built-in periodic `pg_dump` (into `immich_data/backups/`, swept up by the photo rsync). That playbook is the one exception to the "Ansible-over-SSH-as-root against the `proxmox` group" rule: it runs against `localhost` and talks to the Immich HTTP API on the LAN, doing a non-destructive GET→merge-`backup.database`→PUT so the Settings UI stays editable (the `IMMICH_CONFIG_FILE` alternative would lock the whole UI and reset omitted keys). It takes a consistent snapshot (briefly `systemctl stop`s VaultWarden, `cp -a` to a staging dir on the encrypted volume, restarts — wrapped in `block`/`rescue` so the service always comes back), then pipes `tar | age` (no plaintext tarball ever hits disk) to write `vault-<ts>.age` into the **required** `-e syncthing_drop_dir=` (a Syncthing-shared folder, so it auto-syncs and rides the USB backup), prunes to `keep_backups` (default 7). Encryption is **age asymmetric**: on first run it generates a keypair, persists only the **public** key at `secure-storage/vaultwarden_backups/age-recipient.pub` (non-interactive encryption thereafter) and **prints the private key once** for offline storage — losing it makes every backup undecryptable, and keeping it off-box is what preserves the theft protection. Restore: `age -d -i <key> vault-<ts>.age | tar xz`.

Maintenance / upgrade playbooks (recurrent or one-time; not part of the ordered bootstrap pipeline):
- **`bootstrap/08_enable_unattended_upgrades.yaml`** — one-time host setup. Installs `unattended-upgrades` scoped (via an `Origins-Pattern` drop-in that replaces the packaged default) to the **Debian-Security** origin only, with `Automatic-Reboot "false"`, and enables the `apt-daily-upgrade.timer`. Keeps security patches flowing automatically; PVE/Ceph upgrades are deliberately excluded (they go through `update_proxmox.yaml`).
- **`update_proxmox.yaml`** — recurrent (in `ansible/` root). `apt` `update_cache` + `upgrade: dist` + autoremove on the host, then `apt-get update && full-upgrade && autoremove` inside each running LXC guest (gated on `pct status`; this also bumps `docker-ce` in `100`). Never reboots — it only reports `/var/run/reboot-required` (a reboot needs a manual LUKS unlock afterwards).
- **`update_docker_stack.yaml`** — recurrent (in `ansible/` root). The upgrade path for LXC `100`'s compose stack: same mount/container guards as `05`, re-pushes `docker-compose.yml` (so repo tag bumps for postgres/valkey/syncthing/caddy take effect), optionally `sed`s `IMMICH_VERSION` in the **live** `.env` when `-e immich_version=` is passed (the pin lives in the generate-once `.env`, so a repo `.env.example` edit would NOT propagate — this is the one Immich-version gotcha), then `docker compose pull && up -d`. VaultWarden is upgraded by `update_vaultwarden.yaml`, not here.

**Cross-file coupling to keep consistent** (these magic values are duplicated, not shared):
- Container IDs: `container_id` defaults to `100` in `04_provision_docker_lxc.yaml`, `05_deploy_docker_stack.yaml`, `unlock_storage.yaml`, and `update_docker_stack.yaml`; `vaultwarden_container_id` is `101`. `update_proxmox.yaml` lists both (`100`, `101`) in `guest_container_ids`.
- Storage path `/mnt/pve/secure-storage` (host) ↔ `/mnt/storage` (container bind mount) ↔ the `/mnt/storage/*_data` volumes in `ansible/resources/docker-compose.yml`. The disk-setup data dir names, the compose volume mounts, and the storage name `secure-storage` must all agree.
- **Bind-mount ownership under the unprivileged-LXC id map** (default container 0 → host 100000): host-root-owned dirs appear as `nobody` and are unwritable inside the container, so the host dirs must be re-owned to the host uid the relevant container user maps to. `04` chowns the Docker data dirs to `100000:100000` (container root); `06` chowns `vaultwarden_data` to `101000:101000` (the native service's uid 1000). Keep these in step with the in-container users (Docker images' own service uids; the `vaultwarden` user pinned to 1000 in `07`).
- The LUKS mapper name `ssdcrypt_data` and the `target_disk`-derived partition must match the real disk. Both `03_setup_encrypted_disks.yaml` and `unlock_storage.yaml` derive `target_partition` from `target_disk` (appending `p1` for nvme/mmcblk, else `1`), so pass the same `-e target_disk=` to both.

`ansible/resources/docker-compose.yml` is the app stack for the Docker LXC, deployed by `05_deploy_docker_stack.yaml`.

## Secrets & gitignored files

`inventory.ini`, `ansible/resources/.env` (DB password, generated on-box), `ansible/resources/caddy.env` (OVH DNS-01 API credentials + base domain), and `ansible/resources/immich.env` (an Immich admin API key, used only by the optional DB-backup playbook; template `immich.env.example`) are gitignored. Copy `inventory.ini` from `inventory.ini.example` (fill in the host) and `caddy.env` from `caddy.env.example` (fill in the OVH app key/secret/consumer key, endpoint, base domain, ACME email); never commit either. The SSH automation key is expected at `~/.ssh/id_ed25519_ansible` (passphrase-less, generated per the README).

The **age backup keypair** (`backup_vaultwarden.yaml`) is handled like the VaultWarden admin token: the **public** key is persisted on-box at `secure-storage/vaultwarden_backups/age-recipient.pub`, but the **private** key is printed once and stored OFFLINE by the owner — it is never written to disk on the box (and must not be, or off-box theft protection is lost) and is not in git.

## Conventions

- Playbook filenames use **snake_case** (underscores, never dashes) — e.g. `unlock_storage.yaml`, `05_deploy_docker_stack.yaml` — matching Ansible's required snake_case for roles/collections/variables. Keep new playbooks consistent; do not reintroduce hyphens. (Tool-mandated names like `docker-compose.yml`, `Caddyfile`, `Dockerfile` are exempt, as are runtime identifiers like the `secure-storage` storage name and the `ansible-worker` user, which are not source filenames.)
- Playbook task naming and idempotency style: shell/`command` tasks that may legitimately fail on re-run guard with `failed_when` checking for "already exists" in stderr and set `changed_when` explicitly; non-idempotent imperative steps (`pct create`) are gated on an existence probe (`pct status`) with `failed_when: false`. Follow this pattern for new imperative `pct`/`pveum`/`pvesm` calls rather than relying on module idempotency that doesn't exist for these CLIs.
- Everything is Ansible-over-SSH-as-root. Provision Proxmox guests with raw `pct` (not the `community.proxmox` API module), since the operations this repo needs — bind mounts and device passthrough — are root@pam-only and unavailable to a privsep API token.
