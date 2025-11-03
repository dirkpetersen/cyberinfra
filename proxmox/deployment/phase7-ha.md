# Phase 7: HA Configuration and Redfish Fencing

## Overview

This phase configures Proxmox HA (High Availability) Manager for automatic VM/container failover, sets up Redfish-based fencing for node failure recovery, and defines HA policies.

**Duration**: ~40 minutes
**Prerequisites**: Phase 1-6 complete, all nodes operational, Redfish access working

---

## Step 1: Verify Redfish/IPMI Accessibility

### Test Redfish Access to BMCs

```bash
# From pve1-node1, test Redfish API access to each node's BMC

# For each node:
for node_ip in 10.20.0.11 10.20.0.12 10.20.0.13; do
    echo "=== Testing Redfish on $node_ip ==="

    # Test basic Redfish discovery
    curl -s -k -u root:PASSWORD "https://$node_ip/redfish/v1/" | jq '.' | head -20

    # Get system power state
    curl -s -k -u root:PASSWORD "https://$node_ip/redfish/v1/Systems/1/" | jq '.PowerState'
done

# Expected output:
# "On" or "Off"
```

### Retrieve Redfish Credentials

```bash
# Store Redfish credentials in AWS SSM (already should be there from setup)
# Verify accessibility:

aws ssm get-parameter --name /pve1/nodes/node1/ipmi_user --region us-west-2
aws ssm get-parameter --name /pve1/nodes/node1/ipmi_password --region us-west-2 --with-decryption

# If not already saved, add them:
aws ssm put-parameter \
    --name /pve1/nodes/node1/ipmi_user \
    --value "root" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/nodes/node1/ipmi_password \
    --value "YOUR_IPMI_PASSWORD" \
    --type SecureString \
    --region us-west-2 \
    --overwrite
```

---

## Step 2: Configure Redfish Fencing

### Create Fencing Script

Create file: `/usr/local/bin/pve-fence-redfish.py`

```python
#!/usr/bin/env python3

"""
Redfish-based fencing script for Proxmox HA
Integrates with Proxmox HA manager for node power control
"""

import sys
import argparse
import requests
import json
import logging
from urllib3.disable_warnings import disable_warnings

disable_warnings()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Node to Redfish IP mapping
NODE_REDFISH_MAP = {
    'pve1-node1': '10.20.0.11',
    'pve1-node2': '10.20.0.12',
    'pve1-node3': '10.20.0.13',
}

class RedfishFence:
    def __init__(self, node, username, password):
        self.node = node
        self.username = username
        self.password = password
        self.redfish_ip = NODE_REDFISH_MAP.get(node)
        self.base_url = f"https://{self.redfish_ip}/redfish/v1"
        self.session = requests.Session()
        self.session.verify = False
        self.session.auth = (username, password)

    def get_power_state(self):
        """Get current power state"""
        try:
            response = self.session.get(f"{self.base_url}/Systems/1/")
            data = response.json()
            return data.get('PowerState')
        except Exception as e:
            logger.error(f"Failed to get power state: {e}")
            return None

    def power_off(self, graceful=True):
        """Power off node"""
        try:
            action_target = f"{self.base_url}/Systems/1/Actions/ComputerSystem.Reset"
            payload = {
                "ResetType": "GracefulShutdown" if graceful else "ForceOff"
            }
            response = self.session.post(action_target, json=payload)
            if response.status_code in [200, 202]:
                logger.info(f"Power off command sent to {self.node}")
                return True
            else:
                logger.error(f"Power off failed: {response.status_code}")
                return False
        except Exception as e:
            logger.error(f"Power off exception: {e}")
            return False

    def power_on(self):
        """Power on node"""
        try:
            action_target = f"{self.base_url}/Systems/1/Actions/ComputerSystem.Reset"
            payload = {"ResetType": "On"}
            response = self.session.post(action_target, json=payload)
            if response.status_code in [200, 202]:
                logger.info(f"Power on command sent to {self.node}")
                return True
            else:
                logger.error(f"Power on failed: {response.status_code}")
                return False
        except Exception as e:
            logger.error(f"Power on exception: {e}")
            return False

def main():
    parser = argparse.ArgumentParser(description='Redfish fencing agent for Proxmox HA')
    parser.add_argument('action', choices=['status', 'on', 'off'], help='Fencing action')
    parser.add_argument('--node', required=True, help='Node name')
    parser.add_argument('--user', default='root', help='Redfish username')
    parser.add_argument('--password', required=True, help='Redfish password')

    args = parser.parse_args()

    fence = RedfishFence(args.node, args.user, args.password)

    if args.action == 'status':
        state = fence.get_power_state()
        print(state)
        return 0 if state else 1

    elif args.action == 'off':
        success = fence.power_off(graceful=True)
        return 0 if success else 1

    elif args.action == 'on':
        success = fence.power_on()
        return 0 if success else 1

if __name__ == '__main__':
    sys.exit(main())
```

### Make Script Executable

