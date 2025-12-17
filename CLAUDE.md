# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository documents and tracks the design, planning, and deployment of a **heterogeneous cyber infrastructure** including:
- **Proxmox VE** (3-node cluster): Virtualization platform for VMs and LXC containers
- **Weka.io** (9-node cluster): High-performance multi-protocol file system for AI workloads
- **Ceph**: Distributed block/object storage integrated with Proxmox
- **NVIDIA HPC**: GPU compute infrastructure (future)

## Architecture Pattern: Manual Execution with AD Authentication and Audit Trail

The core design philosophy separates **generic automation logic** (stored in public GitHub) from **site-specific topology and secrets** (stored in AWS Systems Manager Parameter Store), with **manual execution** by authenticated administrators.

### Key Principles
1. **Public Repository**: Contains automation playbooks, deployment documentation, and architecture guides
2. **AWS SSM Parameter Store**: Stores all IP addresses, MAC addresses, hostnames, credentials, and secrets
3. **Manual Execution**: Administrators run tug commands on-demand from a centralized Tugboat node (no automated triggers)
4. **AD Authentication + MFA**: All access requires Active Directory credentials with Duo two-factor authentication
5. **Role-Based Service Accounts**: Team-specific local accounts protected by AD group membership
6. **Complete Audit Trail**: All actions logged and attributed to individual users, forwarded to Azure Log Analytics
7. **Path-Based Hierarchy**: SSM parameters follow pattern `/{system_type}/{cluster_id}/{node_id}/{attribute}`

## Repository Structure

```
.
├── README.md              # High-level architecture and design patterns
├── LICENSE                # MIT License
├── ansible.cfg            # Ansible configuration (SSH transport for on-prem)
├── docs/                  # Tugboat operations documentation
│   ├── tugboat-admin-guide.md      # Administrator guide for Tugboat operations
│   ├── tugboat-access-control.md   # AD integration and role-based access
│   ├── tugboat-audit-compliance.md # Audit trail and compliance
│   └── tugboat-node-setup.md    # Management VM configuration
├── inventory/             # Dynamic inventory for Ansible
│   └── ssm_plugin.py      # Queries AWS SSM to build inventory at runtime
├── group_vars/            # Ansible group variables
│   ├── proxmox.yml        # Variables for all Proxmox nodes
│   ├── weka.yml           # Variables for all Weka nodes
│   ├── ceph.yml           # Variables for all Ceph nodes
│   └── nvidia.yml         # Variables for all NVIDIA HPC nodes
├── playbooks/             # Tugboat automation playbooks
│   ├── setup_proxmox.yml  # Configure Proxmox VE cluster
│   ├── setup_weka.yml     # Configure Weka file system
│   ├── setup_ceph.yml     # Configure Ceph storage
│   └── setup_nvidia.yml   # Configure NVIDIA HPC infrastructure
├── proxmox/               # Proxmox VE cluster documentation and deployment
│   ├── README.md          # Proxmox cluster overview and hardware
│   ├── CLAUDE.md          # Proxmox-specific guidance for Claude Code
│   ├── DEPLOYMENT.md      # Complete deployment plan with all phases
│   ├── deployment/        # Phase-by-phase deployment guides
│   │   ├── phase1-base-install.md
│   │   ├── phase2-network.md
│   │   ├── phase3-cluster.md
│   │   ├── phase4-ceph.md
│   │   ├── phase5-gpu.md
│   │   ├── phase6-ansible.md
│   │   ├── phase7-ha.md
│   │   ├── phase8-monitoring.md
│   │   ├── phase9-backup.md
│   │   ├── phase10-weka.md
│   │   └── phase11-testing.md
│   └── hardware-sample-bom-supermicro.csv
├── weka/                  # Weka.io file system cluster documentation
│   ├── README.md          # Weka cluster overview and hardware
│   ├── CLAUDE.md          # Weka-specific guidance for Claude Code
│   ├── hardware-sample-bom-weka-supermicro.csv
│   └── docs-weka-io/      # Symlink to Weka.io documentation (external)
└── tests/                 # Test examples and demonstrations
    └── example/           # AWS EC2 test demonstrating SSM + Ansible pattern
        ├── README.md      # Complete walkthrough of the example
        ├── launch-instance.sh
        ├── cleanup.sh
        ├── change-hostname.yml
        └── inventory.aws_ec2.yml
```

