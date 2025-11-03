# Phase 5: GPU Configuration (NVIDIA Drivers, MIG)

## Overview

This phase installs NVIDIA drivers for the A16 GPUs, enables Multi-Instance GPU (MIG) mode with 3g.20gb profiles, and configures dynamic GPU allocation for LXC containers and VMs.

**Duration**: ~45 minutes per node
**Prerequisites**: Phase 1-4 complete, GPU visible in BIOS

---

## GPU Architecture

```
NVIDIA A16 64GB (per node)
├── MIG Mode: Enabled (dynamic configuration)
├── Profile: 3g.20gb slices
└── Allocation:
    ├── LXC containers: 2/3 resources (4 slices per node)
    └── VMs: 1/3 resources (2 slices per node)
    = 6 total GPU slices per node (3 × 20GB from single 64GB GPU)
```

---

## Step 1: Verify GPU Hardware

### Check GPU Presence

On each node:

```bash
# SSH to pve1-node1
ssh root@10.30.0.11

# List GPUs
lspci | grep -i nvidia

# Expected output:
# <slot>: NVIDIA Corporation Device <id> (rev a4) [NVIDIA A16 64GB]

# Get detailed info
lspci -vv | grep -A 20 "NVIDIA"

# Check for AMD/Intel GPU (should be none)
lspci | grep -E "AMD|Intel" | grep -i vga
```

### Verify GPU in BIOS

```bash
# During system boot, GPU should be visible in BIOS settings
# If not visible:
#   1. Check physical slot connections
#   2. Update motherboard BIOS
#   3. Check for BIOS setting enabling PCIe GPU

# After OS boot, firmware info
dmidecode | grep -i gpu
```

---

## Step 2: Install NVIDIA Driver

### Add NVIDIA Repository and Install Driver

```bash
# On Debian/Proxmox, add NVIDIA repo
apt-get update
apt-get install -y software-properties-common

# Add NVIDIA package repository
# For Debian 12 (Proxmox uses Debian 12):
curl https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/3bf863cc.pub | apt-key add -
echo "deb https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64 /" > /etc/apt/sources.list.d/nvidia-cuda-debian12.list

apt-get update

# Install NVIDIA driver (550+ required for MIG)
apt-get install -y nvidia-driver-550

# Install NVIDIA utilities
apt-get install -y nvidia-utils nvidia-smi
```

### Verify Driver Installation

```bash
# Reboot to load driver module
reboot

# After reboot, verify driver loaded
lsmod | grep nvidia

# Check GPU visibility
nvidia-smi

# Expected output:
# +-----------------------------------------------------------------------------+
# | NVIDIA-SMI 550.xx                  Driver Version: 550.xx                 |
# +-----------------------------------------------------------------------------+
# | GPU  Name              Persistence-M | Bus-Id          | GPU Util. Mem |
# |=============================================================================|
# |   0  NVIDIA A16         On            | 00:1d.0         |    0%    0MB |
# +-----------------------------------------------------------------------------+
```

### Verify MIG Capability

```bash
# Check if GPU supports MIG
nvidia-smi -L

# Expected for A16:
# GPU 0: NVIDIA A16 (UUID: GPU-xxxx-xxxx-xxxx-xxxx)

# Check MIG mode capability
nvidia-smi -i 0 -L

# Expected: Lists GPU instance types available
```

---

## Step 3: Enable MIG Mode

### Enable MIG on GPU

```bash
# Set GPU to MIG mode (requires system root and reboot or reset)
nvidia-smi -i 0 -mig 1

# Verify MIG enabled
nvidia-smi -i 0 -mig | grep "MIG"

# Expected output:
# MIG Mode for GPU 00000000:00:1D.0
# MIG Mode: Enabled
```

### Configure MIG Partitioning (3g.20gb Profile)

MIG profiles determine how GPU memory and cores are partitioned:

