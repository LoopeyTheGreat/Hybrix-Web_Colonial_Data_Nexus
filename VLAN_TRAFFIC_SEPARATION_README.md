# VLAN Traffic Separation for Docker Services

## Overview

This document explains how to configure Docker containers to bind to specific network interfaces (VLANs) for traffic prioritization and QoS management. This setup separates download traffic from VPN/torrent traffic using different network interfaces.

## Network Architecture

### VLAN Configuration
- **Download VLAN (ens4)**: `192.168.100.0/24`
  - Gateway: `192.168.100.1`
  - SABnzbd: `192.168.100.9:8080` (port binding method)
  
- **VPN VLAN (ens5)**: `192.168.105.0/24`
  - Gateway: `192.168.105.1`
  - **Host IP**: `192.168.105.9` (updated to avoid conflicts)
  - **qBittorrent**: `192.168.105.10:8081` (IPvlan - direct IP assignment!)
  - Jackett: `192.168.105.9:9117` (port binding to host)
  - Prowlarr: `192.168.105.9:9696` (port binding to host)
  - Flaresolverr: `192.168.105.9:8191` (port binding to host)

## Solution Evolution: Port Binding → MACVLAN → IPvlan

### First Approach: Port Binding (✅ Works for SABnzbd)
```yaml
# This approach works well for basic VLAN binding
sabnzbd:
  ports:
    - "192.168.100.10:8080:8080"  # Bind to specific VLAN interface
```
**Pros**: Simple, reliable, good for services that don't need direct IP detection  
**Cons**: External IP detection still shows public IP instead of VLAN IP

### Second Approach: MACVLAN (❌ Failed)
```yaml
# This approach had IPv6 binding and accessibility issues
sabnzbd:
  networks:
    sabnzbd_macvlan:
      ipv4_address: 192.168.100.10

networks:
  sabnzbd_macvlan:
    driver: macvlan
    driver_opts:
      parent: ens4
```
**Problems**: 
- LinuxServer.io containers forced IPv6-only binding (`:::8080`)
- Containers isolated from host (security feature, but breaks accessibility)
- Complex troubleshooting and unreliable behavior

### **🏆 FINAL SOLUTION: IPvlan L2 Mode (✅ Perfect!)**
```yaml
# This is the OPTIMAL solution for multi-adapter Docker networking
qbittorrent:
  image: lscr.io/linuxserver/qbittorrent:latest
  container_name: qbittorrent-nexus
  networks:
    qbittorrent_vpn_vlan:
      ipv4_address: 192.168.105.10  # Direct VLAN IP assignment
  # No port mappings needed - container gets direct IP!

networks:
  qbittorrent_vpn_vlan:
    driver: ipvlan
    driver_opts:
      parent: ens5  # Bind directly to VPN VLAN interface
      ipvlan_mode: l2
    ipam:
      config:
        - subnet: 192.168.105.0/24
          gateway: 192.168.105.1
```

**✅ Benefits of IPvlan L2**:
- **Direct IP assignment**: Container gets `192.168.105.10` as its actual IP
- **Perfect external IP detection**: qBittorrent detects `192.168.105.10` as external IP (not public IP!)
- **True VLAN attachment**: Traffic routes directly through specified interface (`ens5`)
- **No port mapping complexity**: Container is directly accessible on the VLAN
- **Clean, simple configuration**: One network definition handles everything
- **Optimal for torrent clients**: Perfect for services that need accurate IP detection

## Implementation Steps

### 1. Verify Network Interfaces
```bash
# Check your network interfaces
ip addr show

# Should show something like:
# ens4: 192.168.100.10/24 (Download VLAN)
# ens5: 192.168.105.10/24 (VPN VLAN)
```

### 2. Configure Docker Compose