## Test Example: AWS EC2 + Ansible + SSM

The `tests/example/` directory contains a **working demonstration** of the Hybrid Cloud IaC pattern using AWS EC2.

**Purpose**: Validates the AWS SSM Parameter Store + Ansible integration pattern before applying it to physical infrastructure.

**Key Differences from Production**:
- **Connection Method**:
  - Test example uses **AWS SSM Agent** (no SSH, no open ports)
  - Production uses **SSH** with key-based authentication to on-premises servers
- **Discovery Method**:
  - Test example uses **AWS EC2 API** (discovers instances by tags)
  - Production uses **AWS SSM Parameter Store** (hierarchical parameter paths like `/proxmox/cl1/n01/ip`)
- **Target Infrastructure**:
  - Test example targets **AWS EC2 instances** (t4g.micro, ARM-based)
  - Production targets **on-premises physical servers** (Proxmox, Weka, Ceph, NVIDIA)

**What It Demonstrates**:
1. Dynamic inventory discovery (AWS EC2 API in test, SSM Parameter Store in production)
2. Runtime configuration retrieval from AWS SSM Parameter Store
3. Ansible playbook execution without hardcoded secrets
4. Separation of code (public GitHub) and data (AWS SSM)

**How to Use**: See `tests/example/README.md` for complete setup and walkthrough.

**Quick Start**:
```bash
cd tests/example
./launch-instance.sh           # Launch test instance
tug deploy -i inventory.aws_ec2.yml change-hostname.yml  # Run playbook
./cleanup.sh                   # Clean up resources
```

This example is a simplified version of the production automation pattern, designed for rapid testing without physical hardware.

## Architecture Overview

### High-Level Architecture Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SYSADMIN WORKSTATION                           │
│                         (Corporate network / VPN)                           │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  │ SSH with AD credentials + Duo MFA
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           MANAGEMENT NODE (VM)                              │
│                         tugboat.domain.local                           │
├─────────────────────────────────────────────────────────────────────────────┤
│  Authentication:  AD (SSSD/Realm) + Duo MFA                                 │
│  Service Accounts: svc-proxmox, svc-weka, svc-ceph, svc-nvidia              │
│  Access Control:  PAM validates AD group membership for su to svc-*        │
│  Execution:       tug wrapper fetches SSM + runs playbooks       │
│  Audit:           JSON logs → Syslog → Azure Log Analytics → Defender XDR  │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
        ┌─────────────────────────┼───────────────────────┐
        │ SSH (key-based)         │                       │
        ▼                         ▼                       ▼
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Proxmox    │         │    Weka      │         │   NVIDIA     │
│   Cluster    │         │   Cluster    │         │    HPC       │
└──────────────┘         └──────────────┘         └──────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                           AWS CLOUD (US-West-2)                             │
│                                                                             │
│   SSM Parameter Store: /{system_type}/{cluster_id}/{node_id}/{attribute}   │
│   - IPs, MACs, credentials (SecureString), configuration data              │
│   - Fetched at runtime by tug wrapper                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Access Control Model

```text
AD User authenticates via SSH + Duo MFA
              │
              ▼
     ┌────────────────────┐
     │ Personal AD Shell  │
     │ jsmith@DOMAIN.LOCAL│
     └────────┬───────────┘
              │
              │ su - svc-proxmox
              ▼
     ┌────────────────────┐     ┌─────────────────────────┐
     │ PAM checks AD      │────▶│ Is user in              │
     │ group membership   │     │ Proxmox-Admins@DOMAIN?  │
     └────────────────────┘     └────────────┬────────────┘
                                             │
                        ┌────────────────────┴────────────────────┐
                        │                                        │
                   ┌────▼────┐                              ┌────▼────┐
                   │   YES   │                              │   NO    │
                   │ Allow   │                              │ Deny    │
                   └────┬────┘                              └─────────┘
                        │
                        ▼
              ┌─────────────────────┐
              │ svc-proxmox shell   │
              │ Run: tug  │
              └─────────────────────┘
```

**Service Accounts and Required AD Groups:**

