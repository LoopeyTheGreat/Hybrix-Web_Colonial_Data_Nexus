# Fail2Ban + CrowdSec Integration Guide for Traefik

**Context**: Fail2Ban monitoring Traefik 3.6.1 access logs and server system logs, pushing bans to CrowdSec LAPI for network-wide enforcement via OPNsense firewall bouncer.

**Target Environment**:
- Traefik 3.6.1 in Docker Swarm mode
- OPNsense 25.7.7 with CrowdSec firewall bouncer
- Fail2Ban running in Docker (or on host)
- Multiple Docker hosts with local logs

**Why This Architecture**:
- Fail2Ban detects attacks from Traefik logs and system logs
- CrowdSec LAPI centralizes ban decisions
- OPNsense firewall bouncer enforces bans network-wide
- Honeypot traps (fake admin pages) trigger instant bans across all services
- 24-hour temporary bans (configurable duration)

---

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────┐
│ Docker Swarm Host (Traefik + Services)                        │
│                                                                │
│  ┌──────────────────────────────────────────────────────┐     │
│  │ Traefik 3.6.1                                        │     │
│  │ - Access logs: /var/log/traefik/access.log         │     │
│  │ - Exposes web services                              │     │
│  └──────────────────────────────────────────────────────┘     │
│                                                                │
│  ┌──────────────────────────────────────────────────────┐     │
│  │ Fail2Ban Container                                   │     │
│  │ - Monitors: Traefik logs, SSH, nginx, etc.         │     │
│  │ - Has cscli configured                              │     │
│  │ - Custom jails for honeypots                        │     │
│  └──────────────────────────────────────────────────────┘     │
│                 ↓ (cscli decisions add)                       │
└────────────────────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────────────────────┐
│ OPNsense Firewall (192.168.1.1)                              │
│                                                                │
│  ┌──────────────────────────────────────────────────────┐     │
│  │ CrowdSec LAPI                                        │     │
│  │ - Receives decisions from Fail2Ban                  │     │
│  │ - Port 8080 (internal)                              │     │
│  └──────────────────────────────────────────────────────┘     │
│                 ↓                                             │
│  ┌──────────────────────────────────────────────────────┐     │
│  │ CrowdSec Firewall Bouncer                            │     │
│  │ - Reads decisions from LAPI                         │     │
│  │ - Creates firewall rules                            │     │
│  │ - Blocks on all interfaces (LAN/VLANs)             │     │
│  └──────────────────────────────────────────────────────┘     │
│                                                                │
└────────────────────────────────────────────────────────────────┘
                    ↓
          All network traffic filtered
  (Honeypot ban → blocked network-wide, not just Traefik)
```

---

## Prerequisites

### 1. CrowdSec on OPNsense

**Install CrowdSec**:
1. System → Firmware → Plugins → `os-crowdsec`
2. Services → CrowdSec → Settings
3. Enable CrowdSec and Firewall Bouncer
4. Apply changes

**Create API key for Fail2Ban**:

SSH into OPNsense:
```bash
# Create a bouncer API key
cscli bouncers add fail2ban-bouncer

# Output will show API key: save this for later
# Example: abcdef1234567890abcdef1234567890
```

**Get LAPI URL**:
- LAPI typically runs on: `http://192.168.1.1:8080` (internal interface)
- Or use hostname: `http://opnsense.local:8080`

**References**:
- OPNsense CrowdSec: https://homenetworkguy.com/how-to/install-and-configure-crowdsec-on-opnsense/
- CrowdSec LAPI: https://docs.crowdsec.net/u/user_guides/lapi_mgmt/

### 2. Traefik Access Logs

Ensure Traefik is writing access logs to a persistent location.

**Update Traefik configuration** (in your Swarm stack):

```yaml
services:
  traefik:
    image: traefik:v3.6
    command:
      - "--log.level=INFO"
      - "--accesslog=true"
      - "--accesslog.filepath=/var/log/traefik/access.log"
      - "--accesslog.format=json"  # JSON format for easier parsing
      - "--accesslog.bufferingsize=100"
    volumes:
      - /var/log/traefik:/var/log/traefik  # Persistent log directory
      - /var/run/docker.sock:/var/run/docker.sock:ro
    # ... rest of your Traefik config
```

**Create log directory on host**:
```bash
mkdir -p /var/log/traefik
chmod 755 /var/log/traefik
```

**Test logging**:
```bash
# Make a web request through Traefik
curl https://your-service.example.com

# Check log
tail -f /var/log/traefik/access.log
```