```bash
# Available profiles for A16 (60GB total usable):
# 1g.6gb   - 1 GPU instance with 6GB
# 2g.12gb  - 2 GPU instances with 12GB each
# 3g.20gb  - 3 GPU instances with 20GB each (what we want)

# Set to 3g.20gb profile (3 slices per GPU)
nvidia-smi -i 0 -mig reset-all

# Create 3 MIG instances with 3g.20gb profile
# Option A: Manual creation (one-time)
nvidia-smi -i 0 -C -G 0,1,1,1,1,1  # Creates 3 instances
# Alternative syntax:
# nvidia-smi -i 0 -mig reset-all && \
# nvidia-smi -i 0 -C -G 0,1,1,1,1,1

# Option B: Use configuration file (persistent after reboot)
# See Step 4 for persistence configuration
```

### Verify MIG Instances Created

```bash
# Check MIG instances
nvidia-smi

# Expected output:
# +------------------------------------------+
# | MIG instances                            |
# |====== GPU 0: NVIDIA A16 ======|
# | GPU Instance ID | Profile      | Memory |
# |===============|=============|========|
# |     0          | 3g.20gb      |  20GB  |
# |     1          | 3g.20gb      |  20GB  |
# |     2          | 3g.20gb      |  20GB  |
# +------------------------------------------+

# Get detailed info
nvidia-smi -L

# Should list GPU instances (MIG 0-2)
```

---

## Step 4: Make MIG Configuration Persistent

### Create Systemd Service for MIG Initialization

Create file: `/etc/systemd/system/nvidia-mig-init.service`

```ini
[Unit]
Description=NVIDIA MIG Configuration (3g.20gb profile)
After=network.target
Before=pveproxy.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nvidia-mig-init.sh
ExecStop=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

### Create MIG Initialization Script

Create file: `/usr/local/bin/nvidia-mig-init.sh`

```bash
#!/bin/bash
set -e

echo "=== Initializing NVIDIA MIG Configuration ==="
date

# Wait for GPU to be ready
sleep 2

# Enable MIG mode
nvidia-smi -i 0 -mig 1

# Wait for GPU to stabilize
sleep 2

# Reset any existing MIG instances
nvidia-smi -i 0 -mig reset-all

# Wait
sleep 1

# Create 3 MIG instances (3g.20gb profile)
# Format: -C -G <GPU_ID>,<instance_count>
# For 3 instances: -C -G 0,1,1,1,1,1
nvidia-smi -i 0 -C -G 0,1,1,1,1,1

# Verify
echo "MIG instances created:"
nvidia-smi

# Save configuration to SSM
PARTITION_INFO=$(nvidia-smi -L | grep "MIG Instance")
aws ssm put-parameter \
    --name /pve1/gpu/mig_config \
    --value "$PARTITION_INFO" \
    --type String \
    --region us-west-2 \
    --overwrite || true  # Ignore errors if not on AWS

echo "=== MIG Configuration Complete ==="
```

### Enable MIG Service

```bash
# Make script executable
chmod +x /usr/local/bin/nvidia-mig-init.sh

# Enable and start service
systemctl daemon-reload
systemctl enable nvidia-mig-init
systemctl start nvidia-mig-init

# Verify MIG instances active
nvidia-smi -L
```

---

## Step 5: Configure GPU Access for Containers

### Install NVIDIA Container Runtime

```bash
# Install NVIDIA container runtime
apt-get install -y nvidia-container-runtime

# Verify installation
which nvidia-container-runtime

