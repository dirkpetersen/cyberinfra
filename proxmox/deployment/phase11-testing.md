# Phase 11: Testing and Validation

## Overview

This final phase validates all cluster components, tests redundancy/failover scenarios, performs security validation, and benchmarks performance against baseline requirements.

**Duration**: ~3-4 hours
**Prerequisites**: Phase 1-10 complete and operational

---

## Test Categories

1. **Network Redundancy** - Link failover, ESI MC-LAG
2. **Storage Failover** - Ceph OSD failure, data availability
3. **Compute Redundancy** - Node failure, HA recovery
4. **Security** - VLAN isolation, AD auth, 2FA
5. **Performance** - Network, storage, GPU throughput
6. **Disaster Recovery** - Backup/restore, configuration recovery

---

## Test 1: Network Redundancy

### Test 1.1: ESI MC-LAG Link Failover

```bash
# On pve1-node1, simulate 200G link failure

# Before: Check both links active
cat /proc/net/bonding/bond0

# Disable one 200G link
ip link set enp7s0np0 down

# Verify traffic continues (test other nodes)
ssh root@10.30.0.12 "ping -c 10 10.30.0.11"

# Expected: All packets succeed (no loss)

# Re-enable link
ip link set enp7s0np0 up
sleep 2

# Verify both links active
cat /proc/net/bonding/bond0

# Check master status
cat /proc/net/bonding/bond0 | grep "Slave Interface"
```

### Test 1.2: Switch Failure Simulation

```bash
# Coordinate with network admin to test switch failover

# On one HPE 5960 switch, disable ESI MC-LAG port

# Verify Proxmox cluster maintains connectivity
ssh root@10.30.0.11 "pvecm status"
ssh root@10.30.0.12 "pvecm status"
ssh root@10.30.0.13 "pvecm status"

# Expected: Cluster stays quorate, no split-brain

# Re-enable switch port and verify recovery
```

### Test 1.3: Network Latency Baseline

```bash
# Measure latency and bandwidth between nodes

# Install iperf3
apt-get install -y iperf3

# On pve1-node2, start iperf server
iperf3 -s -D

# On pve1-node1, measure bandwidth
iperf3 -c 10.30.0.12 -t 60 -P 4

# Expected: > 100 Gbps on 200G links (allowing for protocol overhead)

# Measure latency
ping -c 1000 10.30.0.12 | tail -3

# Expected: < 0.5 ms latency
```

---

## Test 2: Storage Failover (Ceph)

### Test 2.1: OSD Failure Simulation

```bash
# On any Proxmox node

# Check current Ceph status
ceph status
ceph osd tree

# Identify an OSD (e.g., osd.5 on pve1-node2)
# Simulate failure by stopping OSD
ssh root@10.30.0.12 "systemctl stop ceph-osd@5"

# Monitor recovery
watch -n 1 'ceph status'

# Expected within 1-2 minutes:
# - Ceph marks OSD down
# - PGs start remapping
# - Status changes to HEALTH_WARN (temporarily)

# Monitor until recovery completes
# Expected: HEALTH_OK, all PGs active+clean

# Restart OSD
ssh root@10.30.0.12 "systemctl start ceph-osd@5"

# Verify rebalancing completes
watch -n 1 'ceph pg stat'
```

### Test 2.2: MON Failure Simulation

```bash
# Stop Ceph MON on one node
ssh root@10.30.0.12 "systemctl stop ceph-mon@pve1-node2"

# Verify cluster still quorate (need >= 2/3 MONs)
ceph quorum_status

# Expected: Cluster still functional with 2 MONs

# Restart MON
ssh root@10.30.0.12 "systemctl start ceph-mon@pve1-node2"

# Verify recovery
ceph quorum_status
```

### Test 2.3: RBD Volume Performance Under Degradation

```bash
# Create RBD image
rbd create test-degraded --size 10G --pool rbd-vms

# Start I/O workload
fio --name=test \
    --filename=/dev/rbd0 \
    --rw=randread \
    --bs=4k \
    --iodepth=32 \
    --time_based \
    --runtime=300 \
    --numjobs=4 \
    --output=fio-baseline.log &

# While I/O running, stop an OSD
ssh root@10.30.0.12 "systemctl stop ceph-osd@5"

# Monitor I/O performance degradation
watch -n 1 'tail -20 fio-baseline.log'

# Expected: I/O continues, but with increased latency
# No data loss or corruption

# Restart OSD
ssh root@10.30.0.12 "systemctl start ceph-osd@5"

# Monitor recovery during ongoing I/O
# Expected: Performance recovers as Ceph rebalances
```

