# Tugboat Administrator Guide

**Version:** 1.0
**Last Updated:** 2025-01
**Audience:** Infrastructure Administrators

This guide documents how systems administrators execute Tugboat automation tasks against the cyber infrastructure (Proxmox, Weka, Ceph, NVIDIA HPC).

> **Tugboat** is small but able to push around massive HPC fleets. The CLI tool is called `tug`.

---

## Overview

### Execution Model

This infrastructure uses a **manual execution model** where authenticated administrators run `tug` commands on-demand from a centralized Tugboat node. There is no automated triggering from GitHub pushes or AWS SSM parameter changes.

**Key characteristics:**

- Administrators authenticate via Active Directory (AD) with Duo MFA
- Each infrastructure team has a dedicated local service account protected by AD group membership
- Tugboat fetches configuration from AWS SSM Parameter Store at runtime
- All actions are logged and attributed to individual users
- Emergency access via local root account (password in Keeper)

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SYSADMIN WORKSTATION                           │
│                         (Corporate network / VPN)                           │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  │ SSH with AD credentials + Duo MFA
                                  │
┌─────────────────────────────────▼───────────────────────────────────────────┐
│                           TUGBOAT NODE (VM)                                 │
│                         tugboat.domain.local                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    AUTHENTICATION LAYER                             │   │
│   │  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────┐  │   │
│   │  │ SSSD/Realm  │───▶│ Active      │───▶│ Duo MFA                 │  │   │
│   │  │ (PAM)       │    │ Directory   │    │ (SSH 2FA)               │  │   │
│   │  └─────────────┘    └─────────────┘    └─────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                  │                                          │
│                                  ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    ROLE-BASED ACCESS LAYER                          │   │
│   │                                                                     │   │
│   │   AD User ──▶ su to team account ──▶ Team AD Group validates       │   │
│   │                                                                     │   │
│   │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │   │
│   │   │ svc-proxmox  │  │ svc-weka     │  │ svc-nvidia   │  ...        │   │
│   │   │ (local user) │  │ (local user) │  │ (local user) │             │   │
│   │   └──────────────┘  └──────────────┘  └──────────────┘             │   │
│   │         │                  │                  │                     │   │
│   │         ▼                  ▼                  ▼                     │   │
│   │   Proxmox-Admins     Weka-Admins        NVIDIA-Admins              │   │
│   │   (AD Group)         (AD Group)         (AD Group)                 │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                  │                                          │
│                                  ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    TUGBOAT EXECUTION LAYER                          │   │
│   │                                                                     │   │
│   │   tug <subcommand> ──▶ Fetches SSM params ──▶ Runs automation      │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                  │                                          │
│                                  ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    AUDIT LOGGING LAYER                              │   │
│   │                                                                     │   │
│   │   Local logs ──▶ Syslog ──▶ Azure Log Analytics ──▶ Defender XDR   │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  │ SSH (key-based)
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Proxmox    │         │    Weka      │         │   NVIDIA     │
│   Cluster    │         │   Cluster    │         │    HPC       │
└──────────────┘         └──────────────┘         └──────────────┘
```

---

## Workflow Steps

### Step 1: Authenticate to Tugboat Node

Connect via SSH using your AD credentials:

```bash
ssh jsmith@DOMAIN.LOCAL@tugboat.domain.local
```

You will be prompted for:
1. Your AD password
2. Duo MFA verification (push notification or code)

### Step 2: Switch to Team Service Account

Each infrastructure domain has a dedicated local service account. You must be a member of the corresponding AD group to switch to that account.

| Service Account | AD Group Required | Infrastructure Access |
|-----------------|-------------------|----------------------|
| `svc-proxmox` | `Proxmox-Admins@DOMAIN.LOCAL` | Proxmox VE clusters |
| `svc-weka` | `Weka-Admins@DOMAIN.LOCAL` | Weka file systems |
| `svc-ceph` | `Ceph-Admins@DOMAIN.LOCAL` | Ceph storage clusters |
| `svc-nvidia` | `NVIDIA-Admins@DOMAIN.LOCAL` | NVIDIA HPC infrastructure |

Switch to the appropriate service account:

```bash
# Switch to Proxmox team account
su - svc-proxmox

