# AWS EC2 + Ansible SSM Example

This example demonstrates the **Hybrid Cloud IaC with AWS SSM Runtime Injection** pattern used throughout this repository.

## What This Example Does

1. **Launch** an AWS EC2 instance (t4g.micro, ARM-based)
2. **Connect** to it via AWS Systems Manager (no SSH keys, no open ports)
3. **Configure** the instance using Ansible with dynamic inventory
4. **Change** the hostname to "banana" as a simple demonstration
5. **Clean up** all resources when done

This mirrors the architecture used for Proxmox, Weka, Ceph, and NVIDIA infrastructure management in the main repository, but uses AWS EC2 for easy testing without physical hardware

## Prerequisites

### Software Requirements

```bash
# AWS CLI (version 2.x recommended)
aws --version

# Ansible (2.12+) with AWS collection
pip install ansible
ansible-galaxy collection install amazon.aws

# Python AWS SDK
pip install boto3 botocore

# Session Manager plugin (REQUIRED for Ansible SSM connection)
# Install instructions below
```

**Install AWS Session Manager Plugin** (required):

```bash
# For Linux ARM64 (Apple Silicon Macs, AWS Graviton)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" -o "/tmp/session-manager-plugin.deb"
sudo dpkg -i /tmp/session-manager-plugin.deb

# For Linux x86_64
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "/tmp/session-manager-plugin.deb"
sudo dpkg -i /tmp/session-manager-plugin.deb

# For macOS (Intel)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip" -o "/tmp/sessionmanager-bundle.zip"
unzip /tmp/sessionmanager-bundle.zip -d /tmp
sudo /tmp/sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin

# For macOS (Apple Silicon)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/sessionmanager-bundle.zip" -o "/tmp/sessionmanager-bundle.zip"
unzip /tmp/sessionmanager-bundle.zip -d /tmp
sudo /tmp/sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin

# Verify installation
session-manager-plugin --version
```

### AWS Requirements

- **AWS Account** with active credentials
- **AWS CLI configured**: Run `aws configure` or set environment variables
- **AWS Profiles**:
  - **Default profile**: Needs EC2 and SSM permissions
  - **iam-dirk profile**: Needs IAM permissions (for creating roles/instance profiles)
- **Permissions** required:
  - **Default profile** (EC2 + SSM + S3):
    - EC2: `RunInstances`, `DescribeInstances`, `TerminateInstances`, `CreateTags`
    - SSM: `DescribeInstanceInformation`, `StartSession`, `SendCommand`
    - S3: `CreateBucket`, `ListBucket`, `GetObject`, `PutObject` (for SSM session data)
  - **iam-dirk profile** (IAM only):
    - IAM: `CreateRole`, `AttachRolePolicy`, `CreateInstanceProfile`, `AddRoleToInstanceProfile`, `PassRole`
- **Default VPC** (or modify scripts to specify VPC/subnet)

**Note**: The scripts use separate AWS profiles to follow the principle of least privilege. IAM operations use `--profile iam-dirk` while EC2/SSM operations use the default profile.

### Verify Setup

```bash
# Check default AWS credentials (for EC2/SSM)
aws sts get-caller-identity

# Check IAM profile credentials
aws sts get-caller-identity --profile iam-dirk

# Check Ansible AWS collection
ansible-galaxy collection list | grep amazon.aws

# Check Python dependencies
python3 -c "import boto3, botocore; print('OK')"
```

## Files in This Example

| File | Purpose | Key Concepts |
|------|---------|-------------|
| `README.md` | This documentation | - |
| `TROUBLESHOOTING.md` | Common issues and solutions | Debugging guide |
| `ENV_VARS.md` | Environment variables reference guide | Configuration flexibility |
| `SUCCESS.md` | Summary of successful test run | Verification |
| `install-session-manager-plugin.sh` | Install AWS Session Manager plugin (one-time setup) | Required dependency |
| `launch-instance.sh` | Launch EC2 instance with SSM-enabled IAM role | IAM roles, instance profiles, AWS API |
| `ansible.cfg` | Ansible configuration for SSM connection | SSM connection plugin |
| `inventory.aws_ec2.yml` | Dynamic inventory that discovers instances | Runtime discovery, no static IPs |
| `change-hostname.yml` | Ansible playbook to change hostname | Idempotent configuration management |
| `cleanup.sh` | Terminate instance and clean up | Resource cleanup |
| `.gitignore` | Prevent committing instance IDs | Security best practice |

## Quick Start

### 0. Install Session Manager Plugin (One-Time Setup)

**Required before first use:**

```bash
./install-session-manager-plugin.sh
```

