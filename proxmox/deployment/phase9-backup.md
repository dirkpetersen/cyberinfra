# Phase 9: Backup Infrastructure (PBS + S3)

## Overview

This phase deploys Proxmox Backup Server (PBS) as a VM on the cluster and configures it to use external S3-compatible Ceph storage for backup snapshots.

**Duration**: ~60 minutes
**Prerequisites**: Phase 1-8 complete, S3 credentials available

---

## Step 1: Create PBS VM

### Create PBS Virtual Machine

```bash
# SSH to pve1-node1
ssh root@10.30.0.11

# Create VM (VMID 500)
qm create 500 \
    --name pbs-server \
    --memory 16384 \
    --cores 8 \
    --sockets 1 \
    --scsihw virtio-scsi-pci \
    --net0 virtio,bridge=vmbr0,tag=1 \
    --storage local-lvm

# Add boot drive from Ceph
qm set 500 \
    --scsi0 pve1-rbd-vms:vm-500-disk-0,size=100G,cache=writethrough

# Add data drive for backup cache
qm set 500 \
    --scsi1 pve1-rbd-vms:vm-500-backup-cache,size=500G,cache=writethrough

# Set boot options
qm set 500 --boot order=scsi0

# Start VM
qm start 500

# Wait for boot and install OS (Debian 12 recommended for PBS)
```

### Install PBS

Inside PBS VM:

```bash
# Add PBS repository
apt-get update
apt-get install -y software-properties-common

# Add Proxmox repo (same as Proxmox nodes)
echo "deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription" > /etc/apt/sources.list.d/pbs.list
apt-get update

# Install PBS
apt-get install -y proxmox-backup-server proxmox-backup-docs

# Start PBS
systemctl enable proxmox-backup
systemctl start proxmox-backup

# Access: https://pbs-ip:8007 (default admin/password)
```

---

## Step 2: Configure PBS with S3 Backend

### Create S3 Storage Configuration

In PBS web UI or via API:

```bash
# SSH to PBS VM and configure S3 storage

# Get S3 credentials from AWS SSM
S3_ENDPOINT=$(aws ssm get-parameter --name /pve1/backup/s3_endpoint --query 'Parameter.Value' --output text --region us-west-2)
S3_BUCKET=$(aws ssm get-parameter --name /pve1/backup/s3_bucket --query 'Parameter.Value' --output text --region us-west-2)
S3_ACCESS_KEY=$(aws ssm get-parameter --name /pve1/backup/s3_access_key --query 'Parameter.Value' --output text --with-decryption --region us-west-2)
S3_SECRET_KEY=$(aws ssm get-parameter --name /pve1/backup/s3_secret_key --query 'Parameter.Value' --output text --with-decryption --region us-west-2)

# Create storage via API
curl -X POST https://localhost:8007/api2/json/storage \
    -H "Authorization: Bearer $(proxmox-backup-client login)" \
    -H "Content-Type: application/json" \
    -d "{
        \"store\": \"s3-backup\",
        \"type\": \"s3\",
        \"bucket\": \"$S3_BUCKET\",
        \"endpoint\": \"$S3_ENDPOINT\",
        \"access-key\": \"$S3_ACCESS_KEY\",
        \"secret-key\": \"$S3_SECRET_KEY\",
        \"disable\": false
    }"
```

### Alternative: Create Datastore via Configuration File

Edit `/etc/proxmox-backup/datastore.cfg`:

```ini
datastore: s3-backup
    path /mnt/backups-s3

storage: s3-backup
    type s3
    bucket pve1-backups
    endpoint https://s3.example.com
    access-key ACCESS_KEY
    secret-key SECRET_KEY
    verify-tls 1
```

---

## Step 3: Configure PBS Backup Policies

### Create Backup Job Template

```bash
# SSH to Proxmox node (pve1-node1)

# Create backup job configuration for Proxmox cluster

cat > /etc/proxmox/backup-jobs.conf << 'EOF'
# Proxmox Backup Jobs Configuration

# Backup job for VMs
[vm-backup]
enabled: 1
target: pbs-server
datastore: s3-backup
schedule: daily
time: 02:00  # 2 AM UTC
mode: snapshot
retention: 30d
retention_archive: 90d

# Backup job for LXC containers
[lxc-backup]
enabled: 1
target: pbs-server
datastore: s3-backup
schedule: daily
time: 03:00  # 3 AM UTC
mode: snapshot
retention: 30d
retention_archive: 90d

# Backup job for cluster configuration
[config-backup]
enabled: 1
target: pbs-server
datastore: s3-backup
schedule: weekly
time: 01:00  # 1 AM UTC every Sunday
retention: 90d
EOF
```

