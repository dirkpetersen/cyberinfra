# Phase 10: Weka Filesystem Integration

## Overview

This phase mounts the external Weka filesystem on all Proxmox nodes after boot, configures quota management, and validates performance.

**Duration**: ~30 minutes
**Prerequisites**: Phase 1-9 complete, Weka cluster accessible and export configured

---

## Step 1: Verify Weka Cluster Accessibility

### Test Weka Network Connectivity

```bash
# From pve1-node1, test connectivity to Weka cluster

# Get Weka export details from AWS SSM
WEKA_EXPORT=$(aws ssm get-parameter --name /pve1/weka/export_path --query 'Parameter.Value' --output text --region us-west-2)
WEKA_PROTO=$(aws ssm get-parameter --name /pve1/weka/protocol --query 'Parameter.Value' --output text --region us-west-2)

# Extract IP from export path (format: IP:/export_path)
WEKA_IP=$(echo $WEKA_EXPORT | cut -d: -f1)

# Test connectivity
ping -c 3 $WEKA_IP

# Expected: Ping succeeds, latency < 1ms on 200G network

# Verify NFS/SMB service
if [ "$WEKA_PROTO" = "nfs" ]; then
    rpcinfo -p $WEKA_IP | grep nfs
fi
```

### Retrieve Weka Configuration from AWS SSM

```bash
# Get Weka mount parameters
WEKA_MOUNT_PATH=$(aws ssm get-parameter --name /pve1/weka/mount_path --query 'Parameter.Value' --output text --region us-west-2)
WEKA_EXPORT=$(aws ssm get-parameter --name /pve1/weka/export_path --query 'Parameter.Value' --output text --region us-west-2)
WEKA_PROTOCOL=$(aws ssm get-parameter --name /pve1/weka/protocol --query 'Parameter.Value' --output text --region us-west-2)
WEKA_OPTIONS=$(aws ssm get-parameter --name /pve1/weka/mount_options --query 'Parameter.Value' --output text --region us-west-2)

echo "Weka Config:"
echo "  Mount Path: $WEKA_MOUNT_PATH"
echo "  Export: $WEKA_EXPORT"
echo "  Protocol: $WEKA_PROTOCOL"
echo "  Options: $WEKA_OPTIONS"
```

---

## Step 2: Create Mount Point on All Nodes

```bash
# On each Proxmox node (pve1-node1, node2, node3)

# Create mount directory
mkdir -p /mnt/weka

# Set permissions
chmod 755 /mnt/weka

# Verify it's created
ls -la /mnt/weka
```

---

## Step 3: Install NFS/SMB Client Utilities

### For NFS Protocol

```bash
# Install NFS client utilities
apt-get install -y nfs-common portmap

# Verify installation
which mount.nfs
rpcinfo -p localhost
```

### For SMB/CIFS Protocol

```bash
# Install CIFS utilities
apt-get install -y cifs-utils

# Verify installation
which mount.cifs
```

---

## Step 4: Manual Mount Test

```bash
# Test mount on one node first

# Get credentials from AWS SSM (if needed for authentication)
WEKA_USERNAME=$(aws ssm get-parameter --name /pve1/weka/username --query 'Parameter.Value' --output text --region us-west-2 2>/dev/null || echo "")
WEKA_PASSWORD=$(aws ssm get-parameter --name /pve1/weka/password --query 'Parameter.Value' --output text --with-decryption --region us-west-2 2>/dev/null || echo "")

# Mount Weka filesystem (NFS example)
mount -t nfs $WEKA_EXPORT /mnt/weka -o $WEKA_OPTIONS

# Verify mount
df -h /mnt/weka
mount | grep weka

# Create test file
touch /mnt/weka/test-$(hostname)-$(date +%s)

# List files
ls -la /mnt/weka/

# Unmount for now
umount /mnt/weka
```

---

## Step 5: Configure Persistent Mount via /etc/fstab

### Create Weka Mount Entry

On each Proxmox node:

```bash
# Get Weka export and options
WEKA_EXPORT=$(aws ssm get-parameter --name /pve1/weka/export_path --query 'Parameter.Value' --output text --region us-west-2)
WEKA_OPTIONS=$(aws ssm get-parameter --name /pve1/weka/mount_options --query 'Parameter.Value' --output text --region us-west-2)
WEKA_MOUNT="/mnt/weka"

# Add to /etc/fstab
cat >> /etc/fstab << EOF
# Weka filesystem mount (added during deployment Phase 10)
$WEKA_EXPORT $WEKA_MOUNT nfs $WEKA_OPTIONS,_netdev,x-systemd.automount,x-systemd.idle-timeout=30min 0 0
EOF

# View fstab
cat /etc/fstab | grep weka
```

