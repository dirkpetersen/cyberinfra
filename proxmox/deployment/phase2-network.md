# Phase 2: Network Configuration (VLANs, Bonds, ESI MC-LAG)

## Overview

This phase configures the advanced network topology with dual 200G NICs bonded via ESI MC-LAG at the switch level, multiple VLAN interfaces, and bridge configuration for VM/LXC connectivity.

**Duration**: ~45 minutes
**Prerequisites**: Phase 1 complete on all 3 nodes, network switches configured for ESI MC-LAG

---

## Network Architecture Summary

```
200G Dual NIC (per node) → ESI MC-LAG (switch) → VLAN Trunking
├── VLAN6 (host OS/Corosync) - tagged
├── VLAN1-5 (VM/LXC) - tagged
└── Management VLAN (1G IPMI) - separate switch
```

---

## Step 1: Switch Configuration (HPE 5960)

**Note**: This must be completed by network admin BEFORE Proxmox node configuration.

### ESI MC-LAG Configuration on HPE Switches

```
# HPE 5960 CLI Configuration

# Enable EVPN/VXLAN (already done per requirements)
router bgp <bgp_asn>
  address-family evpn

# Configure ESI MC-LAG (per switch pair)
interface ethernet <port> to <port+1>
  description "pve1-node1 ESI MC-LAG"
  no shutdown

# Enable LACP and configure as MC-LAG member
channel-group 1 mode active
vpc domain 100
  peer-address 10.20.0.x
  peer-keepalive destination 10.20.0.x source 10.20.0.x

# VLAN trunk configuration
interface port-channel 1
  description "pve1-node1-trunk"
  switchport mode trunk
  switchport trunk allowed vlan 1-5,6
  no shutdown

# Repeat for pve1-node2 and pve1-node3
```

---

## Step 2: Verify Switch Configuration

From HPE 5960 CLI:

```bash
# Verify LACP operational
show lacp aggregation-group 1 status

# Verify VLAN membership
show spanning-tree vlan <id>

# Verify ESI MC-LAG
show mc-lag
```

---

## Step 3: Configure Proxmox Node Network Interfaces

### Identify NICs

SSH to each node:

```bash
ssh root@10.30.0.11  # pve1-node1

# List network devices
ip link show
lspci | grep Mellanox

# Should show:
# - 200G NICs (e.g., enp7s0np0, enp8s0np0 or similar)
# - 25G NICs (not used in this config)
# - 1G management NIC (IPMI, separate)
```

### Backup Current Network Config

```bash
cp /etc/network/interfaces /etc/network/interfaces.bak-phase2
```

### Create Bond Configuration Script

Create file: `scripts/configure-network-node.sh`

