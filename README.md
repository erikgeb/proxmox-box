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



# TODO: Add ansible script to deploy ansible/resources/docker-compose.yml to docker host and apply it

# TODO: Add support to generate let's encrypt certificate with auto renew

# TODO: Configure VaultWarden host

# TODO: Validate ansible/unlock-storage.yaml after reboot

# TODO: Wrap up


```
