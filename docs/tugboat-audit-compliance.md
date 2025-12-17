# Tugboat Audit and Compliance

**Version:** 1.0
**Last Updated:** 2025-01
**Audience:** Security Administrators, Compliance Officers, Infrastructure Leads

This document defines the audit trail architecture, log retention policies, and compliance requirements for Tugboat automation activities.

---

## Audit Architecture Overview

### Design Principles

1. **Non-repudiation**: Every action is tied to an authenticated individual
2. **Immutability**: Logs cannot be modified by operators
3. **Completeness**: All automation activities are captured
4. **Centralization**: Logs forwarded to enterprise SIEM for analysis
5. **Retention**: Logs retained per organizational policy

### Audit Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AUDIT DATA FLOW                                   │
└─────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────┐
│ tug                   │
│ (wrapper script)     │
└──────────┬───────────┘
           │
           │ Generates structured audit events
           ▼
┌──────────────────────────────────────────────────────────────────┐
│                    LOCAL AUDIT STORAGE                           │
│                    /var/log/tugboat/                       │
│                                                                  │
│  ┌────────────────────┐  ┌────────────────────────────────────┐  │
│  │ executions.log     │  │ tugboat-<uuid>.log                 │  │
│  │ (JSON audit trail) │  │ (Full execution output per run)     │  │
│  └─────────┬──────────┘  └─────────────────────────────────────┘ │
│            │                                                     │
└────────────┼─────────────────────────────────────────────────────┘
             │
             │ Forwarded via syslog
             ▼
┌──────────────────────┐     ┌──────────────────────┐
│ rsyslog              │────▶│ Azure OMS Agent      │
│ (local syslog)       │     │ (Log Analytics)      │
└──────────────────────┘     └──────────┬───────────┘
                                        │
                                        │ HTTPS (port 443)
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        AZURE LOG ANALYTICS                                  │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │ Workspace: tugboat-audit                                      │   │
│   │                                                                     │   │
│   │ Tables:                                                             │   │
│   │   - Syslog (tugboat facility)                                 │   │
│   │   - Custom_TugboatExecution_CL (structured events)                  │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│                              ▼                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │ Microsoft Defender XDR                                              │   │
│   │                                                                     │   │
│   │ - Security alerting on suspicious patterns                          │   │
│   │ - Correlation with AD authentication events                         │   │
│   │ - Integration with incident response                                │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Audit Event Structure

### Execution Audit Record

Each Tugboat execution generates a JSON audit record:

```json
{
  "execution_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "timestamp": "2025-01-15T14:32:00.000Z",
  "event_type": "tug_execution",
  "user": {
    "ad_principal": "jsmith@DOMAIN.LOCAL",
    "service_account": "svc-proxmox",
    "session_id": "12345",
    "source_ip": "10.10.1.50"
  },
  "execution": {
    "command": "setup_proxmox",
    "arguments": ["--check", "--limit", "cl1"],
    "dry_run": true,
    "working_directory": "/opt/cyberinfra"
  },
  "target": {
    "system_type": "proxmox",
    "hosts_affected": ["n01", "n02", "n03"],
    "cluster_id": "cl1"
  },
  "result": {
    "status": "SUCCESS",
    "exit_code": 0,
    "duration_seconds": 127,
    "tasks_changed": 5,
    "tasks_failed": 0,
    "tasks_skipped": 12
  },
  "environment": {
    "hostname": "tugboat.domain.local",
    "tugboat_version": "2.15.0",
    "python_version": "3.11.2"
  }
}
```

### Event Types

| Event Type | Description | Logged When |
|------------|-------------|-------------|
| `tug_execution_started` | Playbook execution initiated | User runs tug |
| `tug_execution_completed` | Playbook finished successfully | Exit code 0 |
| `tug_execution_failed` | Execution failed | Non-zero exit code |
| `tug_execution_cancelled` | User cancelled before execution | User typed 'no' at confirmation |
| `tug_execution_denied` | Access denied | User not in authorized group |
| `service_account_switch` | User switched to service account | Successful su/sudo |
| `service_account_denied` | Service account switch denied | Failed su/sudo (wrong group) |

---

## Log Files and Locations

### Local Log Storage

| File Path | Content | Format | Rotation |
|-----------|---------|--------|----------|
| `/var/log/tugboat/executions.log` | Audit event stream | JSON (one per line) | Daily, 90 days |
| `/var/log/tugboat/tugboat-<uuid>.log` | Full execution output | Text | 90 days |
| `/var/log/sudo-infra.log` | Sudo command log | Text | Daily, 90 days |
| `/var/log/auth.log` | SSH and PAM events | Syslog | Per system policy |
| `/var/log/sssd/*.log` | AD authentication | Text | Per system policy |

### Log Directory Permissions

```bash
# Audit directory permissions
drwxr-x---  root  adm    /var/log/tugboat/
-rw-r-----  root  adm    /var/log/tugboat/executions.log
-rw-r-----  root  adm    /var/log/tugboat/tugboat-*.log
```

