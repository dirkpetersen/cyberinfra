# Ceph Storage Cluster

## Overview

This directory contains documentation for the Ceph distributed storage cluster, which provides S3-compatible object storage via RADOS Gateway (RGW) for AI/ML workloads and serves as a backup target for Weka IO.

## Croit Ceph Distribution

We are using **Croit Ceph**, a secure PXE-booted distribution for Ceph that simplifies deployment and management.

### Croit Limitations

**Important**: Croit Ceph does **not** support HAProxy load balancers - it only supports **keepalived** for high availability.

This creates a challenge for Weka IO integration, which requires proper load balancing for S3 object storage backends. See the [Load Balancer Solutions](#load-balancer-solutions-for-weka-io) section below.

## Weka IO S3 Backend Requirements

Weka IO can use Ceph RGW as an S3-compatible object storage backend for:
- **Tiering**: Moving cold data to lower-cost object storage
- **Snapshots**: Storing filesystem snapshots externally
- **Backup**: S3 backup targets for disaster recovery

### Requirements for Weka IO Integration

| Requirement | Description |
|-------------|-------------|
| **Load Balancing** | Distribute requests across multiple RGW daemons |
| **High Availability** | Automatic failover if an RGW daemon fails |
| **SSL/TLS** | Encrypted connections (terminate at load balancer) |
| **Health Checks** | Detect unhealthy RGW instances |
| **Virtual IP (VIP)** | Single endpoint for Weka to connect to |

**Weka S3 Configuration** (simplified):
```bash
weka s3 cluster create \
  --endpoint https://<load-balancer-vip>:443 \
  --access-key <access-key> \
  --secret-key <secret-key>
```

## Ceph S3 Load Balancer Options

### Official Ceph Documentation

- [IBM Storage Ceph - HAProxy Monitoring](https://www.ibm.com/docs/en/storage-ceph/8.1.0?topic=cluster-monitoring-haproxy)
- [Ceph Cephadm - High Availability Service for RGW](https://docs.ceph.com/en/latest/cephadm/services/rgw/#high-availability-service-for-rgw)

### Option Comparison

| Feature | Ceph Ingress (HAProxy + keepalived) | Standalone HAProxy | Traefik |
|---------|-------------------------------------|-------------------|---------|
| **Croit Support** | No (keepalived only) | No | No |
| **Ceph Native** | Yes | Manual | No |
| **SSL Termination** | Yes | Yes | Yes |
| **Health Checks** | Yes | Yes | Yes |
| **Dynamic Config** | Limited | Manual reload | Yes (auto-discovery) |
| **Container-Native** | No | Optional | Yes |
| **Metrics** | Prometheus | Prometheus | Prometheus |

## Load Balancer Deployment Location

A critical decision is **where** to run the load balancer (HAProxy or Traefik). There are three options:

### Option Comparison

| Location | Pros | Cons |
|----------|------|------|
| **Proxmox VMs** | Isolated from storage workloads; easy to manage/update; can leverage Proxmox HA; no impact on Weka or Ceph performance | Additional VMs to maintain; extra network hop; requires VM resources |
| **Weka Nodes** | Close to S3 client (Weka); no extra infrastructure; reduces network hops for Weka→Ceph traffic | Competes for CPU/memory with Weka; Weka nodes are NVMe-optimized, not for proxying; harder to maintain |
| **Croit Ceph Nodes** | Close to RGW daemons; no extra infrastructure | **Not recommended** - Croit manages these nodes; installing additional software may conflict with Croit; unsupported configuration |

### Detailed Analysis

#### 1. Proxmox VMs (Recommended)

Deploy 2-3 lightweight VMs dedicated to load balancing.

**Pros:**
- **Isolation**: Load balancer failures don't affect storage clusters
- **Manageability**: Easy to update, restart, or replace without touching production storage
- **Proxmox HA**: VMs can be automatically migrated if a Proxmox host fails
- **Resource control**: Dedicated CPU/memory allocation
- **Clean separation**: Different teams can manage different components

**Cons:**
- Additional infrastructure to provision and maintain
- Extra network hop (Weka → Proxmox VM → Ceph)
- Requires VM resources (minimal: 2 vCPU, 2GB RAM per instance)

**Best for**: Production environments where stability and separation of concerns matter.

#### 2. Weka Nodes

Run HAProxy/Traefik directly on Weka cluster nodes.

**Pros:**
- No additional infrastructure
- Weka S3 client connects to localhost or local network
- Fewer network hops for Weka-originated S3 traffic

**Cons:**
- **Resource contention**: Weka nodes are optimized for NVMe I/O, not TCP proxying
- **Blast radius**: Load balancer issues could affect Weka performance
- **Maintenance complexity**: Updating load balancer requires coordination with Weka operations
- **Not designed for this**: Weka nodes run specialized software; adding services complicates support

**Best for**: Small deployments or testing where simplicity outweighs isolation.

#### 3. Croit Ceph Nodes (Not Recommended)

Run load balancer on the same nodes as RGW daemons.

**Pros:**
- Closest to RGW (localhost connections possible)
- No additional infrastructure

**Cons:**
- **Croit conflict**: Croit manages these nodes via PXE boot; installing additional software may break Croit management or be overwritten
- **Unsupported**: Croit only supports keepalived; adding HAProxy is outside their support scope
- **Resource contention**: Ceph OSD/MON/RGW processes need resources
- **Upgrade risk**: Croit updates may remove or break custom installations

**Best for**: Not recommended for production. Only consider if you fully control the nodes and don't rely on Croit support.

### Recommendation

**Deploy load balancers on Proxmox VMs** for these reasons:

1. **Croit limitation**: Can't install HAProxy on Croit-managed nodes
2. **Weka optimization**: Weka nodes should focus on NVMe storage, not proxying
3. **Operational clarity**: Clear boundaries between Weka, Ceph, and infrastructure services
4. **HA integration**: Proxmox HA can restart/migrate load balancer VMs automatically

```
┌──────────────────────────────────────────────────────────────┐
│                     PROXMOX CLUSTER                          │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              HAProxy VMs (2-3 instances)               │  │
│  │         Managed by Ansible, HA via Proxmox             │  │
│  │                   VIP: 10.10.3.100                     │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
         │                                      ▲
         │ HTTP to RGW                          │ HTTPS from Weka
         ▼                                      │
┌─────────────────────┐              ┌─────────────────────────┐
│   CROIT CEPH        │              │      WEKA CLUSTER       │
│   (RGW daemons)     │              │   (S3 client to Ceph)   │
│   Managed by Croit  │              │   Managed by Weka       │
└─────────────────────┘              └─────────────────────────┘
```

## Load Balancer Software Options

Since Croit only supports keepalived (which provides VIP failover but not load balancing), you need an **external load balancer** for proper RGW load distribution.

### Software Comparison

| Feature | Traefik | HAProxy |
|---------|---------|---------|
| **Installation** | Single Go binary | Package manager |
| **Configuration** | YAML files | Custom syntax |
| **Config reload** | Automatic (watches files) | Manual (`systemctl reload`) |
| **Dashboard** | Built-in | Requires stats page setup |
| **Let's Encrypt** | Built-in ACME client (auto-renewal) | Manual cert management (certbot + cron) |
| **Learning curve** | Lower | Higher |
| **Performance** | Excellent | Excellent (slightly higher throughput at extreme scale) |
| **Maturity** | Modern, active development | Battle-tested, 20+ years |

**Recommendation**: For this use case (3 RGW backends, moderate throughput), **Traefik is recommended** due to:
- Single binary installation
- YAML configuration
- Automatic config reloading (no restart needed)
- Built-in Let's Encrypt certificate management with automatic renewal

### Solution 1: Traefik (Recommended)

Deploy Traefik on Proxmox VMs to load balance RGW traffic. Traefik is a single Go binary that watches a configuration directory for changes - no reload commands needed.

#### Installation

```bash
# Download latest Traefik binary
wget https://github.com/traefik/traefik/releases/download/v3.0.0/traefik_v3.0.0_linux_amd64.tar.gz
tar xzf traefik_v3.0.0_linux_amd64.tar.gz
sudo mv traefik /usr/local/bin/
sudo chmod +x /usr/local/bin/traefik

# Create config directories
sudo mkdir -p /etc/traefik/conf.d
sudo mkdir -p /var/log/traefik

# Traefik watches /etc/traefik/conf.d/ for changes - no reload needed
```

#### Systemd Service

```ini
# /etc/systemd/system/traefik.service
[Unit]
Description=Traefik Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now traefik
```

#### Static Configuration

```yaml
# /etc/traefik/traefik.yml

api:
  dashboard: true
  insecure: false

entryPoints:
  websecure:
    address: ":443"
  metrics:
    address: ":8082"

providers:
  file:
    directory: /etc/traefik/conf.d  # Watches this folder for changes
    watch: true

# Built-in Let's Encrypt certificate management
# Traefik automatically obtains and renews certificates
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: /etc/traefik/acme.json  # Store certs here
      tlsChallenge: {}                  # Use TLS-ALPN-01 challenge
      # Or use HTTP challenge:
      # httpChallenge:
      #   entryPoint: web

metrics:
  prometheus:
    entryPoint: metrics

log:
  level: INFO

accessLog:
  filePath: "/var/log/traefik/access.log"
```

#### Dynamic Configuration (RGW Backend)

Drop this file in `/etc/traefik/conf.d/` - Traefik picks it up automatically, no restart needed:

```yaml
# /etc/traefik/conf.d/rgw.yml

http:
  routers:
    rgw-s3:
      rule: "Host(`s3.example.com`)"  # Your S3 endpoint hostname
      entryPoints:
        - websecure
      service: rgw-backend
      tls:
        certResolver: letsencrypt  # Auto-obtain Let's Encrypt cert for this domain

  services:
    rgw-backend:
      loadBalancer:
        healthCheck:
          path: /swift/healthcheck
          interval: 10s
          timeout: 3s
        servers:
          - url: "http://10.10.3.11:8080"
          - url: "http://10.10.3.12:8080"
          - url: "http://10.10.3.13:8080"
```

Traefik will automatically:
1. Obtain a Let's Encrypt certificate for `s3.example.com`
2. Renew the certificate before expiration (typically 30 days before)
3. Store certificates in `/etc/traefik/acme.json`

#### Adding/Removing RGW Backends

Simply edit the YAML file - Traefik detects the change and reloads automatically:

```bash
# Add a new RGW daemon - just edit the file
vim /etc/traefik/conf.d/rgw.yml
# Add: - url: "http://10.10.3.14:8080"
# Save - Traefik reloads automatically, no restart needed
```

#### Keepalived for Traefik VIP

For HA across multiple Traefik instances:

```bash
# /etc/keepalived/keepalived.conf

vrrp_script check_traefik {
    script "/usr/bin/curl -sf http://localhost:8082/ping"
    interval 2
    weight 2
}

vrrp_instance VI_TRAEFIK {
    state MASTER          # BACKUP on secondary node
    interface eth0
    virtual_router_id 52
    priority 101          # 100 on secondary node

    virtual_ipaddress {
        10.10.3.100/24
    }

    track_script {
        check_traefik
    }
}
```

### Solution 2: HAProxy (Alternative)

Deploy HAProxy if you prefer traditional tooling or need HAProxy-specific features.

#### Architecture

```
Weka IO Cluster
      │
      │ HTTPS (port 443)
      ▼
┌─────────────────────────────────────┐
│         HAProxy Cluster             │
│  (2-3 nodes with keepalived VIP)    │
│                                     │
│  VIP: 10.10.3.100                   │
│  haproxy1: 10.10.3.101              │
│  haproxy2: 10.10.3.102              │
│  haproxy3: 10.10.3.103              │
└──────────────┬──────────────────────┘
               │
               │ HTTP (port 8080) - SSL terminated at HAProxy
               ▼
┌─────────────────────────────────────┐
│         Ceph RGW Daemons            │
│                                     │
│  rgw1: 10.10.3.11:8080              │
│  rgw2: 10.10.3.12:8080              │
│  rgw3: 10.10.3.13:8080              │
└─────────────────────────────────────┘
```

#### HAProxy Configuration

```haproxy
# /etc/haproxy/haproxy.cfg

global
    log /dev/log local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4096

    # SSL tuning
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    option  redispatch
    option  forwardfor
    retries 3
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    timeout http-request 10s
    timeout http-keep-alive 10s

# Stats page for monitoring
listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if LOCALHOST

# RGW S3 Frontend (HTTPS)
frontend rgw_s3_https
    bind *:443 ssl crt /etc/haproxy/certs/rgw.pem
    mode http
    default_backend rgw_s3_backend

    # S3 specific headers
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Port 443

# RGW S3 Backend (HTTP to RGW daemons)
backend rgw_s3_backend
    mode http
    balance roundrobin
    option httpchk GET /swift/healthcheck
    http-check expect status 200

    # RGW daemon servers (SSL terminated at HAProxy)
    server rgw1 10.10.3.11:8080 check inter 3s fall 3 rise 2
    server rgw2 10.10.3.12:8080 check inter 3s fall 3 rise 2
    server rgw3 10.10.3.13:8080 check inter 3s fall 3 rise 2
```

#### Keepalived Configuration (for HAProxy VIP)

```bash
# /etc/keepalived/keepalived.conf (on haproxy1 - MASTER)

vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass secretpassword
    }

    virtual_ipaddress {
        10.10.3.100/24
    }

    track_script {
        check_haproxy
    }
}
```

```bash
# /etc/keepalived/keepalived.conf (on haproxy2 - BACKUP)

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100    # Lower priority than MASTER
    # ... rest same as MASTER
}
```

#### Deployment Steps

```bash
# Install on Ubuntu/Debian
apt install haproxy keepalived

# Generate SSL certificate (or use existing)
cat /etc/ssl/certs/rgw.crt /etc/ssl/private/rgw.key > /etc/haproxy/certs/rgw.pem
chmod 600 /etc/haproxy/certs/rgw.pem

# Validate config
haproxy -c -f /etc/haproxy/haproxy.cfg

# Start services
systemctl enable --now haproxy keepalived

# Verify VIP
ip addr show eth0 | grep 10.10.3.100
```

### Solution 3: Ceph Native Ingress (If Not Using Croit)

If you were using standard Ceph (not Croit), you could use the native ingress service:

```yaml
# rgw-ingress.yaml (for cephadm, NOT compatible with Croit)

service_type: ingress
service_id: rgw.default
placement:
  hosts:
    - ceph-node1
    - ceph-node2
    - ceph-node3
spec:
  backend_service: rgw.default
  virtual_ip: 10.10.3.100/24
  frontend_port: 443
  monitor_port: 1967
  virtual_interface_networks:
    - 10.10.3.0/24
  ssl_cert: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
```

**Note**: This is documented for reference but **will not work with Croit Ceph**.

## Recommended Architecture for Weka + Croit Ceph

Given Croit's limitations, we recommend:

```
┌─────────────────────────────────────────────────────────┐
│                    Weka IO Cluster                      │
│                  (9 nodes, NVMe storage)                │
└────────────────────────┬────────────────────────────────┘
                         │
                         │ S3 API (HTTPS)
                         ▼
┌─────────────────────────────────────────────────────────┐
│              External HAProxy Cluster                   │
│         (2-3 VMs on Proxmox, NOT on Croit)              │
│                                                         │
│  - HAProxy for load balancing                           │
│  - Keepalived for VIP failover                          │
│  - SSL termination                                      │
│  - Health checks                                        │
│                                                         │
│  VIP: 10.10.3.100:443                                   │
└────────────────────────┬────────────────────────────────┘
                         │
                         │ HTTP (port 8080)
                         ▼
┌─────────────────────────────────────────────────────────┐
│                Croit Ceph Cluster                       │
│              (managed by Croit, PXE boot)               │
│                                                         │
│  - RGW daemons (S3 endpoint, no SSL)                    │
│  - OSDs (object storage)                                │
│  - MONs, MGRs                                           │
│  - Keepalived for internal HA (Croit-managed)           │
│                                                         │
│  RGW endpoints:                                         │
│    rgw1: 10.10.3.11:8080                                │
│    rgw2: 10.10.3.12:8080                                │
│    rgw3: 10.10.3.13:8080                                │
└─────────────────────────────────────────────────────────┘
```

### Deployment Summary

| Component | Managed By | Location |
|-----------|------------|----------|
| RGW Daemons | Croit | Ceph nodes |
| Keepalived (Ceph internal) | Croit | Ceph nodes |
| HAProxy | Ansible (this repo) | Proxmox VMs |
| Keepalived (HAProxy VIP) | Ansible (this repo) | Proxmox VMs |
| SSL Certificates | Let's Encrypt or internal CA | HAProxy nodes |

## Monitoring

### HAProxy Metrics

HAProxy exposes metrics on the stats endpoint:
- **URL**: `http://<haproxy-node>:9000/stats`
- **Prometheus**: Enable `stats socket` for scraping

Key metrics:
- HTTP response codes
- Request/response volumes
- Connection counts
- Byte transfer rates

### Grafana Dashboards

Import these dashboards for monitoring:
- HAProxy: [Grafana Dashboard 2428](https://grafana.com/grafana/dashboards/2428)
- Traefik: [Grafana Dashboard 4475](https://grafana.com/grafana/dashboards/4475)
- Ceph RGW: Available in Ceph Dashboard or Croit UI

## Related Documentation

- [Weka S3 Configuration](https://docs.weka.io/additional-protocols/s3)
- [Ceph RADOS Gateway](https://docs.ceph.com/en/latest/radosgw/)
- [HAProxy Documentation](https://www.haproxy.org/#docs)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Croit Documentation](https://croit.io/documentation)