**Log rotation** (optional but recommended):
```bash
cat > /etc/logrotate.d/traefik << EOF
/var/log/traefik/access.log {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    missingok
    postrotate
        docker kill -s USR1 \$(docker ps -qf "name=traefik")
    endscript
}
EOF
```

**Reference**: https://doc.traefik.io/traefik/observability/access-logs/

### 3. Docker Host Access

- Docker Engine 20.10+
- Access to host system logs (if monitoring SSH, etc.)
- Network connectivity to OPNsense LAPI

---

## Implementation

### Step 1: Directory Structure

```bash
mkdir -p ~/docker/fail2ban/{config,logs}
cd ~/docker/fail2ban
```

### Step 2: Fail2Ban Docker Configuration

Create `docker-compose.yml`:

```yaml
version: "3.8"

services:
  fail2ban:
    image: crazymax/fail2ban:latest
    container_name: fail2ban
    network_mode: "host"  # Required for iptables access and real IPs
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      # Fail2Ban configuration
      - ./config/jail.d:/data/jail.d:ro
      - ./config/filter.d:/data/filter.d:ro
      - ./config/action.d:/data/action.d:ro
      
      # Logs to monitor
      - /var/log/traefik:/var/log/traefik:ro
      - /var/log/auth.log:/var/log/auth.log:ro  # SSH logs
      - /var/log/nginx:/var/log/nginx:ro  # If you have nginx
      
      # CrowdSec CLI configuration
      - ./config/crowdsec:/etc/crowdsec:ro
      
      # Fail2Ban persistent data
      - ./data:/data
    environment:
      - TZ=America/Denver
      - F2B_LOG_LEVEL=INFO
      - F2B_DB_PURGE_AGE=30d
      - F2B_MAX_RETRY=5
      - F2B_DEST_EMAIL=your-email@example.com  # Optional
      - F2B_SENDER=fail2ban@your-domain.com  # Optional
    restart: unless-stopped

```

**Note on Docker Swarm compatibility**:
- Fail2Ban should run as a **standalone container**, not a Swarm service
- `network_mode: host` and `cap_add` are required but not fully supported in Swarm mode
- Deploy on each Docker host that needs monitoring

### Step 3: Configure CrowdSec CLI Access

**Create CrowdSec API credentials**:

```bash
mkdir -p ~/docker/fail2ban/config/crowdsec

cat > ~/docker/fail2ban/config/crowdsec/local_api_credentials.yaml << EOF
url: http://192.168.1.1:8080  # Your OPNsense LAPI URL
login: fail2ban-bouncer
password: YOUR_API_KEY_FROM_OPNSENSE_HERE
EOF

chmod 600 ~/docker/fail2ban/config/crowdsec/local_api_credentials.yaml
```

**Test cscli access** (after starting container):
```bash
docker exec fail2ban cscli version
docker exec fail2ban cscli lapi status
# Should show: "You can successfully interact with Local API (LAPI)"
```

**Reference**: https://docs.crowdsec.net/docs/user_guides/lapi_mgmt/

### Step 4: Create CrowdSec Action

**Create custom Fail2Ban action for CrowdSec**:

```bash
mkdir -p ~/docker/fail2ban/config/action.d

cat > ~/docker/fail2ban/config/action.d/crowdsec.conf << 'EOF'
# Fail2Ban action that pushes bans to CrowdSec LAPI
#
# This action uses cscli to add/remove decisions in CrowdSec
# Decisions are then enforced by the CrowdSec firewall bouncer

[Definition]

# Action name
actionname = crowdsec

# Command executed once at the start
actionstart =

# Command executed once at the end
actionstop =

# Command executed once before each actionban
actioncheck =

# Command executed when banning an IP
actionban = cscli decisions add --ip <ip> --duration <bantime> --reason "fail2ban: <name>" --type ban

# Command executed when unbanning an IP (optional)
actionunban = cscli decisions delete --ip <ip>

[Init]

# Default ban duration (Fail2Ban passes this from jail config)
# Format: 24h, 30m, 7d, etc.
bantime = 24h

# Name of the jail (automatically set by Fail2Ban)
name = unknown

EOF
```

**Key points**:
- `--duration <bantime>`: Uses jail's bantime setting
- `--reason "fail2ban: <name>"`: Tags bans with jail name for tracking
- `--type ban`: CrowdSec decision type (ban = block)
- `actionunban`: Optional; only called if you manually unban in Fail2Ban