Or install manually following the instructions in the [Prerequisites](#prerequisites) section above.

### 1. Launch the Instance

```bash
./launch-instance.sh
```

This will:
- Create SSM parameter `/example/config/hostname` with value "banana"
- Launch a t4g.micro instance (ARM-based, free tier eligible)
- Use Amazon Linux 2023 (has SSM agent pre-installed)
- Create S3 bucket for SSM session data (if not exists)
- Tag the instance with `Name=ansible-ssm-test`
- Attach an IAM role for SSM connectivity
- Output the instance ID

**Override defaults via environment variables**:
```bash
# Change instance type and region
INSTANCE_TYPE=t4g.small REGION=us-east-1 ./launch-instance.sh

# Use a different IAM profile
IAM_PROFILE=my-admin-profile ./launch-instance.sh

# Change tag name
TAG_NAME=my-test-instance ./launch-instance.sh
```

**Available environment variables**:
- `INSTANCE_TYPE` - EC2 instance type (default: `t4g.micro`)
- `REGION` - AWS region (default: `us-west-2`)
- `AMI_NAME` - AMI search pattern (default: `al2023-ami-*-arm64`)
- `IAM_ROLE_NAME` - IAM role name (default: `AnsibleSSMTestRole`)
- `INSTANCE_PROFILE_NAME` - Instance profile name (default: `AnsibleSSMTestProfile`)
- `TAG_NAME` - Instance tag name (default: `ansible-ssm-test`)
- `IAM_PROFILE` - AWS CLI profile for IAM operations (default: `iam-dirk`)

### 2. Wait for SSM Agent to Register

```bash
# Check if instance is ready for SSM
aws ssm describe-instance-information \
  --filters "Key=tag:Name,Values=ansible-ssm-test" \
  --query "InstanceInformationList[0].PingStatus"
```

Wait until the output shows `"Online"` (usually 2-3 minutes after launch).

### 3. Verify SSM Parameter

Verify that the hostname parameter was created and has the correct value:

```bash
# Verify the hostname parameter value
aws ssm get-parameter \
  --name "/example/config/hostname" \
  --query "Parameter.Value" \
  --output text
```

Expected output:
```
banana
```

**Optional: Change the hostname value** (demonstrates runtime configuration):

```bash
# Update the parameter value
aws ssm put-parameter \
  --name "/example/config/hostname" \
  --value "apple" \
  --type "String" \
  --overwrite

# Run Ansible again - it will use the new value without any code changes!
```

### 4. Run the Ansible Playbook

```bash
ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml
```

This will:
- Discover the instance via AWS EC2 API
- Connect via AWS Systems Manager (no SSH needed!)
- **Retrieve hostname from SSM Parameter Store** (`/example/config/hostname`)
- Change the hostname to the retrieved value
- Persist the change across reboots

### 5. Verify the Change

```bash
# Check hostname via SSM
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["hostname"]' \
  --targets "Key=tag:Name,Values=ansible-ssm-test" \
  --query "Command.CommandId" \
  --output text
```

Then get the output (replace COMMAND_ID):
```bash
aws ssm list-command-invocations \
  --command-id COMMAND_ID \
  --details \
  --query "CommandInvocations[0].CommandPlugins[0].Output"
```

### 6. Cleanup

```bash
./cleanup.sh
```

This will:
- Terminate the EC2 instance
- Delete the SSM parameter `/example/config/hostname`
- Remove local files

**Override defaults via environment variables** (must match values used in launch):
```bash
# If you used a different region or tag name
REGION=us-east-1 TAG_NAME=my-test-instance ./cleanup.sh

# If you used a different IAM profile
IAM_PROFILE=my-admin-profile ./cleanup.sh
```

## How It Works

### Connection Methods: SSM vs SSH

#### This Example (AWS EC2): SSM Agent Connection

For AWS EC2 instances, this example uses AWS Systems Manager Agent instead of SSH:

```
[ Your Laptop ]
       |
       | (1) Ansible connects via AWS SSM API
       v
[ AWS Systems Manager ]
       |
       | (2) SSM agent on EC2 receives commands
       v
[ EC2 Instance (t4g.micro) ]
```

**Benefits of SSM Agent**:
- ✅ No SSH keys to manage
- ✅ No open inbound ports (22) required
- ✅ No public IP needed
- ✅ Works through private subnets
- ✅ IAM-based authentication
- ✅ Centralized audit logging in CloudTrail

**Ansible configuration**:
```yaml
# inventory.aws_ec2.yml
compose:
  ansible_connection: 'community.aws.aws_ssm'
```

#### On-Premises Infrastructure (Proxmox/Weka): Traditional SSH

For on-premises physical servers, the infrastructure uses **traditional SSH** with key-based authentication:

```
[ Self-Hosted Runner ]
       |
       | (1) Ansible connects via SSH (port 22)
       v
[ Proxmox/Weka Server ]
```

**Why SSH for on-premises**:
- Physical servers don't have AWS SSM Agent
- Direct network connectivity available
- SSH keys managed securely (stored in AWS Secrets Manager or SSM)

**Ansible configuration for on-premises**:
```yaml
# Traditional SSH connection
ansible_connection: ssh
ansible_user: root
ansible_ssh_private_key_file: "{{ lookup('amazon.aws.aws_ssm', '/proxmox/shared/ssh_key') }}"
ansible_host: "{{ lookup('amazon.aws.aws_ssm', '/proxmox/cl1/n01/ip') }}"
```

**Key Point**: Both approaches use **AWS SSM Parameter Store** for configuration data (IPs, credentials), but differ in how Ansible connects:
- **AWS EC2**: SSM Agent (no SSH)
- **On-premises**: SSH (with keys from SSM Parameter Store)

### Dynamic Inventory

The `inventory.aws_ec2.yml` file uses Ansible's AWS EC2 plugin to automatically discover instances based on tags:

```yaml
plugin: amazon.aws.aws_ec2
filters:
  tag:Name: ansible-ssm-test
  instance-state-name: running
```

No need to manually maintain IP addresses!

### Connection Plugin

The `ansible.cfg` configures Ansible to use SSM instead of SSH:

```ini
[defaults]
host_key_checking = False
interpreter_python = auto_silent

[inventory]
enable_plugins = amazon.aws.aws_ec2

[connection]
connection = aws_ssm

[aws_ssm]
region = us-west-2
ssm_document = AWS-StartInteractiveCommand
```

### S3 Bucket for Session Data

The SSM connection plugin requires an S3 bucket to store session transcripts and data. The `launch-instance.sh` script automatically creates a bucket named:

```
ansible-ssm-{your-account-id}-us-west-2
```

This bucket is configured in the dynamic inventory (`inventory.aws_ec2.yml`) and is reused across multiple test runs.

## Pattern Used in This Repository

This example demonstrates the **Hybrid Cloud IaC with AWS SSM Runtime Injection** pattern used throughout the repository.

### Architecture Comparison

| Component | This Example | Full Infrastructure (Proxmox/Weka) |
|-----------|--------------|-------------------------------------|
| **Targets** | EC2 instances | On-premises physical servers |
| **Discovery** | AWS EC2 API (tags) | AWS SSM Parameter Store (hierarchy) |
| **Connection** | AWS SSM agent (no SSH) | **SSH with keys** (traditional) |
| **Automation** | Ansible playbooks (public) | Ansible playbooks (public) |
| **Secrets** | IAM instance profile | SSM Parameter Store (SecureString) |
| **Runner** | Your workstation | Self-hosted runner on management node |

**Important Distinction**:
- **This example (AWS EC2)**: Uses SSM Agent instead of SSH for connection
- **On-premises (Proxmox/Weka)**: Uses traditional SSH with key-based authentication
- **Both use**: AWS SSM Parameter Store for configuration data (IPs, passwords, etc.)

### Core Principles

1. **Separation of Code and Data**
   - **Code** (Ansible playbooks): Public GitHub repository
   - **Data** (IPs, credentials): AWS SSM Parameter Store
   - **Result**: No secrets in version control

2. **Dynamic Discovery at Runtime**
   - **This example**: Query EC2 API for instances with specific tags
   - **Full infrastructure**: Query SSM Parameter Store for `/proxmox/cl1/n01/ip`, etc.
   - **Result**: No hardcoded IP addresses or hostnames

3. **Secure, Agentless Connection**
   - **Traditional**: SSH with key management, open port 22, bastion hosts
   - **SSM approach**: AWS API-based, no open ports, centralized audit logs
   - **Result**: Better security posture, easier compliance

4. **Infrastructure as Code**
   - **Declarative**: Describe desired state, not steps
   - **Idempotent**: Run multiple times safely
   - **Version controlled**: Track changes over time

### Extending This Example

To use SSM Parameter Store (like the full infrastructure):

1. **Store configuration in SSM**:
   ```bash
   aws ssm put-parameter \
     --name "/example/demo/hostname" \
     --value "banana" \
     --type "String"
   ```

2. **Retrieve in Ansible playbook**:
   ```yaml
   - name: Get hostname from SSM Parameter Store
     set_fact:
       new_hostname: "{{ lookup('amazon.aws.aws_ssm', '/example/demo/hostname') }}"
   ```

3. **Use in tasks**:
   ```yaml
   - name: Set hostname from SSM
     ansible.builtin.hostname:
       name: "{{ new_hostname }}"
   ```

This is exactly how the Proxmox and Weka automation works, but with a structured hierarchy:
- `/proxmox/cl1/n01/ip` → `10.10.1.11`
- `/weka/cl1/n01/ip` → `10.10.2.11`
- `/proxmox/cl1/shared/token` → `pve!apitoken...` (SecureString)

## Troubleshooting

**For detailed troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)**