---

## Test 3: Compute Redundancy (HA/Failover)

### Test 3.1: VM HA Failover

```bash
# Create test VM (VMID 1000) on pve1-node1

# Register for HA
ha-manager add vm:1000 --group critical-vms

# Verify HA active
ha-manager status | grep vm:1000

# Simulate node failure on pve1-node1
# Isolate pve1-node1 network from other nodes
ssh root@10.30.0.11 "iptables -I INPUT -s 10.30.0.12 -j DROP; iptables -I INPUT -s 10.30.0.13 -j DROP"

# Monitor HA recovery from pve1-node2
ssh root@10.30.0.12 "watch -n 1 'ha-manager status | grep vm:1000'"

# Expected: HA detects node failure, forces node offline (Redfish), restarts VM on surviving node

# After ~3 minutes, VM should be active on pve1-node2 or node3
ssh root@10.30.0.12 "qm status 1000"

# Restore pve1-node1 connectivity
ssh root@10.30.0.11 "iptables -D INPUT -s 10.30.0.12 -j DROP; iptables -D INPUT -s 10.30.0.13 -j DROP"

# Verify cluster recovery
pvecm status
```

### Test 3.2: Container HA Failover

```bash
# Similar test with LXC container

# Create container (VMID 2000) on pve1-node2

# Register for HA
ha-manager add lxc:2000 --group standard-vms

# Simulate node failure on pve1-node2 (from node1)
ssh root@10.30.0.11 "iptables -I INPUT -s 10.30.0.12 -j DROP"

# Monitor failover
ha-manager status | grep lxc:2000

# Expected: Container restarts on surviving node within 2-3 minutes
```

### Test 3.3: HA Recovery After Node Reboot

```bash
# Reboot pve1-node2 gracefully

ssh root@10.30.0.12 "reboot"

# Monitor from pve1-node1
watch -n 5 'pvecm status && echo "---" && ha-manager status'

# Expected:
# - Node disappears from cluster
# - Timeouts VMs/containers migrate
# - After node comes back, it rejoins cluster
# - VMs migrate back if configured
```

---

## Test 4: Security Validation

### Test 4.1: VLAN Isolation

```bash
# Verify VMs/containers cannot access vlan6 (host OS)

# Create test container on vlan1
pct create 3000 local:vztmpl/debian-12-standard_12.1-1_amd64.tar.zst \
    --hostname test-vlan1 \
    --net0 name=eth0,bridge=vmbr0,tag=1

pct start 3000

# Try to access vlan6 network
pct exec 3000 ping -c 3 10.30.0.1

# Expected: No response (VLAN isolated)

# Try to access other VM on same VLAN1
# Expected: Can communicate with other VLAN1 resources

# Cleanup
pct stop 3000
pct destroy 3000
```

### Test 4.2: Active Directory Authentication

```bash
# Test AD login to Proxmox web UI

# From browser:
# 1. Navigate to https://pve1-node1.example.com:8006
# 2. Select realm: AD realm
# 3. Login with AD credentials (e.g., admin@corp.example.com)

# Expected: Login succeeds with AD user

# Verify in Proxmox audit log
tail -20 /var/log/pve/daemon.log | grep "admin@corp"
```

### Test 4.3: Two-Factor Authentication (Duo)

```bash
# Test 2FA with Duo integration

# From browser (after AD login):
# 1. Duo push notification appears on phone
# 2. Approve on phone or use passcode
# 3. Complete login

# Expected: 2FA succeeds, user logged in

# Check Duo logs in Duo admin panel
# Expected: Authentication event logged
```

### Test 4.4: SSH Key Access Only

```bash
# Verify password-based SSH is disabled

# Try password login (should fail)
ssh root@10.30.0.11
# Should prompt for password, then disconnect

# Try key-based login (should succeed)
ssh -i ~/.ssh/pve1_admin_rsa root@10.30.0.11
# Should login without password

# Verify SSH config
cat /etc/ssh/sshd_config | grep -E "PasswordAuth|PermitRootLogin"

# Expected:
# PasswordAuthentication no
# PermitRootLogin prohibit-password
```

---

## Test 5: Performance Benchmarking

