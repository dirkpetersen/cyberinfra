# Cyber Infrastructure Automation

**Version:** 2.1
**Pattern:** Manual Execution with AD Authentication and Audit Trail
**Infrastructure:** Proxmox VE, Weka, Ceph, NVIDIA HPC

This repository contains Tugboat automation for managing a heterogeneous cyber infrastructure including virtualization (Proxmox VE), high-performance storage (Weka, Ceph), and AI/HPC compute (NVIDIA).

**Execution Model:** Administrators manually run tug commands from a centralized Tugboat node after authenticating via Active Directory with Duo MFA. All actions are logged and attributed to individual users.

## Quick Start

### Prerequisites

- **AD Account**: Member of appropriate infrastructure admin group (e.g., `Proxmox-Admins@DOMAIN.LOCAL`)
- **Duo MFA**: Configured for your AD account
- **Network Access**: SSH connectivity to Tugboat node (`tugboat.domain.local`)

### Connect to Tugboat Node

```bash
# SSH with AD credentials (Duo MFA will prompt)
ssh jsmith@DOMAIN.LOCAL@tugboat.domain.local
```

### Switch to Service Account

```bash
# Switch to team service account (PAM verifies AD group membership)
su - svc-proxmox      # For Proxmox administration
su - svc-weka         # For Weka administration
su - svc-ceph         # For Ceph administration
su - svc-nvidia       # For NVIDIA HPC administration
```

### Run Tugboat Automation

```bash
# Always run check mode first
tug setup_proxmox --check

# List hosts that would be affected
tug setup_proxmox --list-hosts

# Execute playbook (requires confirmation)
tug setup_proxmox

# Limit to specific cluster or host
tug setup_proxmox --limit cl1
tug setup_weka --limit n01

# Run specific tags
tug setup_proxmox --tags network

# Increase verbosity
tug setup_proxmox -vv
```

### View Execution Logs

```bash
# View recent audit entries
tail -20 /var/log/tugboat/executions.log | jq .

# View full output for specific execution
cat /var/log/tugboat/ansible-<execution-id>.log
```

## Repository Structure

```
.
├── README.md                  # This file - getting started guide
├── CLAUDE.md                  # Architecture documentation for Claude Code
├── LICENSE                    # MIT License
├── ansible.cfg                # Ansible configuration (SSH transport)
│
├── docs/                      # Tugboat operations documentation
│   ├── tugboat-admin-guide.md      # How to execute Tugboat automation
│   ├── tugboat-access-control.md   # AD groups, service accounts, PAM
│   ├── tugboat-audit-compliance.md # Audit trail, log retention, compliance
│   └── tugboat-node-setup.md    # Management VM configuration
│
├── inventory/                 # Dynamic inventory for Ansible
│   └── ssm_plugin.py          # Queries AWS SSM to build inventory at runtime
│
├── group_vars/                # Ansible group variables
│   ├── proxmox.yml            # Variables for all Proxmox nodes
│   ├── weka.yml               # Variables for all Weka nodes
│   ├── ceph.yml               # Variables for all Ceph nodes
│   └── nvidia.yml             # Variables for all NVIDIA HPC nodes
│
├── playbooks/                 # Tugboat automation playbooks
│   ├── setup_proxmox.yml      # Configure Proxmox VE cluster
│   ├── setup_weka.yml         # Configure Weka file system
│   ├── setup_ceph.yml         # Configure Ceph storage
│   └── setup_nvidia.yml       # Configure NVIDIA HPC infrastructure
│
├── proxmox/                   # Proxmox-specific documentation
│   ├── README.md              # Cluster overview and hardware specs
│   ├── CLAUDE.md              # Proxmox-specific guidance
│   ├── DEPLOYMENT.md          # Complete deployment plan
│   ├── deployment/            # Phase-by-phase deployment guides
│   └── hardware-sample-bom-supermicro.csv
│
├── weka/                      # Weka-specific documentation
│   ├── README.md              # Cluster overview and hardware specs
│   ├── CLAUDE.md              # Weka-specific guidance
│   └── hardware-sample-bom-weka-supermicro.csv
│
└── tests/                     # Test examples and demonstrations
    └── example/               # AWS EC2 test demonstrating SSM + Ansible pattern
        ├── README.md          # Complete walkthrough
        ├── launch-instance.sh
        ├── cleanup.sh
        └── change-hostname.yml
```

