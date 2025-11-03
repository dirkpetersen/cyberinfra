# Phase 8: Monitoring and Logging Integration

## Overview

This phase deploys Prometheus and Grafana for infrastructure monitoring, configures metric exporters, and integrates with Microsoft Defender XDR via Azure Log Analytics agent.

**Duration**: ~90 minutes
**Prerequisites**: Phase 1-7 complete, all services operational

---

## Step 1: Deploy Prometheus as LXC Container

### Create Prometheus Container

```bash
# SSH to pve1-node1
ssh root@10.30.0.11

# Create container
pct create 200 local:vztmpl/debian-12-standard_12.1-1_amd64.tar.zst \
    --hostname prometheus \
    --memory 8192 \
    --cores 4 \
    --storage local-lvm \
    --net0 name=eth0,bridge=vmbr0,tag=1 \
    --unprivileged 1

# Start container
pct start 200

# Enter container
pct enter 200
```

### Install Prometheus in Container

```bash
# Inside container (VMID 200)

# Download and install Prometheus
cd /opt
wget https://github.com/prometheus/prometheus/releases/download/v2.45.0/prometheus-2.45.0.linux-amd64.tar.gz
tar xzf prometheus-2.45.0.linux-amd64.tar.gz
mv prometheus-2.45.0.linux-amd64 prometheus

# Create systemd service for Prometheus
cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network.target

[Service]
Type=simple
User=prometheus
WorkingDirectory=/opt/prometheus
ExecStart=/opt/prometheus/prometheus \
    --config.file=/opt/prometheus/prometheus.yml \
    --storage.tsdb.path=/opt/prometheus/data \
    --storage.tsdb.retention.time=30d
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus

# Verify Prometheus running
curl http://localhost:9090
```

### Configure Prometheus

Create file: `/opt/prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'pve1'
    environment: 'production'

scrape_configs:
  # Proxmox nodes (via node exporter)
  - job_name: 'proxmox-nodes'
    static_configs:
      - targets:
        - '10.30.0.11:9100'
        - '10.30.0.12:9100'
        - '10.30.0.13:9100'
        labels:
          group: 'proxmox'

  # Ceph cluster
  - job_name: 'ceph'
    static_configs:
      - targets: ['10.30.0.11:9283']  # Ceph exporter
        labels:
          group: 'ceph'

  # Proxmox cluster (PVE metrics)
  - job_name: 'proxmox-pve'
    static_configs:
      - targets:
        - 'pve1-node1:8007'
        - 'pve1-node2:8007'
        - 'pve1-node3:8007'
        labels:
          group: 'proxmox-pve'

  # Prometheus itself
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

---

## Step 2: Deploy Grafana as LXC Container

### Create Grafana Container

```bash
# From pve1-node1 (outside container)

pct create 201 local:vztmpl/debian-12-standard_12.1-1_amd64.tar.zst \
    --hostname grafana \
    --memory 4096 \
    --cores 2 \
    --storage local-lvm \
    --net0 name=eth0,bridge=vmbr0,tag=1 \
    --unprivileged 1

pct start 201
pct enter 201
```

### Install Grafana

```bash
# Inside container (VMID 201)

# Add Grafana repository
apt-get install -y software-properties-common
add-apt-repository "deb https://packages.grafana.com/oss/deb stable main"
apt-get update

# Install Grafana
apt-get install -y grafana-server

# Start Grafana
systemctl enable grafana-server
systemctl start grafana-server

# Verify
curl http://localhost:3000

# Access: http://container-ip:3000 (default: admin/admin)
```

### Configure Grafana Data Source

```bash
# Add Prometheus as data source via API
curl -X POST http://localhost:3000/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "url": "http://prometheus:9090",
    "access": "proxy",
    "isDefault": true
  }'

# Import Proxmox dashboard
# Navigate to Grafana UI → Import → ID 10347 (Proxmox VE Cluster)
```

---

## Step 3: Install Node Exporter on All Proxmox Nodes

### Install Node Exporter

On each node (pve1-node1, node2, node3):

```bash
# Download node exporter
cd /opt
wget https://github.com/prometheus/node_exporter/releases/download/v1.6.1/node_exporter-1.6.1.linux-amd64.tar.gz
tar xzf node_exporter-1.6.1.linux-amd64.tar.gz
mv node_exporter-1.6.1.linux-amd64 node_exporter