```bash
#!/bin/bash
set -e

# Network Configuration for Proxmox pve1
# This script configures dual 200G NICs with bonding and VLANs

NODE_NAME=${1:-pve1-node1}
NODE_NUM=${2:-1}

echo "=== Configuring network for $NODE_NAME ==="

# NIC identification (adjust based on your hardware)
# Common naming: enp<slot>s0np<port> or ens<number>
# Verify with: ip link show | grep -E 'enp|ens'

NIC1="enp7s0np0"    # First 200G NIC - adjust as needed
NIC2="enp8s0np0"    # Second 200G NIC - adjust as needed

# VLAN configuration
VLAN6_IP="10.30.0.$((10 + NODE_NUM))"
VLAN6_MASK="24"
VLAN6_GW="10.30.0.1"

# Create network configuration
cat > /etc/network/interfaces << 'EOF'
# Proxmox pve1 Network Configuration - Phase 2
# Dual 200G NIC bonding with ESI MC-LAG (switch level)
# VLAN trunking for 6 VLANs

auto lo
iface lo inet loopback

# Primary 200G NIC 1 (raw, part of bond)
auto NIC1
iface NIC1 inet manual
    # Will be enslaved to bond0

# Primary 200G NIC 2 (raw, part of bond)
auto NIC2
iface NIC2 inet manual
    # Will be enslaved to bond0

# Bond interface (active-active via ESI MC-LAG at switch)
# ESI MC-LAG provides active-active redundancy at L2 level
auto bond0
iface bond0 inet manual
    bond-slaves NIC1 NIC2
    bond-mode active-backup    # Linux mode; switch handles active-active via ESI
    bond-miimon 100
    bond-downdelay 200
    bond-updelay 200
    # Note: ESI MC-LAG at switch provides true active-active

# Bridge for VLANs (tagged trunk)
auto vmbr0
iface vmbr0 inet manual
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 1-6    # All VLANs tagged on bridge

# VLAN6 - Host OS / Management / Corosync
# This VLAN is isolated and restricted to sysadmins only
auto vlan6
iface vlan6 inet static
    address VLAN6_IP/VLAN6_MASK
    gateway VLAN6_GW
    dns-nameservers 8.8.8.8 8.8.4.4
    vlan-raw-device vmbr0
    # Access control (firewall rules to be configured in Phase 7)

# VLAN1 - VM/LXC traffic
auto vlan1
iface vlan1 inet manual
    vlan-raw-device vmbr0

# VLAN2 - VM/LXC traffic
auto vlan2
iface vlan2 inet manual
    vlan-raw-device vmbr0

# VLAN3 - VM/LXC traffic
auto vlan3
iface vlan3 inet manual
    vlan-raw-device vmbr0

# VLAN4 - VM/LXC traffic
auto vlan4
iface vlan4 inet manual
    vlan-raw-device vmbr0

# VLAN5 - VM/LXC traffic
auto vlan5
iface vlan5 inet manual
    vlan-raw-device vmbr0
EOF

# Replace placeholders
sed -i "s/NIC1/$NIC1/g" /etc/network/interfaces
sed -i "s/NIC2/$NIC2/g" /etc/network/interfaces
sed -i "s/VLAN6_IP/$VLAN6_IP/g" /etc/network/interfaces
sed -i "s/VLAN6_MASK/$VLAN6_MASK/g" /etc/network/interfaces
sed -i "s/VLAN6_GW/$VLAN6_GW/g" /etc/network/interfaces

echo "[1/4] Network interfaces configured"

# Verify configuration
echo "[2/4] Verifying network configuration..."
ip -a check -f inet /etc/network/interfaces

# Apply network configuration
echo "[3/4] Applying network configuration (this will restart networking)..."
systemctl restart networking

# Wait for interfaces to come up
sleep 5

echo "[4/4] Verifying interface status..."
ip link show bond0
ip link show vmbr0
ip addr show vlan6

# Verify connectivity
echo "Verifying vlan6 connectivity..."
ping -c 3 $VLAN6_GW

echo "=== Network configuration complete for $NODE_NAME ==="
```

### Execute Network Configuration

```bash
# On pve1-node1
bash scripts/configure-network-node.sh pve1-node1 1

# On pve1-node2
bash scripts/configure-network-node.sh pve1-node2 2

# On pve1-node3
bash scripts/configure-network-node.sh pve1-node3 3
```

---

## Step 4: Verify Bond and VLAN Configuration

On each node:

```bash
# Check bond status
cat /proc/net/bonding/bond0

# Check bridge configuration
brctl show

# Check VLAN status
ip -d link show vlan6
ip -d link show vlan1

# Verify all interfaces up
ip addr show | grep -E "vlan[0-6]|bond0|vmbr0"

# Test connectivity to gateway
ping 10.30.0.1

# Test connectivity to other nodes
ping 10.30.0.12  # pve1-node2 (from pve1-node1)
ping 10.30.0.13  # pve1-node3 (from pve1-node1)
```

---

## Step 5: Configure ESI MC-LAG Redundancy Testing

### Failover Test 1: Link Failure