## Architecture Overview

### Core Design Principles

1. **Separation of Code and Data**
   - **Code** (Ansible playbooks, scripts): Public GitHub repository
   - **Data** (IPs, credentials, configuration): AWS SSM Parameter Store
   - **Result**: No secrets in version control

2. **Manual Execution with Authentication**
   - Administrators manually initiate all automation
   - No automated triggers from GitHub or SSM changes
   - AD authentication + Duo MFA required

3. **Role-Based Access Control**
   - Team-specific service accounts (svc-proxmox, svc-weka, etc.)
   - PAM validates AD group membership before granting access
   - Not all team members have access to all infrastructure

4. **Complete Audit Trail**
   - All actions logged with user attribution
   - Logs forwarded to Azure Log Analytics
   - Integration with Microsoft Defender XDR for alerting

5. **Infrastructure as Code**
   - Declarative configuration (describe desired state)
   - Idempotent operations (safe to run multiple times)
   - Version controlled and peer-reviewed

### How It Works

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SYSADMIN WORKSTATION                           │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  │ 1. SSH with AD + Duo MFA
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           MANAGEMENT NODE (VM)                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  2. su - svc-proxmox (PAM checks AD group: Proxmox-Admins)                  │
│  3. tug setup_proxmox --check                                     │
│     └── Fetches SSM parameters, builds inventory, runs playbook            │
│  4. All actions logged → Azure Log Analytics → Defender XDR                 │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │ 5. SSH (key-based)      │                         │
        ▼                         ▼                         ▼
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Proxmox    │         │    Weka      │         │   NVIDIA     │
│   Cluster    │         │   Cluster    │         │    HPC       │
└──────────────┘         └──────────────┘         └──────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                           AWS CLOUD (US-West-2)                             │
│   SSM Parameter Store: IPs, credentials, configuration (fetched at runtime)│
└─────────────────────────────────────────────────────────────────────────────┘
```

## 🔑 AWS SSM Parameter Hierarchy

All infrastructure configuration follows a consistent path-based hierarchy:

**Pattern**: `/{system_type}/{cluster_id}/{node_id}/{attribute}`

### Example Parameters

**Proxmox Cluster** (`/proxmox/cl1/`):
```
/proxmox/cl1/n01/ip                      → "10.10.1.11"
/proxmox/cl1/n01/mac                     → "aa:bb:cc:11:22:33"
/proxmox/cl1/shared/ssh_private_key      → "-----BEGIN OPENSSH PRIVATE KEY-----..." (SecureString)
/proxmox/cl1/shared/token                → "PVEAPIToken=..." (SecureString)
/proxmox/cl1/shared/ceph_public_network  → "10.10.6.0/24"
```

**Weka Cluster** (`/weka/cl1/`):
```
/weka/cl1/n01/ip                         → "10.10.2.11"
/weka/cl1/n01/container_id               → "weka-01"
/weka/cl1/n01/drives                     → "/dev/nvme0n1,/dev/nvme1n1,..."
/weka/cl1/shared/admin_pw                → "WekaAdmin123!" (SecureString)
/weka/cl1/shared/nfs_vip1                → "10.10.2.100"
```

**Ceph Cluster** (`/ceph/cl1/`):
```
/ceph/cl1/n02/ip                         → "10.10.3.12"
/ceph/cl1/n02/cluster_ip                 → "10.20.3.12"
/ceph/cl1/n02/osd_devices                → "sda,sdb,sdc,sdd"
/ceph/cl1/shared/fsid                    → "a7f64266-yyyy-xxxx-..."
/ceph/cl1/shared/dashboard_password      → "CephAdmin123!" (SecureString)
```

**NVIDIA HPC** (`/nvidia/nvl1/`):
```
/nvidia/nvl1/n01/ip                      → "10.10.4.11"
/nvidia/nvl1/n01/gpu_mask                → "0xFF"
/nvidia/nvl1/shared/ssh_private_key      → "-----BEGIN OPENSSH PRIVATE KEY-----..." (SecureString)
/nvidia/nvl1/shared/gpu_model            → "A100"
```

### Populating SSM Parameters

```bash
# Set AWS region
export AWS_REGION=us-west-2

