# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository documents and tracks the design and planning of a **Weka.io File System Cluster** (9 nodes) providing multi-protocol file storage with high-performance NFS/SMB/S3 access for AI supercomputer users.

The repository is primarily a **design reference and deployment documentation** repository, not a code repository. It contains infrastructure planning, hardware specifications, networking configuration, and operational guides for the Weka cluster.

## Project Structure

```
.
├── README.md                              # High-level project overview
├── hardware-sample-bom-weka-supermicro.csv # Weka hardware bill of materials
├── docs-weka-io/                          # Symlink to Weka.io documentation
└── CLAUDE.md                              # This file
```

## Key Project Information

### Weka Cluster (AI Storage)

- **Purpose**: Multi-protocol file access for AI supercomputer
- **Nodes**: 9 Weka.io hosts
- **CPUs**: AMD Genoa 9455P (48C/96T per node)
- **Storage**: 6x Samsung PM1743 15.3TB NVMe PCIe5 per node (54 drives total)
- **Memory**: ~144GB per node (DDR5-6400)
- **Network**:
  - Dual 25G NICs for NFS/SMB services
  - Dual 200G MCX653106A-HDAT CX-6 NICs (4 total per node with MC-LAG)
  - 1G IPMI/Redfish on dedicated management switch
- **Boot Storage**: 2x Samsung PM9A3 960GB NVMe per node


## Common Documentation Tasks

### Viewing Documentation

- **Weka overview**: See `README.md`
- **Hardware specifications**: Check `hardware-sample-bom-weka-supermicro.csv`
- **Weka.io documentation**: See `docs-weka-io/` symlink (external repo) for Getting Started, Installation, Operations, Kubernetes integration, and Performance guides
- **Network configuration**: See networking sections below
- **IP addressing**: See IP allocation section below

### Adding Documentation

- Follow markdown format for all documentation
- Use clear headings and code blocks for technical content
- Reference hardware specifications from the BOM when discussing deployment
- For Weka documentation, include:
  - Installation and configuration procedures
  - Network setup and NIC bonding details
  - Client mounting procedures (NFS, SMB, Weka native client)
  - Monitoring and health checks
  - Performance tuning and optimization
  - Troubleshooting and operational procedures

## Infrastructure as Code and Automation

### Deployment Approach

- **Primary method**: Ansible playbooks (stored in public GitHub)
- **Configuration management**: AWS Systems Manager (SSM) Parameter Store
  - Namespace: `/weka/` for Weka parameters
  - Stores: IPs, hostnames, credentials, network configuration
  - Region: us-west-2
- **Automation level**: ~85% automated
- **Weka installation**: Via Weka installer or WMS (Weka Management System)

### AWS Integration

- **SSM Parameters**: Ansible uses built-in `aws_ssm` lookup plugin to retrieve parameters at runtime
- **IAM Roles/Policies**: Defined for node access
- **S3 Integration**: Weka S3-compatible API for object storage access
- **Monitoring**: Integration points for CloudWatch and other observability platforms

## Network Architecture

### Weka Cluster Network

**Data Planes (per node):**
- **Dual 25G NICs** (NVIDIA Mellanox): For NFS/SMB multi-protocol access
  - **Bonding**: Mode 4 (LACP) supported for redundancy and performance
  - Connected to enterprise data VLAN
  - Aggregate throughput: 50G per node with bonding

- **Dual 200G MCX653106A-HDAT CX-6 NICs** (4 total per node): For Weka cluster replication and data movement
  - Can be bonded for additional redundancy
  - Connected to HPE 5960 400G switches (EVPN/VXLAN environment)
  - Used for ESI-based MC-LAG (multi-chassis LAG) configuration

**Management Plane:**
- **1G IPMI/Redfish**: Dedicated management network (separate switch)
  - Out-of-band node management and monitoring

### Service Endpoints (RRDNS)

- **NFS Services**: 2 IP addresses (Round-Robin DNS) for load balancing NFS clients
- **SMB Services**: 3 IP addresses (Round-Robin DNS) for load balancing SMB clients
- **Weka Native Client**: Direct cluster connectivity (can use bonded 200G NICs or separate path)

## IP Address Allocation

### Total IP Requirements for Weka Cluster

