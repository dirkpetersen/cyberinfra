# Phase 6: Ansible Automation Framework

## Overview

This phase deploys Ansible on pve1-node1 as the control node, configures AWS SSM parameter integration, and creates the playbook framework for infrastructure-as-code management.

**Duration**: ~40 minutes
**Prerequisites**: Phase 1-5 complete, AWS SSM parameters populated, IAM role configured

---

## Step 1: Install Ansible on Control Node (pve1-node1)

```bash
# SSH to pve1-node1
ssh root@10.30.0.11

# Install Python and Ansible
apt-get update
apt-get install -y python3 python3-pip python3-venv git

# Create Ansible venv
python3 -m venv /opt/ansible-venv
source /opt/ansible-venv/bin/activate

# Install Ansible and AWS modules
pip install --upgrade pip
pip install ansible boto3 botocore

# Install Ansible collections
ansible-galaxy collection install amazon.aws

# Verify installation
ansible --version
```

---

## Step 2: Configure AWS Credentials

```bash
# Create AWS credentials file for Ansible
mkdir -p /root/.aws
cat > /root/.aws/credentials << 'EOF'
[default]
aws_access_key_id = YOUR_ACCESS_KEY
aws_secret_access_key = YOUR_SECRET_KEY
region = us-west-2
EOF

chmod 600 /root/.aws/credentials

# Or use IAM role (if running on AWS EC2 or with instance profile)
# Skip credentials file if using IAM role
```

---

## Step 3: Create Ansible Inventory

Create file: `/etc/ansible/hosts`

```ini
[pve_nodes]
pve1-node1 ansible_host=10.30.0.11 ansible_user=root
pve1-node2 ansible_host=10.30.0.12 ansible_user=root
pve1-node3 ansible_host=10.30.0.13 ansible_user=root

[pve_nodes:vars]
ansible_ssh_private_key_file=/root/.ssh/pve1_ansible_ed25519
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

[pve_control_node]
pve1-node1

[all:vars]
aws_region=us-west-2
ssm_parameter_root=/pve1
```

---

## Step 4: Create Ansible Playbook Directory Structure

```bash
# Create playbook directory structure
mkdir -p /root/pve1-playbooks/{roles,group_vars,host_vars,library}

# Structure:
# /root/pve1-playbooks/
# ├── site.yml                    # Main playbook
# ├── roles/
# │   ├── common/                 # Common configurations
# │   ├── network/                # Network configuration
# │   ├── storage/                # Ceph storage
# │   ├── gpu/                    # GPU configuration
# │   ├── monitoring/             # Prometheus/Grafana
# │   ├── backup/                 # PBS configuration
# │   └── ha/                     # HA configuration
# ├── group_vars/
# │   └── pve_nodes.yml           # Cluster-wide variables from SSM
# ├── host_vars/
# │   ├── pve1-node1.yml
# │   ├── pve1-node2.yml
# │   └── pve1-node3.yml
# ├── library/                    # Custom Ansible modules
# └── templates/                  # Jinja2 templates for configs
```

---

## Step 5: Create AWS SSM Lookup Integration

Create file: `/root/pve1-playbooks/library/ssm_param.py` (Custom Ansible module)

```python
#!/usr/bin/env python3

from ansible.module_utils.basic import AnsibleModule
import boto3
import json

def get_ssm_parameter(param_name, region):
    """Retrieve parameter from AWS SSM Parameter Store"""
    try:
        client = boto3.client('ssm', region_name=region)
        response = client.get_parameter(
            Name=param_name,
            WithDecryption=True
        )
        return response['Parameter']['Value']
    except Exception as e:
        return None

def main():
    module = AnsibleModule(
        argument_spec=dict(
            name=dict(required=True, type='str'),
            region=dict(default='us-west-2', type='str')
        )
    )

    param_name = module.params['name']
    region = module.params['region']

    value = get_ssm_parameter(param_name, region)

    if value is not None:
        module.exit_json(changed=False, value=value)
    else:
        module.fail_json(msg=f"Failed to retrieve parameter: {param_name}")

if __name__ == '__main__':
    main()
```

---

## Step 6: Create Group Variables from SSM

Create file: `/root/pve1-playbooks/group_vars/pve_nodes.yml`

