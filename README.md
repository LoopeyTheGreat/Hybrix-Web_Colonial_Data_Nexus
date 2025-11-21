# Colonial Data Nexus - Clear File Structure

## 📁 TWO COMPOSE FILES (FINAL)

### 1. `colonial_data_nexus-compose.yaml` 
**PURPOSE**: Main download services
- **qBittorrent**: VPN VLAN (ens5 - 192.168.105.10:8081)
- **SABnzbd**: Download VLAN (ens4 - 192.168.100.10:8080)

### 2. `data_nexus_monitor-compose-fixed.yaml`
**PURPOSE**: Monitoring services  
- **Uptime Kuma**: Dashboard (192.168.50.10:3002)
- **Silent Monitor**: Background monitoring (192.168.50.10:8084)

## 🚀 Deployment (CORRECT ORDER)

```bash
# 1. Start monitoring first
docker-compose -f data_nexus_monitor-compose-fixed.yaml up -d

# 2. Configure Uptime Kuma push monitors
# See UPTIME_KUMA_SETUP.md

# 3. Start download services
docker-compose -f colonial_data_nexus-compose.yaml up -d
```

## 🔧 Quick Commands

**Start all**:
```bash
docker-compose -f data_nexus_monitor-compose-fixed.yaml up -d
docker-compose -f colonial_data_nexus-compose.yaml up -d
```

**Stop all**:
```bash
docker-compose -f colonial_data_nexus-compose.yaml down
docker-compose -f data_nexus_monitor-compose-fixed.yaml down
```

**Check status**:
```bash
./check_status.sh
```

## 🎯 Why Two Files?

- **Independence**: Restart downloads without affecting monitoring
- **Maintenance**: Update services separately  
- **Reliability**: Monitoring stays up during app updates

That's it - **2 files, clear purposes, no confusion!**
