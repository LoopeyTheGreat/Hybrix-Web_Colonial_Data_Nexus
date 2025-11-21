# Gluetun + qBittorrent + ProtonVPN Setup Guide

**Context**: Docker-based BitTorrent client with ProtonVPN tunnel, automatic port forwarding, and proxy access for Sonarr/Radarr/*arr services.

**Target Environment**: 
- Docker standalone containers (NOT Docker Swarm - Swarm doesn't support `network_mode: service:`)
- Traefik 3.6.1 running in Swarm mode on same host
- OPNsense 25.7.7 firewall with CrowdSec
- Existing *arr stack needs proxy access to qBittorrent

**Why This Architecture**:
- All qBittorrent traffic routes through ProtonVPN tunnel, bypassing CrowdSec on firewall
- CrowdSec never sees P2P connections (only encrypted VPN tunnel)
- Automatic port forwarding handles ProtonVPN's dynamic port system
- Local services access qBittorrent via HTTP proxy through Gluetun's network stack

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│ Docker Host                                             │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Gluetun Container (VPN Tunnel)                   │  │
│  │ - ProtonVPN WireGuard connection                 │  │
│  │ - Port forwarding (NAT-PMP)                      │  │
│  │ - Exposes ports: 8080, 6881, 8888               │  │
│  │                                                  │  │
│  │  ┌────────────────────────────────────────┐     │  │
│  │  │ qBittorrent Container                  │     │  │
│  │  │ network_mode: "service:gluetun"       │     │  │
│  │  │ - WebUI on localhost:8080             │     │  │
│  │  │ - All traffic via VPN                 │     │  │
│  │  └────────────────────────────────────────┘     │  │
│  │                                                  │  │
│  │  ┌────────────────────────────────────────┐     │  │
│  │  │ Port Manager Container                 │     │  │
│  │  │ network_mode: "service:gluetun"       │     │  │
│  │  │ - Watches forwarded port              │     │  │
│  │  │ - Updates qBittorrent via API         │     │  │
│  │  └────────────────────────────────────────┘     │  │
│  │                                                  │  │
│  │  ┌────────────────────────────────────────┐     │  │
│  │  │ Gluetun-Sync (HTTP Proxy)              │     │  │
│  │  │ network_mode: "service:gluetun"       │     │  │
│  │  │ - HTTP proxy on port 8888             │     │  │
│  │  │ - Allows *arr apps to reach qBit      │     │  │
│  │  └────────────────────────────────────────┘     │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Sonarr/Radarr/*arr Containers                    │  │
│  │ - Configure qBit host: gluetun:8080             │  │
│  │ - Or use proxy: http://gluetun:8888             │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                         ↓ (encrypted VPN)
                  ProtonVPN Server
                         ↓
                    BitTorrent Peers
```

---

## Prerequisites

### 1. ProtonVPN Account Setup

**Get WireGuard credentials**:
1. Log in to ProtonVPN account
2. Navigate to Downloads → WireGuard configuration
3. Select a P2P-enabled server (servers with P2P support for port forwarding)
4. Download the WireGuard config file

**Extract required values from config**:
```ini
[Interface]
PrivateKey = XXXXX                  # Your private key
Address = 10.2.0.2/32               # Your VPN IP

[Peer]
PublicKey = YYYYY                   # Server public key
Endpoint = xx.xx.xx.xx:51820        # Server IP and port
```

**Reference**: https://protonvpn.com/support/wireguard-configurations/

### 2. Docker Host Requirements

- Docker Engine 20.10+ (not Swarm mode for this stack)
- Network access to ProtonVPN endpoints
- Ports available: 8080 (WebUI), 6881 (torrents), 8888 (proxy)

---

## Implementation

### Step 1: Directory Structure

```bash
mkdir -p ~/docker/torrent-stack/{gluetun,qbittorrent,downloads}
cd ~/docker/torrent-stack
```

### Step 2: Docker Compose Configuration

Create `docker-compose.yml`:

```yaml
version: "3.8"

services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8080:8080"   # qBittorrent WebUI
      - "6881:6881"   # qBittorrent TCP
      - "6881:6881/udp" # qBittorrent UDP
      - "8888:8888"   # HTTP proxy for *arr apps
    volumes:
      - ./gluetun:/gluetun
    environment:
      # VPN Provider
      - VPN_SERVICE_PROVIDER=protonvpn
      - VPN_TYPE=wireguard
      
      # WireGuard Configuration (from ProtonVPN config file)
      - WIREGUARD_PRIVATE_KEY=YOUR_PRIVATE_KEY_HERE
      - WIREGUARD_PRESHARED_KEY=  # Leave empty unless specified
      - WIREGUARD_ADDRESSES=10.2.0.2/32  # From config Address field
      - VPN_ENDPOINT_IP=xx.xx.xx.xx  # From config Endpoint field
      - VPN_ENDPOINT_PORT=51820
      - WIREGUARD_PUBLIC_KEY=YOUR_SERVER_PUBLIC_KEY
      
      # Port Forwarding (ProtonVPN NAT-PMP)
      - VPN_PORT_FORWARDING=on
      - VPN_PORT_FORWARDING_PROVIDER=protonvpn
      - FIREWALL_VPN_INPUT_PORTS=  # Auto-configured by port forwarding
      
      # HTTP Proxy for *arr apps
      - HTTPPROXY=on
      - HTTPPROXY_LOG=on
      - HTTPPROXY_LISTENING_ADDRESS=:8888
      - HTTPPROXY_USER=  # Optional: add auth if needed
      - HTTPPROXY_PASSWORD=
      
      # DNS
      - DNS_ADDRESS=1.1.1.1
      
      # Timezone
      - TZ=America/Denver
      
      # Logging
      - LOG_LEVEL=info
      
    restart: unless-stopped
    networks:
      - torrent_net

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    network_mode: "service:gluetun"  # Routes ALL traffic through VPN
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Denver
      - WEBUI_PORT=8080
    volumes:
      - ./qbittorrent/config:/config
      - ./downloads:/downloads
    depends_on:
      - gluetun
    restart: unless-stopped

  # Automatic port forwarding updater
  qbittorrent-port-manager:
    image: snoringdragon/gluetun-qbittorrent-port-manager:latest
    container_name: qb-port-manager
    network_mode: "service:gluetun"  # Must share network with gluetun
    environment:
      - QBITTORRENT_SERVER=localhost
      - QBITTORRENT_PORT=8080
      - QBITTORRENT_USER=admin
      - QBITTORRENT_PASS=adminpass  # Change after first login
      - PORT_FORWARDED=/tmp/gluetun/forwarded_port
      - CHECK_INTERVAL=300  # Check every 5 minutes
    volumes:
      - ./gluetun:/tmp/gluetun:ro
    depends_on:
      - gluetun
      - qbittorrent
    restart: unless-stopped

networks:
  torrent_net:
    driver: bridge

```

**Key Configuration Points**:
- `network_mode: "service:gluetun"` - ALL container traffic goes through VPN
- Gluetun exposes ports 8080, 6881, 8888 - these are the only external access points
- Port manager reads `/tmp/gluetun/forwarded_port` and updates qBittorrent automatically

**References**:
- Gluetun documentation: https://github.com/qdm12/gluetun
- ProtonVPN setup: https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md
- Port manager: https://github.com/SnoringDragon/gluetun-qbittorrent-port-manager

### Step 3: First Run and Configuration

```bash
# Start the stack
docker compose up -d

# Watch logs to verify connection
docker compose logs -f gluetun

# Look for these success messages:
# [INFO] IP: xx.xx.xx.xx  (should be ProtonVPN IP, not your real IP)
# [INFO] Port forwarded successfully: 12345
# [INFO] HTTP proxy listening on :8888
```

**Verify VPN is working**:
```bash
# Check qBittorrent sees VPN IP
docker exec qbittorrent curl ifconfig.me
# Should return ProtonVPN IP, NOT your real IP
```

### Step 4: qBittorrent Initial Setup

1. **Access WebUI**: http://your-docker-host:8080
2. **Default credentials**: 
   - Username: `admin`
   - Password: Check logs: `docker logs qbittorrent | grep "password"`
3. **Change password immediately** in Tools → Options → Web UI
4. **Update port manager environment** with your new password:
   ```bash
   # Edit docker-compose.yml
   # Change QBITTORRENT_PASS to your new password
   docker compose up -d qbittorrent-port-manager
   ```

**Configure qBittorrent Settings**:

Navigate to Tools → Options:

**Connection**:
- Listening Port: Will be auto-updated by port manager (check after 5 minutes)
- UPnP / NAT-PMP: ✅ **DISABLE** (Gluetun handles this)
- Connection Limits: Adjust as needed

**Speed**:
- Global upload/download limits as desired

**BitTorrent**:
- Enable DHT, PEX, LSD as desired
- Encryption: Prefer encrypted connections

**Advanced**:
- Network Interface: Leave blank (uses VPN automatically)
- Optional: Bind to VPN address `10.2.0.2` for extra safety

### Step 5: Verify Port Forwarding

```bash
# Check Gluetun forwarded port
docker exec gluetun cat /tmp/gluetun/forwarded_port
# Example output: 12345

# Check qBittorrent listening port (give it 5 minutes after first start)
docker exec qbittorrent curl -s http://localhost:8080/api/v2/app/preferences | grep -o '"listen_port":[0-9]*'
# Should match the forwarded port from above

# Test port forwarding
# Add a popular torrent and check if it's connectable
# Tools → Options → Connection → Test Port button (in qBittorrent WebUI)
```

**Port Manager Logs**:
```bash
docker logs qbittorrent-port-manager
# Look for:
# Successfully updated qBittorrent port to 12345
```

**References**:
- ProtonVPN port forwarding: https://protonvpn.com/support/port-forwarding-manual-setup
- Testing port forwarding: https://www.yougetsignal.com/tools/open-ports/

---

## Sonarr/Radarr Integration

### Option 1: Direct Connection (Recommended)

Your *arr applications can reach qBittorrent directly through Gluetun's exposed port:

**Sonarr/Radarr/Prowlarr Settings**:
- Settings → Download Clients → Add → qBittorrent
- Host: `gluetun` (or `your-docker-host-ip`)
- Port: `8080`
- Username: `admin`
- Password: (your qBittorrent password)
- Category: `tv` / `movies` / etc.

### Option 2: HTTP Proxy (If Direct Connection Fails)

If your *arr apps are on a different network or direct connection doesn't work:

**Configure *arr apps to use Gluetun's HTTP proxy**:

For Sonarr/Radarr using environment variables:
```yaml
# In your *arr docker-compose.yml
environment:
  - HTTP_PROXY=http://gluetun:8888
  - HTTPS_PROXY=http://gluetun:8888
  - NO_PROXY=localhost,127.0.0.1
```

Or configure in the application:
- Settings → Download Clients → Add → qBittorrent
- Host: `localhost` or `127.0.0.1`
- Port: `8080`
- Then configure HTTP proxy in your container/OS to route through `gluetun:8888`

**Test proxy access**:
```bash
# From *arr container
curl -x http://gluetun:8888 http://localhost:8080/api/v2/app/version
# Should return qBittorrent version
```

### Option 3: Custom Network Bridge

If apps need more complex routing, create a shared Docker network:

```yaml
# In gluetun docker-compose.yml
networks:
  arr_network:
    external: true

services:
  gluetun:
    networks:
      - arr_network
```

```yaml
# In *arr docker-compose.yml
networks:
  arr_network:
    external: true

services:
  sonarr:
    networks:
      - arr_network
```

Then use host `gluetun:8080` in *arr download client settings.

**References**:
- Sonarr qBittorrent setup: https://wiki.servarr.com/sonarr/supported#qbittorrent
- Docker networking: https://docs.docker.com/network/

---

## Dynamic Port Forwarding Management

### How It Works

1. **Gluetun** establishes VPN connection and requests port via NAT-PMP
2. ProtonVPN assigns a random port (changes periodically or on reconnection)
3. Gluetun writes port to `/tmp/gluetun/forwarded_port` inside container
4. **Port Manager** container reads this file every 5 minutes
5. Port Manager calls qBittorrent API to update listening port

### Manual Port Update (Troubleshooting)

If automatic updates aren't working:

```bash
# Get current forwarded port
FORWARDED_PORT=$(docker exec gluetun cat /tmp/gluetun/forwarded_port)
echo "Forwarded port: $FORWARDED_PORT"

# Manually update qBittorrent
docker exec qbittorrent curl -X POST \
  "http://localhost:8080/api/v2/app/setPreferences" \
  -H "Content-Type: application/json" \
  -d "{\"listen_port\": $FORWARDED_PORT}"

# Verify update
docker exec qbittorrent curl -s http://localhost:8080/api/v2/app/preferences | grep listen_port
```

### Alternative: Custom Script

If port manager container doesn't work, create a custom script:

```bash
#!/bin/bash
# save as ~/docker/torrent-stack/update-port.sh

GLUETUN_CONTAINER="gluetun"
QBITTORRENT_CONTAINER="qbittorrent"
QBITTORRENT_USER="admin"
QBITTORRENT_PASS="your_password"

# Get forwarded port from Gluetun
FORWARDED_PORT=$(docker exec $GLUETUN_CONTAINER cat /tmp/gluetun/forwarded_port 2>/dev/null)

if [ -z "$FORWARDED_PORT" ]; then
    echo "Error: Could not read forwarded port"
    exit 1
fi

echo "Forwarded port: $FORWARDED_PORT"

# Update qBittorrent
docker exec $QBITTORRENT_CONTAINER curl -X POST \
    "http://localhost:8080/api/v2/app/setPreferences" \
    -u "$QBITTORRENT_USER:$QBITTORRENT_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"listen_port\": $FORWARDED_PORT}"

echo "Updated qBittorrent listening port to $FORWARDED_PORT"
```

**Make executable and schedule**:
```bash
chmod +x ~/docker/torrent-stack/update-port.sh

# Add to crontab (every 5 minutes)
crontab -e
# Add line:
*/5 * * * * /home/youruser/docker/torrent-stack/update-port.sh >> /var/log/qbit-port-update.log 2>&1
```

### Monitoring Port Changes

```bash
# Watch Gluetun logs for port changes
docker logs -f gluetun | grep -i "port"