```bash
chmod +x /usr/local/bin/pve-fence-redfish.py

# Test fencing script
/usr/local/bin/pve-fence-redfish.py status --node pve1-node2 --password IPMI_PASSWORD

# Expected: "On" or "Off"
```

---

## Step 3: Configure Proxmox HA Manager

### Enable HA Manager

```bash
# On pve1-node1

# Check current HA configuration
ha-manager status

# Enable HA manager
pvecm ha-init

# Verify HA enabled
ha-manager status
# Expected output shows "Enabled"
```

### Define HA Policy

Create file: `/etc/pve/ha/ha-config.cfg`

```ini
# Proxmox HA Configuration

# Global HA settings
shutdown_policy: conditional

# HA groups (virtual machine grouping for failover)
# Example: Group critical VMs together

group: critical-vms
    nodes: pve1-node1,pve1-node2,pve1-node3
    nofailback: 1  # Don't fail back to original node
    restricted: 0  # Allow failover to any node

group: standard-vms
    nodes: pve1-node1,pve1-node2,pve1-node3
    nofailback: 0
    restricted: 0
```

### Define Fencing Configuration

Create file: `/etc/pve/ha/fencing.cfg`

```ini
# Fencing device configuration (Redfish/IPMI)

device: redfish-fence
    type: redfish
    base_url: https://10.20.0.11/redfish/v1
    username: root
    password: PASSWORD

# Node-to-fence device mapping
pve1-node1:
    redfish_url: https://10.20.0.11/redfish/v1

pve1-node2:
    redfish_url: https://10.20.0.12/redfish/v1

pve1-node3:
    redfish_url: https://10.20.0.13/redfish/v1
```

---

## Step 4: Register HA Resources (VMs/Containers)

### Create HA Configuration for Critical VMs

```bash
# Example: Register a VM for HA
# VM VMID 100 (PBS backup server) - critical, should failover

ha-manager add vm:100 \
    --group critical-vms \
    --comment "Proxmox Backup Server" \
    --max_relocate 1 \
    --max_restart 1

# Example: Register a container for HA
# Container VMID 200 (Prometheus) - important, should failover

ha-manager add lxc:200 \
    --group standard-vms \
    --comment "Prometheus monitoring" \
    --max_relocate 1 \
    --max_restart 1

# Verify HA resources
ha-manager status

# Example output:
# HA Resources:
#   vm:100: pve1-node1 (enabled) state ok
#   lxc:200: pve1-node2 (enabled) state ok
```

### HA Configuration Parameters

- `max_relocate`: Number of times resource can relocate (fail over)
- `max_restart`: Number of times resource can restart on same node
- `group`: HA group for resource affinity
- `comment`: Description of resource

---

## Step 5: Configure STONITH (Shoot The Other Node In The Head)

STONITH ensures cluster stability by forcing failed nodes offline.

### Create STONITH Policy

Edit `/etc/corosync/corosync.conf` and add:

```ini
service {
  name: pve_rrstatd
  ver: 0
  use_msgsieve: on
  use_blackbox: on
  rates_enabled: on
}

# Add fencing policy
ha {
  stonith_enabled: yes
  stonith_watchdog_action: reboot
  stonith_fence_timeout: 60
  stonith_power_timeout: 60
}
```

### Restart Corosync

```bash
systemctl restart corosync

# Verify STONITH enabled
corosync-cfgtool -s
```

---

## Step 6: Define Watchdog Timer

Watchdog timer automatically resets node if system becomes unresponsive:

```bash
# Install watchdog
apt-get install -y watchdog

# Enable watchdog daemon
systemctl enable watchdog
systemctl start watchdog

# Verify watchdog operational
systemctl status watchdog
```

---

## Step 7: Test HA Failover Scenario

### Test 1: Simulate Node Failure (Network Isolation)

```bash
# WARNING: This will cause temporary cluster disruption!
# Only run on test cluster or scheduled maintenance window

# From pve1-node1, simulate network isolation of pve1-node2
# This forces pve1-node2 to be isolated from cluster

iptables -I INPUT -s 10.30.0.12 -j DROP
iptables -I OUTPUT -d 10.30.0.12 -j DROP

# Monitor HA failover (from pve1-node3)
ssh root@10.30.0.13 "watch -n 1 'ha-manager status'"

# Expected: VMs from pve1-node2 failover to pve1-node1 or pve1-node3

# Check which node took over
ssh root@10.30.0.13 "ha-manager status | grep vm:"

# Restore connectivity
iptables -D INPUT -s 10.30.0.12 -j DROP
iptables -D OUTPUT -d 10.30.0.12 -j DROP

# Verify cluster recovery
pvecm status
```

### Test 2: Simulate Redfish Fencing

```bash
# Test Redfish fence action (graceful power off of isolated node)
# This would normally be triggered automatically

# Manual test (DO NOT RUN in production without coordination!):
# /usr/local/bin/pve-fence-redfish.py off --node pve1-node2 --password PASSWORD

# In a real failure scenario:
# 1. Node loses network heartbeat
# 2. Cluster marks node as "lost"
# 3. HA manager initiates Redfish power-off of lost node
# 4. VMs restarted on surviving nodes
# 5. When lost node recovers, it rejoins cluster
```

