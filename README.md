# Proxmox VE Home Server Infrastructure-as-Code

Infrastructure-as-code for bootstrapping a single home-server Proxmox VE 9 (Debian "trixie") box from a fresh install into a hardened host running a self-hosted application stack backed by encrypted storage.

---

## Table of Contents

- [Overview \& Purpose](#overview--purpose)
- [Architecture \& Principles](#architecture--principles)
  - [Threat Model \& Security Posture](#threat-model--security-posture)
  - [Service Topology \& Trust Zones](#service-topology--trust-zones)
- [Prerequisites \& Tooling](#prerequisites--tooling)
- [Initial Provisioning Runbook](#initial-provisioning-runbook)
  - [Phase 1: Host Hardening \& Encrypted Storage](#phase-1-host-hardening--encrypted-storage)
  - [Phase 2: Docker Host LXC \& Application Stack](#phase-2-docker-host-lxc--application-stack)
  - [Phase 3: VaultWarden Password Manager](#phase-3-vaultwarden-password-manager)
  - [Phase 4: Remote Access (WireGuard VPN)](#phase-4-remote-access-wireguard-vpn)
  - [Phase 5: Local LLM Inference (Ollama)](#phase-5-local-llm-inference-ollama)
  - [Phase 6: Automatic Security Patching](#phase-6-automatic-security-patching)
- [Day-to-Day Operations](#day-to-day-operations)
  - [Unlocking Storage Post-Reboot](#unlocking-storage-post-reboot)
  - [Managing WireGuard VPN Peers](#managing-wireguard-vpn-peers)
  - [Managing Local LLM Models](#managing-local-llm-models)
- [Backups \& Disaster Recovery](#backups--disaster-recovery)
  - [VaultWarden Vault Backups \& Restore](#vaultwarden-vault-backups--restore)
  - [Immich Database \& Photo Library Backups](#immich-database--photo-library-backups)
  - [Syncthing Data Storage](#syncthing-data-storage)
- [Maintenance \& Upgrades](#maintenance--upgrades)
  - [Host \& Guest OS Updates](#host--guest-os-updates)
  - [Checking \& Applying App Upgrades](#checking--applying-app-upgrades)
  - [Upgrading Ollama LLM Service](#upgrading-ollama-llm-service)
  - [Proxmox Web UI SSL Certificate Renewal](#proxmox-web-ui-ssl-certificate-renewal)
- [Incident Response: Stolen Box Protocol](#incident-response-stolen-box-protocol)
- [Backlog \& Roadmap](#backlog--roadmap)

---

## Overview & Purpose

This repository contains Ansible playbooks to provision and maintain a hardened, single-node Proxmox VE home server. The host runs owner-operated applications including:

- **Immich**: Self-hosted photo and video backup stack (PostgreSQL, Valkey, Machine Learning).
- **Syncthing**: Continuous bidirectional file synchronization.
- **VaultWarden**: Lightweight, Bitwarden-compatible password vault.
- **WireGuard**: Secure IPv6-reachable VPN subnet router for remote access.
- **Ollama**: Local OpenAI-compatible LLM inference server (iGPU accelerated).
- **Caddy**: Reverse proxy with automated Let's Encrypt wildcard TLS via DNS-01.

> [!NOTE]
> All playbooks drive the Proxmox host over SSH as `ansible-worker` (using `sudo` where required). There is no terraform/OpenTofu layer; LXC containers and bind mounts are configured directly using `pct` and `pvesm`.

---

## Architecture & Principles

### Threat Model & Security Posture

- **Single Home Box, Owner-Operated**: Availability is not critical. Manual steps at boot (unlocking LUKS data storage) are acceptable and preferred over automatic unlock mechanisms that store keys on disk.
- **LAN-Only by Default**: No services have public reverse-proxy exposure. In-home HTTPS is enabled via Caddy using Let's Encrypt **ACME DNS-01** challenges (OVH DNS API), requiring zero open inbound HTTP/HTTPS ports.
- **Single Public Port (WireGuard VPN)**: Remote reachability is handled exclusively by WireGuard (LXC 102). Due to ISP CGNAT (no public IPv4), WireGuard listens on an **IPv6 Global Unicast Address (GUA)** with a router IPv6 pinhole.
- **Encryption at Rest & Swap Protection**:
  - The main data array uses **LUKS2 (argon2id)** mounted at `/mnt/pve/secure-storage`. Unlocked manually after boot via `unlock_storage.yaml`.
  - Host **swap** is encrypted (`plain dm-crypt`) on every boot with an ephemeral key (`11_encrypt_swap.yaml`), ensuring swapped process memory (TLS keys, app state) never persists on the unencrypted boot drive.
- **Unattended Boot Trade-Off**: WireGuard (LXC 102) and Ollama (LXC 103) autostart on boot (`onboot=1`) with rootfs on unencrypted storage (`local-lvm`). If power cycles while the owner is away, WireGuard returns automatically, allowing remote SSH access to run `unlock_storage.yaml`.

### Service Topology & Trust Zones

| Container ID | Name | Type / Runtime | Storage Location | Onboot | Trust Zone & Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **100** | `docker-srv` | Unprivileged LXC + Nesting (`docker compose`) | RootFS on `local-lvm`<br>Data on `/mnt/pve/secure-storage` | `onboot=0` | **Media & Sync Tier**: Immich stack, Syncthing, Caddy reverse proxy. iGPU passthrough (`/dev/dri/renderD128`). |
| **101** | `vaultwarden` | Unprivileged LXC (Native Binary, No Docker) | RootFS on `local-lvm`<br>Data on `/mnt/pve/secure-storage` | `onboot=0` | **Security / Vault Tier**: Blast-radius isolated password manager. Nesting disabled to enforce maximum LXC confinement. |
| **102** | `wireguard` | Unprivileged LXC (Native Kernel Module) | Unencrypted RootFS on `local-lvm` | `onboot=1` | **Remote Access Tier**: WireGuard subnet router (`192.168.0.0/24`). Static v4 `192.168.0.55` + SLAAC IPv6 GUA. MASQUERADE return routing. |
| **103** | `ollama-srv` | Unprivileged LXC (Native Systemd Service) | 150GB RootFS on `local-lvm` | `onboot=1` | **Local Inference Tier**: OpenAI API on `:11434` / `llm.<domain>`. iGPU Vulkan acceleration + P-Core thread binding (`OLLAMA_NUM_THREADS=4`). |

---

## Prerequisites & Tooling

### System Requirements & Dependencies

- **Control Node**: Ansible installed on your local machine.
- **Ansible Collections**:
  ```bash
  ansible-galaxy collection install -r requirements.yaml
  ```
  *(Requires `community.proxmox`, `community.general`, `community.crypto`, and `ansible.posix`).*

### Initial Controller Setup

1. **Generate Automation SSH Key**:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ansible -C "ansible-automation-key"
   ```
2. **Configure Inventory**:
   Copy `inventory.ini.example` to `inventory.ini` and set your Proxmox host IP address.

---

## Initial Provisioning Runbook

Execute the following playbooks in order on a fresh Proxmox VE installation.

### Phase 1: Host Hardening & Encrypted Storage

1. **Bootstrap Ansible & Harden Host**:
   Configures `ansible-worker` user with passwordless sudo, installs Python, switches PVE APT repositories to `pve-no-subscription`, and disables root SSH login.
   ```bash
   ansible-playbook ansible/bootstrap/01_bootstrap_and_harden.yaml -i '192.168.0.xxx,' -e "target_host=192.168.0.xxx" --ask-pass
   ```
2. **Remove Proxmox Subscription Nag**:
   ```bash
   ansible-playbook ansible/bootstrap/02_remove_nag_msg.yaml
   ```
3. **Format & Encrypt Data Storage**:
   > [!CAUTION]
   > This command will **wipe all data** on `target_disk`.
   ```bash
   ansible-playbook ansible/bootstrap/03_setup_encrypted_disks.yaml -e "target_disk=/dev/sdX"
   ```
4. **Encrypt Host Swap Space**:
   Configures ephemeral per-boot encrypted swap to protect swapped process memory at rest.
   ```bash
   ansible-playbook ansible/bootstrap/11_encrypt_swap.yaml
   ```

---

### Phase 2: Docker Host LXC & Application Stack

1. **Provision Docker Host LXC (ID 100)**:
   ```bash
   ansible-playbook ansible/bootstrap/04_provision_docker_lxc.yaml
   ```
2. **Mount Encrypted Storage Post-Reboot / Initial Provision**:
   ```bash
   ansible-playbook ansible/unlock_storage.yaml -e "target_disk=/dev/sdX"
   ```
3. **Configure Caddy DNS Credentials**:
   Copy and populate the OVH API token configuration:
   ```bash
   cp ansible/resources/caddy.env.example ansible/resources/caddy.env
   # Edit ansible/resources/caddy.env with your BASE_DOMAIN and OVH API credentials
   ```
   > [!IMPORTANT]
   > Ensure your LAN DNS (Router, Pi-hole, or hosts file) routes `*.<base-domain>` (e.g., `immich.<domain>`, `syncthing.<domain>`) to LXC 100 IP (`192.168.0.53`).

4. **Deploy Docker Stack (Immich, Syncthing, Caddy)**:
   ```bash
   ansible-playbook ansible/bootstrap/05_deploy_docker_stack.yaml
   ```

---

### Phase 3: VaultWarden Password Manager

1. **Provision Isolated VaultWarden LXC (ID 101)**:
   ```bash
   ansible-playbook ansible/bootstrap/06_provision_vaultwarden_lxc.yaml
   ```
2. **Deploy Native VaultWarden Binary**:
   Extracts binary from official Docker image using LXC 100, installs into LXC 101, and outputs the initial `ADMIN_TOKEN`.
   ```bash
   ansible-playbook ansible/bootstrap/07_deploy_vaultwarden.yaml
   ```
3. **Access Admin Panel**:
   Set LAN DNS for `vault.<base-domain>` to `192.168.0.53` and navigate to `https://vault.<base-domain>/admin` using the printed token to invite your owner account.

---

### Phase 4: Remote Access (WireGuard VPN)

1. **Provision WireGuard LXC (ID 102)**:
   ```bash
   ansible-playbook ansible/bootstrap/09_provision_wireguard_lxc.yaml
   ```
2. **Deploy WireGuard Server**:
   ```bash
   ansible-playbook ansible/bootstrap/10_deploy_wireguard.yaml
   ```
3. **Configure Router Firewall & DDNS**:
   - Open an inbound IPv6 firewall pinhole on port `udp/51820` to LXC 102's GUA IPv6 address on your home router.
   - Point `vpn.<base-domain>` AAAA record to the container's GUA IPv6:
     ```bash
     ansible-playbook ansible/update_wireguard_ddns.yaml
     ```
4. **Enrol Client Devices**:
   ```bash
   ansible-playbook ansible/add_wireguard_peer.yaml -e peer_name=phone -e wg_endpoint=vpn.<base-domain>
   ```

---

### Phase 5: Local LLM Inference (Ollama)

1. **Provision Ollama LXC (ID 103)**:
   ```bash
   ansible-playbook ansible/bootstrap/12_provision_llm_lxc.yaml
   ```
2. **Deploy Ollama & Vulkan Acceleration**:
   ```bash
   ansible-playbook ansible/bootstrap/13_deploy_llm.yaml
   ```
3. **Pull Default Coding Model**:
   ```bash
   ansible-playbook ansible/manage_llm_model.yaml -e target_model=deepseek-coder-v2:16b
   ```

---

### Phase 6: Automatic Security Patching & Maintenance

1. **Enable Security Unattended Upgrades**:
   ```bash
   ansible-playbook ansible/bootstrap/08_enable_unattended_upgrades.yaml
   ```

2. **Enable Proxmox Web UI Certificate Auto-Sync**:
   ```bash
   ansible-playbook ansible/bootstrap/14_setup_cert_auto_update.yaml
   ```
   *(Note: If auto-sync is ever delayed or disabled, you can always manually trigger a sync from your workstation using `ansible-playbook ansible/update_proxmox_cert.yaml`.)*

---

## Day-to-Day Operations

### Unlocking Storage Post-Reboot

After any host reboot, data storage remains unmounted. Run `unlock_storage.yaml` to open LUKS and start dependent containers (100 & 101):

```bash
ansible-playbook ansible/unlock_storage.yaml -e "target_disk=/dev/sdX"
```

### Managing WireGuard VPN Peers

- **Enrol New Peer**:
  ```bash
  ansible-playbook ansible/add_wireguard_peer.yaml -e peer_name=laptop -e wg_endpoint=vpn.<base-domain>
  ```
  *(Displays client configuration and a terminal QR code for mobile scanning).*

- **Revoke Existing Peer**:
  ```bash
  ansible-playbook ansible/remove_wireguard_peer.yaml -e peer_name=laptop
  ```

### Managing Local LLM Models

- **Install / Switch Model**:
  ```bash
  ansible-playbook ansible/manage_llm_model.yaml -e target_model=mixtral:8x7b
  ```
- **List Installed Models**:
  ```bash
  ansible-playbook ansible/manage_llm_model.yaml -e model_action=list
  ```

---

## Backups & Disaster Recovery

### VaultWarden Vault Backups & Restore

- **Run Encrypted Vault Backup**:
  Stops container 101 briefly, age-encrypts database snapshot, and places archive into Syncthing drop folder.
  ```bash
  ansible-playbook ansible/backup_vaultwarden.yaml -e syncthing_drop_dir=/mnt/pve/secure-storage/syncthing_share/vault_backups
  ```
  > [!IMPORTANT]
  > On the **first run**, the playbook generates an `age` keypair and prints the **private key**. Store this key **OFFLINE**. It is required for recovery.

- **Automated Retention**:
  Keep-daily (7 days), keep-weekly (4 weeks), keep-monthly (12 months).

- **Restore VaultWarden Vault**:
  ```bash
  ansible-playbook ansible/recovery/recover_vaultwarden.yaml \
    -e backup_path=/mnt/pve/secure-storage/syncthing_share/vault_backups/vault-<ts>.age \
    -e age_identity_file=~/secrets/vaultwarden-age-key.txt
  ```

---

### Immich Database & Photo Library Backups

- **Immich Database Dump**:
  Performs live `pg_dumpall`, age-encrypts output, and saves to Syncthing drop dir:
  ```bash
  ansible-playbook ansible/backup_immich.yaml -e syncthing_drop_dir=/mnt/pve/secure-storage/syncthing_share/immich_db_backups
  ```
- **Restore Immich Database**:
  ```bash
  ansible-playbook ansible/recovery/recover_immich.yaml \
    -e backup_path=/mnt/pve/secure-storage/syncthing_share/immich_db_backups/immich-db-<ts>_<ver>.sql.gz.age \
    -e age_identity_file=~/secrets/immich-db-age-key.txt
  ```
- **Photo Library Rsync Pull (Run from workstation)**:
  ```bash
  rsync -aH --info=progress2 --rsync-path="sudo rsync" \
    --exclude=thumbs/ --exclude=encoded-video/ \
    ansible-worker@<box>:/mnt/pve/secure-storage/immich_data/ /your/local/immich-backup/
  ```

- **Optional Built-in Immich Scheduled DB Backups**:
  ```bash
  # Copy ansible/resources/immich.env.example -> immich.env and add API key
  ansible-playbook ansible/bootstrap/99_optional_immich_db_backup.yaml
  ```

---

### Syncthing Data Storage

Syncthing uses bind mounts under `/mnt/storage/syncthing_share` (`/data` inside container). Always configure sync folders in the Syncthing Web UI (`https://syncthing.<base-domain>`) under `/data/`:
- `/data/personal` → Personal file sync.
- `/data/vault_backups` → VaultWarden `.age` archives.
- `/data/immich_db_backups` → Immich DB `.age` archives.

---

## Maintenance & Upgrades

### Host & Guest OS Updates

Applies `apt update && apt dist-upgrade` across Proxmox host and LXCs 100, 101, and 102. Does not reboot host.
```bash
ansible-playbook ansible/update_proxmox.yaml
```

### Checking & Applying App Upgrades

1. **Check for Upstream Container Updates**:
   ```bash
   ansible-playbook ansible/check_updates.yaml
   ```
2. **Upgrade Docker Application Stack**:
   ```bash
   # Upgrade base compose stack (Syncthing, Caddy, Postgres, Valkey)
   ansible-playbook ansible/update_docker_stack.yaml

   # Upgrade Immich version with auto DB backup
   ansible-playbook ansible/update_docker_stack.yaml -e immich_version=v2.8.0 \
     -e syncthing_drop_dir=/mnt/pve/secure-storage/syncthing_share/immich_db_backups
   ```
3. **Upgrade VaultWarden Native Binary**:
   ```bash
   ansible-playbook ansible/update_vaultwarden.yaml -e target_version=1.33.0
   ```

### Upgrading Ollama LLM Service

Upgrades the Ollama binary inside LXC 103 to the latest upstream release from GitHub (`ollama/ollama`), re-applies systemd P-core thread tuning (`OLLAMA_NUM_THREADS=4`), and verifies API health. Installed model files (`/var/lib/ollama`) remain untouched:

```bash
# Check upstream version and upgrade if outdated
ansible-playbook ansible/update_llm.yaml

# Force re-running installer and systemd override
ansible-playbook ansible/update_llm.yaml -e force_update=true
```

### Proxmox Web UI SSL Certificate Renewal

Copies Caddy's Let's Encrypt wildcard certificate from the encrypted volume to Proxmox `pveproxy`:
```bash
ansible-playbook ansible/update_proxmox_cert.yaml
```
*Note: Access Proxmox UI via subdomain DNS (e.g., `https://pve.<base-domain>:8006`).*

---

## Incident Response: Stolen Box Protocol

If the hardware is stolen while powered down (or before LUKS storage unlock), all data on `/mnt/pve/secure-storage` remains encrypted and secure.

Execute the following checklist immediately:

1. **Revoke VPN & Close IPv6 Pinhole**:
   - Delete router's IPv6 pinhole for `udp/51820`.
   - Remove `vpn.<base-domain>` AAAA record.
   - WireGuard client keys on unencrypted boot rootfs are considered compromised; regenerate server key and peer profiles during rebuild.
2. **Revoke OVH API Credentials**:
   - Revoke OVH API token via OVH control panel to prevent unauthorized DNS-01 challenge responses.
3. **Untrust Syncthing Device ID**:
   - Remove stolen server's Syncthing Device ID from all peer laptops/phones.
4. **Rebuild Infrastructure**:
   - Provision new server hardware using `01` through `13` playbooks.
   - Restore VaultWarden and Immich databases using offline `age` private keys.

---

## Backlog & Roadmap

Active tasks, technical debts, and prioritized enhancements are tracked in [BACKLOG.md](BACKLOG.md).
