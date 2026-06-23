# Backlog

Planned improvements, ordered by priority. This file is the single source of truth
for the project's open work (the README runbook links here instead of carrying inline
TODOs).

**Ordering rationale.** Priorities follow the threat model in `CLAUDE.md`: the box is
owner-operated and **LAN-only by design**, and encryption protects against **physical
theft, not a live compromise**. So *irreplaceable-data-loss* risks (hardware failure,
operator error) rank above *live-attack* risks, and a catastrophic-but-cheap-to-fix
footgun ranks near the top.

Each item is independent. None are implemented yet — they remain separate future tasks.

---

## P1 — Off-box backup for the irreplaceable data (Immich library + DB, Syncthing)

The highest-value asset on the box is the photo library, and it currently has **no
automated, in-tree backup**. Only the vault is covered (`ansible/backup_vaultwarden.yaml`).
Immich originals + the Immich DB and Syncthing data depend on an **undocumented, off-repo,
manual** personal-machine→2×USB pipeline, and there is **no restore test** anywhere. A plain
disk failure (not even theft) loses whatever that manual routine didn't happen to catch.

- **Why #1:** matches the threat model — at-rest theft is the *accepted* risk, but
  hardware failure / operator error is unaddressed and the blast radius is total and
  irreversible. This outranks the security items precisely because the box is LAN-only.
- **Fix:** add an `ansible/immich_backup.yaml` that codifies the one-way, read-only
  `rsync` pull the README currently only describes in prose, plus the Immich DB dump;
  document and periodically run a **restore drill** (decrypt a vault `.age`, restore an
  Immich DB dump into a scratch container) and record when it was last tested.
- **Files:** new `ansible/immich_backup.yaml`; README backup section. Reuse the snapshot
  pattern from `ansible/backup_vaultwarden.yaml` and the existing
  `ansible/bootstrap/99_optional_immich_db_backup.yaml`.

## P2 — `03_setup_encrypted_disks.yaml` must refuse to wipe an existing LUKS disk

Catastrophic footgun, trivial fix. `03` is destructive by design, and its pre-flight
guards (`ansible/bootstrap/03_setup_encrypted_disks.yaml:27-45`) only refuse when the disk
is **currently mounted or has an open crypt/LVM/RAID holder**. After a reboot — before
`unlock_storage.yaml` runs — the encrypted volume is closed and unmounted, so an accidental
re-run with the same `-e target_disk=` passes every guard and `wipefs -a` (`:72`) destroys
the LUKS header → total, unrecoverable loss of photos *and* vault.

- **Why:** worst landmine in the repo; consequence is total data loss from a single
  mistaken re-invocation.
- **Fix:** add a pre-task that probes `cryptsetup isLuks {{ target_partition }}` and
  `fail`s unless the operator explicitly passes `-e force_wipe=true` (mirrors the
  existing `failed_when`/guard idiom). ~6 lines.
- **Files:** `ansible/bootstrap/03_setup_encrypted_disks.yaml`.

## P3 — Make SSH key-only

`ansible/bootstrap/01_bootstrap_and_harden.yaml:103` disables root SSH login but leaves
`PasswordAuthentication` enabled, while `ansible-worker` is granted passwordless sudo
(`:86`, `NOPASSWD:ALL`). Net effect: a weak/guessable password on *any* account is a direct
path to full root over the LAN. "LAN-only" is not a strong boundary — a compromised laptop,
phone, IoT device, or guest on the same network is in scope.

- **Why:** cheap, high-leverage hardening consistent with the key-based automation
  already in use.
- **Fix:** add a second validated `sshd_config.d` drop-in (same idiom as the existing
  `10-disable-root.conf`, validated with `sshd -t -f %s`) containing:
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`.
  Optional add-ons: `MaxAuthTries`, idle `ClientAliveInterval`.
- **Files:** `ansible/bootstrap/01_bootstrap_and_harden.yaml`.

## P4 — Post-deploy / post-upgrade health verification

Several playbooks report success when services are actually dead. `05_deploy_docker_stack.yaml`
and `update_docker_stack.yaml` run `docker compose up -d` and finish without checking that
anything came up (a failed Caddy build or broken Postgres init leaves a "green" run with a
down stack). `update_proxmox.yaml` upgrades guests but never confirms they're still running.
Note the *containers* do have healthchecks (`ansible/resources/docker-compose.yml:50,64`);
what's missing is the *playbook* asserting on them. `update_vaultwarden.yaml` is the model to
copy — it already does an `/alive` health check with retries and auto-rollback.

- **Why:** silent failure on deploy/upgrade is a robustness gap; failures should be loud.
- **Fix:** after `up -d`, poll `docker compose ps` / healthcheck status (optionally
  `curl -k https://immich.<domain>` from the host) with `retries`/`delay`, failing on a
  down service; add a "still running?" assertion to the guest-upgrade loop.
- **Files:** `ansible/bootstrap/05_deploy_docker_stack.yaml`, `ansible/update_docker_stack.yaml`,
  `ansible/update_proxmox.yaml`.

## P5 — Tighten version pinning & remove brittle hardcoded values

Reproducibility/maintainability drift, plus one brittle constant:

- **`valkey:9`** (`ansible/resources/docker-compose.yml:49`) is major-only → silent patch
  upgrades on any `pull`. Pin to a specific patch, consistent with the fully-pinned
  Postgres/Syncthing tags.
- **Caddy OVH plugin is unpinned** — `xcaddy ... --with github.com/caddy-dns/ovh` (no
  `@version`) in `ansible/resources/caddy/Dockerfile`; a rebuild can pull a breaking module
  version and break cert renewal. Pin it.
- **Hardcoded VaultWarden IP** `192.168.0.54:8000` in `ansible/resources/caddy/Caddyfile:45`
  breaks silently if LXC 101 is re-provisioned with a different IP. Promote to a
  `{$VAULT_UPSTREAM}` var sourced from `caddy.env` (already templated by `05`).
- **Files:** `ansible/resources/docker-compose.yml`, `ansible/resources/caddy/Dockerfile`,
  `ansible/resources/caddy/Caddyfile`, `ansible/resources/caddy.env.example`.

---

## Nice to have

Lower-priority polish; didn't make the top 5.

- **VaultWarden admin token resilience.** `07_deploy_vaultwarden.yaml` prints the `/admin`
  token once to stdout — a lost terminal scrollback is fatal. Also write it to
  `/etc/vaultwarden/ADMIN_TOKEN` mode 0600. *Files:* `ansible/bootstrap/07_deploy_vaultwarden.yaml`.
- **Extra systemd sandboxing.** The unit is already strong; incremental additions:
  `SystemCallFilter=@system-service`, `RestrictAddressFamilies=AF_INET AF_INET6`,
  `RestrictSUIDSGID=yes`. *Files:* `ansible/resources/vaultwarden/vaultwarden.service`.
- **Ansible Vault for secrets at rest.** `caddy.env` / `.env` are gitignored but plaintext;
  consider `ansible-vault` encryption. *Files:* secrets handling across the resources.