# Switch to Weka team account
su - svc-weka
```

PAM will verify your AD group membership before allowing the switch. If you are not in the required group, access will be denied:

```
su: Permission denied
```

### Step 3: Execute Tugboat Automation

Use the `tug` CLI to run automation:

```bash
# Check mode (dry run) - always run this first
tug deploy proxmox --check

# List hosts that would be affected
tug deploy proxmox --list-hosts

# Execute deployment (requires confirmation)
tug deploy proxmox

# Limit to specific cluster or host
tug deploy proxmox --limit cl1
tug deploy weka --limit n01

# Run specific tags only
tug deploy proxmox --tags network

# Increase verbosity for troubleshooting
tug deploy proxmox -vvv
```

### Step 4: Review Execution Results

After execution, review the output and logs:

```bash
# View execution log
cat /var/log/tugboat/tug-<execution-id>.log

# View recent audit entries
tail -20 /var/log/tugboat/executions.log | jq .

# Search audit log for your executions
grep "jsmith@DOMAIN.LOCAL" /var/log/tugboat/executions.log | jq .
```

---

## Available Subcommands

### tug deploy

Deploy infrastructure configurations:

| Target | Description | Infrastructure |
|--------|-------------|----------------|
| `tug deploy proxmox` | Configure Proxmox VE cluster | Proxmox nodes |
| `tug deploy weka` | Configure Weka file system | Weka nodes |
| `tug deploy ceph` | Configure Ceph storage | Ceph nodes |
| `tug deploy nvidia` | Configure NVIDIA HPC | NVIDIA nodes |

### tug status

Check infrastructure status (planned):

```bash
tug status proxmox         # Show Proxmox cluster status
tug status weka            # Show Weka cluster status
```

### tug inventory

Manage dynamic inventory:

```bash
tug inventory list         # List all discovered hosts
tug inventory refresh      # Force refresh from SSM
tug inventory show n01     # Show details for specific host
```

### Deployment Tags

Each deployment supports tags for running specific components:

**Proxmox (`tug deploy proxmox`):**
- `common` - Base system configuration
- `network` - VLAN and bonding configuration
- `storage` - Ceph pool setup
- `gpu` - NVIDIA driver and MIG configuration
- `ha` - High availability and fencing
- `monitoring` - Prometheus/Grafana setup
- `backup` - PBS configuration

**Weka (`tug deploy weka`):**
- `common` - Base system configuration
- `network` - LACP bonding and IP setup
- `cluster` - Weka cluster formation
- `filesystems` - Filesystem creation
- `protocols` - NFS/SMB/S3 configuration

---

## tug CLI Reference

### Synopsis

```
tug <subcommand> [target] [OPTIONS]
```

### Global Options

| Option | Description |
|--------|-------------|
| `--check`, `--dry-run` | Run in check mode without making changes |
| `--limit <pattern>` | Limit execution to specific hosts or groups |
| `--tags <tags>` | Run only tasks with specified tags |
| `--list-hosts` | Show hosts that would be affected |
| `-v`, `-vv`, `-vvv` | Increase output verbosity |
| `--help` | Display help message |

### Examples

```bash
# Dry run Proxmox deployment
tug deploy proxmox --check

# Configure only networking on cluster cl1
tug deploy proxmox --tags network --limit cl1

# Full Weka deployment with verbose output
tug deploy weka -vv

# List all hosts in NVIDIA inventory
tug deploy nvidia --list-hosts

# Show current inventory
tug inventory list
```

### Execution Flow

When you run `tug deploy`:

1. **Authentication Check**: Verifies you are in an authorized AD group
2. **Audit Start**: Creates audit log entry with your identity and intent
3. **SSM Fetch**: Queries AWS SSM Parameter Store for infrastructure configuration
4. **Confirmation**: Prompts for confirmation (non-check mode only)
5. **Automation Run**: Executes the deployment with injected parameters
6. **Audit Complete**: Updates audit log with success/failure status

---

## AWS SSM Parameter Integration

### How Parameters Are Fetched

The `tug` CLI uses the dynamic inventory plugin to:

1. Query AWS SSM for all parameters under `/{system_type}/`
2. Parse the hierarchical path structure
3. Build inventory dynamically
4. Inject host variables (IPs, MACs, credentials)

### Parameter Hierarchy

```
/{system_type}/{cluster_id}/{node_id}/{attribute}
```

Examples:
```
/proxmox/cl1/n01/ip          → 10.10.6.11
/proxmox/cl1/n01/mac         → aa:bb:cc:dd:ee:ff
/proxmox/cl1/shared/token    → [SecureString]
/weka/cl1/n01/container_id   → weka-01
```

### Viewing Current Parameters

From the Tugboat node:

```bash
# List all Proxmox parameters
aws ssm get-parameters-by-path --path /proxmox --recursive --query "Parameters[*].Name"