### Quick Diagnostics

#### Instance not showing in inventory

```bash
# Test the dynamic inventory
ansible-inventory -i inventory.aws_ec2.yml --list
```

### SSM agent not online

```bash
# Check SSM agent status
aws ssm describe-instance-information \
  --filters "Key=tag:Name,Values=ansible-ssm-test"
```

If not online:
- Wait 2-3 minutes after launch
- Check IAM role is attached
- Verify security group allows outbound HTTPS (443)

### Ansible connection fails

```bash
# Test SSM connectivity
aws ssm start-session --target i-1234567890abcdef0
```

If this works but Ansible fails, check:
- Ansible SSM plugin installed: `pip install ansible-core boto3 botocore`
- AWS credentials are valid: `aws sts get-caller-identity`

## Cost Notes

- **t4g.micro**: Free tier eligible (750 hours/month for first 12 months)
- **SSM**: No additional charge for Session Manager
- **S3 bucket**: Free tier includes 5GB storage, minimal usage for session logs
- **Data Transfer**: Minimal (< $0.01 for this example)

Remember to run `cleanup.sh` to avoid charges!

**Note**: The S3 bucket created for SSM session data is NOT automatically deleted by `cleanup.sh` as it can be reused for future tests. To delete it manually:
```bash
aws s3 rb s3://ansible-ssm-$(aws sts get-caller-identity --query Account --output text)-us-west-2 --force
```

