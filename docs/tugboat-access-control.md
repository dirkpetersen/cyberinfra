# Tugboat Access Control

**Version:** 1.0
**Last Updated:** 2025-01
**Audience:** Security Administrators, Infrastructure Leads

This document defines the access control model for Tugboat automation, including Active Directory integration, role-based service accounts, and PAM configuration.

---

## Access Control Model

### Design Principles

1. **Separation of Duties**: Not all team members need access to all infrastructure
2. **Least Privilege**: Users only access systems required for their role
3. **Individual Accountability**: All actions traced to individual AD accounts
4. **Defense in Depth**: Multiple authentication factors (AD + Duo MFA)
5. **Auditable Access**: Every privilege escalation is logged

### Access Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ACCESS FLOW DIAGRAM                               │
└─────────────────────────────────────────────────────────────────────────────┘

    ┌──────────────┐
    │ Sysadmin     │
    │ (AD User)    │
    └──────┬───────┘
           │
           │ 1. SSH to Tugboat node
           │    (AD credentials + Duo MFA)
           ▼
    ┌──────────────┐     ┌──────────────┐
    │ PAM Stack    │────▶│ Active       │
    │ (pam_sss)    │     │ Directory    │
    └──────┬───────┘     └──────────────┘
           │                    │
           │ 2. Authenticated   │ Validates credentials
           │    session         │ Returns group membership
           ▼                    ▼
    ┌──────────────────────────────────────┐
    │ User Shell (personal AD account)     │
    │ e.g., jsmith@DOMAIN.LOCAL            │
    └──────────────────┬───────────────────┘
                       │
                       │ 3. su - svc-proxmox
                       │    (switch to team service account)
                       ▼
    ┌──────────────────────────────────────┐
    │ PAM (pam_succeed_if)                 │
    │ Checks: Is user in Proxmox-Admins?   │
    └──────────────────┬───────────────────┘
                       │
           ┌───────────┴───────────┐
           │                       │
     ┌─────▼─────┐           ┌─────▼─────┐
     │ YES       │           │ NO        │
     │ Allow su  │           │ Deny su   │
     └─────┬─────┘           └───────────┘
           │
           │ 4. Now operating as svc-proxmox
           ▼
    ┌──────────────────────────────────────┐
    │ Service Account Shell                │
    │ svc-proxmox                          │
    │                                      │
    │ - Has AWS credentials for SSM        │
    │ - Has SSH keys for target infra      │
    │ - Can run tug commands               │
    └──────────────────────────────────────┘
```

---

## Active Directory Configuration

### Required AD Groups

Create the following security groups in Active Directory:

| AD Group Name | Purpose | Infrastructure Access |
|---------------|---------|----------------------|
| `Proxmox-Admins` | Proxmox VE cluster administration | All Proxmox nodes |
| `Weka-Admins` | Weka file system administration | All Weka nodes |
| `Ceph-Admins` | Ceph storage administration | All Ceph nodes |
| `NVIDIA-Admins` | NVIDIA HPC administration | All NVIDIA nodes |
| `Infrastructure-Admins` | Full infrastructure access (superadmins) | All systems |

### Group Nesting Recommendation

```
Infrastructure-Admins (parent group)
├── Proxmox-Admins (nested)
├── Weka-Admins (nested)
├── Ceph-Admins (nested)
└── NVIDIA-Admins (nested)
```

Members of `Infrastructure-Admins` inherit access to all service accounts. Team-specific groups provide granular access.

### AD Group Attributes

| Attribute | Value |
|-----------|-------|
| Group Scope | Global |
| Group Type | Security |
| OU Location | `OU=Infrastructure,OU=Security Groups,DC=domain,DC=local` |

---

## Local Service Accounts

### Account Definitions

Each service account is a local Linux user on the Tugboat node:

| Account | UID | Home Directory | Shell | Purpose |
|---------|-----|----------------|-------|---------|
| `svc-proxmox` | 10001 | `/home/svc-proxmox` | `/bin/bash` | Proxmox automation |
| `svc-weka` | 10002 | `/home/svc-weka` | `/bin/bash` | Weka automation |
| `svc-ceph` | 10003 | `/home/svc-ceph` | `/bin/bash` | Ceph automation |
| `svc-nvidia` | 10004 | `/home/svc-nvidia` | `/bin/bash` | NVIDIA automation |

### Account Creation Commands

```bash
# Create service accounts with specific UIDs
useradd -u 10001 -m -s /bin/bash -c "Proxmox Automation Account" svc-proxmox
useradd -u 10002 -m -s /bin/bash -c "Weka Automation Account" svc-weka
useradd -u 10003 -m -s /bin/bash -c "Ceph Automation Account" svc-ceph
useradd -u 10004 -m -s /bin/bash -c "NVIDIA Automation Account" svc-nvidia