#### For Services Requiring Direct VLAN IP (IPvlan Method):
```yaml
# BEST for: Torrent clients, VPN services, anything needing accurate external IP detection
qbittorrent:
  image: lscr.io/linuxserver/qbittorrent:latest
  container_name: qbittorrent-nexus
  hostname: qbittorrent-vpn
  networks:
    qbittorrent_vpn_vlan:
      ipv4_address: 192.168.105.10  # Container gets this IP directly
  dns:
    - "1.1.1.1"
    - "9.9.9.9"
    - "1.0.0.1"
  environment:
    - QBT_WEBUI_HOST=*  # Bind to all interfaces internally
  # No ports section needed - container accessible at 192.168.105.10:8081

networks:
  qbittorrent_vpn_vlan:
    driver: ipvlan
    driver_opts:
      parent: ens5  # VPN VLAN interface
      ipvlan_mode: l2
    ipam:
      config:
        - subnet: 192.168.105.0/24
          gateway: 192.168.105.1
```

#### For Services on Download VLAN (Port Binding Method):
```yaml
# GOOD for: Download managers, basic services
sabnzbd:
  image: lscr.io/linuxserver/sabnzbd:latest
  container_name: sabnzbd-nexus
  hostname: sabnzbd-download
  ports:
    - "192.168.100.9:8080:8080"   # Bind to Download VLAN IP
    - "192.168.50.10:8082:8080"   # Dual binding for cross-VLAN connectivity
  dns:
    - "1.1.1.1"
    - "9.9.9.9"
    - "1.0.0.1"
  environment:
    - SABNZBD_HOST=0.0.0.0
    - SABNZBD_PORT=8080
  # ... other configuration
```

#### For Other Services on VPN VLAN (Port Binding Method):
```yaml
# ADEQUATE for: Indexers, utilities that don't need direct IP
jackett:
  ports:
    - "192.168.105.9:9117:9117"  # Bind to host VPN VLAN IP

prowlarr:
  ports:
    - "192.168.105.9:9696:9696"  # Bind to host VPN VLAN IP

flaresolverr:
  ports:
    - "192.168.105.9:8191:8191"  # Bind to host VPN VLAN IP
```

### 3. Deploy and Verify

```bash
# Stop existing containers
docker-compose down

# Start with new configuration
docker-compose up -d

# Verify port bindings
docker ps --format "table {{.Names}}\t{{.Ports}}"

# Check network bindings on host
netstat -tlnp | grep "192.168"
```

### 4. Validation Commands

```bash
# Test SABnzbd API (Download VLAN)
curl -s http://192.168.100.9:8080/api?mode=version

# Test SABnzbd API (Main Network - for service integration)
curl -s http://192.168.50.10:8082/api?mode=version

# Test qBittorrent (VPN VLAN - IPvlan direct IP!)
curl -s http://192.168.105.10:8081/

# Test other VPN services (port binding)
curl -s http://192.168.105.9:9117/  # Jackett
curl -s http://192.168.105.9:9696/  # Prowlarr

# Check IPvlan container network (should show direct VLAN IP)
docker exec qbittorrent-nexus ip addr show

# Verify external IP detection in qBittorrent
# Should show 192.168.105.10 instead of public IP!

# Check port accessibility
nmap -Pn -p 8080 192.168.100.9
nmap -Pn -p 8082 192.168.50.10
nmap -Pn -p 8081 192.168.105.10    # IPvlan direct access
nmap -Pn -p 9117 192.168.105.9     # Port binding

# Test cross-VLAN connectivity
curl -s --max-time 10 http://192.168.100.9:8080/api?mode=version   # May timeout
curl -s --max-time 10 http://192.168.50.10:8082/api?mode=version   # Should work quickly
```

## Troubleshooting

### Common Issues and Solutions

#### 1. "Service refers to undefined network"
**Problem**: Old MACVLAN network references in compose file
**Solution**: Remove all `networks:` sections and MACVLAN definitions

#### 2. IPv6-only binding
**Problem**: Service only listens on `:::PORT` instead of IPv4
**Solution**: Use port binding instead of MACVLAN approach

