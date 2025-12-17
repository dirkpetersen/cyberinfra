# Tugboat Node Setup Guide

**Version:** 1.0
**Last Updated:** 2025-01
**Audience:** Infrastructure Administrators

This guide covers the setup and configuration of the Tugboat Tugboat node VM, including OS installation, AD integration, Duo MFA, and Tugboat tooling.

---

## Overview

### Tugboat Node Purpose

The Tugboat node is a dedicated VM that serves as the central point for all infrastructure automation. It provides:

- Centralized Tugboat execution environment
- Active Directory authentication gateway
- Duo MFA enforcement
- Audit logging and forwarding
- AWS SSM Parameter Store access

### Specifications

| Attribute | Value |
|-----------|-------|
| Hostname | `tugboat.domain.local` |
| Operating System | Ubuntu 24.04 LTS (or Debian 12) |
| vCPUs | 4 |
| Memory | 8 GB |
| Disk | 100 GB (system) |
| Network | vlan6 (management network) |
| Location | Proxmox cluster (pve1) |

---

## VM Provisioning

### Create VM in Proxmox

```bash
# SSH to Proxmox node
ssh root@pve1-node1

# Create VM (adjust VMID and storage as needed)
qm create 200 \
  --name tugboat \
  --memory 8192 \
  --cores 4 \
  --net0 virtio,bridge=vmbr6 \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:100,format=raw \
  --ide2 local:iso/ubuntu-24.04-live-server-amd64.iso,media=cdrom \
  --boot order=ide2

# Start VM and complete Ubuntu installation via console
qm start 200
```

### Post-Installation Configuration

After Ubuntu installation:

```bash
# Update system
apt-get update && apt-get upgrade -y

# Set hostname
hostnamectl set-hostname tugboat.domain.local

# Configure static IP (example for vlan6)
cat > /etc/netplan/00-installer-config.yaml << 'EOF'
network:
  version: 2
  ethernets:
    ens18:
      addresses:
        - 10.10.6.50/24
      routes:
        - to: default
          via: 10.10.6.1
      nameservers:
        addresses:
          - 10.10.6.10
          - 10.10.6.11
        search:
          - domain.local
EOF

netplan apply

# Verify connectivity
ping -c 3 domain.local
```

---

## Active Directory Integration

### Install Required Packages

```bash
apt-get install -y \
  sssd \
  sssd-tools \
  sssd-ad \
  realmd \
  adcli \
  krb5-user \
  libpam-sss \
  libnss-sss \
  packagekit
```

During `krb5-user` installation, provide:
- Default Kerberos realm: `DOMAIN.LOCAL`
- Kerberos servers: `dc1.domain.local dc2.domain.local`
- Administrative server: `dc1.domain.local`

### Discover and Join Domain

```bash
# Discover domain
realm discover DOMAIN.LOCAL

# Join domain (provide AD admin credentials when prompted)
realm join --user=admin@DOMAIN.LOCAL DOMAIN.LOCAL

# Verify join
realm list
```

### Configure SSSD

**`/etc/sssd/sssd.conf`**:

```ini
[sssd]
domains = DOMAIN.LOCAL
config_file_version = 2
services = nss, pam, sudo

[domain/DOMAIN.LOCAL]
# Provider configuration
id_provider = ad
access_provider = ad
auth_provider = ad
chpass_provider = ad

# Domain settings
ad_domain = DOMAIN.LOCAL
krb5_realm = DOMAIN.LOCAL
realmd_tags = manages-system joined-with-adcli

# ID mapping
ldap_id_mapping = true
ldap_schema = ad

# Cache settings
cache_credentials = true
krb5_store_password_if_offline = true

# Access control
ad_gpo_access_control = enforcing

# User/group settings
use_fully_qualified_names = true
fallback_homedir = /home/%u@%d
default_shell = /bin/bash

# Performance
ldap_use_tokengroups = true
ldap_referrals = false
enumerate = false
ldap_group_nesting_level = 2

# Timeout settings
dns_discovery_domain = DOMAIN.LOCAL
```

Set permissions and restart:

```bash
chmod 600 /etc/sssd/sssd.conf
chown root:root /etc/sssd/sssd.conf
systemctl restart sssd
systemctl enable sssd
```

### Configure SSH Access

Permit only infrastructure admin groups:

```bash
# Allow specific AD groups to SSH
realm permit -g 'Proxmox-Admins@DOMAIN.LOCAL'
realm permit -g 'Weka-Admins@DOMAIN.LOCAL'
realm permit -g 'Ceph-Admins@DOMAIN.LOCAL'
realm permit -g 'NVIDIA-Admins@DOMAIN.LOCAL'
realm permit -g 'Infrastructure-Admins@DOMAIN.LOCAL'
```