**Reference**: https://discourse.crowdsec.net/t/fail2ban-as-agent-for-crowdsec/910

### Step 5: Create Traefik Filters

**Create filter for Traefik 4xx/5xx errors**:

```bash
cat > ~/docker/fail2ban/config/filter.d/traefik-auth.conf << 'EOF'
# Fail2Ban filter for Traefik authentication failures
#
# Matches 401 Unauthorized and 403 Forbidden responses

[Definition]

# JSON format
failregex = ^.*"ClientHost":"<HOST>".*"RequestMethod":"(GET|POST|PUT|DELETE)".*"OriginStatus":(401|403).*$

# Common log format fallback
            ^<HOST> -.*"(GET|POST|PUT|DELETE).*" (401|403) .*$

ignoreregex =

[Init]
datepattern = ^"StartUTC":"%%Y-%%m-%%dT%%H:%%M:%%S

EOF
```

**Create filter for Traefik rate limiting / suspicious patterns**:

```bash
cat > ~/docker/fail2ban/config/filter.d/traefik-botsearch.conf << 'EOF'
# Fail2Ban filter for Traefik bot detection
#
# Matches requests to common admin/sensitive paths

[Definition]

# JSON format
failregex = ^.*"ClientHost":"<HOST>".*"RequestPath":"(/admin|/wp-admin|/wp-login|/xmlrpc|/phpmyadmin|/.env|/.git|/\.well-known/security\.txt)".*$

# Common paths targeted by bots
            ^.*"ClientHost":"<HOST>".*"RequestPath":".*\.(php|asp|aspx|cgi).*$
            ^.*"ClientHost":"<HOST>".*"RequestPath":".*(eval\(|base64_decode|shell_exec)".*$

ignoreregex =

[Init]
datepattern = ^"StartUTC":"%%Y-%%m-%%dT%%H:%%M:%%S

EOF
```

**Create honeypot filter** (for fake admin pages):

```bash
cat > ~/docker/fail2ban/config/filter.d/traefik-honeypot.conf << 'EOF'
# Fail2Ban filter for honeypot traps
#
# Matches access to fake admin pages that should never be accessed legitimately

[Definition]

# Match requests to honeypot paths
failregex = ^.*"ClientHost":"<HOST>".*"RequestHost":".*".*"RequestPath":"/(fake-admin|honeypot|trap-admin)".*$

ignoreregex =

[Init]
datepattern = ^"StartUTC":"%%Y-%%m-%%dT%%H:%%M:%%S

EOF
```

**Reference**: https://github.com/fail2ban/fail2ban/tree/master/config/filter.d

### Step 6: Create Jails

**Create jail configuration**:

```bash
mkdir -p ~/docker/fail2ban/config/jail.d

cat > ~/docker/fail2ban/config/jail.d/traefik.local << 'EOF'
# Traefik authentication failures
[traefik-auth]
enabled  = true
port     = http,https
filter   = traefik-auth
logpath  = /var/log/traefik/access.log
maxretry = 5
findtime = 10m
bantime  = 24h
action   = crowdsec[name=traefik-auth]

# Traefik bot/scanner detection
[traefik-botsearch]
enabled  = true
port     = http,https
filter   = traefik-botsearch
logpath  = /var/log/traefik/access.log
maxretry = 3
findtime = 5m
bantime  = 24h
action   = crowdsec[name=traefik-botsearch]

# Honeypot trap (instant ban)
[traefik-honeypot]
enabled  = true
port     = http,https
filter   = traefik-honeypot
logpath  = /var/log/traefik/access.log
maxretry = 1  # Instant ban on first access
findtime = 1m
bantime  = 168h  # 7 days for honeypot hits
action   = crowdsec[name=traefik-honeypot, bantime=168h]

EOF
```

**Create SSH jail** (optional, for system protection):

```bash
cat > ~/docker/fail2ban/config/jail.d/sshd.local << 'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
findtime = 10m
bantime  = 24h
action   = crowdsec[name=sshd]

EOF
```

**Jail parameter meanings**:
- `enabled`: Activates this jail
- `port`: Service ports (used for logging, not blocking - CrowdSec handles that)
- `filter`: Filter file name (from filter.d/)
- `logpath`: Log file to monitor
- `maxretry`: Number of matches before ban
- `findtime`: Time window to count retries
- `bantime`: Duration of ban (passed to CrowdSec)
- `action`: Action to take (our crowdsec action)

**Reference**: https://www.fail2ban.org/wiki/index.php/MANUAL_0_8