### Alternative: Use Systemd Mount Unit (Recommended)

Create file: `/etc/systemd/system/mnt-weka.mount`

```ini
[Unit]
Description=Weka Filesystem Mount
After=network-online.target
Wants=network-online.target

[Mount]
What=WEKA_EXPORT
Where=/mnt/weka
Type=nfs
Options=vers=3,hard,intr,timeo=600,rsize=1048576,wsize=1048576,bg
TimeoutSec=30

[Install]
WantedBy=multi-user.target
```

Replace `WEKA_EXPORT` with actual value:

```bash
WEKA_EXPORT=$(aws ssm get-parameter --name /pve1/weka/export_path --query 'Parameter.Value' --output text --region us-west-2)
sed -i "s|WEKA_EXPORT|$WEKA_EXPORT|" /etc/systemd/system/mnt-weka.mount

# Enable automount
systemctl daemon-reload
systemctl enable mnt-weka.mount
systemctl start mnt-weka.mount

# Verify
systemctl status mnt-weka.mount
```

---

## Step 6: Verify Mount on All Nodes

```bash
# On each node, verify Weka is mounted

for node in pve1-node1 pve1-node2 pve1-node3; do
    node_ip=$(echo $node | grep -o '[0-9]*$' | xargs -I{} echo "10.30.0.$((10 + {}))")

    echo "=== Checking $node ==="
    ssh root@$node_ip "df -h /mnt/weka && mount | grep weka"
done

# Expected: All nodes show Weka filesystem mounted at /mnt/weka
```

---

## Step 7: Configure Quota Management (Optional)

### Enable Weka Quotas

```bash
# If Weka cluster supports quotas, enable per-node limits

# Set quota for VM storage (e.g., 2TB per node)
# Format depends on Weka API, example:

# Via Weka CLI (if available):
# weka filesystem quota set --path /vms --quota 2TB

# Or manually limit directory size (less reliable):
# Create soft limit using quotactl (if supported by Weka NFS)
```

### Monitor Quota Usage

```bash
# Create monitoring script for Weka space usage

cat > /usr/local/bin/check-weka-space.sh << 'EOF'
#!/bin/bash

WEKA_PATH="/mnt/weka"
THRESHOLD=80  # Alert if usage > 80%

if ! mountpoint -q $WEKA_PATH; then
    echo "ERROR: Weka filesystem not mounted"
    exit 1
fi

# Get usage percentage
USAGE=$(df $WEKA_PATH | tail -1 | awk '{print int($5)}')
AVAILABLE=$(df -B1 $WEKA_PATH | tail -1 | awk '{print $4}')
USED=$(df -B1 $WEKA_PATH | tail -1 | awk '{print $3}')

echo "Weka filesystem usage: ${USAGE}% (Used: ${USED} bytes, Available: ${AVAILABLE} bytes)"

if [ $USAGE -gt $THRESHOLD ]; then
    echo "WARNING: Weka filesystem above ${THRESHOLD}% - consider cleanup"
    # Send alert
    exit 1
fi

exit 0
EOF

chmod +x /usr/local/bin/check-weka-space.sh

# Add to cron
echo "0 * * * * /usr/local/bin/check-weka-space.sh >> /var/log/weka-space.log" | crontab -
```

---

## Step 8: Configure VM/Container Storage on Weka

### Create Storage Pool in Proxmox (Optional)

If Weka exports to mount point that Proxmox can use:

```bash
# Create directory storage pointing to Weka mount
pvesh set /storage/weka-vms \
    --type dir \
    --content images,rootdir \
    --path /mnt/weka/vms \
    --disabled 0 \
    --maxfiles 0

# Verify storage added
pvesh get /storage | grep weka

# Create VM storage directories
mkdir -p /mnt/weka/vms
mkdir -p /mnt/weka/containers
mkdir -p /mnt/weka/iso
mkdir -p /mnt/weka/backup

# Set permissions
chown -R root:root /mnt/weka/*
chmod 755 /mnt/weka/*
```