### Configure Retention Policies

In PBS web UI:

1. **Settings > Datastore > s3-backup > Edit**
2. Set retention:
   - Daily backups: 30 days
   - Weekly backups: 90 days
   - Monthly archives: 1 year

### Create Backup Groups

```bash
# Group VMs by type for better organization

# Critical VMs (e.g., PBS, monitoring)
proxmox-backup-client backup vm:100,vm:200,vm:201 --backup-id critical-vms

# Standard VMs
proxmox-backup-client backup vm:300,vm:301 --backup-id standard-vms

# Infrastructure containers
proxmox-backup-client backup lxc:100,lxc:200 --backup-id infra-containers
```

---

## Step 4: Configure Proxmox Nodes for PBS Integration

### Add PBS as Backup Target in Proxmox

On each Proxmox node:

```bash
# Configure PBS in Proxmox

pvesh set /nodes/pve1-node1/config \
    --backup-server pbs-server \
    --backup-datastore s3-backup

# Alternatively, edit config directly
cat >> /etc/pve/datacenter.cfg << 'EOF'
backup-server: pbs-server:8007
backup-user: admin@pam
backup-datastore: s3-backup
backup-retention-days: 30
EOF
```

### Create Backup Script (Ansible playbook)

Create `/root/pve1-playbooks/roles/backup/tasks/main.yml`:

```yaml
---
# Backup configuration tasks

- name: Configure PBS datastore
  uri:
    url: "https://{{ pbs_server }}/api2/json/datastore"
    method: POST
    user: "{{ pbs_user }}"
    password: "{{ pbs_password }}"
    validate_certs: no
    body_format: json
    body:
      store: s3-backup
      type: s3
      bucket: "{{ s3_bucket }}"
      endpoint: "{{ s3_endpoint }}"
      access-key: "{{ s3_access_key }}"
      secret-key: "{{ s3_secret_key }}"

- name: Create backup jobs
  lineinfile:
    path: /etc/proxmox/backup-jobs.conf
    state: present
    line: "{{ item }}"
  loop: "{{ backup_jobs }}"

- name: Start backup jobs
  command: "proxmox-backup-client backup {{ item.resources }} --backup-id {{ item.id }}"
  loop: "{{ backup_jobs }}"
```

---

## Step 5: Test Backup Functionality

### Manual Backup Test

```bash
# On pbs-server VM or via Proxmox node

# Create test backup
proxmox-backup-client backup vm:100 \
    --datastore s3-backup \
    --backup-id test-vm-100 \
    --verbose

# Monitor backup progress
proxmox-backup-client status

# List backups
proxmox-backup-client list

# Expected output shows backup archive created
```

### Verify S3 Storage

```bash
# Verify backups stored in S3

# Using AWS CLI (if S3 is AWS S3)
aws s3 ls s3://pve1-backups/

# Or using S3 CLI tool
s3cmd ls s3://pve1-backups/

# Should show backup archive files
```

---

## Step 6: Configure Backup Retention and Pruning

### Automatic Cleanup Policy

```bash
# Configure PBS pruning job

cat > /etc/cron.d/pbs-prune << 'EOF'
# Proxmox Backup Server - Automatic pruning

# Daily at 4 AM UTC - prune backups older than retention
0 4 * * * root proxmox-backup-client prune --backup-group vm --keep-last 30 --keep-monthly 3 >> /var/log/pbs-prune.log 2>&1

# Weekly at 5 AM UTC on Sunday - archive old backups
0 5 * * 0 root proxmox-backup-client prune --backup-group vm --keep-monthly 12 --keep-yearly 3 >> /var/log/pbs-prune.log 2>&1
EOF

chmod 0644 /etc/cron.d/pbs-prune
```

### Monitor Disk Space