# Add Proxmox node parameters
aws ssm put-parameter \
  --name /proxmox/cl1/n01/ip \
  --value "10.10.1.11" \
  --type String \
  --description "Proxmox node 1 management IP"

aws ssm put-parameter \
  --name /proxmox/cl1/n01/mac \
  --value "aa:bb:cc:11:22:33" \
  --type String \
  --description "Proxmox node 1 PXE boot MAC"

# Add shared SSH key (SecureString)
aws ssm put-parameter \
  --name /proxmox/cl1/shared/ssh_private_key \
  --value "$(cat ~/.ssh/id_ed25519)" \
  --type SecureString \
  --description "SSH private key for Tugboat automation"

# List all parameters
aws ssm get-parameters-by-path \
  --path /proxmox/cl1 \
  --recursive \
  --query "Parameters[*].[Name,Type]" \
  --output table
```

## 🔐 Security Configuration

### Required IAM Policy

The automation runner (GitHub Actions or local workstation) requires the following IAM policy:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ReadSSMParameters",
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath"
            ],
            "Resource": [
                "arn:aws:ssm:us-west-2:*:parameter/proxmox/*",
                "arn:aws:ssm:us-west-2:*:parameter/weka/*",
                "arn:aws:ssm:us-west-2:*:parameter/ceph/*",
                "arn:aws:ssm:us-west-2:*:parameter/nvidia/*"
            ]
        },
        {
            "Sid": "DecryptSecureStrings",
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "arn:aws:kms:us-west-2:*:key/alias/aws/ssm"
        }
    ]
}
```

### SSH Key Management

- **Tugboat automation**: ED25519 keys (modern, fast, secure)
- **Admin access**: RSA 4096 keys (broad compatibility)
- **Storage**: AWS SSM Parameter Store as SecureString
- **Password authentication**: Disabled on all infrastructure

## Deployment Workflows

### Authenticated Manual Execution

All deployments are executed manually by authenticated administrators from the Tugboat node.

**Step 1: Authenticate**
```bash
# SSH to Tugboat node with AD credentials
ssh jsmith@DOMAIN.LOCAL@tugboat.domain.local
# Complete Duo MFA prompt
```

**Step 2: Switch to Service Account**
```bash
# Switch to appropriate team account (PAM validates AD group)
su - svc-proxmox    # Requires membership in Proxmox-Admins@DOMAIN.LOCAL
```

**Step 3: Execute Playbook**
```bash
# Always run check mode first
tug setup_proxmox --check

# Execute with confirmation
tug setup_proxmox

# Available playbooks:
tug setup_proxmox    # Proxmox VE cluster
tug setup_weka       # Weka file system
tug setup_ceph       # Ceph storage
tug setup_nvidia     # NVIDIA HPC
```

### Access Requirements

| Infrastructure | Service Account | Required AD Group |
|----------------|-----------------|-------------------|
| Proxmox | `svc-proxmox` | `Proxmox-Admins@DOMAIN.LOCAL` |
| Weka | `svc-weka` | `Weka-Admins@DOMAIN.LOCAL` |
| Ceph | `svc-ceph` | `Ceph-Admins@DOMAIN.LOCAL` |
| NVIDIA | `svc-nvidia` | `NVIDIA-Admins@DOMAIN.LOCAL` |

Members of `Infrastructure-Admins@DOMAIN.LOCAL` have access to all service accounts.

### Emergency Access

In case of AD outage, root password is stored in Keeper password manager. See `docs/tugboat-node-setup.md` for emergency procedures.

## 🧪 Testing

### Test with AWS EC2 Example

