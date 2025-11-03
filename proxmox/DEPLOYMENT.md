# Proxmox Cluster Deployment Plan

## Overview

This document provides a comprehensive, step-by-step deployment plan for the 3-node Proxmox VE cluster with advanced capabilities including Ceph storage, GPU MIG support, Active Directory integration, and full Ansible automation.

**Cluster Name**: pve1
**Nodes**: pve1-node1, pve1-node2, pve1-node3
**Proxmox Version**: Latest stable (9.0.8+)
**Infrastructure**: 3 x AMD Genoa 9534, 72x 96GB DDR5, 12x 7.68TB NVMe per node

---

## Table of Contents

1. [Pre-Deployment Checklist](#pre-deployment-checklist)
2. [Architecture Overview](#architecture-overview)
3. [AWS SSM Parameter Store Setup](#aws-ssm-parameter-store-setup)
4. [Phase-by-Phase Deployment](#phase-by-phase-deployment)
5. [Quick Reference](#quick-reference)

---

## Pre-Deployment Checklist

### Hardware Verification
- [ ] All 3 nodes have correct CPU, RAM, storage configurations
- [ ] BIOS firmware updated to latest version
- [ ] BMC/Redfish firmware updated and accessible
- [ ] Boot drives (2x Micron 7450 PRO 480GB) installed and recognized
- [ ] Data storage (12x 7.68TB NVMe) installed and recognized
- [ ] NVIDIA A16 GPUs installed and visible in BIOS
- [ ] Dual 200G NICs (MCX653106A-HDAT) installed and visible
- [ ] 1G management NIC (IPMI) connected to dedicated management switch

### Network Preparation
- [ ] HPE 5960 400G switches configured for EVPN/VXLAN
- [ ] ESI MC-LAG configured on switches
- [ ] VLAN 6 (sysadmin/host OS) created on switches
- [ ] VLAN 1-5 (VMs/LXC) created on switches
- [ ] Static IPs allocated for 3 nodes on VLAN 6 (documented in AWS SSM)
- [ ] IPMI/Redfish IPs configured on management switch
- [ ] Redfish API credentials tested and working

### AWS Preparation
- [ ] AWS Account active in us-west-2 region
- [ ] IAM role created for Proxmox nodes (SSM access)
- [ ] SSM Parameter Store namespace created: `/pve1/`
- [ ] Service role attached to EC2 instance or configured for direct access
- [ ] Credentials/SSH keys stored in AWS Secrets Manager or SSM

### External Services
- [ ] Weka filesystem cluster accessible and export points documented
- [ ] External S3-compatible Ceph cluster for backups (credentials ready)
- [ ] Active Directory server details documented (domain, DN, bind account)
- [ ] Duo API credentials ready for 2FA integration
- [ ] Microsoft Defender XDR workspace/tenant info documented
- [ ] Azure Log Analytics workspace created and ready

### USB Installation Media
- [ ] USB media prepared with custom Proxmox installer
- [ ] Unattended installation scripts tested (preseed/installer config)
- [ ] Post-install automation scripts on separate partition

---

## Architecture Overview

### Network Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                    HPE 5960 400G Switches (EVPN/VXLAN)          │
│                         ESI MC-LAG Enabled                      │
└─────────────────────────────────────────────────────────────────┘
        │                    │                    │
        │ 200G QSFP56        │ 200G QSFP56        │ 200G QSFP56
        │ (2 links per)      │ (2 links per)      │ (2 links per)
        ▼                    ▼                    ▼
    ┌─────────┐         ┌─────────┐         ┌─────────┐
    │pve1-node1         │pve1-node2         │pve1-node3
    │(Ansible Ctrl)     │                   │
    └─────────┘         └─────────┘         └─────────┘

    VLANs per node:
    - vlan1-5: VMs/LXC containers (performance data)
    - vlan6: Host OS / Sysadmin only (Corosync, management)
    - Management: 1G IPMI/Redfish (dedicated switch)
```

### Storage Architecture

```
Ceph Flash Pool (3 nodes, replicated)
├── rbd-vms (60%)
│   └── VM disk images
├── rbd-containers (30%)
│   └── LXC container disks
├── cephfs-data (8%)
│   └── Shared file data
└── cephfs-metadata (2%)
    └── File metadata (SSD optimized)

External Backup:
└── S3-compatible Ceph cluster
    └── PBS snapshots
```

### GPU Distribution

```
NVIDIA A16 64GB per node
├── MIG enabled (dynamic configuration)
├── Profile: 3g.20gb slices
└── Allocation:
    ├── LXC containers: 2/3 resources
    └── VMs: 1/3 resources
```

---

## AWS SSM Parameter Store Setup

### Parameter Hierarchy Structure

All parameters stored in AWS Systems Manager Parameter Store with hierarchy:

```
/pve1/
├── network/
│   ├── vlan6/subnet              "10.30.0.0/24"
│   ├── vlan6/gateway             "10.30.0.1"
│   ├── vlan1/subnet              "10.31.0.0/24"
│   ├── vlan2/subnet              "10.32.0.0/24"
│   ├── vlan3/subnet              "10.33.0.0/24"
│   ├── vlan4/subnet              "10.34.0.0/24"
│   ├── vlan5/subnet              "10.35.0.0/24"
│   ├── dns_servers               "8.8.8.8,8.8.4.4"
│   ├── ntp_servers               "0.pool.ntp.org,1.pool.ntp.org"
│   └── domain                    "example.com"
├── nodes/
│   ├── node1/hostname            "pve1-node1"
│   ├── node1/vlan6_ip            "10.30.0.11"
│   ├── node1/ipmi_ip             "10.20.0.11"
│   ├── node2/hostname            "pve1-node2"
│   ├── node2/vlan6_ip            "10.30.0.12"
│   ├── node2/ipmi_ip             "10.20.0.12"
│   ├── node3/hostname            "pve1-node3"
│   ├── node3/vlan6_ip            "10.30.0.13"
│   └── node3/ipmi_ip             "10.20.0.13"
├── cluster/
│   ├── name                      "pve1"
│   ├── cluster_id                "auto-generated"
│   ├── corosync_key              "(base64 encoded)"
│   └── pmgnt_key                 "(base64 encoded)"
├── authentication/
│   ├── ad/domain                 "corp.example.com"
│   ├── ad/base_dn                "dc=corp,dc=example,dc=com"
│   ├── ad/bind_user              "ansible@corp.example.com"
│   ├── ad/bind_password          "(SecureString)"
│   ├── duo/integration_key       "(SecureString)"
│   ├── duo/secret_key            "(SecureString)"
│   └── duo/api_hostname          "api-xxxxxxxx.duosecurity.com"
├── backup/
│   ├── s3_endpoint               "https://s3.example.com"
│   ├── s3_bucket                 "pve1-backups"
│   ├── s3_access_key             "(SecureString)"
│   └── s3_secret_key             "(SecureString)"
├── monitoring/
│   ├── defender_xdr/tenant_id    "(SecureString)"
│   ├── defender_xdr/client_id    "(SecureString)"
│   ├── defender_xdr/client_secret "(SecureString)"
│   ├── defender_xdr/workspace_id "(SecureString)"
│   ├── prometheus/retention      "30d"
│   └── grafana/admin_password    "(SecureString)"
├── weka/
│   ├── mount_path                "/mnt/weka"
│   ├── export_path               "10.40.0.1:/pve1"
│   ├── protocol                  "nfs"
│   └── mount_options             "vers=3,hard,intr,timeo=600"
├── ssh_keys/
│   ├── ansible/public_key        "(ED25519 public key)"
│   ├── ansible/private_key       "(SecureString - ED25519 private key)"
│   ├── admin/public_key          "(RSA 4096 public key)"
│   └── admin/private_key         "(SecureString - RSA 4096 private key)"
└── ceph/
    ├── fsid                      "auto-generated"
    ├── mon_secret                "(base64 encoded)"
    └── admin_key                 "(base64 encoded)"
```

### Creating Parameters (Ansible Lookup)

In Ansible playbooks, reference parameters like:

```yaml
- name: Get node IP from SSM
  set_fact:
    node_vlan6_ip: "{{ lookup('aws_ssm', '/pve1/nodes/node1/vlan6_ip') }}"
```

---

## Phase-by-Phase Deployment

### Phase 1: Base OS Installation and Initial Configuration
- [Phase 1 Detailed Guide](./deployment/phase1-base-install.md)
- USB boot with custom Proxmox installer
- Unattended preseed-based installation
- Post-install networking bootstrap
- Initial SSH key setup

### Phase 2: Network Configuration (VLANs, Bonds, ESI MC-LAG)
- [Phase 2 Detailed Guide](./deployment/phase2-network.md)
- Configure dual 200G NIC bonding (ESI MC-LAG support)
- VLAN interface creation (vlan1-6)
- Network bridge configuration for VMs/LXC
- Validation and testing

### Phase 3: Cluster Formation and Corosync Setup
- [Phase 3 Detailed Guide](./deployment/phase3-cluster.md)
- Initialize Proxmox cluster (pve1)
- Configure Corosync with multiple rings for redundancy
- Cluster join for node2 and node3
- Cluster status verification

### Phase 4: Ceph Storage Deployment
- [Phase 4 Detailed Guide](./deployment/phase4-ceph.md)
- Deploy Ceph MON, OSD, and MDS services
- Create rbd-vms, rbd-containers pools
- Create cephfs-data and cephfs-metadata pools
- Configure replication (factor 3, min_size 2)
- Storage validation

### Phase 5: GPU Configuration (NVIDIA Drivers, MIG)
- [Phase 5 Detailed Guide](./deployment/phase5-gpu.md)
- Install NVIDIA driver 550+ (NVIDIA vGPU software)
- Enable MIG with 3g.20gb profile
- Configure dynamic GPU allocation
- Test GPU access from LXC/VMs

### Phase 6: Ansible Automation Framework
- [Phase 6 Detailed Guide](./deployment/phase6-ansible.md)
- Deploy Ansible control node (on pve1-node1)
- Configure AWS SSM integration
- Create playbook structure
- Test infrastructure-as-code automation

### Phase 7: HA Configuration and Redfish Fencing
- [Phase 7 Detailed Guide](./deployment/phase7-ha.md)
- Configure Proxmox HA Manager
- Set up Redfish fencing (IPMI alternative)
- Define HA groups and policies
- Test failover scenarios

### Phase 8: Monitoring and Logging Integration
- [Phase 8 Detailed Guide](./deployment/phase8-monitoring.md)
- Deploy Prometheus + Grafana
- Configure node exporters, Ceph exporters, PVE exporters
- Deploy Azure Log Analytics agent
- Integrate with Microsoft Defender XDR
- Create monitoring dashboards

### Phase 9: Backup Infrastructure (PBS + S3)
- [Phase 9 Detailed Guide](./deployment/phase9-backup.md)
- Deploy Proxmox Backup Server (PBS) as VM
- Configure S3-compatible external Ceph backend
- Set up backup retention policies
- Test backup and restore procedures

### Phase 10: Weka Filesystem Integration
- [Phase 10 Detailed Guide](./deployment/phase10-weka.md)
- Mount Weka filesystems after boot
- Configure automount entries
- Set up quota management
- Validate performance and connectivity

### Phase 11: Testing and Validation
- [Phase 11 Detailed Guide](./deployment/phase11-testing.md)
- Network redundancy testing (link failover)
- Storage failover testing (Ceph OSD failure)
- Compute redundancy testing (node failure)
- Security validation (VLAN isolation, AD auth, 2FA)
- Performance benchmarking
- Disaster recovery drills

---

## Quick Reference

### SSH Access (Post-Installation)

```bash
# From Ansible control (pve1-node1)
ssh -i /root/.ssh/id_ed25519 root@10.30.0.12    # pve1-node2
ssh -i /root/.ssh/id_ed25519 root@10.30.0.13    # pve1-node3

# From external admin workstation
ssh -i ~/.ssh/pve1_admin_rsa root@10.30.0.11    # pve1-node1
```

### Useful Commands

```bash
# Check cluster status
pvecm status

# Check Ceph status
ceph status

# Check GPU MIG status
nvidia-smi -L

# Check Proxmox HA status
ha-manager status

# View Ansible inventory
cat /etc/ansible/hosts

# Check SSM parameters
aws ssm get-parameters-by-path --path /pve1 --region us-west-2
```

### Rollback Procedures

If deployment fails at any phase:
1. Document the error from `/var/log/syslog` or `/var/log/pve/`
2. Refer to troubleshooting section in specific phase guide
3. For critical failures: Re-image USB media and restart from Phase 1
4. All infrastructure-as-code (Ansible/scripts) is idempotent and safe to re-run

---

## Support & Documentation

- **Proxmox Admin Guide**: [pve-admin-guide.md](./pve-admin-guide.md)
- **CLAUDE.md**: Project guidelines and configuration decisions
- **README.md**: High-level cluster overview
- **Hardware BOM**: [hardware-sample-bom-supermicro.csv](./hardware-sample-bom-supermicro.csv)

---

**Deployment Started**: [Date/Time]
**Deployment Completed**: [Date/Time]
**Deployment By**: [Administrator Name]