## Detailed File Documentation

### launch-instance.sh

**Purpose**: Automates the complete EC2 instance setup with SSM support.

**What it does**:
1. Finds the latest Amazon Linux 2023 ARM AMI
2. Creates IAM role `AnsibleSSMTestRole` with SSM permissions
3. Creates instance profile and associates role
4. Creates SSM parameter `/example/config/hostname` with value "banana"
5. Creates S3 bucket for SSM session data: `ansible-ssm-{account-id}-{region}`
6. Launches t4g.micro instance in default VPC
7. Tags instance with `Name=ansible-ssm-test`
8. Waits for instance to reach "running" state
9. Saves instance ID to `instance-id.txt`

**Key configurations**:
- **Instance Type**: `t4g.micro` (ARM, free tier eligible)
- **AMI**: Amazon Linux 2023 (SSM agent pre-installed)
- **IAM Policy**: `AmazonSSMManagedInstanceCore` (AWS managed)
- **Region**: `us-west-2` (configurable)
- **IAM Profile**: Uses `iam-dirk` profile for IAM operations (separation of concerns)

**Idempotency**: Safe to run multiple times; checks if IAM resources exist before creating.

**Profile Usage**: All `aws iam` commands use `--profile iam-dirk` while EC2 commands use the default profile. This follows the principle of least privilege by separating IAM management permissions from operational permissions.

### ansible.cfg

**Purpose**: Configures Ansible to use AWS SSM instead of SSH.

**Key settings**:
```ini
[connection]
connection = aws_ssm  # Use SSM plugin instead of SSH
```

**Why this matters**:
- Ansible defaults to SSH for remote connections
- SSM connection plugin intercepts Ansible's connection layer
- No SSH daemon or port 22 required on target
- Works identically from Ansible's perspective

### inventory.aws_ec2.yml

**Purpose**: Dynamic inventory that queries AWS EC2 API at runtime.

**How it works**:
1. Ansible calls AWS EC2 `DescribeInstances` API
2. Filters for instances with tag `Name=ansible-ssm-test` in `running` state
3. Returns instance IDs as inventory hostnames
4. Sets `ansible_connection: aws_ssm` for each host

**Dynamic vs Static Inventory**:
- **Static** (traditional): Manual INI/YAML file with hardcoded IPs
  ```ini
  [webservers]
  web1 ansible_host=10.0.1.10
  web2 ansible_host=10.0.1.11
  ```
- **Dynamic** (this example): Query cloud provider at runtime
  ```yaml
  plugin: amazon.aws.aws_ec2
  filters:
    tag:Name: ansible-ssm-test
  ```

**Benefits**:
- No manual IP management
- Automatically reflects infrastructure changes
- Works across regions
- Can filter by tags, instance types, VPCs, etc.

### change-hostname.yml

**Purpose**: Ansible playbook demonstrating SSM-based configuration management.

**Playbook structure**:
```yaml
- name: Playbook name
  hosts: all              # Target all discovered hosts
  gather_facts: yes       # Collect system information
  become: yes             # Use sudo for privileged operations

  vars:
    new_hostname: "banana"  # Variables for reusability

  tasks:
    - name: Task description
      ansible.builtin.hostname:  # Ansible module
        name: "{{ new_hostname }}"  # Module parameters
```

**What it does**:
1. **Display current hostname**: Shows before state
2. **Check connection method**: Verifies SSM is being used
3. **Set hostname**: Uses `ansible.builtin.hostname` module
4. **Update /etc/hosts**: Ensures hostname resolves locally
5. **Persist across reboots**: Updates `/etc/hostname`
6. **Notify**: Informs about reboot requirement

**Idempotency**: Safe to run multiple times; only changes if needed.

#### Where the `new_hostname` Variable Comes From