# Check port manager activity
docker logs -f qbittorrent-port-manager

# Create monitoring script
cat > ~/docker/torrent-stack/check-port.sh << 'EOF'
#!/bin/bash
echo "=== Port Forwarding Status ==="
echo "Gluetun forwarded port:"
docker exec gluetun cat /tmp/gluetun/forwarded_port

echo -e "\nqBittorrent listening port:"
docker exec qbittorrent curl -s http://localhost:8080/api/v2/app/preferences | jq '.listen_port'

echo -e "\nPort Manager last log:"
docker logs --tail 5 qbittorrent-port-manager
EOF

chmod +x ~/docker/torrent-stack/check-port.sh
```

**Reference**: https://github.com/qdm12/gluetun/wiki/Port-forwarding

---

## Troubleshooting

### VPN Not Connecting

```bash
# Check Gluetun logs
docker logs gluetun | grep -i error

# Common issues:
# 1. Wrong WireGuard credentials
# 2. Firewall blocking UDP 51820
# 3. Time sync issues

# Test WireGuard manually
docker exec gluetun ping -c 3 1.1.1.1
```

### Port Forwarding Not Working

```bash
# Verify ProtonVPN assigned a port
docker exec gluetun cat /tmp/gluetun/forwarded_port

# If empty, check:
# 1. Server supports P2P (must be P2P server)
# 2. VPN_PORT_FORWARDING=on is set
# 3. Check Gluetun logs for NAT-PMP errors