### Step 7: Create Honeypot Pages in Traefik

**Add honeypot services to your Traefik stack**:

```yaml
# In your docker-compose.yml or Swarm stack
services:
  honeypot:
    image: nginx:alpine
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.honeypot.rule=PathPrefix(`/fake-admin`) || PathPrefix(`/wp-admin`) || PathPrefix(`/phpmyadmin`)"
        - "traefik.http.routers.honeypot.entrypoints=web,websecure"
        - "traefik.http.routers.honeypot.tls.certresolver=letsencrypt"
        - "traefik.http.services.honeypot.loadbalancer.server.port=80"
    volumes:
      - ./honeypot/index.html:/usr/share/nginx/html/index.html:ro
```

**Create honeypot page**:
```bash
mkdir -p ~/docker/traefik-stack/honeypot

cat > ~/docker/traefik-stack/honeypot/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Admin Panel</title></head>
<body>
<h1>Admin Login</h1>
<p>This is a honeypot. Your IP has been logged.</p>
</body>
</html>
EOF
```

Now any access to `/fake-admin`, `/wp-admin`, or `/phpmyadmin` will:
1. Be logged by Traefik
2. Trigger Fail2Ban filter
3. Add decision to CrowdSec
4. Block IP on OPNsense firewall (all services, not just web)

### Step 8: Start and Test

**Start Fail2Ban**:
```bash
cd ~/docker/fail2ban
docker compose up -d

# Watch logs
docker logs -f fail2ban
```

**Test cscli connectivity**:
```bash
docker exec fail2ban cscli lapi status
# Should show: "You can successfully interact with Local API (LAPI)"

docker exec fail2ban cscli version
```

**Test filters manually**:
```bash
# Test traefik-auth filter
docker exec fail2ban fail2ban-regex /var/log/traefik/access.log /data/filter.d/traefik-auth.conf

# Test traefik-honeypot filter
docker exec fail2ban fail2ban-regex /var/log/traefik/access.log /data/filter.d/traefik-honeypot.conf
```

**Check jail status**:
```bash
docker exec fail2ban fail2ban-client status
# Should list: traefik-auth, traefik-botsearch, traefik-honeypot, sshd

docker exec fail2ban fail2ban-client status traefik-honeypot
# Shows currently banned IPs for this jail
```

**Trigger a test ban**:
```bash
# Access honeypot from another machine
curl https://your-domain.com/fake-admin

# Check Fail2Ban
docker exec fail2ban fail2ban-client status traefik-honeypot
# Should show banned IP

# Check CrowdSec on OPNsense
ssh root@opnsense
cscli decisions list
# Should show IP with reason "fail2ban: traefik-honeypot"
```

**Verify firewall blocking**:
```bash
# From the banned IP, try to access ANY service on your network
# Should be blocked at firewall level, not just Traefik
```

---

## Server Log Monitoring (SSH, Nginx, etc.)

### SSH Brute Force Protection

Already configured in `sshd.local` jail above.

**Verify SSH log format**:
```bash
# Check log location
ls -la /var/log/auth.log

# Test filter
docker exec fail2ban fail2ban-regex /var/log/auth.log /etc/fail2ban/filter.d/sshd.conf
```

### Nginx Logs (if applicable)

**Create Nginx auth filter**:
```bash
cat > ~/docker/fail2ban/config/filter.d/nginx-auth.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*" (401|403) .*$
ignoreregex =
EOF
```

**Create Nginx jail**:
```bash
cat > ~/docker/fail2ban/config/jail.d/nginx.local << 'EOF'
[nginx-auth]
enabled  = true
port     = http,https
filter   = nginx-auth
logpath  = /var/log/nginx/access.log
maxretry = 5
findtime = 10m
bantime  = 24h
action   = crowdsec[name=nginx-auth]
EOF
```

**Mount Nginx logs in Fail2Ban container**:
```yaml
# Add to docker-compose.yml volumes:
volumes:
  - /var/log/nginx:/var/log/nginx:ro
```

### Docker Container Logs

If you need to monitor logs from other Docker containers:

**Option 1: Use Docker log driver to write to files**:
```yaml
# In your service docker-compose.yml
services:
  myservice:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
        # Or use syslog driver to write to /var/log
```

**Option 2: Use log collector (e.g., Promtail, Filebeat)**:
Stream Docker logs to files that Fail2Ban can monitor.

---

## CrowdSec Integration Details

### How Bans Propagate