# Create systemd service
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/node_exporter/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

# Verify
curl http://localhost:9100/metrics | head -20
```

---

## Step 4: Deploy Ceph Exporter

### Install Ceph Exporter

```bash
# On pve1-node1 (or any node in cluster)

wget https://github.com/digitalocean/ceph_exporter/releases/download/v2.5.0/ceph_exporter-2.5.0-linux-amd64.tar.gz
tar xzf ceph_exporter-2.5.0-linux-amd64.tar.gz
cp ceph_exporter /usr/local/bin/

# Create systemd service
cat > /etc/systemd/system/ceph_exporter.service << 'EOF'
[Unit]
Description=Ceph Exporter
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ceph_exporter
Environment="CEPH_CONFIG=/etc/ceph/ceph.conf"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ceph_exporter
systemctl start ceph_exporter

# Verify
curl http://localhost:9283/metrics | grep ceph_
```

---

## Step 5: Install Azure Log Analytics Agent

### Download and Install Agent

On each node:

```bash
# Download Microsoft Monitoring Agent for Linux
wget https://aka.ms/dependencyagentlinux -O InstallDependencyAgent-Linux64.bin
chmod +x InstallDependencyAgent-Linux64.bin

# Install
sudo sh InstallDependencyAgent-Linux64.bin -s

# Verify installation
systemctl status waagent
systemctl status omsagent
```

### Configure Log Analytics Workspace

```bash
# Configure agent with workspace

WORKSPACE_ID=$(aws ssm get-parameter --name /pve1/monitoring/defender_xdr/workspace_id --query 'Parameter.Value' --output text --region us-west-2)
WORKSPACE_KEY=$(aws ssm get-parameter --name /pve1/monitoring/defender_xdr/workspace_key --query 'Parameter.Value' --output text --with-decryption --region us-west-2)

# Configure agent
/opt/microsoft/omsagent/bin/omsadmin.sh -w $WORKSPACE_ID -s $WORKSPACE_KEY

