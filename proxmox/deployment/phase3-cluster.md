# Phase 3: Cluster Formation and Corosync Setup

## Overview

This phase initializes the Proxmox cluster, configures Corosync with multiple rings for redundancy, and joins nodes 2 and 3 to the cluster.

**Duration**: ~30 minutes
**Prerequisites**: Phase 1 & 2 complete on all 3 nodes, full network connectivity verified

---

## Step 1: Initialize Cluster on Node 1

### Create Cluster on pve1-node1

```bash
# SSH to pve1-node1
ssh root@10.30.0.11

# Initialize cluster (must be done on node1 first)
pvecm create pve1 --bindnet0_addr 10.30.0.11 --ring0_addr 10.30.0.11

# This creates:
# - Corosync configuration (/etc/corosync/conf.d/pve1.conf)
# - Cluster secrets in /etc/pve/
# - Initial cluster state
```

### Verify Cluster Creation

```bash
# Check cluster status
pvecm status

# Expected output:
# Cluster information
# ==================
# Name:             pve1
# Config Version:   1
# Primary:          Yes
# Nodes:            1
#   pve1-node1: 10.30.0.11, nodeid 1
# [...]

# View Corosync config
cat /etc/corosync/conf.d/pve1.conf
```

---

## Step 2: Configure Corosync for High Availability

### Modify Corosync Configuration for Multiple Rings

The default configuration has one ring. For high availability with redundancy, add a second ring:

```bash
# On pve1-node1
vim /etc/corosync/conf.d/pve1.conf
```

**Updated Corosync Configuration**:

```ini
totem {
  version: 2

  # This timeout is used for cluster formation
  token: 3000
  token_retransmits_before_loss_const: 10
  join: 60
  consensus: 6000
  max_messages: 20

  # Network interface bindings (multiple rings)
  interface {
    ringnumber: 0
    bindnetaddr: 10.30.0.0
    mcastport: 5405
    ttl: 1
  }

  # Optional: Second ring for redundancy (same network, different node)
  # Can use alternate network if available, or same network on different interfaces
  # For pve1, both rings use same VLAN6 for simplicity (network provides redundancy via ESI MC-LAG)
  interface {
    ringnumber: 1
    bindnetaddr: 10.30.0.0
    mcastport: 5406
    ttl: 1
  }

  # Ensure flow control is disabled for performance
  transport: udpu

  # Crypto for cluster communication
  crypto_cipher: aes256
  crypto_hash: sha256
}

nodelist {
  node {
    ring0_addr: 10.30.0.11
    ring1_addr: 10.30.0.11
    name: pve1-node1
    nodeid: 1
  }
  node {
    ring0_addr: 10.30.0.12
    ring1_addr: 10.30.0.12
    name: pve1-node2
    nodeid: 2
  }
  node {
    ring0_addr: 10.30.0.13
    ring1_addr: 10.30.0.13
    name: pve1-node3
    nodeid: 3
  }
}

quorum {
  # 3-node cluster - need majority (2 nodes)
  provider: corosync_votequorum
  expected_votes: 3
  two_node: 0
  last_man_standing: 0
  wait_for_all: 0
}

logging {
  fileline: off
  to_stderr: no
  to_logfile: yes
  logfile: /var/log/corosync/corosync.log
  to_syslog: yes
  debug: off
  timestamp: on
  logger_subsys {
    subsys: QUORUM
    debug: off
  }
}

service {
  name: pve_rrstatd
  ver: 0
}
```

### Apply Corosync Configuration

```bash
# Backup original
cp /etc/corosync/conf.d/pve1.conf /etc/corosync/conf.d/pve1.conf.bak

# Copy updated config (created above) to all nodes
# This will be distributed when nodes join

# Restart Corosync on pve1-node1
systemctl restart corosync

# Wait for cluster to stabilize
sleep 5

# Verify
corosync-cfgtool -s

# Check Corosync is running
systemctl status corosync
```

---

## Step 3: Generate Cluster Join Information

Before nodes 2 and 3 can join, they need the cluster authentication tokens:

