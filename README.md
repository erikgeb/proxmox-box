# Requirements

- ansible
- OpenTofu

Run `ansible-galaxy collection install -r requirements.yaml`

# How to run

After a fresh proxmox install, when you only have the root account and its password:

```
# Create a dedicated ssh key, with no passphrase for automations
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ansible -C "ansible-automation-key"

# You will need to add the host key fingerprint to known_hosts
ansible-playbook ansible/bootstrap/bootstrap_and_harden.yml -i '192.168.0.xxx,' -e "target_host=192.168.0.xxx" --ask-pass

# Add API user for Open Tofu
ansible-playbook ansible/bootstrap/harden_and_provision_api_user.yaml
cp secrets.auto.tfvars.example secrets.auto.tfvars
# edit secrets.auto.tfvars and add the newly created secret

# No longer show message about subscriptions - your browser cache may prevent seeing the change at first
ansible-playbook ansible/bootstrap/remove_nag_msg.yaml

# Warning: this will wipe the targeted disk
ansible-playbook ansible/bootstrap/setup_encrypted_disks.yaml -e "target_disk=/dev/sdX"

# Install open tofu and then initialize it in the project directory
tofu init

# Prepare variables for tofu
cp tofu.tfvars.example tofu.tfvars
# Edit file according to your configuration

## Pending confirmation
# Provision docker host
tofu apply

# TODO: Add ansible script to deploy ansible/resources/docker-compose.yml to docker host and apply it

# TODO: Add support to generate let's encrypt certificate with auto renew

# TODO: Configure VaultWarden host

# TODO: Validate ansible/unlock-storage.yaml after reboot

# TODO: Wrap up


```