| Service Account | AD Group Required | Infrastructure Access |
|-----------------|-------------------|----------------------|
| `svc-proxmox` | `Proxmox-Admins@DOMAIN.LOCAL` | Proxmox VE clusters |
| `svc-weka` | `Weka-Admins@DOMAIN.LOCAL` | Weka file systems |
| `svc-ceph` | `Ceph-Admins@DOMAIN.LOCAL` | Ceph storage clusters |
| `svc-nvidia` | `NVIDIA-Admins@DOMAIN.LOCAL` | NVIDIA HPC infrastructure |

Members of `Infrastructure-Admins@DOMAIN.LOCAL` can access all service accounts.

### Dynamic Inventory Logic

The key to making `/proxmox/cl1/n01` usable in Ansible is the logic within `inventory/ssm_plugin.py`.

**Parsing Logic:**
When the script runs, it recursively fetches paths and builds a JSON inventory in memory based on the path segments:

1. **Segment 1** (`proxmox`, `weka`, `nvidia`): Becomes a top-level **Ansible Group**
2. **Segment 2** (`cl1`, `nvl1`): Becomes a **Cluster Group** and a host variable `cluster_id`
3. **Segment 3** (`n01`, `n02`): Becomes the **Inventory Hostname**
4. **Segment 4** (`ip`, `mac`): Becomes a **Host Variable**

**Generated Inventory Object (Example):**
```json
{
  "nvidia": {
    "children": ["nvl1", "nvl2"]
  },
  "nvl1": {
    "hosts": ["n01"]
  },
  "_meta": {
    "hostvars": {
      "n01": {
        "ansible_host": "10.10.4.11",
        "system_type": "nvidia",
        "cluster_id": "nvl1",
        "gpu_mask": "0xFF"
      }
    }
  }
}
```

### Workflow Summary

1. **Provision Hardware**: Rack physical servers for the new cluster
2. **Update AWS SSM**: Administrator adds parameters under `/{system_type}/{cluster_id}/{node_id}/...`
3. **Authenticate**: Sysadmin SSHs to Tugboat node with AD credentials + Duo MFA
4. **Switch Account**: Sysadmin runs `su - svc-proxmox` (or appropriate service account)
5. **Execute Playbook**: Sysadmin runs `tug setup_proxmox --check` then `tug setup_proxmox`
6. **Runtime Injection**: Wrapper fetches SSM parameters and builds dynamic inventory
7. **Configuration**: Ansible connects via SSH to configure target systems
8. **Audit**: All actions logged with user attribution, forwarded to Azure Log Analytics

**No automated triggers**: Changes to GitHub or SSM do not automatically trigger execution. All automation is manually initiated by authenticated administrators.

## AWS Systems Manager (SSM) Parameter Schema

All infrastructure parameters follow a consistent hierarchy:

**Pattern**: `/{system_type}/{cluster_id}/{node_id}/{attribute}`

### System Types
- `/proxmox/` - Virtualization infrastructure
- `/weka/` - High-performance file storage
- `/ceph/` - Block/object storage
- `/nvidia/` - AI/HPC compute (future)

### Example Parameters

**Proxmox** (`/proxmox/cl1/n01/`):
- `ip`: Management IP address
- `mac`: PXE boot MAC address
- `root_pass`: Root password (SecureString)
- `/proxmox/cl1/shared/token`: Cluster API token

**Weka** (`/weka/cl1/n01/`):
- `ip`: InfiniBand/Ethernet IP
- `container_id`: Weka container name
- `/weka/cl1/shared/admin_pw`: Cluster admin password

## Documentation Standards

### When Adding Documentation
1. **Follow existing structure**: Each subsystem has its own directory with README.md and CLAUDE.md
2. **Use clear markdown formatting**: Headings, code blocks, tables for technical content
3. **Reference hardware BOMs**: Link to CSV files for exact specifications
4. **Include validation steps**: For deployment procedures, always include verification commands
5. **Document networking details**: IP allocations, VLAN assignments, bonding configuration
6. **Cross-reference related docs**: Link between Proxmox, Weka, and root-level documentation

### When Working on Deployment Plans
1. **Check existing phase documents**: Review `proxmox/deployment/phase*.md` for structure
2. **Include pre-requisites**: What must be completed before this phase
3. **Provide exact commands**: Copy-pasteable commands with placeholders clearly marked
4. **Add validation steps**: How to verify each step completed successfully
5. **Document rollback procedures**: How to undo changes if something fails