# Lock password authentication (su only via PAM group check)
passwd -l svc-proxmox
passwd -l svc-weka
passwd -l svc-ceph
passwd -l svc-nvidia
```

### Service Account Home Directory Structure

Each service account home directory contains:

```
/home/svc-proxmox/
├── .ssh/
│   ├── tugboat_ed25519         # SSH private key for automation
│   ├── tugboat_ed25519.pub     # SSH public key
│   └── config                  # SSH client configuration
├── .aws/
│   └── credentials             # AWS credentials (or use IAM role)
└── .bashrc                     # Shell configuration
```

---

## PAM Configuration

### Overview

PAM (Pluggable Authentication Modules) enforces AD group membership when users attempt to switch to service accounts.

### Configuration Files

**`/etc/pam.d/su`** - Controls `su` command access:

```
#%PAM-1.0

# Authenticate via SSSD (AD)
auth        sufficient    pam_rootok.so
auth        required      pam_sss.so

# Account validation
account     sufficient    pam_rootok.so
account     required      pam_sss.so

# Service account access control
# Allow Infrastructure-Admins to su to any svc-* account
account     [success=1 default=ignore] pam_succeed_if.so user ingroup Infrastructure-Admins@DOMAIN.LOCAL

# Team-specific access controls
# Proxmox-Admins can su to svc-proxmox
account     [success=done default=ignore] pam_succeed_if.so service = su user = svc-proxmox ruser ingroup Proxmox-Admins@DOMAIN.LOCAL

# Weka-Admins can su to svc-weka
account     [success=done default=ignore] pam_succeed_if.so service = su user = svc-weka ruser ingroup Weka-Admins@DOMAIN.LOCAL

# Ceph-Admins can su to svc-ceph
account     [success=done default=ignore] pam_succeed_if.so service = su user = svc-ceph ruser ingroup Ceph-Admins@DOMAIN.LOCAL

# NVIDIA-Admins can su to svc-nvidia
account     [success=done default=ignore] pam_succeed_if.so service = su user = svc-nvidia ruser ingroup NVIDIA-Admins@DOMAIN.LOCAL

# Deny all other su attempts to svc-* accounts
account     requisite     pam_deny.so

# Session handling
session     required      pam_unix.so
session     optional      pam_sss.so
```

### PAM Logic Explanation

The PAM stack processes rules sequentially:

1. **Root bypass**: `pam_rootok.so` allows root to su without restriction
2. **Infrastructure-Admins**: Members can su to ANY service account (superadmin)
3. **Team checks**: Each team group is checked for its corresponding service account
4. **Deny fallthrough**: If no rule matches, access is denied

### Alternative: sudoers.d Configuration

If you prefer using sudo instead of su for service account access:

**`/etc/sudoers.d/tugboat-service-accounts`**:

```sudoers
# Tugboat service account access via sudo

# Infrastructure-Admins can become any service account
%Infrastructure-Admins@DOMAIN.LOCAL ALL=(svc-proxmox,svc-weka,svc-ceph,svc-nvidia) NOPASSWD: ALL

# Proxmox-Admins can only become svc-proxmox
%Proxmox-Admins@DOMAIN.LOCAL ALL=(svc-proxmox) NOPASSWD: ALL

# Weka-Admins can only become svc-weka
%Weka-Admins@DOMAIN.LOCAL ALL=(svc-weka) NOPASSWD: ALL

# Ceph-Admins can only become svc-ceph
%Ceph-Admins@DOMAIN.LOCAL ALL=(svc-ceph) NOPASSWD: ALL

# NVIDIA-Admins can only become svc-nvidia
%NVIDIA-Admins@DOMAIN.LOCAL ALL=(svc-nvidia) NOPASSWD: ALL

# Enable sudo logging
Defaults log_output
Defaults log_input
Defaults logfile="/var/log/sudo-tugboat.log"
```

With this approach, users would run:

```bash
sudo -u svc-proxmox -i    # Instead of: su - svc-proxmox
```

---

## SSSD Configuration

### Domain Join

The Tugboat node must be joined to the AD domain:

```bash
# Install required packages
apt-get install -y sssd sssd-tools realmd adcli krb5-user

# Discover and join domain
realm discover DOMAIN.LOCAL
realm join --user=admin@DOMAIN.LOCAL DOMAIN.LOCAL

# Permit specific groups to login via SSH
realm permit -g 'Proxmox-Admins@DOMAIN.LOCAL'
realm permit -g 'Weka-Admins@DOMAIN.LOCAL'
realm permit -g 'Ceph-Admins@DOMAIN.LOCAL'
realm permit -g 'NVIDIA-Admins@DOMAIN.LOCAL'
realm permit -g 'Infrastructure-Admins@DOMAIN.LOCAL'
```

### SSSD Configuration File

**`/etc/sssd/sssd.conf`**:

```ini
[sssd]
domains = DOMAIN.LOCAL
config_file_version = 2
services = nss, pam, sudo

[domain/DOMAIN.LOCAL]
# Identity provider
id_provider = ad
access_provider = ad
auth_provider = ad

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

# Performance tuning
ldap_use_tokengroups = true
ldap_referrals = false

# Fully qualified names (user@DOMAIN.LOCAL format)
use_fully_qualified_names = true
fallback_homedir = /home/%u@%d
default_shell = /bin/bash