| Component | Count | IPs | Notes |
|-----------|-------|-----|-------|
| Weka Node IPs (management/data) | 9 | 9 | One per host on primary data VLAN |
| IPMI/Redfish IPs | 9 | 9 | Dedicated management network |
| NFS Service VIPs (RRDNS) | 2 | 2 | For NFS client load balancing |
| SMB Service VIPs (RRDNS) | 3 | 3 | For SMB client load balancing |
| **TOTAL** | - | **23 IPs** | Minimum allocation |

**Recommended**: Allocate a /25 subnet (126 usable IPs) to accommodate current needs and future growth.

### Network Allocation Recommendation

- **Management VLAN** (1G IPMI): Reserve 20 IPs (9 nodes + headroom)
- **Primary Data VLAN** (25G/200G): Use /25 subnet (126 IPs) for:
  - 9 node IPs
  - 2 NFS service VIPs
  - 3 SMB service VIPs
  - Future service IPs and expansion

## NIC Bonding (NVIDIA Mellanox)

### Supported Configuration

According to Weka documentation (`planning-and-installation/prerequisites-and-compatibility.md`):

- **LACP Support**: Supported when bonding ports from dual-port NVIDIA Mellanox NICs into a single device
- **Mode**: Use Mode 4 (LACP) for active-active bonding
- **Limitation**: LACP bonding is NOT compatible with Virtual Functions (VFs)

### Recommended Bonding Strategy

For the dual 25G NICs (NFS/SMB traffic):
- **Set up active-active LACP bonding (Mode 4)**
- Provides redundancy: if one NIC fails, traffic continues on the other
- Provides throughput aggregation: 50G per node instead of 25G
- Standard practice for Weka deployments

For the dual 200G MCX653106A-HDAT CX-6 NICs:
- Can also be bonded for additional redundancy if needed
- Typically configured based on data center fabric requirements

## Managing Hardware BOMs

The hardware specifications are tracked in CSV format with Supermicro part numbers. When discussing hardware:
- Reference the BOM file for exact part numbers and specifications
- Include quantity and per-unit specifications
- Note any special considerations (e.g., NVMe form factors, thermal requirements)
- When adding new hardware, maintain consistent formatting and part number reference

## Documentation Standards

- Use markdown for all documentation files
- Include objectives, prerequisites, and validation steps in procedure documents
- Provide configuration examples when documenting setup procedures
- Cross-reference between Weka and Proxmox documentation as needed
- Include hardware specifications and network topology diagrams where helpful

## Client Access Patterns

### Weka Native Client (HPC)

- **Direct cluster connectivity**: Connects directly to Weka cluster for highest performance
- **Can use bonded 200G NICs** or dedicated network path
- **No DNS/RRDNS required**: HPC is a separate system managed independently

### NFS Clients

- **Service access**: Connect via 2 NFS service VIPs using RRDNS
- **Load balancing**: DNS round-robin distributes clients across VIPs
- **Mounting**: Clients mount NFS paths through service VIPs, Weka handles routing to healthy nodes

### SMB Clients

- **Service access**: Connect via 3 SMB service VIPs using RRDNS
- **Load balancing**: DNS round-robin distributes clients across VIPs
- **Authentication**: Domain/local authentication configured in Weka

## External References

- **Weka.io Documentation**: `docs-weka-io/` symlink contains official documentation
  - Ingesting all relevant Weka documentation is critical for deployment
  - Multi-protocol support (NFS, SMB, S3-compatible)
  - Kubernetes native workload integration
  - Network bonding and high availability configuration
- **AWS Systems Manager**: For understanding parameter store integration with Ansible
- **NVIDIA Mellanox NICs**: For network bonding and performance optimization

## Key Considerations for Weka Deployment

- **Network Planning**: Plan VLAN allocation and IP addressing before installation
- **NIC Bonding**: Implement LACP bonding for redundancy and throughput aggregation
- **Service VIPs**: Configure RRDNS for NFS/SMB service endpoints for load balancing
- **Performance Tuning**: Monitor and optimize based on workload characteristics
- **Monitoring**: Monitor node health, replication lag, and performance metrics
- **Disaster Recovery**: Plan for node failures and recovery procedures
- **Capacity Planning**: Consider future expansion when sizing IP subnets and storage