## Subsystem-Specific Guidance

### Proxmox VE Cluster (`proxmox/`)
- **Purpose**: Infrastructure VMs and LXC containers across multiple VLANs
- **Nodes**: 3 nodes (pve1-node1, pve1-node2, pve1-node3)
- **Key features**: Ceph storage, NVIDIA A16 GPU with MIG, ESI MC-LAG networking
- **Detailed guidance**: See `proxmox/CLAUDE.md`

### Weka.io Cluster (`weka/`)
- **Purpose**: Multi-protocol file access (NFS/SMB/S3) for AI supercomputer
- **Nodes**: 9 nodes with 6x 15.3TB NVMe each
- **Key features**: Dual 200G networking, LACP bonding, RRDNS service endpoints
- **Detailed guidance**: See `weka/CLAUDE.md`

## Common Workflows

### Viewing Infrastructure Information
1. **Hardware specifications**: Check `hardware-sample-bom-*.csv` files
2. **Network topology**: See README.md architecture diagrams
3. **IP addressing**: Documented in AWS SSM (placeholders in deployment docs)
4. **Deployment status**: Review phase completion in deployment documents

### Adding New Infrastructure Components
1. **Document hardware**: Add BOM entry with exact part numbers
2. **Update AWS SSM schema**: Define parameter paths following hierarchy
3. **Create deployment phases**: Break down into sequential, testable steps
4. **Update network diagrams**: Reflect new topology in documentation
5. **Add to monitoring**: Include in observability and health check procedures

### Working with Ansible Automation
- **Playbooks**: Stored in this repository (public GitHub)
- **Inventory**: Generated dynamically by querying AWS SSM at runtime
- **Variables**: Group vars for system types, host vars from SSM parameters
- **Secrets**: NEVER commit secrets - always use `aws_ssm` lookup plugin
- **Tugboat Node**: Dedicated VM (`tugboat.domain.local`) with AD authentication
- **Execution**: Use `tug` wrapper script (not raw tug deploy)
- **Documentation**: See `docs/tugboat-admin-guide.md` for complete operations guide

## Network Architecture

### Proxmox Cluster
- **Management**: 1G IPMI/Redfish on dedicated switch
- **Host OS**: vlan6 (isolated, sysadmin-only)
- **VM/LXC**: vlan1-5 (performance data)
- **Uplinks**: Dual 200G CX-6 with ESI MC-LAG to HPE 5960 switches

### Weka Cluster
- **Management**: 1G IPMI/Redfish on dedicated switch
- **NFS/SMB**: Dual 25G bonded (LACP Mode 4)
- **Cluster traffic**: Dual 200G CX-6 with ESI MC-LAG
- **Service VIPs**: 2 for NFS (RRDNS), 3 for SMB (RRDNS)

## Security Considerations

### Authentication & Secrets
- **Tugboat Node Access**: AD authentication (SSSD/Realm) with Duo MFA required
- **Service Account Access**: PAM validates AD group membership before allowing `su` to svc-* accounts
- **SSH Keys**: ED25519 for Tugboat automation, per-team service account keys
- **Passwords**: All stored in AWS SSM as SecureString type
- **API Tokens**: Stored in SSM under `/shared/` paths
- **Emergency Access**: Root password stored in Keeper (break-glass procedure documented)
- **Two-Factor Auth**: Duo integration for Tugboat node SSH and Proxmox web UI

### Network Isolation
- **Host OS network**: vlan6 - sysadmin access only
- **VM/Container networks**: vlan1-5 - no host OS access
- **Management network**: Separate 1G switch for IPMI/Redfish
- **Gateway VMs**: Carefully document VLAN bridging and routing

## Monitoring & Operations

### Proxmox Monitoring
- **Stack**: Prometheus + Grafana (deployed as VMs/LXC)
- **Exporters**: Node exporter, Ceph exporter, PVE exporter
- **Centralized Logging**: Microsoft Defender XDR + Azure Log Analytics
- **Log Sources**: All hosts, VMs, containers, Ceph cluster

### Weka Monitoring
- **Native Monitoring**: Weka Management System (WMS)
- **Integration Points**: CloudWatch, Prometheus exporters
- **Health Checks**: Node status, replication lag, performance metrics

## Backup Strategy

