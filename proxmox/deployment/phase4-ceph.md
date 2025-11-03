# Phase 4: Ceph Storage Deployment

## Overview

This phase deploys a replicated Ceph cluster across the 3 Proxmox nodes, creates storage pools (rbd-vms, rbd-containers, cephfs-data, cephfs-metadata), and validates functionality.

**Duration**: ~60 minutes
**Prerequisites**: Phase 1-3 complete, cluster operational, all 12x 7.68TB NVMe SSDs visible per node

---

## Ceph Architecture

```
3-Node Ceph Flash Pool (All NVMe SSDs)
├── 12 OSDs per node (36 total)
├── Replication factor: 3 (min_size: 2)
├── Placement groups calculated for high IOPS
└── Pools:
    ├── rbd-vms (60%) - VM disk images
    ├── rbd-containers (30%) - LXC container disks
    ├── cephfs-data (8%) - Shared files
    └── cephfs-metadata (2%) - File metadata (SSD-optimized)
```

---

## Step 1: Prepare Data SSDs for Ceph

### Identify Data SSDs

On each node, identify the 12 data SSDs:

```bash
# SSH to pve1-node1
ssh root@10.30.0.11

# List NVMe devices
lsblk | grep nvme

# Expected output:
# nvme0n1 - Boot drive 1 (Micron 7450, 480GB, part of ZFS mirror)
# nvme1n1 - Boot drive 2 (Micron 7450, 480GB, part of ZFS mirror)
# nvme2n1 through nvme13n1 - Data SSDs (7.68TB each, for Ceph)

# Total: 14 NVMe devices (2 boot + 12 data)

# Get detailed info
nvme list

# Expected for data SSDs:
# Capacity: 7.68TB
# Model: (Micron/Western Digital/Intel model for 7.68TB NVMe)
# Wearout: Should show 100% (0 DWPD)
```

### Wipe Data SSDs (Destructive - Be Careful!)

```bash
# WARNING: This removes all data on the SSDs

for i in {2..13}; do
    DEV="/dev/nvme${i}n1"
    echo "Wiping $DEV..."

    # Option 1: Quick wipe (secure erase if supported)
    nvme format -s 0 -f $DEV  # -s 0 selects OACS for secure erase

    # Option 2: If secure erase not available, use dd
    # This is slower but more compatible
    # dd if=/dev/zero of=$DEV bs=1M count=1024 oflag=direct

    echo "$DEV wiped"
done

# Verify devices are clean
lsblk | grep nvme
```

---

## Step 2: Deploy Ceph MON (Monitors)

Ceph Monitors (MONs) manage cluster state. We'll deploy 1 MON per node for redundancy.

### Bootstrap First MON (pve1-node1)

```bash
# On pve1-node1

# Create Ceph cluster bootstrap directory
mkdir -p /etc/ceph

# Generate initial MON key and cluster info
# Proxmox has helper scripts for this

# Option A: Use Proxmox Ceph deployment (recommended)
# Navigate to Proxmox web UI or use CLI:

# Create initial cluster
pveceph init --cluster-name pve1

# Set MON address
pveceph add_mon_node pve1-node1

# Verify MON started
systemctl status ceph-mon@pve1-node1
ceph -s
```

### Add MONs to Node 2 and 3

```bash
# From pve1-node1, add MONs to other nodes

# Add node2 MON
pveceph add_mon_node pve1-node2

# Add node3 MON
pveceph add_mon_node pve1-node3

# Verify all 3 MONs active
ssh root@10.30.0.12 "systemctl status ceph-mon@pve1-node2"
ssh root@10.30.0.13 "systemctl status ceph-mon@pve1-node3"

# Check cluster quorum
ceph quorum_status

# Expected: 3 MONs, quorum active
```

---

## Step 3: Deploy Ceph OSDs (Object Storage Daemons)

Each data SSD becomes a separate OSD:

```bash
# On pve1-node1, deploy OSDs for all 12 data drives
# Using Proxmox CLI helper

for i in {2..13}; do
    DEV="/dev/nvme${i}n1"

    # Create OSD
    pveceph osd create $DEV --crush_device_class ssd

    echo "OSD created for $DEV"
done

# Verify all 12 OSDs created
ceph osd tree | grep pve1-node1

# Expected: 12 OSDs per node
```

### Deploy OSDs on Node 2 and 3

Repeat OSD creation on pve1-node2 and pve1-node3:

```bash
# This can be done in parallel via Ansible or manually via SSH

# From pve1-node1, remote SSH:
for node in pve1-node2 pve1-node3; do
    node_ip=$(grep "$node" /etc/hosts | awk '{print $1}')

    ssh root@$node_ip "
        for i in {2..13}; do
            DEV=/dev/nvme\${i}n1
            pveceph osd create \$DEV --crush_device_class ssd
        done
    "
done

# Verify all OSDs
ceph osd tree

# Expected output shows 36 OSDs total (3 nodes × 12 OSDs)
```