# Update Docker/container config to use NVIDIA runtime
# For LXC, we'll configure GPU passthrough differently (Step 6)
```

### Configure LXC GPU Access (3 Approaches)

#### Approach A: GPU Device Passthrough (Recommended for our setup)

In Proxmox LXC container config (`/etc/pve/lxc/<vmid>.conf`):

```bash
# Add GPU access (example for container VMID 100)
# lxc.cgroup.devices.allow: c 195:* rwm  # For all NVIDIA devices
# lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
# lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
# lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
# lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
```

#### Approach B: MIG Device Mapping (Dynamic, per container)

For MIG instances, map specific MIG device:

```bash
# Example: Map MIG instance 0 to container
# In LXC config:
# lxc.cgroup.devices.allow: c 195:0 rwm
# lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
```

---

## Step 6: Configure GPU for VMs

### NVIDIA vGPU License (Optional for VMs)

For full GPU access in VMs, vGPU license may be needed. Skip if using MIG exclusively for containers.

### Configure VM GPU Passthrough (Optional)

In VM config, add GPU:

```bash
# Create VM with GPU support (via Proxmox web UI or config)
# PCI passthrough: enumerates available GPUs and can pass whole GPU or MIG instance
```

---

## Step 7: Validate MIG Configuration Across Nodes

### Repeat GPU Setup on Nodes 2 and 3

```bash
# SSH to each node and repeat Steps 1-6
# Can be automated via SSH or Ansible

for node in pve1-node2 pve1-node3; do
    node_ip=$(echo $node | grep -o '[0-9]*$' | xargs -I{} echo "10.30.0.$((10 + {}))")

    ssh root@$node_ip << 'EOF'
    # Steps 1-6 commands here (abbreviated)
    apt-get install -y nvidia-driver-550 nvidia-utils
    nvidia-smi
    nvidia-smi -i 0 -mig 1
    nvidia-smi -i 0 -mig reset-all
    nvidia-smi -i 0 -C -G 0,1,1,1,1,1
    systemctl enable nvidia-mig-init
    nvidia-smi
EOF
done
```

### Verify All Nodes

```bash
# Check GPU status on all nodes
for node in pve1-node1 pve1-node2 pve1-node3; do
    node_ip=$(echo $node | grep -o '[0-9]*$' | xargs -I{} echo "10.30.0.$((10 + {}))")
    echo "=== $node ==="
    ssh root@$node_ip "nvidia-smi -L"
done

# Expected: Each node lists 3 MIG instances (MIG 0-2)
```

---

## Step 8: Create Test LXC Container with GPU

### Create GPU-Enabled LXC Container

```bash
# Create container (VMID 100) with GPU access
pct create 100 local:vztmpl/debian-12-standard_12.1-1_amd64.tar.zst \
    --hostname gpu-test \
    --memory 8192 \
    --cores 8 \
    --net0 name=eth0,bridge=vmbr0,tag=1

# Add GPU access to container config
cat >> /etc/pve/lxc/100.conf << 'EOF'
# GPU access (MIG instance 0)
lxc.cgroup.devices.allow: c 195:0 rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /usr/lib/x86_64-linux-gnu/libnvidia-gl.so.550 usr/lib/x86_64-linux-gnu/libnvidia-gl.so.550 none bind,optional,create=file
lxc.mount.entry: /usr/bin/nvidia-smi usr/bin/nvidia-smi none bind,optional,create=file
EOF

# Start container
pct start 100

# Enter container and test GPU
pct exec 100 nvidia-smi

# Expected output:
# +-----------------------------------------------------------------------------+
# | NVIDIA-SMI 550.xx                  Driver Version: 550.xx                 |
# +-----------------------------------------------------------------------------+
# | GPU  Name                  Persistence-M | Bus-Id          | GPU Util. Mem |
# |=============================================================================|
# |   0  NVIDIA A16 MIG         On            | 00:1d.0-1       |     0%  0MB |
# +-----------------------------------------------------------------------------+
```

### Test GPU Compute

```bash
# Install CUDA toolkit in container for full testing
pct exec 100 apt-get update
pct exec 100 apt-get install -y nvidia-cuda-toolkit

# Run test
pct exec 100 cuda-memtest --stress --htod --dtoh --dtod --bidirectional --iterations 100

# Expected: Test completes successfully with no errors
```

---

## Step 9: Document GPU Allocation Strategy

### Create GPU Allocation Plan

Document in `/root/gpu-allocation-plan.txt`:

```
GPU Allocation Strategy for pve1 Cluster
=========================================