The `new_hostname` variable demonstrates **Ansible's integration with AWS SSM Parameter Store** - the key pattern used throughout this repository.

**The variable is retrieved from SSM Parameter Store at runtime**:

```yaml
vars:
  new_hostname: "{{ lookup('amazon.aws.aws_ssm', '/example/config/hostname') }}"
```

This is **variable expansion within Ansible** using the `aws_ssm` lookup plugin to fetch a key-value pair from AWS Systems Manager Parameter Store.

### How It Works: Ansible + SSM Parameter Store Integration

#### Step 1: Store Configuration in SSM Parameter Store

```bash
# Store the hostname value in SSM
aws ssm put-parameter \
  --name "/example/config/hostname" \
  --value "banana" \
  --type "String" \
  --description "Desired hostname for test instance"
```

#### Step 2: Verify Using AWS CLI

```bash
# Retrieve the parameter value
aws ssm get-parameter \
  --name "/example/config/hostname" \
  --query "Parameter.Value" \
  --output text
```

Output:
```
banana
```

List all parameters:
```bash
aws ssm get-parameters-by-path \
  --path "/example" \
  --recursive \
  --query "Parameters[*].[Name,Value,Type]" \
  --output table
```

Output:
```
------------------------------------------------
|            GetParametersByPath               |
+----------------------------+---------+--------+
|  /example/config/hostname  |  banana |  String|
+----------------------------+---------+--------+
```

#### Step 3: Ansible Retrieves from SSM at Runtime

Update `change-hostname.yml` to use SSM lookup:

```yaml
- name: Change hostname using value from SSM Parameter Store
  hosts: all
  gather_facts: yes
  become: yes

  vars:
    # Variable expansion: lookup SSM parameter at runtime
    new_hostname: "{{ lookup('amazon.aws.aws_ssm', '/example/config/hostname') }}"

  tasks:
    - name: Display hostname retrieved from SSM
      ansible.builtin.debug:
        msg: "Setting hostname to: {{ new_hostname }} (from SSM)"

    - name: Set hostname
      ansible.builtin.hostname:
        name: "{{ new_hostname }}"

    - name: Update /etc/hosts
      ansible.builtin.lineinfile:
        path: /etc/hosts
        regexp: '^127\.0\.0\.1\s+localhost'
        line: "127.0.0.1   localhost {{ new_hostname }}"
```

**What happens when Ansible runs**:
1. Ansible evaluates `{{ lookup('amazon.aws.aws_ssm', '/example/config/hostname') }}`
2. Queries AWS SSM Parameter Store for `/example/config/hostname`
3. Retrieves value: `"banana"`
4. Variable `new_hostname` is set to `"banana"`
5. Tasks use `{{ new_hostname }}` which expands to `"banana"`

### Production Pattern: Proxmox/Weka Infrastructure

This same pattern is used throughout the repository for managing infrastructure:

**SSM Parameter Store Hierarchy**:
```bash
# Proxmox cluster configuration
/proxmox/cl1/n01/ip           → "10.10.1.11"
/proxmox/cl1/n01/mac          → "aa:bb:cc:11:22:33"
/proxmox/cl1/n02/ip           → "10.10.1.12"
/proxmox/cl1/shared/token     → "pve!apitoken..." (SecureString)

# Weka cluster configuration
/weka/cl1/n01/ip              → "10.10.2.11"
/weka/cl1/n01/container_id    → "weka-01"
/weka/cl1/shared/admin_pw     → "wekaAdmin123" (SecureString)
```

**Ansible playbook retrieves these at runtime**:
```yaml
- name: Configure Proxmox node
  hosts: proxmox_nodes
  vars:
    # Dynamic parameter path construction
    node_ip: "{{ lookup('amazon.aws.aws_ssm', '/proxmox/' + cluster_id + '/' + inventory_hostname + '/ip') }}"
    api_token: "{{ lookup('amazon.aws.aws_ssm', '/proxmox/' + cluster_id + '/shared/token') }}"

  tasks:
    - name: Configure node with IP {{ node_ip }}
      debug:
        msg: "Configuring {{ inventory_hostname }} at {{ node_ip }}"
```

### Working with SecureString (Encrypted Parameters)

For sensitive values like passwords and tokens:

```bash
# Store encrypted value
aws ssm put-parameter \
  --name "/example/secrets/db_password" \
  --value "MySecretPassword123" \
  --type "SecureString"

# Retrieve and decrypt (requires KMS decrypt permission)
aws ssm get-parameter \
  --name "/example/secrets/db_password" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text
```

**In Ansible**, the `aws_ssm` lookup automatically handles decryption:
```yaml
vars:
  # Ansible automatically decrypts SecureString parameters
  db_password: "{{ lookup('amazon.aws.aws_ssm', '/example/secrets/db_password') }}"
```

### Why This Pattern Matters

