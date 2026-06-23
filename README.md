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


```