Operators can read logs but cannot modify or delete them.

---

## Log Retention Policy

### Retention Requirements

| Log Type | Local Retention | Cloud Retention | Total Retention |
|----------|-----------------|-----------------|-----------------|
| Audit events | 90 days | 1 year | 1 year |
| Playbook output | 90 days | 1 year | 1 year |
| Authentication logs | 90 days | 1 year | 1 year |
| Access denied events | 90 days | 2 years | 2 years |

### Logrotate Configuration

**`/etc/logrotate.d/tugboat`**:

```
/var/log/tugboat/executions.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        /usr/bin/systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}

/var/log/tugboat/tugboat-*.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}

/var/log/sudo-infra.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
```

---

## Syslog Forwarding

### Rsyslog Configuration

**`/etc/rsyslog.d/50-tugboat.conf`**:

```
# Tugboat audit logging configuration

# Define template for structured logging
template(name="TugboatAuditFormat" type="string"
    string="%TIMESTAMP:::date-rfc3339% %HOSTNAME% tugboat: %msg%\n")

# Local file logging
local0.* /var/log/tugboat/syslog.log;TugboatAuditFormat

# Forward to Azure Log Analytics agent
local0.* @127.0.0.1:25224

# Also keep in standard syslog for backup
local0.* /var/log/syslog
```

### Rsyslog Facility Assignment

| Facility | Purpose |
|----------|---------|
| `local0` | Tugboat audit events |
| `local1` | Reserved for future use |
| `authpriv` | Authentication events (SSH, PAM) |

---

## Azure Log Analytics Integration

### OMS Agent Configuration

The Azure OMS Agent (Microsoft Monitoring Agent) forwards logs to Azure Log Analytics.

**Installation:**
```bash
# Download and install OMS agent
wget https://raw.githubusercontent.com/Microsoft/OMS-Agent-for-Linux/master/installer/scripts/onboard_agent.sh
sh onboard_agent.sh -w <WORKSPACE_ID> -s <WORKSPACE_KEY> -d opinsights.azure.com
```

**Syslog Collection Configuration:**
```bash
# Configure OMS agent to collect local0 facility
cat >> /etc/opt/microsoft/omsagent/<WORKSPACE_ID>/conf/omsagent.conf << 'EOF'

<source>
  type syslog
  port 25224
  bind 127.0.0.1
  protocol_type udp
  tag oms.syslog
</source>

<filter oms.syslog.**>
  type filter_syslog
</filter>
EOF

systemctl restart omsagent-<WORKSPACE_ID>
```

### Log Analytics Workspace

| Setting | Value |
|---------|-------|
| Workspace Name | `tugboat-audit` |
| Resource Group | Per organization standard |
| Region | Match infrastructure region |
| Retention | 365 days (cloud) |
| SKU | Per-GB pricing |

### Custom Log Table

Create custom log table for structured Tugboat events:

**Table Name:** `TugboatExecution_CL`

**Schema:**
| Column | Type | Description |
|--------|------|-------------|
| TimeGenerated | datetime | Event timestamp |
| ExecutionId_g | guid | Unique execution ID |
| UserPrincipal_s | string | AD user (jsmith@DOMAIN.LOCAL) |
| ServiceAccount_s | string | Service account used |
| Playbook_s | string | Playbook name |
| Status_s | string | SUCCESS/FAILED/CANCELLED |
| DryRun_b | bool | Check mode flag |
| TargetHosts_s | string | Comma-separated host list |
| ExitCode_d | double | Process exit code |
| DurationSeconds_d | double | Execution duration |

---

## Microsoft Defender XDR Integration

### Data Connector

Configure Log Analytics workspace as data source for Defender XDR:

1. Navigate to Microsoft Defender portal
2. Settings > Endpoints > Advanced features
3. Enable "Microsoft Defender for Cloud" integration
4. Connect Log Analytics workspace

### Detection Rules

Create custom detection rules for suspicious Tugboat activity:

**Rule: Multiple Failed Executions**
```kusto
TugboatExecution_CL
| where TimeGenerated > ago(1h)
| where Status_s == "FAILED"
| summarize FailureCount = count() by UserPrincipal_s
| where FailureCount > 5
```

**Rule: Execution Outside Business Hours**
```kusto
TugboatExecution_CL
| where TimeGenerated > ago(24h)
| extend Hour = datetime_part("hour", TimeGenerated)
| where Hour < 6 or Hour > 22  // Outside 6 AM - 10 PM
| where DryRun_b == false  // Actual executions only
| project TimeGenerated, UserPrincipal_s, Playbook_s, TargetHosts_s
```

**Rule: Denied Access Attempts**
```kusto
Syslog
| where Facility == "local0"
| where SyslogMessage contains "DENIED"
| summarize DeniedCount = count() by HostName, bin(TimeGenerated, 1h)
| where DeniedCount > 3
```