**The Key Benefit**: Variable expansion from SSM means:
- ✅ **No secrets in GitHub** - Code is public, configuration is private
- ✅ **Centralized configuration** - Change SSM parameter, no code changes needed
- ✅ **Encryption at rest** - SecureString type uses AWS KMS
- ✅ **IAM-based access control** - Fine-grained permissions per parameter
- ✅ **Audit trail** - CloudTrail logs all parameter access
- ✅ **Dynamic discovery** - Parameters can be constructed from variables

**Example: No hardcoded IPs anywhere**:
```yaml
# This is the pattern - configuration pulled from SSM at runtime
- hosts: all
  vars:
    management_ip: "{{ lookup('amazon.aws.aws_ssm', '/' + system_type + '/' + cluster_id + '/' + inventory_hostname + '/ip') }}"
  tasks:
    - name: Use dynamically retrieved IP
      debug:
        msg: "Connecting to {{ management_ip }}"
```

The entire infrastructure can be reconfigured by updating SSM parameters without touching any code in the repository.

### Scaling to Multiple Parameters

**Q: What if I have 100+ configuration values?**

You have several approaches:

#### Approach 1: Individual Lookups (Simple, Low Volume)

For a small number of parameters (< 10), individual lookups work fine:

```yaml
vars:
  hostname: "{{ lookup('amazon.aws.aws_ssm', '/example/config/hostname') }}"
  ip_address: "{{ lookup('amazon.aws.aws_ssm', '/example/config/ip') }}"
  admin_user: "{{ lookup('amazon.aws.aws_ssm', '/example/config/admin_user') }}"
```

**Pros**: Clear, explicit
**Cons**: Verbose for many parameters

#### Approach 2: Path-Based Lookup (Recommended for On-Premises)

Use the SSM parameter hierarchy to construct paths dynamically:

```yaml
- name: Configure Proxmox nodes
  hosts: proxmox_nodes
  vars:
    # Dynamically construct parameter paths based on inventory
    cluster_id: "cl1"
    param_prefix: "/proxmox/{{ cluster_id }}/{{ inventory_hostname }}"

    # Lookup parameters using constructed paths
    node_ip: "{{ lookup('amazon.aws.aws_ssm', param_prefix + '/ip') }}"
    node_mac: "{{ lookup('amazon.aws.aws_ssm', param_prefix + '/mac') }}"
    node_gateway: "{{ lookup('amazon.aws.aws_ssm', param_prefix + '/gateway') }}"

    # Shared parameters for the cluster
    api_token: "{{ lookup('amazon.aws.aws_ssm', '/proxmox/' + cluster_id + '/shared/token') }}"
```

**Example hierarchy**:
```
/proxmox/cl1/n01/ip           → "10.10.1.11"
/proxmox/cl1/n01/mac          → "aa:bb:cc:11:22:33"
/proxmox/cl1/n01/gateway      → "10.10.1.1"
/proxmox/cl1/n02/ip           → "10.10.1.12"
/proxmox/cl1/n02/mac          → "aa:bb:cc:22:33:44"
/proxmox/cl1/shared/token     → "pve!token..."
```

**Pros**: Scalable, maintainable, follows pattern
**Cons**: Requires hierarchical organization

#### Approach 3: Bulk Retrieval with get-parameters-by-path

For retrieving all parameters under a path at once:

```yaml
- name: Get all node parameters at once
  set_fact:
    all_params: "{{ lookup('amazon.aws.aws_ssm',
                    '/proxmox/cl1/n01',
                    bypath=true,
                    recursive=true) }}"

- name: Use the parameters
  debug:
    msg: "IP: {{ all_params['/proxmox/cl1/n01/ip'] }}"
```

**AWS CLI equivalent**:
```bash
# Get all parameters under a path
aws ssm get-parameters-by-path \
  --path "/proxmox/cl1/n01" \
  --recursive \
  --query "Parameters[*].[Name,Value]" \
  --output table
```

**Pros**: One API call for multiple parameters
**Cons**: More complex to parse in Ansible

#### Approach 4: External Inventory Script (100+ Servers)

For large-scale deployments, use a custom inventory script that queries SSM:

```python
#!/usr/bin/env python3
# inventory/ssm_inventory.py
import boto3
import json

ssm = boto3.client('ssm', region_name='us-west-2')

# Get all Proxmox nodes from SSM
response = ssm.get_parameters_by_path(
    Path='/proxmox/cl1',
    Recursive=True
)

# Build Ansible inventory from SSM parameters
inventory = {
    'proxmox': {
        'hosts': [],
        'vars': {}
    },
    '_meta': {
        'hostvars': {}
    }
}

# Parse parameters and build inventory
for param in response['Parameters']:
    # Example: /proxmox/cl1/n01/ip → node=n01, key=ip
    parts = param['Name'].split('/')
    if len(parts) >= 5:
        node = parts[3]
        key = parts[4]

        if node not in inventory['_meta']['hostvars']:
            inventory['_meta']['hostvars'][node] = {}
            inventory['proxmox']['hosts'].append(node)

        inventory['_meta']['hostvars'][node][key] = param['Value']

print(json.dumps(inventory, indent=2))
```