Verify:

```bash
realm list
# Should show "permitted-logins" with the groups
```

---

## Duo MFA Integration

### Install Duo Unix

```bash
# Download Duo Unix source
cd /tmp
wget https://dl.duosecurity.com/duo_unix-latest.tar.gz
tar xzf duo_unix-latest.tar.gz
cd duo_unix-*

# Install dependencies
apt-get install -y libssl-dev libpam-dev

# Configure and install
./configure --with-pam --prefix=/usr
make
make install
```

### Configure Duo

Obtain integration credentials from Duo Admin Panel:

1. Log into Duo Admin Panel
2. Applications > Protect an Application
3. Search for "Unix Application"
4. Copy Integration key, Secret key, and API hostname

**`/etc/duo/pam_duo.conf`**:

```ini
[duo]
; Duo integration credentials
ikey = DIXXXXXXXXXXXXXXXXXX
skey = XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
host = api-XXXXXXXX.duosecurity.com

; Authentication behavior
pushinfo = yes
autopush = yes
prompts = 1

; Fail open if Duo service unavailable (set to "secure" for fail-closed)
failmode = safe

; Optional: Restrict to specific groups (uncomment to enable)
; groups = Infrastructure-Admins@DOMAIN.LOCAL
```

Set permissions:

```bash
chmod 600 /etc/duo/pam_duo.conf
chown root:root /etc/duo/pam_duo.conf
```

### Configure PAM for SSH

**`/etc/pam.d/sshd`**:

```
#%PAM-1.0

# Standard Un*x authentication
@include common-auth

# Duo two-factor authentication
auth    required    pam_duo.so

# Account management
@include common-account

# Session setup
@include common-session
session    optional    pam_motd.so motd=/run/motd.dynamic
session    optional    pam_motd.so noupdate

# Password management
@include common-password
```

### Configure SSHD

**`/etc/ssh/sshd_config`** (relevant settings):

```
# Authentication methods
PubkeyAuthentication yes
PasswordAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes

# Use keyboard-interactive for Duo
AuthenticationMethods keyboard-interactive

# Security hardening
PermitRootLogin prohibit-password
PermitEmptyPasswords no
X11Forwarding no

# Idle timeout (30 minutes)
ClientAliveInterval 300
ClientAliveCountMax 6

# Logging
SyslogFacility AUTH
LogLevel INFO
```

Restart SSH:

```bash
systemctl restart sshd
```

### Test Duo Authentication

From a workstation:

```bash
ssh jsmith@DOMAIN.LOCAL@tugboat.domain.local
# Enter AD password
# Receive Duo push notification
# Approve to complete login
```

---

## Service Account Setup

### Create Local Service Accounts

```bash
# Create service accounts with specific UIDs
useradd -u 10001 -m -s /bin/bash -c "Proxmox Automation Account" svc-proxmox
useradd -u 10002 -m -s /bin/bash -c "Weka Automation Account" svc-weka
useradd -u 10003 -m -s /bin/bash -c "Ceph Automation Account" svc-ceph
useradd -u 10004 -m -s /bin/bash -c "NVIDIA Automation Account" svc-nvidia

# Lock direct password login (access via su only)
passwd -l svc-proxmox
passwd -l svc-weka
passwd -l svc-ceph
passwd -l svc-nvidia
```

### Configure PAM for Service Account Access

**`/etc/pam.d/su`**:

```
#%PAM-1.0

# Root can su to anything
auth       sufficient pam_rootok.so

# Authenticate the calling user via SSSD
auth       required   pam_sss.so

# Account management
account    sufficient pam_rootok.so
account    required   pam_sss.so

# Infrastructure-Admins can su to any svc-* account
account    [success=1 default=ignore] pam_succeed_if.so user ingroup Infrastructure-Admins@DOMAIN.LOCAL

# Team-specific access: Proxmox-Admins -> svc-proxmox
account    [success=done default=ignore] pam_succeed_if.so service = su user = svc-proxmox ruser ingroup Proxmox-Admins@DOMAIN.LOCAL

# Team-specific access: Weka-Admins -> svc-weka
account    [success=done default=ignore] pam_succeed_if.so service = su user = svc-weka ruser ingroup Weka-Admins@DOMAIN.LOCAL

# Team-specific access: Ceph-Admins -> svc-ceph
account    [success=done default=ignore] pam_succeed_if.so service = su user = svc-ceph ruser ingroup Ceph-Admins@DOMAIN.LOCAL

# Team-specific access: NVIDIA-Admins -> svc-nvidia
account    [success=done default=ignore] pam_succeed_if.so service = su user = svc-nvidia ruser ingroup NVIDIA-Admins@DOMAIN.LOCAL

# Deny all other su attempts to svc-* accounts
account    [success=ignore default=bad] pam_succeed_if.so user notingroup svc-proxmox:svc-weka:svc-ceph:svc-nvidia
account    requisite  pam_deny.so

# Session handling
session    required   pam_unix.so
session    optional   pam_sss.so
```