1. **Fail2Ban detects attack** (e.g., 5 failed auth attempts)
2. **Fail2Ban executes action**: `cscli decisions add --ip 1.2.3.4 --duration 24h --reason "fail2ban: traefik-auth"`
3. **CrowdSec LAPI** on OPNsense receives decision
4. **CrowdSec Firewall Bouncer** reads decisions from LAPI (polls every 10 seconds by default)
5. **OPNsense creates firewall rules** to block IP on all interfaces
6. **Attacker is blocked** from ALL services (web, SSH, SMTP, everything)

### Viewing Decisions

**On Fail2Ban host**:
```bash
# Via cscli
docker exec fail2ban cscli decisions list

# Filter by origin
docker exec fail2ban cscli decisions list --origin fail2ban
```

**On OPNsense**:
```bash
ssh root@opnsense
cscli decisions list

# Show only Fail2Ban decisions
cscli decisions list | grep fail2ban

# Show specific jail
cscli decisions list | grep traefik-honeypot
```

**Via CrowdSec Console** (if enrolled):
- https://app.crowdsec.net/
- View decisions across all enrolled instances

### Manual Decision Management

**Add manual ban**:
```bash
docker exec fail2ban cscli decisions add --ip 1.2.3.4 --duration 24h --reason "manual-ban"
```

**Remove ban early**:
```bash
docker exec fail2ban cscli decisions delete --ip 1.2.3.4
```

**Add IP to whitelist** (never ban):
```bash
# On OPNsense
ssh root@opnsense
cat > /usr/local/etc/crowdsec/parsers/s02-enrich/mywhitelist.yaml << EOF
name: my/whitelist
description: "My trusted IPs"
whitelist:
  reason: "Trusted network"
  ip:
    - 192.168.1.100
    - 10.0.0.50
  cidr:
    - 192.168.1.0/24  # Entire local network
EOF

service crowdsec reload
```

**Reference**: https://docs.crowdsec.net/u/getting_started/post_installation/whitelists/

### Ban Duration Configuration

**Set different durations per jail**:
```bash
# In jail.d/traefik.local
[traefik-honeypot]
bantime  = 168h  # 7 days
action   = crowdsec[name=traefik-honeypot, bantime=168h]

[traefik-auth]
bantime  = 24h  # 1 day (default)
action   = crowdsec[name=traefik-auth, bantime=24h]
```

**Ban duration formats**:
- `30m` = 30 minutes
- `4h` = 4 hours
- `24h` = 24 hours (1 day)
- `168h` = 7 days
- `720h` = 30 days
- `8760h` = 1 year

### CrowdSec Decision Lifecycle

```
Ban Event → Fail2Ban → CrowdSec LAPI → Firewall Bouncer → Block
                                  ↓
                            (after duration)
                                  ↓
                         Decision expires → Unblock
```

Decisions **automatically expire** after the specified duration. No manual unbanning required unless you want to unblock early.

---

## Advanced Configurations

### Escalating Ban Times (Progressive Bans)

**Longer bans for repeat offenders**:

```bash
cat > ~/docker/fail2ban/config/action.d/crowdsec-progressive.conf << 'EOF'
[Definition]

# Progressive ban time based on repeat offenses
actionban = if [ <failures> -gt 10 ]; then
                cscli decisions add --ip <ip> --duration 7d --reason "fail2ban: <name> (repeat offender)" --type ban;
            elif [ <failures> -gt 5 ]; then
                cscli decisions add --ip <ip> --duration 48h --reason "fail2ban: <name> (multiple offenses)" --type ban;
            else
                cscli decisions add --ip <ip> --duration 24h --reason "fail2ban: <name>" --type ban;
            fi

actionunban = cscli decisions delete --ip <ip>

[Init]
name = unknown
EOF
```

**Use in jail**:
```bash
[traefik-auth]
action = crowdsec-progressive[name=traefik-auth]
```

### Notification on Bans

**Email notifications**:
```bash
# In docker-compose.yml
environment:
  - F2B_DEST_EMAIL=admin@example.com
  - F2B_SENDER=fail2ban@example.com
  - SSMTP_HOST=smtp.example.com
  - SSMTP_PORT=587
  - SSMTP_USER=fail2ban@example.com
  - SSMTP_PASSWORD=your_password
  - SSMTP_TLS=YES
```