**Use in Ansible**:
```bash
ansible-playbook -i inventory/ssm_inventory.py playbook.yml
```

**Pros**: Efficient, scalable to 1000+ servers
**Cons**: Requires custom code

#### Real-World Example: 9-Node Weka Cluster

For the Weka cluster (9 nodes × 5 parameters each = 45 parameters):

**SSM Structure**:
```
/weka/cl1/n01/ip              → "10.10.2.11"
/weka/cl1/n01/container_id    → "weka-01"
/weka/cl1/n01/nic1_mac        → "aa:bb:cc:..."
/weka/cl1/n01/nic2_mac        → "dd:ee:ff:..."
/weka/cl1/n01/drive_count     → "6"
# ... repeat for n02 through n09
/weka/cl1/shared/admin_pw     → "password" (SecureString)
/weka/cl1/shared/nfs_vip1     → "10.10.2.100"
```

**Ansible Playbook**:
```yaml
- name: Configure Weka cluster
  hosts: weka_nodes
  vars:
    cluster_id: "cl1"
    # Dynamic lookup per node
    node_ip: "{{ lookup('amazon.aws.aws_ssm', '/weka/' + cluster_id + '/' + inventory_hostname + '/ip') }}"
    container_id: "{{ lookup('amazon.aws.aws_ssm', '/weka/' + cluster_id + '/' + inventory_hostname + '/container_id') }}"
    # Shared cluster password
    admin_pw: "{{ lookup('amazon.aws.aws_ssm', '/weka/' + cluster_id + '/shared/admin_pw') }}"

  tasks:
    - name: Configure Weka container with IP {{ node_ip }}
      command: weka local setup container --name {{ container_id }} --ip {{ node_ip }}
```

**Inventory** (static or dynamic):
```ini
[weka_nodes]
n01
n02
n03
n04
n05
n06
n07
n08
n09
```

#### Recommended Approach by Scale

| Scale | Recommendation | Why |
|-------|---------------|-----|
| 1-10 parameters | Individual lookups | Simple, clear |
| 10-50 parameters | Path-based construction | Organized, maintainable |
| 50-200 parameters | `get-parameters-by-path` | Fewer API calls |
| 200+ parameters | Custom inventory script | Most efficient |

#### Best Practices

1. **Use hierarchical paths**: `/{system}/{cluster}/{node}/{attribute}`
2. **Group by access patterns**: Put frequently-used params together
3. **Cache when possible**: Use Ansible facts caching to reduce SSM API calls
4. **Monitor costs**: SSM API is free (4000 TPS limit), but review CloudWatch metrics
5. **Use SecureString**: Encrypt sensitive values (passwords, tokens, keys)

### cleanup.sh

**Purpose**: Terminates EC2 instance and cleans up local files.

**What it does**:
1. Reads instance ID from `instance-id.txt` (or looks up by tag)
2. Calls EC2 `TerminateInstances` API
3. Waits for termination to complete
4. Deletes SSM parameter `/example/config/hostname`
5. Removes local `instance-id.txt` file

**What it doesn't do**:
- Does NOT delete IAM role/instance profile (reusable for next run)
- Does NOT delete S3 bucket (reusable for future tests)
- Does NOT delete security groups or VPC resources

## Advanced Usage

### Using Environment Variables for Configuration

All scripts support environment variable overrides for flexible configuration:

```bash
# Example: Launch in us-east-1 with a larger instance
REGION=us-east-1 INSTANCE_TYPE=t4g.small ./launch-instance.sh

# Example: Use your own IAM profile name
IAM_PROFILE=my-iam-admin ./launch-instance.sh

# Example: Multiple overrides
REGION=eu-west-1 \
TAG_NAME=prod-test \
INSTANCE_TYPE=t4g.medium \
IAM_PROFILE=eu-admin \
./launch-instance.sh
```

**Important**: When cleaning up, use the same environment variables:
```bash
# Must match the values used during launch
REGION=us-east-1 TAG_NAME=prod-test ./cleanup.sh
```

### Run Against Multiple Instances

Modify `launch-instance.sh` to launch multiple instances:
```bash
# Launch 3 instances
for i in {1..3}; do
  aws ec2 run-instances \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ansible-ssm-test},{Key=Index,Value=$i}]" \
    # ... other parameters
done
```

Update `inventory.aws_ec2.yml` to target all:
```yaml
filters:
  tag:Name: ansible-ssm-test
  instance-state-name: running
```

Ansible will automatically discover and configure all 3 instances in parallel.

### Use SSM Parameter Store

Store the hostname in Parameter Store instead of hardcoding:

```bash
# Store parameter
aws ssm put-parameter \
  --name "/example/config/hostname" \
  --value "banana" \
  --type "String" \
  --description "Example hostname for testing"
```

Update `change-hostname.yml`:
```yaml
vars:
  # Retrieve from SSM at runtime
  new_hostname: "{{ lookup('amazon.aws.aws_ssm', '/example/config/hostname') }}"
```

### Interactive SSM Session

Test SSM connectivity manually:
```bash
# Start interactive shell session
aws ssm start-session --target i-1234567890abcdef0

# You'll get a shell prompt on the instance
# No SSH keys or open ports required!
```

### Ansible Verbosity

Debug Ansible execution:
```bash
# Basic output
ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml

# Verbose (shows task details)
ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml -v

# Very verbose (shows module arguments)
ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml -vv

# Debug level (shows SSM API calls)
ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml -vvv
```

## Common Issues and Solutions

### "No hosts matched"

**Cause**: Dynamic inventory not finding instances.

**Debug**:
```bash
# View discovered inventory
ansible-inventory -i inventory.aws_ec2.yml --list

# Check if instance has correct tag
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ansible-ssm-test"
```

**Solution**:
- Verify instance is in `running` state
- Check region matches in `inventory.aws_ec2.yml`
- Ensure AWS credentials are configured

### "SSM plugin not found"

**Cause**: Ansible can't find the SSM connection plugin.

**Solution**:
```bash
# Install amazon.aws collection
ansible-galaxy collection install amazon.aws

# Verify installation
ansible-galaxy collection list | grep amazon.aws
```

### "Unable to locate credentials"

**Cause**: Boto3 can't find AWS credentials.

**Solution**:
```bash
# Configure AWS CLI (creates ~/.aws/credentials)
aws configure

# Or set environment variables
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret
export AWS_DEFAULT_REGION=us-west-2

# Or use AWS SSO
aws sso login --profile your-profile
export AWS_PROFILE=your-profile
```

### "Instance not available for SSM"

**Cause**: SSM agent not registered yet.

**Debug**:
```bash
# Check SSM agent status
aws ssm describe-instance-information \
  --filters "Key=tag:Name,Values=ansible-ssm-test"
```

**Solution**:
- Wait 2-3 minutes after launch
- Verify IAM instance profile is attached
- Check security group allows outbound HTTPS (443) to AWS endpoints
- Review instance system logs: `aws ec2 get-console-output --instance-id i-xxx`

### Permission Denied Errors

**Cause**: Insufficient AWS IAM permissions.

**Required IAM Permissions**:

**Default Profile** (EC2 + SSM + S3 operations):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeImages",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ssm:DescribeInstanceInformation",
        "ssm:StartSession",
        "ssm:SendCommand",
        "s3:CreateBucket",
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "*"
    }
  ]
}
```

**iam-dirk Profile** (IAM operations only):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:AttachRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:PassRole",
        "iam:DeleteRole",
        "iam:DetachRolePolicy",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile"
      ],
      "Resource": "*"
    }
  ]
}
```

This separation follows the **principle of least privilege**: day-to-day operations (EC2, SSM) are separated from privileged IAM management.

## Learning Resources

### AWS Systems Manager
- [SSM Agent Documentation](https://docs.aws.amazon.com/systems-manager/latest/userguide/ssm-agent.html)
- [Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Hybrid Activation](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-managed-instance-activation.html) (for on-premises)

### Ansible with AWS
- [amazon.aws Collection](https://docs.ansible.com/ansible/latest/collections/amazon/aws/index.html)
- [aws_ec2 Inventory Plugin](https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html)
- [aws_ssm Lookup Plugin](https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ssm_lookup.html)
- [AWS SSM Connection Plugin](https://docs.ansible.com/ansible/latest/collections/community/aws/aws_ssm_connection.html)

### Infrastructure as Code
- [Ansible Best Practices](https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html)
- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)

## Next Steps

After completing this example, you can:

1. **Explore the main repository**:
   - Review `README.md` for the full architecture
   - Study `proxmox/DEPLOYMENT.md` for real-world deployment
   - Examine SSM Parameter Store hierarchy in `README.md`

2. **Extend this example**:
   - Add more configuration tasks (install packages, configure services)
   - Use SSM Parameter Store for configuration data
   - Deploy multiple instances and use inventory grouping
   - Add AWS Secrets Manager for sensitive data

3. **Apply to on-premises infrastructure**:
   - Set up SSM hybrid activation for physical servers
   - Implement the SSM parameter hierarchy (`/proxmox/cl1/n01/ip`)
   - Create dynamic inventory script that queries SSM Parameter Store
   - Deploy self-hosted GitHub Actions runner for automation

4. **Learn more**:
   - Explore Ansible roles and collections
   - Study AWS CloudFormation or Terraform for infrastructure provisioning
   - Investigate GitOps patterns with GitHub Actions
   - Review security best practices for infrastructure automation