---

## Step 4: Monitor OSD Peering

After OSDs created, Ceph performs peering (synchronization):

```bash
# Monitor cluster status during peering
watch -n 1 'ceph status'

# Expected progression:
# - Health: HEALTH_WARN (during peering)
#   OSD status: peering
#   PGs: many remapped
#
# After 5-15 minutes:
# - Health: HEALTH_OK
#   OSDs: 36 up, 36 in
#   PGs: active+clean

# Check specific PG status
ceph pg stat
```

---

## Step 5: Deploy Ceph MGR (Manager)

Managers provide cluster monitoring and management:

```bash
# Deploy MGR on each node (1 MON + 1 MGR per node is typical)

pveceph mgr_create

# This should deploy MGRs on all 3 nodes automatically

# Verify MGRs active
ceph mgr stat

# Enable dashboard (optional, useful for monitoring)
ceph mgr module enable dashboard
# Note: Proxmox web UI already includes Ceph integration
```

---

## Step 6: Configure CRUSH Rules for SSD Pool

By default, Ceph uses generic CRUSH rules. For SSD-only pool, optimize placement:

```bash
# View current CRUSH rules
ceph osd crush rule ls

# Create SSD-specific rule (if needed)
# This ensures data distributed across SSDs only (already enforced by device class)

# Check device class assignment
ceph osd crush class ls

# Verify all OSDs marked as 'ssd'
ceph osd crush tree
```

---

## Step 7: Create Ceph Pools

### Create rbd-vms Pool (60% capacity)

```bash
# Calculate PG count
# PGs should be: (OSDs × 100) / replication_factor = (36 × 100) / 3 = 1200
# Typically use power of 2 closest to this: 1024 or 2048

# Create VM pool (60% of total)
ceph osd pool create rbd-vms 1024 1024 replicated

# Set application type
ceph osd pool application enable rbd-vms rbd

# Set replica count
ceph osd pool set rbd-vms size 3
ceph osd pool set rbd-vms min_size 2

# Optional: Enable cache tiering or compression (advanced)
# Skip for now, can be added later

# Verify pool
ceph osd pool ls
ceph osd pool get rbd-vms all
```

### Create rbd-containers Pool (30% capacity)

```bash
ceph osd pool create rbd-containers 512 512 replicated
ceph osd pool application enable rbd-containers rbd
ceph osd pool set rbd-containers size 3
ceph osd pool set rbd-containers min_size 2
```

### Create CephFS Data and Metadata Pools (8% + 2%)

CephFS requires separate data and metadata pools:

```bash
# Metadata pool (2%, but SSD optimized)
ceph osd pool create cephfs-metadata 256 256 replicated
ceph osd pool set cephfs-metadata size 3
ceph osd pool set cephfs-metadata min_size 2

# Data pool (8%)
ceph osd pool create cephfs-data 512 512 replicated
ceph osd pool set cephfs-data size 3
ceph osd pool set cephfs-data min_size 2

# Create CephFS filesystem
ceph fs new pve1-fs cephfs-metadata cephfs-data

# Verify filesystem created
ceph fs ls
ceph mds stat
```

---

## Step 8: Deploy Ceph MDS (Metadata Server)

MDS handles CephFS metadata operations:

```bash
# Deploy MDS on all 3 nodes (for redundancy)
for node in pve1-node1 pve1-node2 pve1-node3; do
    pveceph mds_create $node
done

# Verify MDS status
ceph mds stat

# Expected: at least 1 MDS active, others standby
```

---

## Step 9: Configure Proxmox to Use Ceph Pools

### Add Ceph Storage to Proxmox

```bash
# In Proxmox web UI or via CLI:
# Datacenter > Storage > Add > RBD

# Pool: rbd-vms
# Storage ID: pve1-rbd-vms
# Username: admin
# Keyring: (auto-detected)

# Repeat for rbd-containers pool

# Via CLI:
pvesh set /storage/pve1-rbd-vms --type rbd --content images,rootdir --pool rbd-vms
pvesh set /storage/pve1-rbd-containers --type rbd --content images,rootdir --pool rbd-containers
```

### Verify Storage in Proxmox

```bash
# List configured storage
pvesh get /storage

# Should show rbd-vms and rbd-containers with correct capacity
```

---

## Step 10: Validate Ceph Cluster Health

```bash
# Full cluster status
ceph status

# Expected output:
#   cluster:
#     id:     <cluster-id>
#     health: HEALTH_OK
#
#   services:
#     mon: 3 daemons, quorum pve1-node1,pve1-node2,pve1-node3 (age 5m)
#     mgr: pve1-node1(active, since 5m), pve1-node2(standby), pve1-node3(standby)
#     osd: 36 osds: 36 up (since 5m), 36 in (since 5m)
#     mds: pve1-fs:1 up:active, 2 up:standby
#
#   data:
#     pools:   4 pools, X pgs
#     objects: 0 objects, 0 B
#     usage:   0 B used, X TB / X TB avail
#     pgs:     X active+clean

# Detailed check
ceph health detail

# Should show no warnings or errors
```