---

## Step 8: Configure HA Advanced Settings

### Recovery Behavior

Create file: `/etc/pve/ha/ha-config.cfg` additions:

```ini
# Recovery actions
recovery:
    # When node fails and recovers
    auto_recovery: yes           # Automatically recover VMs when node comes back
    max_recovery_restarts: 3     # Max restarts during recovery
    recovery_grace_period: 600   # Wait 10 min before trying recovery

# Alert thresholds
monitoring:
    check_interval: 10           # Check HA resources every 10 seconds
    missed_packets_threshold: 3  # Fence after 3 missed heartbeats
```

### Resource-Specific Policies

```bash
# Set different policies per VM

# PBS backup server - critical, aggressive restart
ha-manager set vm:100 --max_restart 3 --max_relocate 3

# Non-critical service - limited restart
ha-manager set lxc:200 --max_restart 1 --max_relocate 1

# Static VM (never restart) - only failover
ha-manager set vm:300 --max_restart 0 --max_relocate 1
```

---

## Step 9: Monitor HA Status

### HA Manager Commands

```bash
# View all HA resources
ha-manager status

# View specific resource
ha-manager status vm:100

# View HA logs
tail -f /var/log/pve/ha-manager.log

# View cluster events
journalctl -u pve-ha-lrm -f  # Local Resource Manager
journalctl -u pve-ha-crm -f  # Cluster Resource Manager

# Check recent failovers
grep "restart\|relocate" /var/log/pve/ha-manager.log
```

### Create Monitoring Dashboard

Save HA status to file for monitoring:

```bash
# Create script to export HA status
cat > /usr/local/bin/export-ha-status.sh << 'EOF'
#!/bin/bash
HA_STATUS=$(ha-manager status)
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Parse output and export to monitoring
echo "$HA_STATUS" | grep "^\s*vm:\|^\s*lxc:" | while read line; do
    resource=$(echo $line | awk '{print $1}')
    node=$(echo $line | awk '{print $2}')
    state=$(echo $line | awk '{print $NF}')
    echo "$timestamp resource=$resource node=$node state=$state"
done
EOF

chmod +x /usr/local/bin/export-ha-status.sh

# Add to cron for periodic export
echo "*/5 * * * * /usr/local/bin/export-ha-status.sh >> /var/log/pve/ha-status.log" | crontab -
```

---

## Step 10: Save HA Configuration to AWS SSM

```bash
# Save HA configuration

HA_CONFIG=$(cat /etc/pve/ha/ha-config.cfg)

aws ssm put-parameter \
    --name /pve1/ha/config \
    --value "$HA_CONFIG" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/ha/enabled \
    --value "true" \
    --type String \
    --region us-west-2 \
    --overwrite

echo "HA configuration saved to AWS SSM"
```

---

## Validation Checklist

- [ ] Redfish access working for all 3 BMCs
- [ ] HA manager enabled (`ha-manager status`)
- [ ] HA groups defined (critical-vms, standard-vms)
- [ ] Fencing script created and tested
- [ ] Critical VMs registered for HA (vm:100, etc.)
- [ ] STONITH enabled in Corosync
- [ ] Watchdog timer running on all nodes
- [ ] Network isolation test: VMs failover successfully
- [ ] HA logs show proper recovery actions
- [ ] HA status monitored in Proxmox web UI

---

## Troubleshooting

### HA Manager Not Starting
```bash
# Check if cluster initialized
pvecm nodes

# If cluster issues, fix cluster first (Phase 3)

# Restart HA services
systemctl restart pve-ha-lrm
systemctl restart pve-ha-crm
```

### VM Not Failing Over
```bash
# Check if VM registered for HA
ha-manager status | grep vm:VMID

# If not registered
ha-manager add vm:VMID --group critical-vms

# Check HA logs for failures
tail -100 /var/log/pve/ha-manager.log | grep vm:VMID
```

### Fencing Script Fails
```bash
# Test Redfish manually
curl -k -u root:PASSWORD https://10.20.0.12/redfish/v1/Systems/1/

# Verify firewall allows Redfish (port 443)
netstat -tlnp | grep 443

# Check fencing script logs
tail -f /var/log/syslog | grep fence
```

### Node Stuck in Fenced State
```bash
# Manual intervention to recover node
ha-manager recover <node>

# Or force recovery
systemctl restart pve-ha-crm

# Monitor recovery
tail -f /var/log/pve/ha-manager.log
```

---

## Next Steps

After HA validation:

1. Test failover scenarios with actual VMs/containers
2. Document recovery procedures
3. Proceed to **Phase 8: Monitoring and Logging Integration**

---

**Phase 7 Status**: [Start Date] - [Completion Date]
**HA Status**: OPERATIONAL (Redfish fencing, watchdog, STONITH enabled)