```bash
# On pve1-node1, generate join information for nodes 2 and 3
# This creates authentication materials that nodes will use to join

# View cluster info (needed by joining nodes)
cat /etc/corosync/authkey
cat /etc/pve/corosync.conf

# Create a join script for automation
cat > /tmp/prepare-join-node.sh << 'EOF'
#!/bin/bash
# Prepare cluster join package for new node

TARGET_NODE=$1
TARGET_IP=$2

if [[ -z "$TARGET_NODE" || -z "$TARGET_IP" ]]; then
    echo "Usage: prepare-join-node.sh <node-name> <node-ip>"
    exit 1
fi

# Copy cluster secrets to temp location
mkdir -p /tmp/pve1-join-$TARGET_NODE
cp /etc/corosync/authkey /tmp/pve1-join-$TARGET_NODE/
cp /etc/pve/corosync.conf /tmp/pve1-join-$TARGET_NODE/

# Transfer to joining node
scp -r /tmp/pve1-join-$TARGET_NODE/* root@$TARGET_IP:/tmp/

echo "Cluster join files prepared for $TARGET_NODE at $TARGET_IP"
EOF

chmod +x /tmp/prepare-join-node.sh

# Prepare join package
bash /tmp/prepare-join-node.sh pve1-node2 10.30.0.12
bash /tmp/prepare-join-node.sh pve1-node3 10.30.0.13
```

---

## Step 4: Join Node 2 to Cluster

```bash
# SSH to pve1-node2
ssh root@10.30.0.12

# Stop Corosync if running (shouldn't be, but just in case)
systemctl stop corosync

# Copy cluster secrets from node1 (already transferred by scp above)
mkdir -p /etc/corosync
cp /tmp/authkey /etc/corosync/
cp /tmp/corosync.conf /etc/pve/

# Fix permissions
chmod 400 /etc/corosync/authkey

# Start Corosync
systemctl start corosync

# Wait for initialization
sleep 5

# Verify node joined cluster
pvecm status

# Expected output shows 2 nodes now:
# Nodes: 2
#   pve1-node1: 10.30.0.11, nodeid 1
#   pve1-node2: 10.30.0.12, nodeid 2
```

### Verify Node 2 Connection

```bash
# From pve1-node2
corosync-cfgtool -s

# From pve1-node1, verify node2 visible
corosync-quorumtool
pvecm nodes
```

---

## Step 5: Join Node 3 to Cluster

Repeat Step 4 for pve1-node3:

```bash
# SSH to pve1-node3
ssh root@10.30.0.13

# Copy cluster secrets (from previous scp)
mkdir -p /etc/corosync
cp /tmp/authkey /etc/corosync/
cp /tmp/corosync.conf /etc/pve/
chmod 400 /etc/corosync/authkey

# Start Corosync
systemctl start corosync
sleep 5

# Verify joined
pvecm status

# Should show 3 nodes now
```

---

## Step 6: Verify Full Cluster Formation

On any node:

```bash
# Full cluster status
pvecm status

# Corosync status
corosync-quorumtool

# Verify all 3 nodes visible
pvecm nodes

# Check quorum
corosync-cfgtool -s

# Verify Corosync communication
netstat -tlnp | grep corosync
```

**Expected output**:

```
Cluster information
==================
Name:             pve1
Config Version:   2
Primary:          Yes
Nodes:            3
  pve1-node1: 10.30.0.11, nodeid 1
  pve1-node2: 10.30.0.12, nodeid 2
  pve1-node3: 10.30.0.13, nodeid 3
```

---

## Step 7: Test Cluster Communication and Failover

### Test 1: Node Isolation Simulation

```bash
# On pve1-node1, simulate network isolation
# WARNING: This will cause cluster communication loss!
# Only do on test cluster or scheduled maintenance window

# Simulate isolation (restrict traffic)
iptables -I INPUT -s 10.30.0.12 -j DROP
iptables -I INPUT -s 10.30.0.13 -j DROP

# Check cluster status from node1 (will show degraded)
pvecm status

# From node2 or node3, should still see cluster (majority)
ssh root@10.30.0.12 pvecm status

# Restore connectivity
iptables -D INPUT -s 10.30.0.12 -j DROP
iptables -D INPUT -s 10.30.0.13 -j DROP

# Verify cluster reforms
pvecm status
```