docker logs gluetun | grep -i "port forward"
```

### qBittorrent Not Accessible

```bash
# Check if qBittorrent is running
docker ps | grep qbittorrent

# Check network mode
docker inspect qbittorrent | grep -i network

# Should show: "NetworkMode": "container:gluetun"

# Test from Docker host
curl http://localhost:8080/api/v2/app/version
```

### *arr Apps Can't Reach qBittorrent

```bash
# Test from Sonarr/Radarr container
docker exec sonarr curl -v http://gluetun:8080/api/v2/app/version

# If fails, try:
# 1. Use Docker host IP instead: http://192.168.1.x:8080
# 2. Check Docker network connectivity
docker network inspect bridge

# 3. Verify ports are exposed
docker port gluetun
```

### Verifying VPN Kill Switch

```bash
# Stop Gluetun
docker stop gluetun

# qBittorrent should also stop (shares network stack)
docker ps | grep qbittorrent
# Should show as stopped

# This proves no traffic can leak outside VPN tunnel
```

---

## Security Hardening

### 1. Verify No DNS Leaks

```bash
# Check DNS from qBittorrent perspective
docker exec qbittorrent nslookup google.com

# Should show Gluetun's DNS (1.1.1.1), not your ISP DNS
```

### 2. Verify IP Address

```bash
# Real IP check
curl ifconfig.me