#### 3. Port not accessible
**Problem**: Service shows as running but port isn't reachable
**Solution**: 
- Check firewall rules
- Verify interface has the correct IP
- Test from inside container first

#### 4. Container won't start
**Problem**: Port binding conflicts
**Solution**: 
- Check if IP is already in use: `ss -tlnp | grep :8080`
- Verify network interface exists: `ip addr show`

#### 6. IPvlan containers can't ping from host interface
**Problem**: `ping 192.168.105.10` from host fails with "Destination Host Unreachable"
**Solution**: This is **expected behavior** - IPvlan isolation prevents host access for security
**Test From**: Use another machine on the VLAN (e.g., Lenovo-Flex) to test connectivity

#### 7. External IP detection still shows public IP
**Problem**: Service shows public IP instead of VLAN IP in external IP detection
**Solution**: Use **IPvlan instead of port binding** - gives container direct VLAN IP
**Result**: qBittorrent with IPvlan correctly detects `192.168.105.10` as external IP!
#### 5. Cross-VLAN service timeouts
**Problem**: Services on different VLANs experiencing connection timeouts
**Solution**: 
- Configure services to use same-network addresses when possible
- Use dual interface binding for services that need cross-VLAN connectivity
- Example: Sonarr → SABnzbd should use `192.168.50.10:8082` not `192.168.100.9:8080`

### Debug Commands

```bash
# Check container logs
docker logs sabnzbd-nexus --tail 20

# Test inside container
docker exec sabnzbd-nexus curl -I http://localhost:8080/

# Check network binding
ss -tlnp | grep :8080

# Verify container network
docker inspect sabnzbd-nexus | grep -A 10 "NetworkSettings"
```

## Benefits Achieved

### Traffic Separation
- **Download traffic** (SABnzbd) → `ens4` interface → `192.168.100.x` subnet
- **Torrent/VPN traffic** (qBittorrent, indexers) → `ens5` interface → `192.168.105.x` subnet

### QoS/Traffic Shaping Ready
You can now apply traffic shaping rules to specific interfaces:
```bash
# Example: Limit download interface to 50Mbps
tc qdisc add dev ens4 root handle 1: htb default 30
tc class add dev ens4 parent 1: classid 1:1 htb rate 50mbit

# Example: Prioritize VPN interface
tc qdisc add dev ens5 root handle 1: htb default 10
tc class add dev ens5 parent 1: classid 1:1 htb rate 100mbit prio 1
```

## Service Access URLs

After successful deployment:
- **SABnzbd** (Download VLAN): `http://192.168.100.9:8080/`
- **SABnzbd** (Main Network - for Sonarr): `http://192.168.50.10:8082/`
- **🌟 qBittorrent** (VPN VLAN - IPvlan): `http://192.168.105.10:8081/` ⭐ **Direct VLAN IP!**
- **Jackett** (VPN VLAN): `http://192.168.105.9:9117/`
- **Prowlarr** (VPN VLAN): `http://192.168.105.9:9696/`
- **Flaresolverr** (VPN VLAN): `http://192.168.105.9:8191/`

### Service Integration URLs
When configuring services to communicate with each other:
- **Sonarr → SABnzbd**: Use `http://192.168.50.10:8082/` (same network, no cross-VLAN routing)
- **Other services → SABnzbd**: Use `http://192.168.100.9:8080/` (Download VLAN)
- **⚡ qBittorrent advantage**: External IP detection shows `192.168.105.10` (VLAN IP) instead of public IP!

## Cross-VLAN Connectivity Issues and Solutions

### Problem: Sonarr-SABnzbd Timeouts
**Issue**: Even with firewall rules allowing traffic between VLANs, Sonarr (running on main network) was experiencing timeouts when connecting to SABnzbd (on Download VLAN).

**Root Cause**: Cross-VLAN communication can have latency and routing issues even when firewall rules permit the traffic.

**Solution**: Configure SABnzbd to bind to multiple interfaces, including the main network interface for direct connectivity.