```bash
# Create monitoring check for backup storage

cat > /usr/local/bin/check-backup-space.sh << 'EOF'
#!/bin/bash

# Check S3 backup storage usage

THRESHOLD=80  # Alert if usage > 80%

S3_SIZE=$(aws s3 ls s3://pve1-backups --recursive --summarize | grep "Total Size" | awk '{print $3}')
S3_QUOTA=10737418240000  # 10TB in bytes
USAGE_PERCENT=$((S3_SIZE * 100 / S3_QUOTA))

if [ $USAGE_PERCENT -gt $THRESHOLD ]; then
    echo "WARNING: Backup storage at ${USAGE_PERCENT}% capacity"
    # Send alert to monitoring system
else
    echo "OK: Backup storage at ${USAGE_PERCENT}% capacity"
fi
EOF

chmod +x /usr/local/bin/check-backup-space.sh

# Add to cron
echo "0 * * * * /usr/local/bin/check-backup-space.sh" | crontab -
```

---

## Step 7: Configure Backup Notifications

### Email Alerts

```bash
# Configure PBS email alerts

cat > /etc/proxmox-backup/notifications.cfg << 'EOF'
# Notifications configuration

[email]
enabled: 1
smtp-server: smtp.example.com
smtp-port: 587
smtp-user: backups@example.com
smtp-password: PASSWORD
from-address: pbs-server@example.com
to-addresses: ops@example.com

[backup-complete]
enabled: 1
channels: email
include-details: yes

[backup-failed]
enabled: 1
channels: email
include-details: yes
EOF
```

### Prometheus Metrics Export

```bash
# Export backup metrics to Prometheus

cat > /etc/proxmox-backup/metrics-export.conf << 'EOF'
# Metrics export configuration

prometheus-enabled: 1
prometheus-path: /metrics
prometheus-port: 9100
EOF

systemctl restart proxmox-backup
```

---

## Step 8: Implement Disaster Recovery Procedures

### Backup Verification Procedures

```bash
# Script to verify backup integrity

cat > /usr/local/bin/verify-backups.sh << 'EOF'
#!/bin/bash

# Verify recent backups

DATASTORE="s3-backup"
DAYS=7

echo "Verifying backups from last $DAYS days..."

proxmox-backup-client list --datastore $DATASTORE | while read backup; do
    echo "Checking $backup..."

    # Verify backup files
    proxmox-backup-client verify --datastore $DATASTORE --backup-id $backup

    if [ $? -eq 0 ]; then
        echo "✓ $backup - VALID"
    else
        echo "✗ $backup - FAILED"
        # Alert on failure
    fi
done
EOF

chmod +x /usr/local/bin/verify-backups.sh
```

### Restore Testing Schedule

```bash
# Monthly restore test on non-production resources

cat > /root/restore-test.sh << 'EOF'
#!/bin/bash

# Test restore from backup (to temporary VM)

# Get most recent backup
BACKUP=$(proxmox-backup-client list | tail -1 | awk '{print $1}')

# Create temporary test VM
TEST_VMID=9999
qm create $TEST_VMID \
    --name pve-restore-test \
    --memory 4096 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0

# Restore from backup
proxmox-backup-client restore $BACKUP vm-disk --to-stdout | qm importdisk $TEST_VMID /dev/stdin local-lvm

# Boot test VM and verify
qm start $TEST_VMID

echo "Restore test VM $TEST_VMID created. Verify and delete when done."
EOF

chmod +x /root/restore-test.sh

# Schedule monthly
echo "0 0 1 * * /root/restore-test.sh" | crontab -
```

---

## Step 9: Save Backup Configuration to AWS SSM

```bash
# Save backup configuration

PBS_CONFIG=$(proxmox-backup-client get-repository-config)

aws ssm put-parameter \
    --name /pve1/backup/pbs_server \
    --value "pbs-server:8007" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/backup/datastore \
    --value "s3-backup" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/backup/retention_days \
    --value "30" \
    --type String \
    --region us-west-2 \
    --overwrite

echo "Backup configuration saved to AWS SSM"
```

---

## Validation Checklist

- [ ] PBS VM created and running
- [ ] PBS web interface accessible
- [ ] S3 datastore configured in PBS
- [ ] Proxmox integrated with PBS
- [ ] Test backup created successfully
- [ ] Backup visible in S3 storage
- [ ] Pruning jobs scheduled
- [ ] Backup notifications configured
- [ ] Restore test completed successfully
- [ ] Backup metrics exported to Prometheus

---

## Next Steps

After backup:

1. Verify backup jobs run on schedule
2. Monitor backup duration and storage growth
3. Proceed to **Phase 10: Weka Filesystem Integration**

---

**Phase 9 Status**: [Start Date] - [Completion Date]
**Backup Infrastructure**: OPERATIONAL (PBS + S3)