---

## Step 11: Test Ceph Functionality

### Create Test RBD Image

```bash
# Create 1GB test image in rbd-vms pool
rbd create test-image --size 1G --pool rbd-vms

# List images
rbd ls -p rbd-vms

# Map image to filesystem
rbd map test-image -p rbd-vms  # Returns device path, e.g., /dev/rbd0

# Format and mount
mkfs.ext4 /dev/rbd0
mkdir -p /mnt/test-rbd
mount /dev/rbd0 /mnt/test-rbd

# Test write/read
dd if=/dev/zero of=/mnt/test-rbd/test-file bs=1M count=100
dd if=/mnt/test-rbd/test-file of=/dev/null bs=1M

# Measure performance
# Should see > 2GB/s on 200G network with 12 SSDs per node

# Cleanup
umount /mnt/test-rbd
rbd unmap /dev/rbd0
rbd rm test-image -p rbd-vms
```

### Test CephFS

```bash
# Mount CephFS
mkdir -p /mnt/pve1-fs

# Get mon addresses
MONS=$(ceph-conf --lookup 'mon_host' | tr ',' ' ')

# Mount
mount -t ceph :/ /mnt/pve1-fs \
  -o name=admin,secretfile=/etc/ceph/ceph.client.admin.keyring,mds_namespace=pve1-fs

# Test write
dd if=/dev/zero of=/mnt/pve1-fs/test-file bs=1M count=100

# Verify on another node
ssh root@10.30.0.12 "mount -t ceph :/ /mnt/pve1-fs -o name=admin,secretfile=/etc/ceph/ceph.client.admin.keyring,mds_namespace=pve1-fs && ls -lh /mnt/pve1-fs/"

# Cleanup
umount /mnt/pve1-fs
```

---

## Step 12: Save Ceph Configuration to AWS SSM

```bash
# Save critical Ceph parameters

FSID=$(ceph fsid)
ADMIN_KEY=$(ceph auth get client.admin)
MON_IPS=$(ceph mon dump | grep addr | awk '{print $3}' | tr '\n' ',' | sed 's/,$//')

# Save to SSM
aws ssm put-parameter --name /pve1/ceph/fsid --value "$FSID" --type String --region us-west-2 --overwrite
aws ssm put-parameter --name /pve1/ceph/mon_ips --value "$MON_IPS" --type String --region us-west-2 --overwrite
aws ssm put-parameter --name /pve1/ceph/admin_key --value "$ADMIN_KEY" --type SecureString --region us-west-2 --overwrite

echo "Ceph configuration saved to AWS SSM"
```

---

## Validation Checklist

- [ ] All 36 OSDs (12 per node) initialized and active
- [ ] Ceph health status is HEALTH_OK
- [ ] All 3 MON quorum active
- [ ] MGR and MDS services running
- [ ] 4 pools created (rbd-vms, rbd-containers, cephfs-data, cephfs-metadata)
- [ ] RBD pool can be mapped and read/write tested
- [ ] CephFS can be mounted and accessed
- [ ] Ceph configuration saved to AWS SSM
- [ ] PG distribution is balanced (no PGs stuck in non-clean states)

---

## Troubleshooting

### OSDs Not Forming Quorum
```bash
# Check OSD logs
tail -f /var/log/ceph/ceph-osd.*.log

# Restart OSDs
systemctl restart ceph-osd@*

# Check connectivity between nodes
ceph osd perf
```

### PGs Stuck "Inactive+Down"
```bash
# Usually temporary during initial peering
# Monitor and wait

watch -n 1 'ceph pg stat'

# If stuck > 30 minutes, check OSD hardware
ceph osd stats
```

### RBD Image Slow or Unresponsive
```bash
# Check cluster load
ceph status

# Check network latency
ping -c 100 10.30.0.12 | tail -5

# Check OSD I/O
ceph osd perf

# If high latency, check network/switch configuration
```

### CephFS MDS in Standby
```bash
# Check MDS status
ceph mds stat

# If MDS not active, restart
systemctl restart ceph-mds@*

# Check MDS ranks
ceph mds dump
```

---

## Next Steps

After Ceph validation:

1. Verify performance with `iperf` across nodes and to Ceph
2. Document actual throughput and IOPS for baseline
3. Proceed to **Phase 5: GPU Configuration (NVIDIA Drivers, MIG)**

---

**Phase 4 Status**: [Start Date] - [Completion Date]
**Ceph Cluster**: OPERATIONAL (36 OSDs, 3 Nodes, HEALTH_OK)