### Implementation
```yaml
# SABnzbd configuration with dual interface binding
sabnzbd:
  ports:
    - "192.168.100.9:8080:8080"   # Download VLAN (primary)
    - "192.168.50.10:8082:8080"   # Main network (for Sonarr connectivity)
```

### Sonarr Configuration
Configure Sonarr to use the local address for SABnzbd:
- **SABnzbd Host**: `192.168.50.10` (main network IP)
- **SABnzbd Port**: `8082`
- **URL**: `http://192.168.50.10:8082/`

This eliminates cross-VLAN routing and provides direct, low-latency connectivity.

## Key Learnings

1. **🏆 IPvlan is THE solution for multi-adapter Docker networking** - gives containers direct VLAN IPs
2. **IPvlan L2 mode is perfect for torrent clients** - proper external IP detection (shows VLAN IP, not public IP)
3. **Port binding is reliable but limited** - good for basic VLAN separation, poor for IP detection
4. **MACVLAN is problematic** - IPv6 binding issues, accessibility problems, complex troubleshooting
5. **LinuxServer.io containers** can have IPv6-only binding issues with MACVLAN
6. **Cross-VLAN communication can cause timeouts** even with proper firewall rules
7. **Dual interface binding solves connectivity issues** between services on different VLANs
8. **Always configure services to use local network addresses** when possible
9. **IPvlan containers are isolated from host by design** - test from other VLAN machines, not host
10. **🎯 Use IPvlan for services needing accurate external IP detection** (VPN clients, torrent apps)
11. **Use port binding for basic services** that don't need direct IP assignment
12. **Always verify network interfaces** before configuring services
13. **Test API endpoints first** before troubleshooting web interfaces
14. **Use curl and netstat** for debugging connectivity issues

## Method Selection Guide

### Use **IPvlan L2** when:
- ✅ Service needs accurate external IP detection (torrent clients, VPN apps)
- ✅ True VLAN attachment is required
- ✅ Container should be directly addressable on the VLAN
- ✅ Clean, simple network configuration is desired

### Use **Port Binding** when:
- ✅ Basic VLAN traffic separation is sufficient
- ✅ External IP detection is not critical
- ✅ Need cross-VLAN connectivity from host
- ✅ Simple troubleshooting is preferred

### **Avoid MACVLAN** because:
- ❌ LinuxServer.io containers have IPv6 binding issues
- ❌ Host isolation can break accessibility
- ❌ Complex troubleshooting and unpredictable behavior

## Future Modifications

To add more services to specific VLANs:

### Add to Download VLAN (ens4 - Port Binding):
```yaml
new_service:
  ports:
    - "192.168.100.9:PORT:PORT"  # Replace PORT with desired port
```

### Add to VPN VLAN (ens5 - Port Binding):
```yaml
new_service:
  ports:
    - "192.168.105.9:PORT:PORT"  # Replace PORT with desired port
```

### Add to VPN VLAN (ens5 - IPvlan for Direct IP):
```yaml
# For services needing direct VLAN IP (torrent clients, VPN apps)
new_service:
  networks:
    new_service_vpn_vlan:
      ipv4_address: 192.168.105.11  # Next available IP

networks:
  new_service_vpn_vlan:
    driver: ipvlan
    driver_opts:
      parent: ens5
      ipvlan_mode: l2
    ipam:
      config:
        - subnet: 192.168.105.0/24
          gateway: 192.168.105.1
```

## Files Modified
- `/opt/colonial_data_nexus/docker-compose.yaml` - Main configuration
- `/opt/colonial_data_nexus/colonial_data_nexus-compose.yaml` - Updated with IPvlan solution

---

**Created**: June 10, 2025  
**Updated**: June 11, 2025 - ⭐ **BREAKTHROUGH: IPvlan L2 solution implemented!** ⭐  
**Status**: 🏆 **OPTIMAL - IPvlan provides perfect external IP detection for qBittorrent**  
**Last Tested**: June 11, 2025 - qBittorrent correctly detects 192.168.105.10 as external IP!