Per-Node Configuration:
- GPU: NVIDIA A16 64GB
- MIG Mode: Enabled (3g.20gb profile)
- Total Slices per node: 3 (3 × 20GB)

Allocation:
- LXC Containers: MIG 0, MIG 1 (2 slices)
- VMs: MIG 2 (1 slice)

Container Assignment:
- Container 100 (gpu-test): MIG 0
- Container 101 (ML-inference): MIG 1
- Container 102 (ML-training): MIG 2 (if VM GPU not used)

Dynamic Allocation:
- Use Proxmox API to dynamically add/remove GPU access
- Monitor via nvidia-smi within containers

Performance Expectations:
- Single MIG 3g.20gb: ~20% of full A16 performance
- 2 containers: ~40% of full A16 performance
- 3 containers: ~60% of full A16 performance
- Unused capacity: Available for VM or container scaling

Monitoring:
- nvidia-smi: Host GPU status
- pct exec <vmid> nvidia-smi: Container GPU view
- Ceph monitor for storage I/O during GPU jobs
```

---

## Step 10: Save GPU Configuration to AWS SSM

```bash
# Save MIG and GPU configuration

GPU_INFO=$(nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader)
MIG_CONFIG=$(nvidia-smi -L)

aws ssm put-parameter \
    --name /pve1/gpu/info \
    --value "$GPU_INFO" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/gpu/mig_instances \
    --value "$MIG_CONFIG" \
    --type String \
    --region us-west-2 \
    --overwrite

echo "GPU configuration saved to AWS SSM"
```

---

## Validation Checklist

- [ ] NVIDIA driver 550+ installed on all 3 nodes
- [ ] `nvidia-smi` shows all 3 GPUs
- [ ] MIG mode enabled on all GPUs
- [ ] 3 MIG instances (3g.20gb) created per GPU
- [ ] MIG initialization service enabled and persistent
- [ ] Test container created with GPU access
- [ ] `nvidia-smi` works inside test container
- [ ] GPU compute test passes (cuda-memtest or equivalent)
- [ ] GPU configuration saved to AWS SSM
- [ ] GPU is properly allocated (2/3 for LXC, 1/3 for VMs)

---

## Troubleshooting

### GPU Not Detected
```bash
# Check if GPU visible in BIOS/UEFI first
# Verify PCIe slot and power connections

# Reload drivers
modprobe -r nvidia_uvm
modprobe -r nvidia
modprobe nvidia
modprobe nvidia_uvm

# Check for driver errors
dmesg | grep -i nvidia
```

### MIG Creation Fails
```bash
# Ensure MIG mode enabled first
nvidia-smi -i 0 -mig 1

# Check if MIG mode supported (A16 supports it)
nvidia-smi -i 0 -mig | grep "Supported"

# Reset and try again
nvidia-smi -i 0 -mig reset-all
sleep 2
nvidia-smi -i 0 -C -G 0,1,1,1,1,1
```

### LXC GPU Access Denied
```bash
# Verify device files exist on host
ls -la /dev/nvidia* /dev/nvidia-*

# Check container cgroup permissions
cat /etc/pve/lxc/100.conf | grep -i nvidia

# Verify container has permission to access
pct exec 100 ls -la /dev/nvidia*
```

### Performance Lower Than Expected
```bash
# Check if GPU is being throttled (thermal)
nvidia-smi --query-gpu=temperature.gpu,clocks_throttle_reasons.active --format=csv,noheader

# Check GPU utilization during workload
nvidia-smi dmon

# Check PCIe link speed and width
lspci -vv | grep -A 10 NVIDIA | grep -E "Link|Width"
```

---

## Next Steps

After GPU validation:

1. Test GPU performance with real workloads (ML inference, etc.)
2. Implement GPU scheduling/quotas for container fair allocation
3. Proceed to **Phase 6: Ansible Automation Framework**

---

**Phase 5 Status**: [Start Date] - [Completion Date]
**GPU Configuration**: OPERATIONAL (3 nodes, MIG enabled, 3g.20gb profiles)