The `tests/example/` directory contains a complete working example using AWS EC2 to demonstrate the pattern:

```bash
cd tests/example

# Launch test instance
./launch-instance.sh

# Wait for SSM agent to come online (2-3 minutes)
aws ssm describe-instance-information \
  --filters "Key=tag:Name,Values=ansible-ssm-test"

# Run Ansible playbook
tug deploy -i inventory.aws_ec2.yml change-hostname.yml

# Clean up
./cleanup.sh
```

See `tests/example/README.md` for complete walkthrough.

### Validate Playbooks Locally

```bash
# Syntax check all playbooks
for playbook in playbooks/*.yml; do
  echo "Checking $playbook..."
  tug deploy --syntax-check $playbook
done

# Lint playbooks
pip install # ansible-lint (if using ansible backend)
# ansible-lint (if using ansible backend) playbooks/

# Dry run against inventory
tug deploy -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml --check --diff
```

## Documentation

### Tugboat Operations
- **[docs/tugboat-admin-guide.md](docs/tugboat-admin-guide.md)**: How to execute Tugboat automation
- **[docs/tugboat-access-control.md](docs/tugboat-access-control.md)**: AD groups, service accounts, PAM configuration
- **[docs/tugboat-audit-compliance.md](docs/tugboat-audit-compliance.md)**: Audit trail, log retention, compliance
- **[docs/tugboat-node-setup.md](docs/tugboat-node-setup.md)**: Management VM configuration

### Architecture
- **[CLAUDE.md](CLAUDE.md)**: Complete architecture documentation and guidance for Claude Code

### Infrastructure
- **[proxmox/README.md](proxmox/README.md)**: Proxmox VE cluster overview and hardware specifications
- **[proxmox/DEPLOYMENT.md](proxmox/DEPLOYMENT.md)**: Phase-by-phase deployment plan for Proxmox
- **[weka/README.md](weka/README.md)**: Weka cluster overview and hardware specifications

### Testing
- **[tests/example/README.md](tests/example/README.md)**: AWS EC2 test example walkthrough

## 🛠️ Common Operations

### Add a New Node

```bash
# 1. Add parameters to AWS SSM
aws ssm put-parameter --name /proxmox/cl1/n04/ip --value "10.10.1.14" --type String
aws ssm put-parameter --name /proxmox/cl1/n04/mac --value "aa:bb:cc:44:55:66" --type String

# 2. Verify inventory discovery
python3 inventory/ssm_plugin.py --host n04

# 3. Run playbook (will automatically detect new node)
tug deploy -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml --limit n04
```

### Update a Configuration Value

```bash
# 1. Update parameter in AWS SSM
aws ssm put-parameter \
  --name /weka/cl1/shared/admin_pw \
  --value "NewPassword123!" \
  --type SecureString \
  --overwrite

# 2. Re-run playbook (uses new value automatically)
tug deploy -i inventory/ssm_plugin.py playbooks/setup_weka.yml
```

### Debug Inventory Issues

```bash
# List all discovered hosts
python3 inventory/ssm_plugin.py --list | jq .

# Check specific host variables
python3 inventory/ssm_plugin.py --host n01 | jq .

# Verify AWS credentials
aws sts get-caller-identity

# Test SSM access
aws ssm get-parameters-by-path --path /proxmox/cl1 --recursive
```

## 🤝 Contributing

1. Create a feature branch from `main`
2. Make changes to playbooks, group_vars, or documentation
3. Test changes locally using `--check` mode
4. Submit pull request (will run automated checks)
5. After approval and merge, changes deploy automatically

## 📄 License

MIT License - See [LICENSE](LICENSE) file for details

## 🆘 Support

For questions or issues:
- Review documentation in `CLAUDE.md` for architecture details
- Check `tests/example/README.md` for working demonstration
- Refer to subsystem-specific documentation in `proxmox/` and `weka/` directories

---

**Note**: This is a documentation and automation repository. All sensitive data (credentials, IP addresses) are stored in AWS Systems Manager Parameter Store and are NOT checked into version control.