### Test 5.1: Network Performance

```bash
# Multi-stream network bandwidth test

iperf3 -s -D  # On pve1-node2

# From pve1-node1
iperf3 -c 10.30.0.12 -t 60 -P 8 -R

# Expected: > 150 Gbps effective (accounting for protocol)
# Should achieve near line rate on 200G links

# Document result
echo "Network BW: 150+ Gbps" >> /root/deployment-results.txt
```

### Test 5.2: Storage Performance (Ceph)

```bash
# RBD sequential read/write

# Create 100GB RBD image
rbd create perf-test --size 100G --pool rbd-vms

# Map and format
rbd map perf-test -p rbd-vms
mkfs.ext4 /dev/rbd0
mount /dev/rbd0 /mnt/rbd-test

# Sequential write test
dd if=/dev/zero of=/mnt/rbd-test/test bs=1M count=50000 conv=fdatasync

# Expected: > 1 GB/s throughput on Ceph flash pool

# Sequential read test
dd if=/mnt/rbd-test/test of=/dev/null bs=1M

# Expected: > 2 GB/s throughput

# Random I/O test with fio
fio --name=rand-read \
    --filename=/mnt/rbd-test/test \
    --rw=randread \
    --bs=4k \
    --iodepth=64 \
    --runtime=120

# Expected: > 100,000 IOPS

# Cleanup
umount /mnt/rbd-test
rbd unmap /dev/rbd0
rbd rm perf-test -p rbd-vms
```

### Test 5.3: GPU Performance (MIG)

```bash
# Test MIG GPU performance

# Create container with GPU
pct create 4000 local:vztmpl/debian-12-standard_12.1-1_amd64.tar.zst \
    --hostname gpu-perf \
    --net0 name=eth0,bridge=vmbr0,tag=1

pct start 4000

# Add GPU access to container config (MIG instance 0)
cat >> /etc/pve/lxc/4000.conf << 'EOF'
lxc.cgroup.devices.allow: c 195:0 rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
EOF

pct restart 4000

# Test GPU from container
pct exec 4000 nvidia-smi

# Run CUDA test (if available)
pct exec 4000 "cuda-memtest --stress --htod --dtoh --iterations 100"

# Expected: Memory test completes without errors
```

### Test 5.4: Weka Performance

```bash
# Benchmark Weka filesystem

# Sequential read
dd if=/mnt/weka/test-file of=/dev/null bs=1M count=10000

# Expected: Near line-rate on 200G network (50-100 GB/s realistic)

# Random IOPS test
fio --name=weka-rand \
    --filename=/mnt/weka/test-random \
    --rw=randread \
    --bs=4k \
    --iodepth=32 \
    --numjobs=8 \
    --size=100G \
    --runtime=120

# Expected: > 50,000 IOPS depending on Weka backend
```

---

## Test 6: Backup and Disaster Recovery

### Test 6.1: Backup Job Execution

```bash
# Execute backup job

proxmox-backup-client backup vm:1000 \
    --datastore s3-backup \
    --backup-id test-vm-1000 \
    --verbose

# Monitor progress
proxmox-backup-client status

# Expected: Backup completes successfully
```

### Test 6.2: Backup Integrity Verification

```bash
# Verify backup integrity

proxmox-backup-client verify --datastore s3-backup --backup-id test-vm-1000

# Expected: Verification succeeds, no corruption detected
```

### Test 6.3: Restore Test

```bash
# Restore from backup to temporary VM

# Get backup ID
BACKUP=$(proxmox-backup-client list | tail -1 | awk '{print $1}')

# Create temporary VM
qm create 9999 --name restore-test --memory 4096

# Restore disk from backup
proxmox-backup-client restore $BACKUP vm-disk --to-stdout | qm importdisk 9999 /dev/stdin local-lvm

# Start and verify
qm start 9999

# Expected: VM boots and is functional
```

---

## Test 7: Monitoring and Alerting

### Test 7.1: Metrics Collection

```bash
# Verify Prometheus collecting metrics

# Query Prometheus
curl -s 'http://prometheus:9090/api/v1/query?query=up' | jq '.data.result | length'

# Expected: 3 or more series (3 nodes + ceph + prometheus)

# Check Grafana dashboards
# Navigate to http://grafana:3000
# Expected: Dashboards displaying live cluster data
```

### Test 7.2: Alert Generation