```yaml
---
# Proxmox pve1 Cluster Variables
# These are fetched from AWS SSM Parameter Store at playbook runtime

# Network Configuration
network:
  vlan6:
    subnet: "{{ lookup('aws_ssm', '/pve1/network/vlan6/subnet') }}"
    gateway: "{{ lookup('aws_ssm', '/pve1/network/vlan6/gateway') }}"
    dns_servers: "{{ lookup('aws_ssm', '/pve1/network/dns_servers').split(',') }}"
  vlan_ids: [1, 2, 3, 4, 5, 6]

# Cluster Configuration
cluster:
  name: "{{ lookup('aws_ssm', '/pve1/cluster/name', default='pve1') }}"
  nodes: "{{ lookup('aws_ssm', '/pve1/cluster/nodes').split(',') }}"

# Storage Configuration
storage:
  ceph:
    pools:
      - name: rbd-vms
        size: "60%"
      - name: rbd-containers
        size: "30%"
      - name: cephfs-data
        size: "8%"
      - name: cephfs-metadata
        size: "2%"

# GPU Configuration
gpu:
  model: "NVIDIA A16"
  mig_enabled: true
  mig_profile: "3g.20gb"
  allocation:
    lxc: "2/3"
    vm: "1/3"

# Authentication
authentication:
  ad:
    domain: "{{ lookup('aws_ssm', '/pve1/authentication/ad/domain') }}"
    base_dn: "{{ lookup('aws_ssm', '/pve1/authentication/ad/base_dn') }}"

# Monitoring
monitoring:
  prometheus_retention: "30d"
  defender_xdr_enabled: true

# Weka Filesystem
weka:
  mount_path: "{{ lookup('aws_ssm', '/pve1/weka/mount_path', default='/mnt/weka') }}"
  export_path: "{{ lookup('aws_ssm', '/pve1/weka/export_path') }}"
```

---

## Step 7: Create Host Variables

Create file: `/root/pve1-playbooks/host_vars/pve1-node1.yml`

```yaml
---
# Node-specific configuration

node_name: pve1-node1
node_id: 1
vlan6_ip: "{{ lookup('aws_ssm', '/pve1/nodes/node1/vlan6_ip') }}"
ipmi_ip: "{{ lookup('aws_ssm', '/pve1/nodes/node1/ipmi_ip') }}"
```

Repeat for nodes 2 and 3 with appropriate node IDs.

---

## Step 8: Create Main Playbook

Create file: `/root/pve1-playbooks/site.yml`

```yaml
---
# Proxmox pve1 Main Playbook
# Orchestrates entire infrastructure deployment and management

- name: Configure Proxmox pve1 Cluster
  hosts: pve_nodes
  become: yes
  gather_facts: yes

  pre_tasks:
    - name: Retrieve parameters from AWS SSM
      debug:
        msg: "Loading configuration from AWS SSM for {{ ansible_host }}"

    - name: Test connectivity to all nodes
      ping:

  roles:
    - role: common
      tags: [common, always]

    - role: network
      tags: [network]
      when: configure_network | default(false)

    - role: storage
      tags: [storage, ceph]
      when: configure_storage | default(false)

    - role: gpu
      tags: [gpu, nvidia]
      when: configure_gpu | default(false)

    - role: ha
      tags: [ha]
      when: configure_ha | default(false)
      run_once: true

    - role: monitoring
      tags: [monitoring, prometheus]
      when: configure_monitoring | default(false)

    - role: backup
      tags: [backup, pbs]
      when: configure_backup | default(false)

  post_tasks:
    - name: Save deployment completion time
      shell: |
        aws ssm put-parameter \
          --name /pve1/deployment/last_run \
          --value "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --type String \
          --region us-west-2 \
          --overwrite
      delegate_to: pve1-node1
      run_once: true
```

---

## Step 9: Create Common Role

Create file: `/root/pve1-playbooks/roles/common/tasks/main.yml`

```yaml
---
# Common tasks for all nodes

- name: Update system packages
  apt:
    update_cache: yes
    upgrade: dist

- name: Install common tools
  apt:
    name:
      - git
      - curl
      - wget
      - vim
      - tmux
      - htop
      - net-tools
      - jq
      - awscli
    state: present

- name: Configure SSH hardening
  lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "^{{ item.key }}"
    line: "{{ item.key }} {{ item.value }}"
  loop:
    - { key: "PasswordAuthentication", value: "no" }
    - { key: "PermitRootLogin", value: "prohibit-password" }
    - { key: "PubkeyAuthentication", value: "yes" }
  notify: restart ssh

- name: Configure NTP
  lineinfile:
    path: /etc/chrony/chrony.conf
    regexp: "^pool"
    line: "pool {{ item }} iburst"
  loop: "{{ network.dns_servers }}"
  notify: restart chrony

- name: Set timezone to UTC
  timezone:
    name: UTC
```