# qBittorrent IP check (should be different)
docker exec qbittorrent curl ifconfig.me

# If they match, VPN is NOT working!
```

### 3. WebUI Access Control

In qBittorrent Settings → Web UI:
- Enable "Bypass authentication for clients on localhost"
- Set IP address whitelist: `127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16`
- Consider using Traefik with authentication for external access

### 4. Firewall Rules (Optional)

On OPNsense, you can still firewall the Docker host but qBittorrent traffic is already isolated in VPN tunnel:

```
# Allow Docker host to reach ProtonVPN
Protocol: UDP
Source: Docker_Host
Destination: ProtonVPN_Servers (51820)
Action: Allow

# Allow LAN to reach qBittorrent WebUI
Protocol: TCP
Source: LAN
Destination: Docker_Host Port 8080
Action: Allow
```

---

## Backup and Recovery

### Backup Configuration

```bash
# Backup script
cat > ~/docker/torrent-stack/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/backup/torrent-stack-$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Backup configs
cp docker-compose.yml $BACKUP_DIR/
cp -r gluetun $BACKUP_DIR/
cp -r qbittorrent/config $BACKUP_DIR/qbittorrent-config

# Create archive
tar -czf $BACKUP_DIR.tar.gz -C /backup torrent-stack-$(date +%Y%m%d)
rm -rf $BACKUP_DIR