# Get specific parameter value
aws ssm get-parameter --name /proxmox/cl1/n01/ip --query "Parameter.Value"

# Test inventory generation
tug inventory list
```

### Caching

SSM parameters are cached locally for 5 minutes to reduce API calls. To force a refresh:

```bash
tug inventory refresh
```

---

## Emergency Access

### Break-Glass Procedure

In case of AD outage or emergency requiring immediate access:

1. **Obtain root password** from Keeper password manager
2. **Access console** via IPMI/BMC or VM console
3. **Login as root** with stored password
4. **Document the access** - emergency access is logged separately

The root password is rotated quarterly and stored in:
- **Keeper Path**: `Infrastructure/Tugboat-Node/root-password`

### Emergency Contacts

| Role | Contact |
|------|---------|
| Infrastructure Lead | [per local policy] |
| Security Team | [per local policy] |
| AD/Identity Team | [per local policy] |

---

## Troubleshooting

### Cannot Switch to Service Account

**Symptom:** `su: Permission denied` when switching to svc-proxmox (or other service account)

**Cause:** Your AD account is not a member of the required AD group.

**Solution:**
1. Verify your group membership: `id` or `groups`
2. Request group membership through your organization's access request process
3. Log out and log back in for group changes to take effect

### AWS SSM Permission Denied

**Symptom:** `AccessDeniedException` when running tug commands

**Cause:** The Tugboat node's IAM role lacks SSM permissions.

**Solution:**
1. Verify IAM role attachment: `aws sts get-caller-identity`
2. Check IAM policy allows `ssm:GetParametersByPath` for the required paths
3. Contact cloud team if policy update is needed

### SSH Connection Failures to Infrastructure

**Symptom:** Tugboat cannot connect to target hosts

**Checks:**
1. Verify SSH key exists: `ls -la ~/.ssh/`
2. Test connectivity manually: `ssh -i ~/.ssh/tugboat_ed25519 root@<target-ip>`
3. Check target host firewall allows SSH from Tugboat node
4. Verify network route exists to target subnet

### Duo MFA Not Working

**Symptom:** Cannot complete MFA during SSH login

**Solutions:**
1. Verify Duo app is configured correctly on your phone
2. Try alternate MFA method (SMS, phone call)
3. If Duo service is down, use emergency bypass (requires security team approval)

---

## Best Practices

### Before Making Changes

1. **Always run `--check` first** - Preview changes before applying
2. **Start with `--limit`** - Test on one host before full cluster
3. **Review the diff output** - Understand what will change
4. **Verify SSM parameters** - Ensure configuration data is correct

### During Execution

1. **Monitor output** - Watch for errors or warnings
2. **Don't interrupt** - Let deployments complete; interruption may leave inconsistent state
3. **Use appropriate verbosity** - `-v` for normal, `-vvv` for debugging

### After Execution

1. **Verify success** - Check exit code and output
2. **Test functionality** - Validate the infrastructure is working
3. **Review audit log** - Confirm your actions were logged correctly
4. **Document exceptions** - Note any manual interventions required

### Security Guidelines

1. **Never share service account sessions** - Each person switches to their own session
2. **Log out when done** - Don't leave sessions open
3. **Report suspicious activity** - Audit logs showing unknown users
4. **Don't disable auditing** - All bypasses require security approval

---

## Related Documentation

- [Tugboat Access Control](tugboat-access-control.md) - AD integration and role-based access details
- [Tugboat Audit and Compliance](tugboat-audit-compliance.md) - Audit trail and retention policies
- [Tugboat Node Setup](tugboat-node-setup.md) - VM configuration and maintenance
- [AWS IAM Policies](../proxmox/deployment/AWS-IAM-POLICIES.md) - IAM policy specifications