### Test 2: Cross-Node Communication Latency

```bash
# Measure latency between nodes (VLAN6)
ping -c 100 10.30.0.12 | grep "min/avg/max"
ping -c 100 10.30.0.13 | grep "min/avg/max"

# Expected: < 1ms on 200G links
```

---

## Step 8: Save Cluster Configuration to AWS SSM

After cluster successfully formed, save critical parameters:

```bash
# On pve1-node1

# Retrieve and save cluster ID
CLUSTER_ID=$(grep cluster_uuid /etc/pve/corosync.conf | awk '{print $2}')

# Save to AWS SSM
aws ssm put-parameter \
    --name /pve1/cluster/cluster_id \
    --value "$CLUSTER_ID" \
    --type String \
    --region us-west-2 \
    --overwrite

# Save corosync.conf
COROSYNC_CONF=$(cat /etc/pve/corosync.conf | base64)
aws ssm put-parameter \
    --name /pve1/cluster/corosync_conf \
    --value "$COROSYNC_CONF" \
    --type String \
    --region us-west-2 \
    --overwrite

# Save cluster node list
aws ssm put-parameter \
    --name /pve1/cluster/nodes \
    --value "pve1-node1,pve1-node2,pve1-node3" \
    --type String \
    --region us-west-2 \
    --overwrite

echo "Cluster configuration saved to AWS SSM"
```

---

## Step 9: Enable Cluster Autostart Services

Ensure cluster services start automatically on node reboot:

```bash
# On all 3 nodes
systemctl enable corosync
systemctl enable pvestatd
systemctl enable pvedaemon

# Verify
systemctl is-enabled corosync
```

---

## Validation Checklist

- [ ] All 3 nodes visible in `pvecm status`
- [ ] Quorum achieved (3/3 nodes)
- [ ] Corosync status shows "Quorate: Yes"
- [ ] All nodes have consistent cluster configuration
- [ ] Network latency < 1ms between all nodes
- [ ] Cluster reforms after simulated node isolation
- [ ] Corosync logs show clean operation (`/var/log/corosync/corosync.log`)
- [ ] No "split-brain" warnings in logs
- [ ] Cluster persists after node reboot

---

## Troubleshooting

### Node Won't Join Cluster
```bash
# Check if corosync started
systemctl status corosync

# Check logs
tail -f /var/log/corosync/corosync.log

# Verify cluster secrets copied correctly
diff <(cat /tmp/authkey) <(cat /etc/corosync/authkey)

# Try manual join
corosync-keygen  # Generate new key if corrupted
systemctl restart corosync
```

### "Lost Quorum" Error
```bash
# Check if majority of nodes operational
pvecm status

# If < 2 nodes up, cluster cannot operate
# Restart missing nodes, or restore from backup

# Force quorum recovery (dangerous!)
# Only use if > 50% nodes are up but quorum lost
corosync-quorumtool -s -e 1
```

### High Network Latency on Cluster Traffic
```bash
# Verify VLAN6 is using both 200G links via ESI MC-LAG
cat /proc/net/bonding/bond0

# Check for packet loss
ping -D -c 1000 10.30.0.12 | grep "loss"

# Verify switch ESI MC-LAG is active
# Contact network admin to check switch port status
```

### Cluster Configuration Conflicts
```bash
# If nodes have different corosync.conf:
# Copy from node1 to others
scp /etc/pve/corosync.conf root@10.30.0.12:/etc/pve/
scp /etc/pve/corosync.conf root@10.30.0.13:/etc/pve/

systemctl restart corosync  # On each node
```

---

## Next Steps

Once cluster is fully operational:

1. Verify cluster persists after maintenance reboot cycle
2. Run network diagnostic suite (iperf, latency tests)
3. Proceed to **Phase 4: Ceph Storage Deployment**

---

**Phase 3 Status**: [Start Date] - [Completion Date]
**Cluster Status**: OPERATIONAL (3/3 nodes)

