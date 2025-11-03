# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository contains documentation and configuration planning for a 3-node Proxmox VE cluster designed to provide infrastructure VMs and LXC containers across multiple VLANs. Some VMs act as gateway systems bridging different VLANs.

## Infrastructure Architecture

### Hardware Configuration (Per Host)
- **CPU**: AMD Genoa 9534 (64C/128T, 2.45GHz)
- **Memory**: 72x 96GB DDR5-5600 modules
- **Boot Storage**: 2x Micron 7450 PRO 480GB NVMe (mirrored via Proxmox)
- **Data Storage**: 12x 7.68TB NVMe PCIe5 SSDs (1DWPD TLC)
  - Will be configured as either:
    - Replicated Ceph flash pool across hosts, OR
    - One ZFS dRAID pool per host
- **GPU**: Single NVIDIA A16 64GB (shared via vGPU/MIG with LXC containers and VMs)
- **Network Interfaces**:
  - 1x 1G IPMI/Redfish management port (dedicated switch network)
  - 2x 25GbE SFP28 (Mellanox CX-6) - not actively planned for use
  - 2x 200GbE QSFP56 (MCX653106A-HDAT CX-6 VPI) with multiple VLANs

### Network Topology
- Dual CX-6 200G NICs per host connected to redundant HPE 5960 400G switches
- Switches configured as EVPN/VXLAN environment with ESI-based MC-LAG support
- **5 VLANs** for VMs/LXC containers only
- **1 isolated VLAN** bound to host OS, accessible only by sysadmins
- Each host mounts a Weka file system that hosts most VMs and LXC containers

## Key Design Considerations

### Storage Strategy
The data storage SSDs can be configured in two ways:
1. **Ceph flash pool**: Replicated across all 3 hosts for high availability
2. **ZFS dRAID**: One pool per host for maximum performance

When making storage recommendations, consider:
- Ceph provides better HA but slightly lower performance
- ZFS dRAID provides maximum performance but requires host-level HA
- Weka file system will carry most workloads

### Network Isolation
- VMs and LXC containers must NEVER have direct access to the host OS VLAN
- Only the isolated sysadmin VLAN can reach host management interfaces
- Gateway VMs bridge specific VLANs - document any VLAN routing carefully

### GPU Sharing
- NVIDIA A16 GPUs support both MIG (Multi-Instance GPU) and vGPU modes
- Consider MIG for containerized workloads (LXC)
- Consider vGPU for full VM GPU access
- Document which mode is being used when configuring GPU allocation

## Reference Documents

- **README.md**: Overview of cluster purpose and hardware
- **hardware-sample-bom-supermicro.txt/csv**: Detailed bill of materials with part numbers
- **pve-admin-guide.md**: Complete Proxmox VE 9.0.8 administration guide (1.2MB reference)

## Deployment Decisions

### Confirmed Configuration
- **Storage Strategy**: Ceph flash pool (replicated across all 3 hosts)
  - Replication factor: 3 (min_size: 2)
  - Public network: vlan6
  - Cluster network: vlan6
  - Recommended pools:
    - `rbd-vms`: For VM disks (size: 60% of total)
    - `rbd-containers`: For LXC containers (size: 30% of total)
    - `cephfs-data`: CephFS data pool (size: 8% of total)
    - `cephfs-metadata`: CephFS metadata pool (size: 2% of total, SSD optimized)
- **Weka Mount**: WekaFS native protocol, mounted after boot (not during bootstrap)
- **VLAN Naming**: vlan1, vlan2, vlan3, vlan4, vlan5 (VM/LXC), vlan6 (isolated host OS/sysadmin)
- **IP Addressing**:
  - Placeholder subnets will be used (10.x.x.x ranges)
  - Host OS on vlan6: Static IPs
  - Actual IPs stored in AWS SSM Parameter Store
- **GPU Allocation**:
  - MIG enabled with dynamic configuration
  - Profile: 3g.20gb slices
  - 2/3 resources for LXC containers, 1/3 for VMs