```bash
# On pve1-node1, disable one 200G NIC
ip link set enp7s0np0 down

# Verify traffic stays up
ping -c 10 10.30.0.1
# Should continue pinging (failover to second NIC via ESI MC-LAG)

# Re-enable NIC
ip link set enp7s0np0 up
sleep 2

# Verify both links operational
cat /proc/net/bonding/bond0 | grep "Active Slave"
```

### Failover Test 2: Switch Failover

```bash
# Coordinate with network admin to test switch failover
# Simulate one HPE 5960 becoming unavailable
# Verify Proxmox cluster maintains connectivity through other switch

# Check from any Proxmox node
pvecm status
```

---

## Step 6: Bridge Configuration for VM/LXC (Final Step)

The bridge (`vmbr0`) is already configured in Step 3. This is used by Proxmox for VM/LXC network connectivity.

### Verify Bridge in Proxmox Web UI

1. Login to Proxmox (any node)
2. Navigate to **Node > Network**
3. Verify:
   - `vmbr0` (bridge) exists and configured
   - `vlan6` has IP address
   - `vlan1-5` exist as VLAN interfaces

### Create VM Network Bridge (Optional - for additional isolation)

If you need separate bridge per VLAN:

```bash
# Not required for basic setup, but useful for advanced segmentation
# Skip this unless specifically needed

cat >> /etc/network/interfaces << 'EOF'

# Optional: Separate bridges per VLAN (for advanced isolation)
auto vmbr-vlan1
iface vmbr-vlan1 inet manual
    bridge-ports vlan1
    bridge-stp off
    bridge-fd 0

# Repeat for vlan2-5 if needed
EOF

systemctl restart networking
```

---

## Step 7: Update Proxmox Network Configuration

Update Proxmox internal network config to reflect new setup:

```bash
# Edit Proxmox network file
pvesh set /nodes/pve1-node1/config/network --comment "ESI MC-LAG dual 200G bonded configuration"

# Restart Proxmox services
systemctl restart pveproxy
systemctl restart pvestatd
```

---

## Validation Checklist

For each node:

- [ ] Both 200G NICs present and up
- [ ] Bond interface (`bond0`) active with both slaves
- [ ] Bridge interface (`vmbr0`) operational
- [ ] VLAN6 has correct static IP (10.30.0.1x)
- [ ] Can ping gateway and other nodes via VLAN6
- [ ] All VLAN interfaces (vlan1-6) present
- [ ] Failover test: Single NIC failure doesn't affect connectivity
- [ ] ESI MC-LAG: Both links show as active (not just backup)

---

## Troubleshooting

### Bond Interface Not Forming
```bash
# Check for conflicting network configs
ip link show

# Manually bring up bond
ip link set bond0 up

# Check bond mode
cat /proc/net/bonding/bond0
```

### VLAN Not Tagged on Bridge
```bash
# Verify bridge VLAN awareness
ip -d link show vmbr0 | grep vlan_aware

# If not enabled, re-run network config script
```

### No Connectivity After Network Restart
```bash
# Revert to backup
cp /etc/network/interfaces.bak-phase2 /etc/network/interfaces
systemctl restart networking

# Re-run with debug
bash -x scripts/configure-network-node.sh pve1-node1 1
```

### Ping to Other Nodes Fails
```bash
# Verify static IPs assigned
ip addr show vlan6

# Check firewall blocking (should be minimal at this stage)
iptables -L -n | grep vlan6

# Verify switch VLAN membership
# Contact network admin to check switch port VLAN config
```

---

## Next Steps

Once all 3 nodes have network configured:

1. Verify full mesh connectivity (each node ↔ all other nodes)
2. Test with `mtr` or `iperf` for bandwidth verification
3. Proceed to **Phase 3: Cluster Formation** to initialize Proxmox cluster

---

**Phase 2 Status**: [Start Date] - [Completion Date]
**Nodes Completed**: 1/3, 2/3, 3/3