echo "Backup complete: $BACKUP_DIR.tar.gz"
EOF

chmod +x ~/docker/torrent-stack/backup.sh
```

### Restore from Backup

```bash
# Stop containers
docker compose down

# Restore
tar -xzf /backup/torrent-stack-YYYYMMDD.tar.gz -C ~/docker/torrent-stack/

# Start
docker compose up -d
```

---

## Performance Optimization

### Connection Limits

In qBittorrent Settings → Connection:
- Max connections: 500-1000 (depending on hardware)
- Max connections per torrent: 100
- Max uploads per torrent: 15

### Disk Cache

Settings → Advanced:
- Disk cache: 512 MB - 2048 MB
- Disk cache expiry: 60 seconds

### ProtonVPN Server Selection

- Choose geographically close P2P servers
- Test different servers for speed: https://protonvpn.com/support/p2p-vpn/
- Servers in Netherlands, Switzerland, Sweden typically best for torrents

---

## Monitoring and Maintenance

### Health Check Script

```bash
cat > ~/docker/torrent-stack/health-check.sh << 'EOF'
#!/bin/bash

echo "=== Torrent Stack Health Check ==="
echo ""

# Check containers
echo "Container Status:"
docker ps --filter "name=gluetun|qbittorrent|qb-port" --format "table {{.Names}}\t{{.Status}}"
echo ""

