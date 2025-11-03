# Phase 1: Base OS Installation and Initial Configuration

## Overview

This phase covers USB-based installation of Proxmox VE with unattended preseed configuration, followed by post-install bootstrapping to prepare for cluster formation.

**Duration**: ~30 minutes per node (3x sequential = 90 minutes total)
**Prerequisites**: USB media prepared, BIOS/BMC configured, network accessible

---

## Step 1: Prepare USB Installation Media

### Download Proxmox ISO

```bash
# On your local workstation
cd ~/proxmox-deployment
wget https://enterprise.proxmox.com/iso/proxmox-ve_9.0-2.iso
# Alternative (community): https://www.proxmox.com/en/downloads/item/proxmox-ve-9-0-iso
```

### Prepare USB Media (macOS/Linux)

```bash
# Identify USB device
lsblk  # or diskutil list (macOS)

# Create bootable USB (example: /dev/sdb)
sudo dd if=proxmox-ve_9.0-2.iso of=/dev/sdb bs=4M conv=fsync status=progress
sudo eject /dev/sdb
```

### Copy Preseed Configuration to USB

After ISO is written:

```bash
# Mount USB media
sudo mount /dev/sdb1 /mnt/usb

# Create preseed directory
sudo mkdir -p /mnt/usb/preseed

# Copy preseed files (see below)
sudo cp preseed.cfg /mnt/usb/preseed/
sudo cp post-install.sh /mnt/usb/preseed/

# Unmount
sudo umount /mnt/usb
```

---

## Step 2: Boot Node 1 from USB

1. **Physical Access**: Connect USB media to pve1-node1 USB port
2. **BIOS Setup**:
   - Reboot and enter BIOS (usually F2 or DEL during boot)
   - Set USB drive as boot priority
   - Enable XMP/DOCP for DDR5 memory
   - Enable virtualization (SVM/VMX)
   - Disable Secure Boot (Proxmox compatibility)
   - Save and exit
3. **Boot**: Node will boot from USB

---

## Step 3: Proxmox Installer - Unattended Installation

The installer will:
- Detect hardware automatically
- Use preseed configuration for non-interactive setup
- Configure RAID-1 ZFS mirror for boot drives
- Partition data SSDs for Ceph OSD allocation

### Preseed Configuration File

Create file: `preseed/preseed.cfg`

```bash
# Proxmox VE 9.x Preseed Configuration
# ==================================

# Hostname and domain
d-i netcfg/get_hostname string pve1-node1
d-i netcfg/get_domain string example.com
d-i netcfg/hostname string pve1-node1

# Network setup (static via VLAN6)
d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_timeout string 5
d-i netcfg/dhcp_options select "Configure network manually"

# Network configuration - PLACEHOLDER
# Will be replaced with actual values from AWS SSM during installation
# Static IP: 10.30.0.11 (vlan6) - node1, adjust for node2/3
d-i netcfg/get_ipaddress string 10.30.0.11
d-i netcfg/get_netmask string 255.255.255.0
d-i netcfg/get_gateway string 10.30.0.1
d-i netcfg/get_nameservers string 8.8.8.8 8.8.4.4
d-i netcfg/confirm_static boolean true

# Proxmox-specific partitioning
# Boot drives (nvme0n1, nvme1n1) configured as ZFS RAID-1
d-i partman/early_command string \
    debconf-set partman-auto/disk "/dev/nvme0n1 /dev/nvme1n1"; \
    debconf-set partman-auto/method zfs; \
    debconf-set partman-zfs/raidlevel zfs1;

# Data SSDs (/dev/nvme2n1 through /dev/nvme13n1)
# Reserved for Ceph OSD - will not be partitioned during install

# Proxmox repository (enterprise - requires subscription)
d-i apt-setup/services-select multiselect proxmox-enterprise
# Alternative (community)
# d-i apt-setup/services-select multiselect proxmox-pve-release

# Root password - PLACEHOLDER
# SSH key-based auth will be configured post-install
d-i passwd/root-password password ProxmoxTemp123!
d-i passwd/root-password-again password ProxmoxTemp123!

# SSL certificates
d-i cert-generator/hostname string pve1-node1
d-i cert-generator/domain string example.com

# Finish installation
d-i finish-install/reboot_in_background boolean true
```

---

## Step 4: Post-Installation Bootstrap Script

After first boot, the following script runs to prepare for cluster/networking:

Create file: `preseed/post-install.sh`