### Alert Configuration

| Alert | Severity | Action |
|-------|----------|--------|
| Multiple failed executions | Medium | Email to team lead |
| After-hours execution | Low | Log only (audit trail) |
| Repeated access denials | High | Email to security team |
| Service account from unknown IP | High | Page on-call security |

---

## Compliance Requirements

### SOC 2 Type II

| Control | Implementation |
|---------|----------------|
| CC6.1 - Logical access | AD authentication + MFA |
| CC6.2 - Access authorization | AD group-based access control |
| CC6.3 - Access removal | AD group removal process |
| CC7.2 - System monitoring | Centralized logging to SIEM |
| CC7.3 - Anomaly detection | Defender XDR alerting |

### ISO 27001

| Control | Implementation |
|---------|----------------|
| A.9.2.1 - User registration | AD account provisioning |
| A.9.2.3 - Privileged access | Service account separation |
| A.9.4.2 - Secure log-on | MFA via Duo |
| A.12.4.1 - Event logging | Comprehensive audit trail |
| A.12.4.3 - Admin logs | Separate audit for privileged ops |

### NIST 800-53

| Control | Implementation |
|---------|----------------|
| AC-2 - Account management | AD lifecycle management |
| AC-6 - Least privilege | Team-based service accounts |
| AU-2 - Audit events | All automation activities logged |
| AU-3 - Audit content | Structured JSON with full context |
| AU-6 - Audit review | SIEM dashboards and alerts |
| AU-9 - Audit protection | Immutable cloud storage |

---

## Audit Queries and Reports

### Common Queries

**All executions by user (last 7 days):**
```bash
grep "jsmith@DOMAIN.LOCAL" /var/log/tugboat/executions.log | \
  jq 'select(.timestamp > (now - 604800 | todate))'
```

**Failed executions (last 24 hours):**
```bash
jq 'select(.result.status == "FAILED") | select(.timestamp > (now - 86400 | todate))' \
  /var/log/tugboat/executions.log
```

**Executions affecting specific host:**
```bash
jq 'select(.target.hosts_affected | contains(["n01"]))' \
  /var/log/tugboat/executions.log
```

### Azure Log Analytics Queries

**Execution summary dashboard:**
```kusto
TugboatExecution_CL
| where TimeGenerated > ago(7d)
| summarize
    TotalExecutions = count(),
    Successful = countif(Status_s == "SUCCESS"),
    Failed = countif(Status_s == "FAILED"),
    DryRuns = countif(DryRun_b == true)
  by bin(TimeGenerated, 1d)
| render timechart
```

**Top operators by execution count:**
```kusto
TugboatExecution_CL
| where TimeGenerated > ago(30d)
| summarize ExecutionCount = count() by UserPrincipal_s
| top 10 by ExecutionCount
| render barchart
```

**Execution duration trends:**
```kusto
TugboatExecution_CL
| where TimeGenerated > ago(7d)
| where Status_s == "SUCCESS"
| summarize AvgDuration = avg(DurationSeconds_d) by Playbook_s, bin(TimeGenerated, 1d)
| render timechart
```

### Scheduled Reports

| Report | Frequency | Recipients | Content |
|--------|-----------|------------|---------|
| Weekly execution summary | Weekly (Monday) | Infrastructure leads | Execution counts, failures, top users |
| Monthly access review | Monthly (1st) | Security team | Unique users, service account usage |
| Quarterly compliance | Quarterly | Compliance officer | Full audit for compliance review |

---

## Incident Response

### Audit Trail for Investigations

When investigating an incident:

1. **Identify timeframe** of the incident
2. **Query execution logs** for that period:
   ```bash
   jq 'select(.timestamp >= "2025-01-15T00:00:00Z" and .timestamp <= "2025-01-15T23:59:59Z")' \
     /var/log/tugboat/executions.log
   ```
3. **Retrieve full execution output** for relevant execution IDs:
   ```bash
   cat /var/log/tugboat/tugboat-<execution-id>.log
   ```
4. **Correlate with authentication logs**:
   ```bash
   grep "jsmith" /var/log/auth.log | grep "2025-01-15"
   ```
5. **Check Azure Log Analytics** for additional context

### Evidence Preservation

For legal or compliance investigations:

1. **Do not modify local logs** - they may be evidence
2. **Export from Azure Log Analytics** (immutable copy):
   ```kusto
   TugboatExecution_CL
   | where TimeGenerated between (datetime(2025-01-15) .. datetime(2025-01-16))
   | order by TimeGenerated asc
   ```
3. **Document chain of custody** for exported logs
4. **Engage legal/compliance** before sharing with external parties

---

## Related Documentation

- [Tugboat Administrator Guide](tugboat-admin-guide.md) - Day-to-day operations
- [Tugboat Access Control](tugboat-access-control.md) - AD integration details
- [Tugboat Node Setup](management-node-setup.md) - Logging infrastructure setup