### Proxmox
- **Proxmox Backup Server (PBS)**: Deployed as VM on cluster
- **Backup Target**: External S3-compatible Ceph cluster
- **Scope**: All VMs, LXC containers, cluster configuration

### Weka
- **Snapshots**: Weka native snapshots
- **Replication**: To secondary Weka cluster (if available)
- **S3 Integration**: For object storage backup workflows

## Key Design Decisions

### Storage
- **Proxmox**: Ceph flash pool (replicated, 3x) for HA
- **Weka**: 54x 15.3TB NVMe drives across 9 nodes
- **Integration**: Proxmox hosts mount Weka for VM/LXC workloads

### Networking
- **Bonding**: LACP Mode 4 for Weka 25G NICs
- **Redundancy**: ESI MC-LAG for 200G uplinks
- **Load Balancing**: RRDNS for NFS/SMB service endpoints

### GPU Allocation
- **MIG**: Enabled on NVIDIA A16 GPUs
- **Profile**: 3g.20gb slices
- **Distribution**: 2/3 for LXC containers, 1/3 for VMs

## Security & Identity Management

### AD Groups and Service Accounts

**Required AD Security Groups:**

| AD Group | Purpose |
|----------|---------|
| `Proxmox-Admins@DOMAIN.LOCAL` | Access to svc-proxmox service account |
| `Weka-Admins@DOMAIN.LOCAL` | Access to svc-weka service account |
| `Ceph-Admins@DOMAIN.LOCAL` | Access to svc-ceph service account |
| `NVIDIA-Admins@DOMAIN.LOCAL` | Access to svc-nvidia service account |
| `Infrastructure-Admins@DOMAIN.LOCAL` | Superadmin access to all service accounts |

### Service Account IAM Policies

Each service account has an IAM user with access limited to its infrastructure type:

**Example: svc-proxmox IAM policy:**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath"
            ],
            "Resource": "arn:aws:ssm:us-west-2:*:parameter/proxmox/*"
        },
        {
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "arn:aws:kms:us-west-2:*:key/alias/aws/ssm"
        }
    ]
}
```

### Audit Trail

All Ansible executions are logged with:
- **User attribution**: AD principal who initiated the action
- **Service account**: Which svc-* account was used
- **Execution details**: Playbook, arguments, target hosts
- **Results**: Success/failure, exit code, duration

**Log destinations:**
- Local: `/var/log/tugboat/` (90-day retention)
- Cloud: Azure Log Analytics (1-year retention)
- SIEM: Microsoft Defender XDR (alerting and correlation)

See `docs/tugboat-audit-compliance.md` for complete audit documentation.

### Network Flow

1. **Outbound**: Management node initiates connection to AWS API (HTTPS port 443)
2. **Inbound**: SSH (port 22) from corporate network to Tugboat node
3. **Internal**: Management node connects to infrastructure nodes via:
   - SSH (port 22) for host configuration
   - Proxmox API (port 8006) for cluster management
   - Weka API (port 14000) for cluster management

## Important Reminders

1. **Never commit secrets**: Use AWS SSM Parameter Store exclusively
2. **Follow SSM hierarchy**: Maintain consistency in parameter paths
3. **Use tug wrapper**: Never run raw tug deploy; always use the audited wrapper
4. **Always run --check first**: Preview changes before applying to production
5. **Document IP allocations**: Even placeholders help during planning
6. **Test incrementally**: Validate each phase before proceeding
7. **Reference hardware specs**: Always check BOM files for exact part numbers
8. **Cross-reference docs**: Keep Proxmox, Weka, and root-level docs synchronized
9. **Include rollback procedures**: Document how to undo changes safely
10. **Plan for monitoring**: Add observability from the start, not as afterthought

## Ansible Operations Documentation

For day-to-day Tugboat operations, see the documentation in `docs/`:

- **[docs/tugboat-admin-guide.md](docs/tugboat-admin-guide.md)**: How to execute Tugboat automation
- **[docs/tugboat-access-control.md](docs/tugboat-access-control.md)**: AD groups, service accounts, PAM configuration
- **[docs/tugboat-audit-compliance.md](docs/tugboat-audit-compliance.md)**: Audit trail, log retention, compliance
- **[docs/tugboat-node-setup.md](docs/tugboat-node-setup.md)**: Management VM setup and configuration
