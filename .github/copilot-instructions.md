# Colonial Data Nexus - AI Agent Instructions

## Project Overview
Colonial Data Nexus is a **Docker-based download management infrastructure** using advanced VLAN separation and IPvlan networking to isolate VPN-protected torrent traffic from regular download traffic. Deployed on Docker Swarm hosts with custom network interfaces.

## Critical Architecture Decisions

### 1. **IPvlan L2 Mode for VLAN Separation** (Not MACVLAN, Not Port Binding)
- **VPN VLAN** (`enp6s0` - 192.168.105.0/24): qBittorrent, Prowlarr, Flaresolverr get **direct IP assignments**
- **Download VLAN** (`enp4s0` - 192.168.100.0/24): SABnzbd gets direct IP
- **Why IPvlan**: Containers need accurate external IP detection (qBittorrent shows `192.168.105.10` not public IP)
- **Key Pattern**: Each service defines its own IPvlan network in `docker-compose.yaml`:

```yaml
networks:
  vpn_vlan:
    driver: ipvlan
    driver_opts:
      parent: enp6s0  # Physical interface binding
      ipvlan_mode: l2
    ipam:
      config:
        - subnet: 192.168.105.0/24
          gateway: 192.168.105.1
```

See `VLAN_TRAFFIC_SEPARATION_README.md` for full IPvlan vs MACVLAN vs port binding decision history.

### 2. **Cross-VLAN Communication via Nginx Proxies**
Services on different VLANs can't directly communicate. Solution: nginx proxy containers bridging networks.

**Pattern** (`sabnzbd-proxy`, `prowlarr-proxy`):
```yaml
sabnzbd-proxy:
  networks:
    - default          # Main LAN accessibility
    - download_vlan    # Reaches SABnzbd backend
  ports:
    - "192.168.50.10:9020:9020"  # Exposes to main network
```

**Usage**: Sonarr/Radarr connect to `192.168.50.10:9020` (proxy) not `192.168.100.10:8080` (direct VLAN IP).

### 3. **DNS Search Domain Conflict Mitigation**
AdGuard wildcard DNS rewrites caused external domain resolution failures in containers.

**Required configuration** in ALL VPN/download services:
```yaml
dns:
  - "1.1.1.1"
  - "9.9.9.9"
dns_search: []        # CRITICAL: Prevents loopey.net injection
dns_opt:
  - "ndots:0"         # Forces external DNS for all queries
```

Automated via `set_docker_networking.sh` which configures `/etc/docker/daemon.json` across Docker Swarm nodes.

### 4. **Two Compose File Strategy**
- `colonial_data_nexus-compose.yaml`: Download services (qBittorrent, SABnzbd, indexers)
- `data_nexus_monitor-compose-fixed.yaml`: Monitoring (Uptime Kuma, Silent Monitor) - **separate project**

**Rationale**: Restart downloads without affecting monitoring uptime.

## Key Developer Workflows

### Deploy Services
```bash
# Start monitoring first (if monitoring stack exists separately)
docker-compose -f data_nexus_monitor-compose-fixed.yaml up -d

# Start download services
docker-compose -f colonial_data_nexus-compose.yaml up -d
```

### Test VLAN Connectivity
```bash
# Run enhanced VLAN monitor (checks VPN vs normal internet IPs)
./data/vlan_connectivity_check_enhanced.sh

# Manual verification from another VLAN host (NOT Docker host - IPvlan isolation)
curl http://192.168.105.10:8081  # qBittorrent on VPN VLAN
curl http://192.168.100.10:8080  # SABnzbd on Download VLAN
```

**Important**: IPvlan containers are isolated from their host interface by design. Test from other machines on the VLAN.

### Apply Docker DNS Fixes Across Swarm
```bash
./set_docker_networking.sh  # Configures daemon.json, removes dns-search from /etc/network/interfaces
sudo systemctl restart docker
```

### Update Firewall Rules
```bash
./firewall.sh  # Adds UFW rules for VLAN service IPs
```

## Project-Specific Conventions

### Network Interface Naming
- Physical interfaces: `enp6s0` (VPN), `enp4s0` (Download), `ens3` (Main)
- **Docker networks**: Named `vpn_vlan`, `download_vlan` (not generic names)
- Check current interfaces: `ip addr show` before modifying compose files

### Static IP Assignments
- **Host IP on VPN VLAN**: `192.168.105.8` (not .9 - avoid conflicts with Prowlarr at .9)
- **qBittorrent**: `.10`, **Prowlarr**: `.9`, **Flaresolverr**: `.12`
- **SABnzbd**: `192.168.100.10`

### Health Checks Pattern
All services use curl-based healthchecks with API endpoints:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://127.0.0.1:8081"]
  interval: 2m
  timeout: 10s
  retries: 3
  start_period: 30s
```

### Resource Limits Convention
Download services have explicit CPU/memory limits for heavy torrent/NZB loads:
```yaml
deploy:
  resources:
    limits:
      cpus: '2.25'
      memory: 4G
    reservations:
      cpus: '.75'
      memory: 768M
```

## Critical Files Reference

- **`docker-compose.yaml`**: Main compose (aliased to `colonial_data_nexus-compose.yaml` via symlink or rename)
- **`VLAN_TRAFFIC_SEPARATION_README.md`**: Complete IPvlan implementation history and troubleshooting
- **`progress.md`**: Deployment status tracking, DNS issue resolution timeline
- **`firewall.sh`**: UFW rules for VLAN service access (references specific .105/.100 IPs)
- **`data/vlan_connectivity_check_enhanced.sh`**: VPN verification script (compares public IPs)
- **`set_docker_networking.sh`**: Swarm-wide Docker daemon configuration deployment

## Common Pitfalls

1. **Don't use MACVLAN**: LinuxServer.io images have IPv6 binding issues with MACVLAN (see VLAN README)
2. **IPvlan host isolation**: Can't ping IPvlan container IPs from the Docker host - this is expected
3. **Cross-VLAN timeouts**: Always use nginx proxies for inter-VLAN service communication
4. **DNS search inheritance**: Must set `dns_search: []` in EVERY service to prevent AdGuard conflicts
5. **Interface parent names**: Physical interface names vary (`enp6s0` on this host, may differ on others)

## Integration Points

- **Uptime Kuma Push Monitors**: `vlan_connectivity_check_enhanced.sh` reports to centralized monitoring
- **External Services**: Sonarr/Radarr connect via nginx proxies on `192.168.50.10` (main LAN)
- **VPN Provider**: Configured externally; services verify VPN via public IP comparison
- **AdGuard Home**: DNS server at `192.168.50.10`, `192.168.50.20` - requires search domain override

## Testing After Changes

1. Verify IPvlan network creation: `docker network ls | grep -E "(vpn|download)_vlan"`
2. Check container direct IP: `docker exec qbittorrent-nexus ip addr show`
3. Confirm VPN routing: `./data/vlan_connectivity_check_enhanced.sh` (should show different public IPs)
4. Test cross-VLAN proxy: `curl http://192.168.50.10:9020/api?mode=version` (SABnzbd via proxy)

## When Modifying Network Configuration

- **Adding new VLAN service**: Copy IPvlan network block from existing service, assign new IP
- **Changing interface names**: Update `parent:` in all IPvlan network definitions
- **New cross-VLAN integration**: Deploy nginx proxy container with dual network attachment
- **Firewall updates**: Edit `firewall.sh` with new IP:port, run script, verify with `ufw status verbose`