```bash
#!/bin/bash
set -e

# Post-Installation Bootstrap Script for Proxmox pve1
# Runs immediately after OS installation

echo "=== Proxmox pve1 Post-Installation Bootstrap ==="
date

# Node identification
NODE_NAME="pve1-node1"  # Will be parameterized
NODE_NUMBER="1"

# AWS SSM Parameter Retrieval Function
# Requires AWS CLI and IAM permissions
get_ssm_param() {
    local param_name=$1
    aws ssm get-parameter \
        --name "$param_name" \
        --region us-west-2 \
        --query 'Parameter.Value' \
        --output text 2>/dev/null || echo "FAILED"
}

echo "[1/8] Retrieving configuration from AWS SSM..."
VLAN6_IP=$(get_ssm_param "/pve1/nodes/node${NODE_NUMBER}/vlan6_ip")
VLAN6_GW=$(get_ssm_param "/pve1/network/vlan6/gateway")
VLAN6_SUBNET=$(get_ssm_param "/pve1/network/vlan6/subnet")
DNS_SERVERS=$(get_ssm_param "/pve1/network/dns_servers")
NTP_SERVERS=$(get_ssm_param "/pve1/network/ntp_servers")

if [[ "$VLAN6_IP" == "FAILED" ]]; then
    echo "ERROR: Failed to retrieve SSM parameters. Check AWS credentials."
    exit 1
fi

echo "[2/8] Configuring static IP address (VLAN6)..."
cat > /etc/network/interfaces << EOF
# Proxmox pve1 Network Configuration - Phase 1 (Bootstrap)
# Final network config will be applied in Phase 2

auto lo
iface lo inet loopback

# Management network (vlan6) - temporary for cluster bootstrap
auto vlan6
iface vlan6 inet static
    address $VLAN6_IP/24
    gateway $VLAN6_GW
    dns-nameservers $DNS_SERVERS

EOF

echo "[3/8] Configuring systemd-resolved..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/pve1.conf << EOF
[Resolve]
DNS=$DNS_SERVERS
FallbackDNS=8.8.8.8 8.8.4.4
DNSSEC=no
EOF

systemctl restart systemd-resolved

echo "[4/8] Configuring NTP (Chrony)..."
sed -i 's/^pool .*/# commented out/' /etc/chrony/chrony.conf
for ntp_server in $NTP_SERVERS; do
    echo "server $ntp_server iburst" >> /etc/chrony/chrony.conf
done
systemctl restart chrony
timedatectl set-timezone UTC

echo "[5/8] Installing AWS CLI and dependencies..."
apt-get update
apt-get install -y awscli jq curl wget vim git

echo "[6/8] Retrieving SSH keys from AWS SSM..."
# Retrieve Ansible public key
ANSIBLE_PUBKEY=$(get_ssm_param "/pve1/ssh_keys/ansible/public_key")

# Create root SSH config
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Add Ansible SSH key for non-password authentication
echo "$ANSIBLE_PUBKEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Disable password-based SSH login
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh

echo "[7/8] Updating system packages..."
apt-get upgrade -y
apt-get install -y \
    build-essential \
    linux-headers-generic \
    git \
    python3-pip \
    python3-venv

echo "[8/8] System bootstrap complete!"
echo "Host: $NODE_NAME"
echo "VLAN6 IP: $VLAN6_IP"
echo "Ready for Phase 2: Network configuration"

# Log bootstrap completion
cat > /var/log/pve1-bootstrap.log << EOF
Proxmox pve1 Bootstrap Completed
Date: $(date)
Hostname: $NODE_NAME
VLAN6 IP: $VLAN6_IP
Status: SUCCESS
EOF

date >> /var/log/pve1-bootstrap.log
echo "Bootstrap logs saved to /var/log/pve1-bootstrap.log"
```

---

## Step 5: Initial SSH Access Verification

After node boots and bootstrap completes:

```bash
# From Ansible control node (or any node with SSH key)
ssh -i ~/.ssh/pve1_ansible_ed25519 root@10.30.0.11

# Verify system
hostname -f       # Should show: pve1-node1.example.com
ip addr           # Should show vlan6 with correct IP
pvecm nodes       # Will fail initially (no cluster yet)
```

---

## Step 6: Repeat for Nodes 2 and 3

Repeat Steps 2-5 for pve1-node2 and pve1-node3:

**Modifications for each node:**
- Change hostname in preseed: `pve1-node2`, `pve1-node3`
- Change IP addresses: `10.30.0.12`, `10.30.0.13`
- Update preseed `/NODE_NUMBER` SSM retrieval

---

## Step 7: Validation Checklist

For each node, verify:

- [ ] Hostname correctly set
- [ ] VLAN6 IP static and accessible from network
- [ ] SSH key-based login works
- [ ] Password-based SSH disabled
- [ ] System packages updated
- [ ] Time synchronized (chronyc tracking)
- [ ] All data SSDs visible (`lsblk | grep nvme`)
- [ ] Boot ZFS mirror verified (`zpool status`)
- [ ] No Proxmox cluster yet (`pvecm nodes` returns error)

---

## Troubleshooting

### USB Boot Fails
- Verify USB media created correctly (`dd` command)
- Try different USB port
- Check BIOS boot order
- Disable Secure Boot in BIOS

### Preseed Configuration Not Applied
- Ensure preseed file copied to correct path on USB
- Check installer log: `/var/log/installer/syslog`
- Manual installation as fallback

### Network Not Configured Post-Install
- Verify `/etc/network/interfaces` file syntax
- Restart networking: `systemctl restart networking`
- Check VLAN VLAN configuration from network admin

### SSH Access Denied
- Verify SSH key copied to `/root/.ssh/authorized_keys`
- Check SSH daemon running: `systemctl status ssh`
- Verify permissions: `ls -la /root/.ssh/`

### SSM Parameter Retrieval Fails
- Verify AWS CLI installed: `aws --version`
- Check IAM role attached to Proxmox nodes
- Test manually: `aws ssm get-parameter --name /pve1/nodes/node1/vlan6_ip --region us-west-2`

---

## Next Steps

Once all 3 nodes are installed and bootstrapped:

1. Verify all 3 nodes network connectivity to each other
2. Proceed to **Phase 2: Network Configuration** for ESI MC-LAG and VLAN setup
3. Document any deviations from plan in deployment log

---

**Phase 1 Status**: [Start Date] - [Completion Date]
**Nodes Completed**: 1/3, 2/3, 3/3