# Restart agent
systemctl restart omsagent
```

### Configure Log Collection

Create file: `/etc/opt/microsoft/omsagent/conf.d/proxmox.conf`

```conf
# Collect Proxmox logs
<source>
  @type tail
  path /var/log/pve/*.log
  pos_file /var/opt/microsoft/omsagent/state/pve.pos
  read_from_head true
  <parse>
    @type multiline
    format_firstline /^\d{4}-\d{2}-\d{2}/
    format1 /^(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+\[\d+\]\s+(?<level>\w+)\s+(?<message>.*)$/
  </parse>
  tag oms.api.pve
</source>

# Collect syslog
<source>
  @type syslog
  port 514
  bind 127.0.0.1
  protocol_type udp
  tag oms.syslog.local
</source>
```

Restart agent:

```bash
systemctl restart omsagent
```

---

## Step 6: Configure Alerting Rules (Optional)

### Create Alert Rules in Prometheus

Create file: `/opt/prometheus/alert_rules.yml`

```yaml
groups:
  - name: proxmox_cluster
    interval: 1m
    rules:
      # Node down
      - alert: ProxmoxNodeDown
        expr: up{job="proxmox-nodes"} == 0
        for: 2m
        annotations:
          summary: "Proxmox node {{ $labels.instance }} down"

      # High CPU
      - alert: ProxmoxHighCPU
        expr: (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))) > 0.8
        for: 5m
        annotations:
          summary: "High CPU on {{ $labels.instance }}"

      # Ceph health
      - alert: CephUnhealthy
        expr: ceph_health_status != 0
        for: 2m
        annotations:
          summary: "Ceph health status is not OK"

      # OSD down
      - alert: CephOSDDown
        expr: ceph_osd_up == 0
        annotations:
          summary: "Ceph OSD {{ $labels.osd }} is down"
```

Add to Prometheus config:

```yaml
rule_files:
  - /opt/prometheus/alert_rules.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: []  # Add Alertmanager if available
```

---

## Step 7: Create Grafana Dashboards

### Import Pre-built Dashboards

In Grafana web UI:

1. **Menu > Dashboards > Import**
2. Import dashboard by ID:
   - **10347**: Proxmox VE Cluster
   - **3662**: Prometheus Statistics
   - **9628**: Ceph Cluster

### Create Custom Dashboard

```json
{
  "dashboard": {
    "title": "Proxmox pve1 Cluster Overview",
    "panels": [
      {
        "title": "Cluster Status",
        "targets": [
          {
            "expr": "up{job='proxmox-nodes'}"
          }
        ]
      },
      {
        "title": "Memory Usage",
        "targets": [
          {
            "expr": "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes"
          }
        ]
      },
      {
        "title": "Ceph Pool Usage",
        "targets": [
          {
            "expr": "ceph_pool_percent_used"
          }
        ]
      }
    ]
  }
}
```

---

## Step 8: Configure Defender XDR Integration

### Create Defender XDR Workspace

In Microsoft Azure Portal:

1. Create Log Analytics Workspace
2. Get Workspace ID and Primary Key
3. Store in AWS SSM:

```bash
aws ssm put-parameter \
    --name /pve1/monitoring/defender_xdr/workspace_id \
    --value "YOUR_WORKSPACE_ID" \
    --type SecureString \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/monitoring/defender_xdr/workspace_key \
    --value "YOUR_WORKSPACE_KEY" \
    --type SecureString \
    --region us-west-2 \
    --overwrite
```

### Create KQL Queries for Monitoring

```kusto
// Example KQL queries in Defender XDR

// Proxmox cluster health
Syslog
| where ProcessName contains "pve"
| where SeverityLevel in ("Error", "Warning")
| summarize count() by Computer

// Failed VM operations
Syslog
| where ProcessName == "pvedaemon"
| where SyslogMessage contains "error"
| project TimeGenerated, Computer, SyslogMessage

// Network latency
Perf
| where ObjectName == "Network Interface"
| where CounterName == "Bytes/sec"
| summarize AvgLatency = avg(CounterValue) by Computer
```

---

## Step 9: Test Monitoring Pipeline

### Generate Test Metrics

```bash
# Trigger some load to test monitoring
# On any Proxmox node

# Generate CPU load
stress-ng --cpu 4 --timeout 30s

# Generate network traffic
iperf3 -c 10.30.0.12 -t 60 &

# Monitor metrics collection
curl -s http://prometheus-container-ip:9090/api/v1/query?query=up | jq
```

### Verify Log Ingestion

```bash
# Check if logs appearing in Log Analytics
# In Azure portal: Log Analytics Workspace > Logs

# Run query
Syslog
| where ProcessName contains "pve"
| top 10 by TimeGenerated desc
```

---

## Step 10: Save Monitoring Configuration

```bash
# Save configuration to SSM

aws ssm put-parameter \
    --name /pve1/monitoring/prometheus_url \
    --value "http://prometheus:9090" \
    --type String \
    --region us-west-2 \
    --overwrite

aws ssm put-parameter \
    --name /pve1/monitoring/grafana_url \
    --value "http://grafana:3000" \
    --type String \
    --region us-west-2 \
    --overwrite

echo "Monitoring configuration saved to AWS SSM"
```

---

## Validation Checklist

- [ ] Prometheus container running and scraping metrics
- [ ] Grafana container running and accessible
- [ ] Node exporter running on all 3 Proxmox nodes
- [ ] Ceph exporter collecting metrics
- [ ] Azure Log Analytics agent installed on all nodes
- [ ] Logs flowing to Log Analytics Workspace
- [ ] Grafana dashboards displaying data
- [ ] Prometheus alerting rules functional
- [ ] Defender XDR queries working
- [ ] Test metrics visible in Prometheus and Grafana

---

## Next Steps

After monitoring:

1. Validate dashboards with real cluster data
2. Fine-tune alert thresholds
3. Proceed to **Phase 9: Backup Infrastructure (PBS + S3)**

---

**Phase 8 Status**: [Start Date] - [Completion Date]
**Monitoring**: OPERATIONAL (Prometheus, Grafana, Defender XDR)