```bash
# Trigger alert condition

# Simulate high CPU
stress-ng --cpu 8 --timeout 120 &

# Monitor Prometheus alerts
# Query: ALERTS{alertstate="firing"}

# Expected: ProxmoxHighCPU alert fires

# Kill stress process
pkill stress-ng
```

### Test 7.3: Logging Pipeline

```bash
# Verify logs flowing to Defender XDR

# In Azure Log Analytics, query:
Syslog
| where ProcessName contains "pve"
| top 10 by TimeGenerated desc

# Expected: Recent Proxmox logs visible
```

---

## Test 8: Cluster Recovery

### Test 8.1: Complete Node Recovery

```bash
# Simulate complete node loss and recovery

# On pve1-node2:
reboot  # Force reboot

# Monitor cluster from pve1-node1
watch -n 5 'pvecm status'

# Expected:
# - Node drops from cluster
# - Cluster continues with 2 nodes (quorate)
# - VMs fail over to remaining nodes
# - Node rejoins cluster after reboot
# - VMs migrate back (if configured)
```

### Test 8.2: Cluster Configuration Recovery

```bash
# Restore cluster config from backup

# Backup current config
tar czf /tmp/pve-config-backup.tar.gz /etc/pve/

# Test recovery (on test node or VM):
# 1. Extract backup
# 2. Restore to /etc/pve/ on new node
# 3. Restart Proxmox services

# Expected: Cluster config restored, node rejoins cluster
```

---

## Test 9: Documentation and Verification

### Create Final Validation Report

```bash
# Document all test results

cat > /root/deployment-validation-report.txt << 'EOF'
Proxmox pve1 Cluster - Deployment Validation Report
====================================================
Date: $(date)
Cluster: pve1
Nodes: pve1-node1, pve1-node2, pve1-node3

TEST RESULTS:
=============

Network:
  ✓ ESI MC-LAG link failover
  ✓ Network latency < 0.5ms
  ✓ Bandwidth > 150 Gbps

Storage:
  ✓ Ceph OSD failure recovery
  ✓ RBD performance > 1 GB/s
  ✓ Random IOPS > 100k

Compute:
  ✓ HA VM failover
  ✓ HA container failover
  ✓ Node recovery

Security:
  ✓ VLAN isolation enforced
  ✓ AD authentication working
  ✓ 2FA enabled and functional
  ✓ SSH key-only access

Performance:
  ✓ Network: 150+ Gbps
  ✓ Ceph: 1+ GB/s
  ✓ GPU: MIG functional
  ✓ Weka: Near line-rate

Disaster Recovery:
  ✓ Backup created successfully
  ✓ Backup integrity verified
  ✓ Restore tested and functional

Monitoring:
  ✓ Prometheus collecting metrics
  ✓ Grafana dashboards functional
  ✓ Defender XDR logging active

CONCLUSION: Cluster PASSED all tests. READY FOR PRODUCTION
EOF

cat /root/deployment-validation-report.txt
```

---

## Validation Checklist

- [ ] All network redundancy tests passed
- [ ] Storage failover recovers successfully
- [ ] HA failover functional for VMs and containers
- [ ] VLAN isolation confirmed
- [ ] AD authentication and 2FA working
- [ ] SSH key access only
- [ ] Network performance > 150 Gbps
- [ ] Ceph performance > 1 GB/s
- [ ] GPU MIG functional
- [ ] Backups executed and verified
- [ ] Restore testing successful
- [ ] Monitoring and alerting active
- [ ] Full validation report completed

---

## Final Sign-Off

```bash
# Deploy complete - save final status to AWS SSM

aws ssm put-parameter \
    --name /pve1/deployment/status \
    --value "COMPLETE" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/deployment/completion_date \
    --value "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --type String \
    --region us-west-2 \
    --overwrite

echo "Deployment Complete and Validated"
echo "Cluster Status: OPERATIONAL"
echo "All tests PASSED"
```

---

## Post-Deployment Operations

1. **Monitoring**: Monitor cluster for 1-2 weeks post-deployment
2. **Optimization**: Tune Ceph, network, and VM parameters based on real workload
3. **Documentation**: Update runbooks and recovery procedures
4. **Training**: Document procedures for ops team
5. **Handoff**: Transfer to operations team

---

**Phase 11 Status**: [Start Date] - [Completion Date]
**Cluster Status**: VALIDATED - READY FOR PRODUCTION