**Webhook notifications** (e.g., Slack, Discord):
```bash
cat > ~/docker/fail2ban/config/action.d/webhook.conf << 'EOF'
[Definition]

actionban = curl -X POST https://hooks.slack.com/services/YOUR/WEBHOOK/URL \
            -H 'Content-Type: application/json' \
            -d '{"text":"Fail2Ban: Banned IP <ip> for <name>"}'

actionunban =

[Init]
name = unknown
EOF
```

**Use multiple actions**:
```bash
[traefik-honeypot]
action = crowdsec[name=traefik-honeypot, bantime=168h]
         webhook[name=traefik-honeypot]
```

### Geographic Blocking

**Block entire countries via CrowdSec**:

```bash
# On OPNsense
ssh root@opnsense

# Subscribe to geo-blocking lists
cscli hub update
cscli collections install crowdsecurity/iptables
cscli collections install crowdsecurity/linux

# Create custom scenario for geo-blocking
cat > /usr/local/etc/crowdsec/scenarios/geoblock.yaml << EOF
type: trigger
name: my/geoblock
description: "Block traffic from specific countries"
filter: "evt.Meta.geoip_country in ['CN', 'RU', 'KP']"  # China, Russia, North Korea
blackhole: 1m
labels:
  remediation: true
EOF

service crowdsec reload
```

---

## Monitoring and Maintenance

### Health Check Script

```bash
cat > ~/docker/fail2ban/health-check.sh << 'EOF'
#!/bin/bash

echo "=== Fail2Ban + CrowdSec Health Check ==="
echo ""

# Check Fail2Ban container
echo "Fail2Ban Container:"
docker ps --filter "name=fail2ban" --format "table {{.Names}}\t{{.Status}}"
echo ""

# Check jail status
echo "Active Jails:"
docker exec fail2ban fail2ban-client status | grep "Jail list" | cut -d: -f2
echo ""

# Check CrowdSec connectivity
echo "CrowdSec LAPI Status:"
docker exec fail2ban cscli lapi status 2>&1
echo ""

# Count current bans
echo "Current Bans:"
for jail in $(docker exec fail2ban fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr ',' ' '); do
    count=$(docker exec fail2ban fail2ban-client status $jail | grep "Currently banned" | awk '{print $4}')
    echo "  $jail: $count IPs"
done
echo ""

# CrowdSec decisions
echo "CrowdSec Decisions:"
docker exec fail2ban cscli decisions list --origin fail2ban 2>&1 | head -10
echo ""

# Recent bans (last 5)
echo "Recent Bans (Last 5):"
docker exec fail2ban fail2ban-client status traefik-honeypot | grep "Banned IP list" | cut -d: -f2 | tr ' ' '\n' | head -5
EOF

chmod +x ~/docker/fail2ban/health-check.sh
```

### Log Monitoring

**Watch Fail2Ban activity**:
```bash
# Real-time logs
docker logs -f fail2ban | grep "Ban\|Unban"

# Ban count by jail
docker exec fail2ban fail2ban-client status | grep -A 20 "Jail list"
```

**Watch CrowdSec decisions**:
```bash
# On OPNsense or Fail2Ban host
watch -n 5 'cscli decisions list --origin fail2ban'
```

### Performance Monitoring

**Check Fail2Ban performance**:
```bash
# Container resources
docker stats fail2ban

# Jail processing times
docker exec fail2ban fail2ban-client status traefik-auth
```

**Monitor log file sizes**:
```bash
# Check Traefik logs
du -sh /var/log/traefik/

# Watch growth
watch -n 60 'ls -lh /var/log/traefik/access.log'
```

### Database Maintenance

**Clean old bans**:
```bash
# Fail2Ban auto-purges based on F2B_DB_PURGE_AGE (default 30 days)

# Manual purge
docker exec fail2ban fail2ban-client unban --all

# CrowdSec decisions expire automatically based on duration
# Manual cleanup (remove expired decisions older than 7 days)
ssh root@opnsense
cscli decisions delete --type ban --range 7d
```

---

## Troubleshooting

### Fail2Ban Not Detecting Attacks

```bash
# Test filter against log file
docker exec fail2ban fail2ban-regex /var/log/traefik/access.log /data/filter.d/traefik-auth.conf

# Check jail is enabled
docker exec fail2ban fail2ban-client status | grep traefik-auth

# Increase log level
# In docker-compose.yml: F2B_LOG_LEVEL=DEBUG
docker compose up -d fail2ban
docker logs -f fail2ban
```

### CrowdSec Connection Failing