- **Cluster Configuration**:
  - Cluster Name: pve1
  - Corosync: Uses vlan6 (host OS network)
  - Corosync Rings: Multiple rings configured for redundancy
  - HA Manager: Enabled with IPMI/Redfish fencing
  - Fencing Method: Redfish API (preferred over IPMI for modern BMCs)
- **Network Bonding**: ESI MC-LAG with both 200G links for maximum redundancy and performance
- **Deployment Method**:
  - USB boot with custom unattended Proxmox installer
  - Post-install automation scripts
  - Ansible orchestration from one Proxmox host (designated as Ansible control node)
  - No PXE boot capability needed
- **DevOps**:
  - Ansible playbooks stored in public GitHub
  - Parameters (IPs, hostnames, credentials) stored in AWS SSM Parameter Store
  - AWS Region: us-west-2
  - IAM roles/policies for SSM access included in plan
  - SSM parameter hierarchy to be defined as part of deployment plan
  - SSH Keys: ED25519 key pairs for Ansible automation, RSA 4096 for admin access
  - Ansible control node: Runs on pve1-node1

### Host Configuration
- **Hostnames**: pve1-node1, pve1-node2, pve1-node3
- **Proxmox Version**: Latest stable (9.0.8+)
- **Repository**: Enterprise repository (subscription required but not yet purchased - plan includes migration path)
- **Roles**: No specific role assignment - all nodes are equal peers

### Security & Authentication
- **Authentication**: Active Directory integration
  - AD server details stored in AWS SSM (placeholders in plan)
- **Two-Factor Authentication**: Enabled with Duo integration for web UI
  - Duo configuration stored in AWS SSM (placeholders in plan)
- **SSH Access**: Key-based authentication only (passwords disabled)
  - Ansible: ED25519 keys (modern, fast, secure)
  - Admin access: RSA 4096 keys (broad compatibility)

### Backup Strategy
- **Proxmox Backup Server (PBS)**: Deployed as VM on the cluster
- **Backup Storage**: External S3-compatible Ceph cluster
- **Backup Scope**: All VMs, LXC containers, and cluster configuration

### Monitoring & Logging
- **Monitoring Stack**: Prometheus + Grafana (deployed as VMs or LXC containers)
- **Metrics Collection**: Node exporter, Ceph exporter, PVE exporter
- **Centralized Logging**: Microsoft Defender XDR Logging integration
  - Defender XDR workspace/tenant details stored in AWS SSM (placeholders in plan)
  - **Primary Method**: Azure Log Analytics agent (Microsoft Monitoring Agent)
  - **Alternative Methods** (documented for reference):
    - Syslog forwarding (traditional method)
    - Azure Arc for servers (modern cloud-native approach)
    - Custom API integration
- **Log Sources**: All Proxmox hosts, VMs, containers, and Ceph cluster

### Deployment Phases
The deployment plan will be organized into sequential phases:
1. **Phase 1**: Base OS installation and initial configuration
2. **Phase 2**: Network configuration (VLANs, bonds, ESI MC-LAG)
3. **Phase 3**: Cluster formation and Corosync setup
4. **Phase 4**: Ceph storage deployment
5. **Phase 5**: GPU configuration (NVIDIA drivers, MIG setup)
6. **Phase 6**: Ansible automation framework
7. **Phase 7**: HA configuration and fencing
8. **Phase 8**: Monitoring and logging integration
9. **Phase 9**: Backup infrastructure (PBS + S3)
10. **Phase 10**: Weka filesystem integration
11. **Phase 11**: Testing and validation

## Cluster Configuration Notes

When working on Proxmox configurations:
- Boot drives should always be configured in ZFS mirror (RAID-1)
- Document any changes to VLAN assignments clearly
- Keep track of which hosts are assigned to which storage strategy (Ceph vs ZFS)
- IPMI/Redfish interfaces are on separate management network
- Consider ESI MC-LAG configuration for 200G uplinks when planning network redundancy