### Create SSH Keys for Service Accounts

Each service account needs SSH keys to connect to infrastructure:

```bash
# For each service account
for svc in svc-proxmox svc-weka svc-ceph svc-nvidia; do
  # Create .ssh directory
  mkdir -p /home/$svc/.ssh
  chmod 700 /home/$svc/.ssh

  # Generate ED25519 key pair
  ssh-keygen -t ed25519 -f /home/$svc/.ssh/tugboat_ed25519 -N "" \
    -C "$svc@tugboat"

  # Create SSH config
  cat > /home/$svc/.ssh/config << 'EOF'
Host *
  IdentityFile ~/.ssh/tugboat_ed25519
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF

  # Set ownership
  chown -R $svc:$svc /home/$svc/.ssh
  chmod 600 /home/$svc/.ssh/*
  chmod 644 /home/$svc/.ssh/*.pub
done
```

### Distribute Public Keys

The public keys must be installed on target infrastructure:

```bash
# Display public keys for distribution
for svc in svc-proxmox svc-weka svc-ceph svc-nvidia; do
  echo "=== $svc ==="
  cat /home/$svc/.ssh/tugboat_ed25519.pub
done
```

Add public keys to `/root/.ssh/authorized_keys` on respective infrastructure nodes.

---

## AWS Credentials Setup

### Option 1: IAM Instance Role (Recommended for AWS-hosted VMs)

If running in AWS, attach an IAM role to the VM with SSM read permissions.

### Option 2: IAM User Credentials (For on-premises VMs)

Create AWS credentials for each service account:

```bash
# Install AWS CLI
apt-get install -y awscli

# For each service account, create credentials directory
for svc in svc-proxmox svc-weka svc-ceph svc-nvidia; do
  mkdir -p /home/$svc/.aws

  cat > /home/$svc/.aws/credentials << EOF
[default]
aws_access_key_id = <ACCESS_KEY_FOR_$svc>
aws_secret_access_key = <SECRET_KEY_FOR_$svc>
EOF

  cat > /home/$svc/.aws/config << EOF
[default]
region = us-west-2
output = json
EOF

  chown -R $svc:$svc /home/$svc/.aws
  chmod 600 /home/$svc/.aws/credentials
done
```

### IAM Policy for Service Accounts

Each service account IAM user should have a policy limiting SSM access to their infrastructure:

**Example: svc-proxmox IAM policy**:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ReadProxmoxSSMParameters",
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath"
            ],
            "Resource": "arn:aws:ssm:us-west-2:*:parameter/proxmox/*"
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

---

## Tugboat Installation

### Install Tugboat in Virtual Environment

```bash
# Install Python prerequisites
apt-get install -y python3 python3-pip python3-venv git

# Create shared Tugboat installation
python3 -m venv /opt/tugboat
source /opt/tugboat/bin/activate

# Install Tugboat and dependencies
pip install --upgrade pip
pip install tugboat boto3 botocore jmespath

# Install Tugboat collections
tugboat-galaxy collection install amazon.aws community.general

# Deactivate venv
deactivate
```

### Clone Infrastructure Repository

```bash
# Clone repository
git clone https://github.com/your-org/cyberinfra.git /opt/tugboat

# Set ownership (readable by all service accounts)
chown -R root:root /opt/tugboat
chmod -R 755 /opt/tugboat
```

### Install tug Wrapper

**`/usr/local/bin/tug`**:

```bash
#!/bin/bash
set -euo pipefail

# ============================================================================
# tug - Audited Tugboat wrapper for infrastructure management
# ============================================================================

AUDIT_LOG="/var/log/tugboat/executions.log"
AUDIT_DIR="/var/log/tugboat"
REPO_PATH="/opt/tugboat"
VENV_PATH="/opt/tugboat"

# Ensure audit directory exists
mkdir -p "$AUDIT_DIR"

# Get authenticated user info
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}"
SERVICE_ACCOUNT="$USER"
SESSION_ID=$(cat /proc/self/sessionid 2>/dev/null || echo "$$")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EXECUTION_ID=$(uuidgen)
SOURCE_IP=$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()' || echo "console")

# Logging function
log_audit() {
    local status="$1"
    local message="$2"
    shift 2
    local json_log=$(cat <<EOF
{
  "execution_id": "$EXECUTION_ID",
  "timestamp": "$TIMESTAMP",
  "event_type": "tugboat_execution",
  "user": {
    "ad_principal": "$REAL_USER",
    "service_account": "$SERVICE_ACCOUNT",
    "session_id": "$SESSION_ID",
    "source_ip": "$SOURCE_IP"
  },
  "status": "$status",
  "message": "$message",
  "arguments": "$*"
}
EOF
)
    echo "$json_log" >> "$AUDIT_LOG"
    logger -t "tugboat" -p local0.info "$json_log"
}

# Validate service account
if [[ ! "$SERVICE_ACCOUNT" =~ ^svc- ]]; then
    log_audit "DENIED" "Must run as service account (svc-*)"
    echo "ERROR: This command must be run as a service account."
    echo "Use: su - svc-proxmox (or appropriate service account)"
    exit 1
fi

# Parse arguments
PLAYBOOK=""
EXTRA_ARGS=()
DRY_RUN=false

usage() {
    cat <<EOF
Usage: tug [OPTIONS] <playbook>

Options:
    --check, --dry-run    Run in check mode (no changes)
    --limit <pattern>     Limit to specific hosts
    --tags <tags>         Only run specific tags
    --list-hosts          List hosts that would be affected
    -v, -vv, -vvv         Increase verbosity
    --help                Show this help

Available Playbooks:
    setup_proxmox         Configure Proxmox VE cluster
    setup_weka            Configure Weka file system
    setup_ceph            Configure Ceph storage
    setup_nvidia          Configure NVIDIA HPC infrastructure

Examples:
    tug setup_proxmox --check
    tug setup_weka --limit 'cl1'
    tug setup_proxmox --tags network
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --check|--dry-run)
            DRY_RUN=true
            EXTRA_ARGS+=("--check")
            shift
            ;;
        --limit|--tags|-l|-t)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        --list-hosts)
            EXTRA_ARGS+=("--list-hosts")
            shift
            ;;
        -v|-vv|-vvv|-vvvv)
            EXTRA_ARGS+=("$1")
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            PLAYBOOK="$1"
            shift
            ;;
    esac
done

if [[ -z "$PLAYBOOK" ]]; then
    echo "ERROR: Playbook name required"
    usage
    exit 1
fi

# Resolve playbook path
PLAYBOOK_PATH="$REPO_PATH/playbooks/${PLAYBOOK}.yml"
if [[ ! -f "$PLAYBOOK_PATH" ]]; then
    PLAYBOOK_PATH="$REPO_PATH/playbooks/${PLAYBOOK}"
fi
if [[ ! -f "$PLAYBOOK_PATH" ]]; then
    echo "ERROR: Playbook not found: $PLAYBOOK"
    exit 1
fi

# Log execution start
log_audit "STARTED" "Playbook: $PLAYBOOK, DryRun: $DRY_RUN" "${EXTRA_ARGS[*]:-none}"

echo "================================================================"
echo "Infrastructure Automation"
echo "================================================================"
echo "Execution ID: $EXECUTION_ID"
echo "Operator:     $REAL_USER"
echo "Account:      $SERVICE_ACCOUNT"
echo "Playbook:     $PLAYBOOK"
echo "Timestamp:    $TIMESTAMP"
echo "Dry Run:      $DRY_RUN"
echo "================================================================"

# Confirmation prompt for non-dry-run
if [[ "$DRY_RUN" == "false" ]] && [[ ! "${EXTRA_ARGS[*]:-}" =~ "--list-hosts" ]]; then
    echo ""
    echo "WARNING: This will make changes to production infrastructure."
    read -p "Type 'yes' to continue: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_audit "CANCELLED" "User cancelled execution"
        echo "Execution cancelled."
        exit 0
    fi
fi

# Activate virtual environment
source "$VENV_PATH/bin/activate"

# Set Tugboat environment
export TUG_LOG_PATH="$AUDIT_DIR/tugboat-${EXECUTION_ID}.log"
export TUG_STDOUT_CALLBACK="yaml"

# Execute Tugboat
cd "$REPO_PATH"

set +e
tug \
    -i "$REPO_PATH/inventory/ssm_plugin.py" \
    "$PLAYBOOK_PATH" \
    "${EXTRA_ARGS[@]}" \
    2>&1 | tee -a "$AUDIT_DIR/tugboat-${EXECUTION_ID}.log"

EXIT_CODE=${PIPESTATUS[0]}
set -e

# Deactivate virtual environment
deactivate

# Update completion timestamp
END_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Log completion
if [[ $EXIT_CODE -eq 0 ]]; then
    log_audit "SUCCESS" "Playbook completed successfully"
else
    log_audit "FAILED" "Playbook failed with exit code $EXIT_CODE"
fi

echo ""
echo "================================================================"
echo "Execution complete"
echo "Exit code: $EXIT_CODE"
echo "Log file:  $AUDIT_DIR/tugboat-${EXECUTION_ID}.log"
echo "================================================================"

exit $EXIT_CODE
```

