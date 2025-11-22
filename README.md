# Cyber Infrastructure Automation

**Version:** 2.0
**Pattern:** Hybrid Cloud IaC with AWS SSM Runtime Injection
**Infrastructure:** Proxmox VE, Weka, Ceph, NVIDIA HPC

This repository contains Ansible automation for managing a heterogeneous cyber infrastructure including virtualization (Proxmox VE), high-performance storage (Weka, Ceph), and AI/HPC compute (NVIDIA).

## 🎯 Quick Start

### Prerequisites

- **Python 3.11+** with pip
- **Ansible 2.12+**
- **AWS CLI** configured with credentials
- **SSH access** to infrastructure nodes
- **AWS SSM Parameter Store** populated with infrastructure data

### Installation

```bash
# Clone repository
git clone https://github.com/yourusername/cyberinfra.git
cd cyberinfra

# Install Python dependencies
pip install ansible boto3 botocore

# Install Ansible collections
ansible-galaxy collection install amazon.aws community.general

# Configure AWS credentials
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: us-west-2
```

### Test Dynamic Inventory

```bash
# List all discovered hosts from AWS SSM
python3 inventory/ssm_plugin.py --list

# Get variables for a specific host
python3 inventory/ssm_plugin.py --host n01

# Test with Ansible
ansible-inventory -i inventory/ssm_plugin.py --list
ansible-inventory -i inventory/ssm_plugin.py --graph
```

### Run a Playbook

```bash
# Syntax check
ansible-playbook --syntax-check playbooks/setup_proxmox.yml

# Dry run (check mode)
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml --check --diff

# Execute playbook
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml -v

# Execute with limit (single host)
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml --limit n01
```

## 📁 Repository Structure

```
.
├── README.md                  # This file - getting started guide
├── CLAUDE.md                  # Architecture documentation for Claude Code
├── LICENSE                    # MIT License
├── ansible.cfg                # Ansible configuration (SSH transport)
│
├── .github/workflows/         # GitHub Actions automation
│   └── deploy.yml             # Automated deployment workflow
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
├── playbooks/                 # Ansible automation playbooks
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
        ├── README.md          # Complete walkthrough of the example
        ├── launch-instance.sh
        ├── cleanup.sh
        └── change-hostname.yml
```

## 🏗️ Architecture Overview

### Core Design Principles

1. **Separation of Code and Data**
   - **Code** (Ansible playbooks, scripts): Public GitHub repository
   - **Data** (IPs, credentials, configuration): AWS SSM Parameter Store
   - **Result**: No secrets in version control

2. **Dynamic Discovery at Runtime**
   - Inventory is generated dynamically by querying AWS SSM
   - No hardcoded IP addresses or hostnames in code
   - Infrastructure changes reflected automatically

3. **SSH-Based Transport**
   - Traditional SSH with key-based authentication for on-premises servers
   - SSH keys stored securely in AWS SSM (retrieved at runtime)
   - Direct network connectivity to infrastructure

4. **Infrastructure as Code**
   - Declarative configuration (describe desired state)
   - Idempotent operations (safe to run multiple times)
   - Version controlled and peer-reviewed

### How It Works

```text
┌─────────────────┐              ┌─────────────────────┐
│  Public GitHub  │              │   AWS Cloud         │
│  (This Repo)    │              │   (SSM Parameters)  │
└────────┬────────┘              └──────────┬──────────┘
         │                                   │
         │ 1. Pull code                      │ 3. Query parameters
         │                                   │
         └──────────────┐       ┌────────────┘
                        │       │
                   ┌────▼───────▼────┐
                   │  Self-Hosted    │
                   │  Runner/Admin   │
                   │  Workstation    │
                   └────────┬─────────┘
                            │
                            │ 4. SSH to configure
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   ┌────▼─────┐      ┌─────▼──────┐     ┌─────▼──────┐
   │ Proxmox  │      │    Weka    │     │   NVIDIA   │
   │ Cluster  │      │  Cluster   │     │    HPC     │
   └──────────┘      └────────────┘     └────────────┘
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
  --description "SSH private key for Ansible automation"

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

- **Ansible automation**: ED25519 keys (modern, fast, secure)
- **Admin access**: RSA 4096 keys (broad compatibility)
- **Storage**: AWS SSM Parameter Store as SecureString
- **Password authentication**: Disabled on all infrastructure

## 🚀 Deployment Workflows

### Manual Execution

```bash
# Deploy Proxmox cluster
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml

# Deploy Weka cluster
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_weka.yml

# Deploy Ceph storage
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_ceph.yml

# Deploy NVIDIA HPC infrastructure
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_nvidia.yml
```

### GitHub Actions (Automated)

The repository includes a GitHub Actions workflow (`.github/workflows/deploy.yml`) for automated deployment:

**Manual Trigger:**
1. Go to **Actions** tab in GitHub
2. Select **Deploy Infrastructure** workflow
3. Click **Run workflow**
4. Choose target infrastructure (proxmox, weka, ceph, nvidia, or all)
5. Enable/disable dry run mode

**Automatic Trigger:**
- Pushes to `main` branch that modify playbooks, group_vars, or inventory
- Pull requests (runs in check mode only)

**Requirements:**
- Self-hosted GitHub Actions runner with network access to infrastructure
- GitHub repository secrets configured:
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`

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
ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml

# Clean up
./cleanup.sh
```

See `tests/example/README.md` for complete walkthrough.

### Validate Playbooks Locally

```bash
# Syntax check all playbooks
for playbook in playbooks/*.yml; do
  echo "Checking $playbook..."
  ansible-playbook --syntax-check $playbook
done

# Lint playbooks
pip install ansible-lint
ansible-lint playbooks/

# Dry run against inventory
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml --check --diff
```

## 📚 Documentation

- **[CLAUDE.md](CLAUDE.md)**: Complete architecture documentation and guidance for Claude Code
- **[proxmox/README.md](proxmox/README.md)**: Proxmox VE cluster overview and hardware specifications
- **[proxmox/DEPLOYMENT.md](proxmox/DEPLOYMENT.md)**: Phase-by-phase deployment plan for Proxmox
- **[weka/README.md](weka/README.md)**: Weka cluster overview and hardware specifications
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
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_proxmox.yml --limit n04
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
ansible-playbook -i inventory/ssm_plugin.py playbooks/setup_weka.yml
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