### Alternative: Use Weka for High-Performance Workloads

```bash
# Mount Weka for specific high-performance workloads
# (e.g., ML training, rendering, data processing)

# Create workspace on Weka
mkdir -p /mnt/weka/workspace

# Symlink to common location
ln -s /mnt/weka/workspace /var/lib/workspace

# Document for users where to store high-I/O workloads
echo "High-performance storage: /mnt/weka/workspace" > /etc/issue.local
```

---

## Step 9: Performance Testing

### Benchmark Weka Performance

```bash
# Test Weka read/write performance

# Install benchmark tools
apt-get install -y fio iozone

# Sequential read test
fio --name=sequential-read \
    --filename=/mnt/weka/test-file \
    --rw=read \
    --bs=1m \
    --size=10g \
    --numjobs=4 \
    --runtime=60

# Sequential write test
fio --name=sequential-write \
    --filename=/mnt/weka/test-file \
    --rw=write \
    --bs=1m \
    --size=10g \
    --numjobs=4 \
    --runtime=60

# Expected: Near line-rate performance on 200G network
```

### Document Baseline Performance

```bash
# Record performance metrics to AWS SSM

WEKA_READ_BW=120000  # MB/s example
WEKA_WRITE_BW=110000  # MB/s example
WEKA_LATENCY=0.5  # ms example

aws ssm put-parameter \
    --name /pve1/weka/baseline_read_bw_mbps \
    --value "$WEKA_READ_BW" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/weka/baseline_write_bw_mbps \
    --value "$WEKA_WRITE_BW" \
    --type String \
    --region us-west-2 \
    --overwrite
```

---

## Step 10: Failover and Redundancy Testing

### Test Weka Export Failover

```bash
# If Weka has multiple export endpoints:

# Simulate export failure (if supported)
# Verify automatic failover to alternate export

# Check mount point recovery
mountpoint /mnt/weka
while [ $? -ne 0 ]; do
    echo "Weka unmounted, waiting for remount..."
    sleep 5
    mountpoint /mnt/weka
done

echo "Weka remounted successfully"
```

### Monitor Mount Persistence

```bash
# Create monitoring check for mount health

cat > /usr/local/bin/check-weka-mount.sh << 'EOF'
#!/bin/bash

WEKA_PATH="/mnt/weka"

if ! mountpoint -q $WEKA_PATH; then
    echo "CRITICAL: Weka filesystem not mounted"
    # Send alert
    # Auto-remount attempt
    mount -a
    sleep 5
    if mountpoint -q $WEKA_PATH; then
        echo "Weka remounted successfully"
    else
        echo "CRITICAL: Weka remount failed"
    fi
else
    echo "OK: Weka filesystem mounted"
fi
EOF

chmod +x /usr/local/bin/check-weka-mount.sh

# Add to monitoring
echo "*/5 * * * * /usr/local/bin/check-weka-mount.sh" | crontab -
```

---

## Step 11: Save Weka Configuration to AWS SSM

```bash
# Verify and save Weka configuration

WEKA_MOUNTED=$(mountpoint -q /mnt/weka && echo "true" || echo "false")
WEKA_SPACE=$(df -h /mnt/weka | tail -1 | awk '{print $2}')

aws ssm put-parameter \
    --name /pve1/weka/mounted \
    --value "$WEKA_MOUNTED" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/weka/total_space \
    --value "$WEKA_SPACE" \
    --type String \
    --region us-west-2 \
    --overwrite

echo "Weka configuration saved to AWS SSM"
```

---

## Validation Checklist

- [ ] Weka cluster accessible from all Proxmox nodes
- [ ] Mount point /mnt/weka created on all nodes
- [ ] NFS/CIFS utilities installed
- [ ] Manual mount test successful
- [ ] Persistent mount configured in /etc/fstab or systemd
- [ ] All 3 nodes show Weka mounted
- [ ] Read/write performance baseline documented
- [ ] Quota monitoring configured (if applicable)
- [ ] Failover test successful
- [ ] Mount status monitored

---

## Next Steps

After Weka integration:

1. Create test VMs/containers on Weka storage
2. Monitor performance during normal workloads
3. Proceed to **Phase 11: Testing and Validation**

---

**Phase 10 Status**: [Start Date] - [Completion Date]
**Weka Integration**: OPERATIONAL (mounted on all nodes)