```bash
# Test cscli connectivity
docker exec fail2ban cscli lapi status

# Check API credentials
docker exec fail2ban cat /etc/crowdsec/local_api_credentials.yaml

# Test manual decision
docker exec fail2ban cscli decisions add --ip 1.2.3.4 --duration 1m --reason "test"
docker exec fail2ban cscli decisions list | grep 1.2.3.4
docker exec fail2ban cscli decisions delete --ip 1.2.3.4

# Check OPNsense LAPI is accessible
docker exec fail2ban curl -v http://192.168.1.1:8080/v1/heartbeat
```

### Bans Not Appearing on OPNsense

```bash
# Check CrowdSec service on OPNsense
ssh root@opnsense
service crowdsec status

# Check firewall bouncer
service crowdsec_firewall status

# View bouncer logs
tail -f /var/log/crowdsec-firewall-bouncer.log

# Force bouncer sync
service crowdsec_firewall restart

# Check firewall rules were created
pfctl -sr | grep crowdsec
```

### Traefik Logs Not Parsing

```bash
# Check log format
tail /var/log/traefik/access.log

# Should be JSON if configured correctly
# If not, update Traefik --accesslog.format=json

# Test log readability
docker exec fail2ban cat /var/log/traefik/access.log | tail -5

# Check file permissions
ls -la /var/log/traefik/access.log
# Should be readable by fail2ban container
```

### Legitimate Users Getting Banned

```bash
# Whitelist IP immediately
docker exec fail2ban cscli decisions delete --ip 1.2.3.4

# Add to permanent whitelist
ssh root@opnsense
# Edit /usr/local/etc/crowdsec/parsers/s02-enrich/mywhitelist.yaml
# Add IP or CIDR
service crowdsec reload

# Adjust jail sensitivity
# In jail.d/traefik.local: increase maxretry or findtime
maxretry = 10  # Allow more failures
findtime = 30m  # Over longer period
```

---

## Security Considerations

### 1. Protect LAPI Access

**OPNsense firewall rules**:
```
# Allow only Docker hosts to reach LAPI
Protocol: TCP
Source: Docker_Host_Network (e.g., 192.168.1.0/24)
Destination: OPNsense Port 8080
Action: Allow

# Block all other access to LAPI
Protocol: TCP
Source: any
Destination: OPNsense Port 8080
Action: Block
```

### 2. Rotate API Keys

```bash
# On OPNsense
ssh root@opnsense

# Remove old bouncer
cscli bouncers delete fail2ban-bouncer

# Create new one
cscli bouncers add fail2ban-bouncer-new

# Update credentials in Fail2Ban
# Edit ~/docker/fail2ban/config/crowdsec/local_api_credentials.yaml
# Restart Fail2Ban
docker restart fail2ban
```

### 3. Rate Limiting

**Prevent ban flooding**:
```bash
# In jail configuration
[traefik-auth]
# Limit bans per time period
maxretry = 5
findtime = 10m
bantime = 24h

# Don't ban too aggressively
# Avoid instant bans except for honeypots
```

### 4. Log Security

**Protect log files**:
```bash
# Restrict permissions
chmod 640 /var/log/traefik/access.log
chown root:docker /var/log/traefik/access.log

# Ensure log rotation
# See logrotate config in Prerequisites section
```

### 5. Monitor False Positives

```bash
# Regular audits
docker exec fail2ban fail2ban-client status traefik-auth
# Review banned IPs for legitimacy

# Check CrowdSec community feedback
cscli decisions list --origin fail2ban
# Compare against CrowdSec threat intelligence
```

---

## Backup and Recovery

### Backup Configuration

```bash
cat > ~/docker/fail2ban/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/backup/fail2ban-$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Backup configs
cp docker-compose.yml $BACKUP_DIR/
cp -r config $BACKUP_DIR/

# Backup Fail2Ban database
docker exec fail2ban cat /data/fail2ban.sqlite3 > $BACKUP_DIR/fail2ban.sqlite3

# Create archive
tar -czf $BACKUP_DIR.tar.gz -C /backup fail2ban-$(date +%Y%m%d)
rm -rf $BACKUP_DIR

echo "Backup complete: $BACKUP_DIR.tar.gz"
EOF

chmod +x ~/docker/fail2ban/backup.sh

# Schedule backup (crontab)
# 0 2 * * * /home/user/docker/fail2ban/backup.sh
```

### Restore from Backup

```bash
# Stop Fail2Ban
docker compose down

# Restore
tar -xzf /backup/fail2ban-YYYYMMDD.tar.gz -C ~/docker/fail2ban/

# Start
docker compose up -d
```

