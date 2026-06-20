# Requirements

- ansible
- 

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


```