Set permissions:

```bash
chmod 755 /usr/local/bin/tug
chown root:root /usr/local/bin/tug
```

---

## Audit Logging Setup

### Create Audit Directory

```bash
mkdir -p /var/log/tugboat
chmod 750 /var/log/tugboat
chown root:adm /var/log/tugboat
```

### Configure Rsyslog

**`/etc/rsyslog.d/50-tugboat.conf`**:

```
# Tugboat audit logging
local0.* /var/log/tugboat/syslog.log
local0.* @127.0.0.1:25224
```

Restart rsyslog:

```bash
systemctl restart rsyslog
```

### Configure Logrotate

**`/etc/logrotate.d/tugboat`**:

```
/var/log/tugboat/*.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
```

### Install Azure OMS Agent

```bash
# Download OMS agent installer
wget https://raw.githubusercontent.com/Microsoft/OMS-Agent-for-Linux/master/installer/scripts/onboard_agent.sh

# Install (replace with your workspace ID and key)
sh onboard_agent.sh -w <WORKSPACE_ID> -s <WORKSPACE_KEY> -d opinsights.azure.com

# Verify installation
systemctl status omsagent-<WORKSPACE_ID>
```

---

## Session Timeout Configuration

### Shell Timeout

**`/etc/profile.d/timeout.sh`**:

```bash
# Auto-logout after 30 minutes of inactivity
TMOUT=1800
readonly TMOUT
export TMOUT
```

### SSH Timeout

Already configured in `/etc/ssh/sshd_config`:

```
ClientAliveInterval 300
ClientAliveCountMax 6
```

---

## Emergency Access

### Root Password Storage

The root password is stored in Keeper password manager:

| Field | Value |
|-------|-------|
| Keeper Path | `Infrastructure/Tugboat-Node/root-password` |
| Username | `root` |
| Hostname | `tugboat.domain.local` |

### Emergency Access Procedure

1. Obtain root password from Keeper
2. Access VM console via Proxmox web UI or `qm terminal 200`
3. Login as root
4. Document the emergency access
5. Rotate password after incident

### Password Rotation Schedule

| Account | Rotation Frequency |
|---------|-------------------|
| root | Quarterly |
| Service account SSH keys | Annually |
| AWS IAM credentials | Annually |

---

## Verification Checklist

After setup, verify each component:

- [ ] VM boots and network connectivity works
- [ ] DNS resolution for domain.local
- [ ] SSSD connects to AD: `realm list`
- [ ] AD user can SSH: `ssh user@DOMAIN.LOCAL@tugboat`
- [ ] Duo MFA prompts during SSH login
- [ ] Service accounts exist: `id svc-proxmox`
- [ ] PAM allows authorized group to su: `su - svc-proxmox`
- [ ] PAM denies unauthorized group: (test with non-member)
- [ ] AWS credentials work: `aws sts get-caller-identity`
- [ ] SSM parameters accessible: `aws ssm get-parameter --name /proxmox/cl1/n01/ip`
- [ ] Tugboat runs: `tug setup_proxmox --check --limit n01`
- [ ] Audit logs generated: `cat /var/log/tugboat/executions.log`
- [ ] Logs forwarded to Azure: Check Log Analytics workspace

---

## Maintenance

### Update Tugboat

```bash
source /opt/tugboat/bin/activate
pip install --upgrade tugboat boto3 botocore
tugboat-galaxy collection install --upgrade amazon.aws community.general
deactivate
```

### Update Infrastructure Repository

```bash
cd /opt/tugboat
git pull origin main
```

### Renew Kerberos Ticket (if needed)

AD authentication typically handles this automatically, but manual renewal:

```bash
kinit jsmith@DOMAIN.LOCAL
klist
```

---

## Related Documentation

- [Tugboat Administrator Guide](tugboat-admin-guide.md) - Day-to-day operations
- [Tugboat Access Control](tugboat-access-control.md) - AD group configuration
- [Tugboat Audit and Compliance](tugboat-compliance.md) - Logging details