# Check VPN IP
echo "VPN IP Address:"
docker exec qbittorrent curl -s ifconfig.me
echo ""

# Check port forwarding
echo "Port Forwarding:"
FORWARDED=$(docker exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null)
LISTENING=$(docker exec qbittorrent curl -s http://localhost:8080/api/v2/app/preferences | jq -r '.listen_port')
echo "Forwarded: $FORWARDED"
echo "Listening: $LISTENING"
if [ "$FORWARDED" == "$LISTENING" ]; then
    echo "✓ Ports match"
else
    echo "✗ Ports don't match!"
fi
echo ""

# Check proxy
echo "HTTP Proxy:"
curl -s -x http://localhost:8888 http://ifconfig.me
echo ""
EOF

chmod +x ~/docker/torrent-stack/health-check.sh
```

### Log Rotation

```bash
# Add to docker-compose.yml for each service:
logging:
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"
```

---

## Reference Links

### Official Documentation
- Gluetun: https://github.com/qdm12/gluetun
- Gluetun Wiki: https://github.com/qdm12/gluetun-wiki
- ProtonVPN: https://protonvpn.com/support/
- qBittorrent: https://github.com/qbittorrent/qBittorrent/wiki
- Port Manager: https://github.com/SnoringDragon/gluetun-qbittorrent-port-manager

### Community Resources
- Gluetun + qBittorrent Guide: https://pimylifeup.com/docker-gluetun/
- ProtonVPN Port Forwarding: https://github.com/qdm12/gluetun/wiki/ProtonVPN
- Docker Networking: https://docs.docker.com/network/
- LinuxServer.io qBittorrent: https://docs.linuxserver.io/images/docker-qbittorrent

### Troubleshooting Resources
- Gluetun GitHub Issues: https://github.com/qdm12/gluetun/issues
- ProtonVPN Support: https://protonvpn.com/support/
- r/ProtonVPN: https://reddit.com/r/ProtonVPN
- r/qBittorrent: https://reddit.com/r/qBittorrent

---

## Quick Command Reference

```bash
# Start stack
docker compose up -d

# Stop stack
docker compose down

# View logs
docker compose logs -f [service_name]

# Restart specific service
docker compose restart gluetun

# Check VPN IP
docker exec qbittorrent curl ifconfig.me

# Check forwarded port
docker exec gluetun cat /tmp/gluetun/forwarded_port

# Update to latest images
docker compose pull
docker compose up -d

# Clean up old images
docker image prune -a

# Full rebuild
docker compose down
docker compose pull
docker compose up -d --force-recreate
```

---

## AI Agent Instructions

When assisting with this setup:

1. **Always verify Docker mode**: This stack MUST run as standalone Docker containers, NOT Docker Swarm services
2. **Network mode is critical**: `network_mode: "service:gluetun"` cannot be changed without breaking VPN isolation
3. **Port exposure**: Only Gluetun exposes ports to host; other containers share its network
4. **Credentials security**: Remind user to change default passwords and never commit credentials to git
5. **Testing steps**: Always include VPN IP verification steps in any modifications
6. **Port forwarding**: Any changes to Gluetun may require port manager restart
7. ***arr integration**: Test connectivity from *arr containers before assuming success
8. **Logs are key**: When troubleshooting, always check Gluetun logs first

**Common Issues to Watch For**:
- Trying to use Docker Swarm mode (won't work)
- Forgetting to update port manager password after changing qBittorrent password
- Mixing container names and service names in network_mode
- Not waiting 5 minutes for port manager to complete first update
- Firewall rules blocking UDP 51820 to ProtonVPN

---

## End of Guide

This setup provides:
- ✅ Complete VPN isolation for BitTorrent traffic
- ✅ Automatic port forwarding with ProtonVPN
- ✅ Bypass of CrowdSec firewall monitoring (by design)
- ✅ Proxy access for Sonarr/Radarr/*arr applications
- ✅ No traffic leaks outside VPN tunnel
- ✅ Simple Docker Compose management

For questions or issues, consult the reference links or GitHub issues for the respective projects.