# Group enumeration (required for PAM group checks)
enumerate = false
ldap_group_nesting_level = 2
```

Set permissions:

```bash
chmod 600 /etc/sssd/sssd.conf
systemctl restart sssd
```

---

## Duo MFA Integration

### SSH Integration

Duo provides MFA for SSH access to the Tugboat node.

**`/etc/pam.d/sshd`** (add Duo after primary auth):

```
#%PAM-1.0

# Primary authentication via SSSD (AD)
auth       required     pam_sss.so

# Duo MFA (after AD password)
auth       required     pam_duo.so

# Account and session handling
account    required     pam_nologin.so
account    required     pam_sss.so
password   requisite    pam_sss.so
session    required     pam_limits.so
session    required     pam_unix.so
session    optional     pam_sss.so
```

### Duo Configuration

**`/etc/duo/pam_duo.conf`**:

```ini
[duo]
; Duo API credentials (stored in file, not here)
ikey = <stored-in-ssm>
skey = <stored-in-ssm>
host = <stored-in-ssm>

; Authentication settings
pushinfo = yes
autopush = yes
prompts = 1

; Failmode: "safe" allows access if Duo unreachable
; Use "secure" in high-security environments
failmode = safe

; Group restrictions (optional - can restrict Duo to specific groups)
; groups = Infrastructure-Admins@DOMAIN.LOCAL
```

### Duo Bypass for Emergencies

In case of Duo service outage, authorized security personnel can enable bypass:

```bash
# Temporarily disable Duo (requires root)
# Comment out pam_duo.so line in /etc/pam.d/sshd

# Re-enable after Duo service restored
# Uncomment pam_duo.so line
```

All bypass events must be documented and reported to security team.

---

## Access Request Process

### New User Access

1. **User submits request** via organization's access request system
2. **Manager approval** for team membership
3. **Security review** for sensitive groups (Infrastructure-Admins)
4. **AD team adds user** to appropriate group(s)
5. **User logs out/in** to refresh group membership
6. **User tests access** to Tugboat node and service accounts

### Access Removal

1. **Trigger**: Employee termination, role change, or access review
2. **AD team removes user** from group(s)
3. **Active sessions terminated** (if immediate removal required)
4. **Access reviewed** in next periodic audit

### Periodic Access Reviews

| Review Type | Frequency | Reviewer |
|-------------|-----------|----------|
| Team membership | Quarterly | Team leads |
| Infrastructure-Admins | Monthly | Security team |
| Service account usage | Monthly | Infrastructure lead |
| Emergency access | Per occurrence | Security team |

---

## Security Considerations

### Account Lockout

AD account lockout policies apply to SSH authentication:

| Setting | Recommended Value |
|---------|-------------------|
| Lockout threshold | 5 failed attempts |
| Lockout duration | 30 minutes |
| Reset counter | 15 minutes |

### Session Timeout

Configure idle session timeout to prevent abandoned sessions:

**`/etc/profile.d/timeout.sh`**:

```bash
# Auto-logout after 30 minutes of inactivity
TMOUT=1800
readonly TMOUT
export TMOUT
```

### SSH Key Management

| Key Type | Purpose | Rotation |
|----------|---------|----------|
| User SSH keys | Personal authentication | User-managed |
| Service account keys | Tugboat to infrastructure | Annual |
| Host keys | Tugboat node identity | On rebuild |

### Audit Points

All access control events are logged:

- SSH login attempts (success/failure)
- Duo MFA results
- Service account switches (su/sudo)
- tug command execution
- AWS SSM parameter access

---

## Troubleshooting

### User Cannot SSH to Tugboat Node

**Check AD account status:**
```bash
# On a domain-joined system
net ads user info jsmith
```

**Check SSSD cache:**
```bash
sss_cache -u jsmith@DOMAIN.LOCAL
systemctl restart sssd
```

**Check SSH access permissions:**
```bash
realm list
# Verify user's group is in "permitted-groups"
```

### User Cannot Switch to Service Account

**Verify group membership:**
```bash
# As the user
id
groups

# Should show: Proxmox-Admins@DOMAIN.LOCAL (or relevant group)
```

**Check PAM configuration:**
```bash
# Test PAM authentication
pamtester su svc-proxmox authenticate
```

**Check SSSD group resolution:**
```bash
getent group Proxmox-Admins@DOMAIN.LOCAL
```

### Duo MFA Not Prompting

**Check Duo daemon:**
```bash
systemctl status duo
journalctl -u duo
```

**Verify Duo configuration:**
```bash
# Test Duo connectivity
/usr/sbin/login_duo -c /etc/duo/pam_duo.conf echo "Duo works"
```

---

## Related Documentation

- [Tugboat Administrator Guide](tugboat-admin-guide.md) - Day-to-day operations
- [Tugboat Audit and Compliance](tugboat-audit-compliance.md) - Audit trail details
- [Tugboat Node Setup](tugboat-node-setup.md) - Initial configuration