---

## Reference Links

### Official Documentation
- Fail2Ban: https://www.fail2ban.org/
- Fail2Ban Manual: https://www.fail2ban.org/wiki/index.php/MANUAL_0_8
- CrowdSec: https://docs.crowdsec.net/
- CrowdSec LAPI: https://docs.crowdsec.net/u/user_guides/lapi_mgmt/
- CrowdSec Decisions: https://docs.crowdsec.net/u/user_guides/decisions_mgmt
- Traefik Access Logs: https://doc.traefik.io/traefik/observability/access-logs/

### Docker Images
- Fail2Ban (crazymax): https://github.com/crazy-max/docker-fail2ban
- Traefik: https://hub.docker.com/_/traefik

### Community Resources
- Fail2Ban + CrowdSec: https://discourse.crowdsec.net/t/fail2ban-as-agent-for-crowdsec/910
- OPNsense CrowdSec Guide: https://homenetworkguy.com/how-to/install-and-configure-crowdsec-on-opnsense/
- CrowdSec OPNsense: https://docs.crowdsec.net/u/integrations/opnsense
- Traefik + Fail2Ban: https://community.traefik.io/t/fail2ban-with-traefik/

### Troubleshooting
- Fail2Ban GitHub Issues: https://github.com/fail2ban/fail2ban/issues
- CrowdSec Discourse: https://discourse.crowdsec.net/
- r/CrowdSec: https://reddit.com/r/CrowdSec

---

## Quick Command Reference

```bash
# Start Fail2Ban
docker compose up -d

# Stop Fail2Ban
docker compose down

# View logs
docker logs -f fail2ban

# Check jail status
docker exec fail2ban fail2ban-client status
docker exec fail2ban fail2ban-client status traefik-honeypot

# Test filter
docker exec fail2ban fail2ban-regex /var/log/traefik/access.log /data/filter.d/traefik-auth.conf

# Check CrowdSec connectivity
docker exec fail2ban cscli lapi status

# List CrowdSec decisions
docker exec fail2ban cscli decisions list

# Manual ban
docker exec fail2ban cscli decisions add --ip 1.2.3.4 --duration 24h --reason "manual"

# Manual unban
docker exec fail2ban cscli decisions delete --ip 1.2.3.4

# Reload Fail2Ban
docker exec fail2ban fail2ban-client reload

# Restart specific jail
docker exec fail2ban fail2ban-client restart traefik-auth

# Unban all (Fail2Ban only, doesn't affect CrowdSec)
docker exec fail2ban fail2ban-client unban --all
```

---

## AI Agent Instructions

When assisting with this setup:

1. **Verify log paths**: Ensure logs are accessible to Fail2Ban container via volume mounts
2. **Test filters first**: Always use `fail2ban-regex` to test filters before deploying
3. **CrowdSec API connectivity**: Verify cscli can reach LAPI before creating jails
4. **Ban duration format**: Ensure duration uses correct format (30m, 4h, 24h, 7d)
5. **Action parameters**: Pass jail-specific parameters like `bantime` to actions correctly
6. **Network mode**: Fail2Ban requires `network_mode: host` for iptables access (though we're using CrowdSec for actual blocking)
7. **Log format**: JSON logs from Traefik are easier to parse; verify format before creating filters
8. **Whitelist management**: Always provide whitelist instructions to prevent locking out legitimate users

**Common Issues to Watch For**:
- Forgetting to restart Fail2Ban after config changes
- Using wrong log paths in jail configuration
- Not passing `bantime` parameter to CrowdSec action
- API credentials not readable by container (permissions)
- Traefik not writing logs to persistent location
- Attempting to run in Docker Swarm mode (use standalone containers)

**Testing Workflow**:
1. Test filter with `fail2ban-regex` first
2. Enable jail with high `maxretry` initially
3. Trigger test ban and verify in CrowdSec
4. Check firewall rules on OPNsense
5. Lower `maxretry` once confident filter works

---

## End of Guide

This setup provides:
- ✅ Fail2Ban monitoring Traefik and system logs
- ✅ Automatic ban propagation to CrowdSec LAPI
- ✅ Network-wide enforcement via OPNsense firewall bouncer
- ✅ Honeypot traps for instant bans
- ✅ Configurable ban durations (24h default, 7d for honeypots)
- ✅ Bans apply to ALL services, not just Traefik routes
- ✅ Temporary bans that auto-expire

For questions or issues, consult the reference links or community forums for Fail2Ban and CrowdSec.