---

## Step 10: Test Ansible Connectivity

```bash
# Test connectivity to all nodes
cd /root/pve1-playbooks
ansible pve_nodes -m ping

# Expected output:
# pve1-node1 | SUCCESS => {
#     "changed": false,
#     "ping": "pong"
# }
# pve1-node2 | SUCCESS => {...}
# pve1-node3 | SUCCESS => {...}

# Test SSM parameter lookup
ansible pve_nodes -m debug -a "msg={{ lookup('aws_ssm', '/pve1/nodes/node1/vlan6_ip') }}"
```

---

## Step 11: Create Playbook Repository (GitHub)

```bash
# Initialize local git repo
cd /root/pve1-playbooks
git init
git add .
git commit -m "Initial Proxmox pve1 Ansible playbooks"

# Push to GitHub (assumes repo created on GitHub)
git remote add origin https://github.com/your-org/pve1-playbooks.git
git branch -M main
git push -u origin main
```

---

## Step 12: Create Ansible Configuration

Create file: `/root/pve1-playbooks/ansible.cfg`

```ini
[defaults]
inventory = /etc/ansible/hosts
roles_path = /root/pve1-playbooks/roles
host_key_checking = False
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 86400
log_path = /var/log/ansible.log

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no
control_path = /tmp/ansible-ssh-%%h-%%p-%%r
pipelining = True
```

---

## Step 13: Create Deployment Automation Script

Create file: `/root/deploy.sh`

```bash
#!/bin/bash
set -e

# Deployment orchestration script for Proxmox pve1

PLAYBOOK_DIR="/root/pve1-playbooks"
LOG_DIR="/var/log/pve1-deployment"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p $LOG_DIR

echo "=== Proxmox pve1 Ansible Deployment ==="
echo "Timestamp: $TIMESTAMP"
echo "Playbook dir: $PLAYBOOK_DIR"

# Source Ansible venv
source /opt/ansible-venv/bin/activate

# Run playbook with tags
cd $PLAYBOOK_DIR

# Common configuration on all nodes
echo "[1/6] Running common configuration..."
ansible-playbook site.yml --tags common -i /etc/ansible/hosts | tee $LOG_DIR/phase-common-$TIMESTAMP.log

# Network configuration
echo "[2/6] Running network configuration..."
ansible-playbook site.yml --tags network -i /etc/ansible/hosts -e configure_network=true | tee $LOG_DIR/phase-network-$TIMESTAMP.log

# Ceph storage
echo "[3/6] Running Ceph storage deployment..."
ansible-playbook site.yml --tags storage -i /etc/ansible/hosts -e configure_storage=true | tee $LOG_DIR/phase-storage-$TIMESTAMP.log

# GPU configuration
echo "[4/6] Running GPU configuration..."
ansible-playbook site.yml --tags gpu -i /etc/ansible/hosts -e configure_gpu=true | tee $LOG_DIR/phase-gpu-$TIMESTAMP.log

# HA configuration
echo "[5/6] Running HA configuration..."
ansible-playbook site.yml --tags ha -i /etc/ansible/hosts -e configure_ha=true | tee $LOG_DIR/phase-ha-$TIMESTAMP.log

# Monitoring
echo "[6/6] Running monitoring setup..."
ansible-playbook site.yml --tags monitoring -i /etc/ansible/hosts -e configure_monitoring=true | tee $LOG_DIR/phase-monitoring-$TIMESTAMP.log

echo "=== Deployment Complete ==="
```

---

## Validation Checklist

- [ ] Ansible installed and in venv
- [ ] AWS credentials configured
- [ ] Ansible inventory correctly lists all 3 nodes
- [ ] `ansible pve_nodes -m ping` succeeds
- [ ] Playbook directory structure created
- [ ] AWS SSM parameter lookups work
- [ ] Group and host variables correctly reference SSM
- [ ] Main playbook syntax valid (`ansible-playbook --syntax-check site.yml`)
- [ ] Playbooks pushed to GitHub repository
- [ ] Deployment script is executable

---

## Next Steps

After Ansible framework:

1. Test individual playbook roles on one node first
2. Proceed to **Phase 7: HA Configuration and Redfish Fencing**

---

**Phase 6 Status**: [Start Date] - [Completion Date]
**Ansible Control Node**: pve1-node1 (operational)

