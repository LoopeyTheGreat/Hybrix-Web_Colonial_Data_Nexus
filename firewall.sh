#!/bin/bash

# Script to configure UFW rules for Colonial Data Nexus services
# This script only adds rules and does not remove existing ones.

echo "Adding UFW rules for Colonial Data Nexus..."

# Define specific local subnets
LOOPYNET_SUBNET="192.168.50.0/24"    # LoopeyNet
SPARTANNET_SUBNET="192.168.80.0/24"  # Spartan-Net
DOCKER0_SUBNET="172.17.0.0/24"       # Docker Internal - docker0
DOCKER_USER_SUBNET="172.20.0.0/16"   # Docker overlay networks
#"172.18.0.0/20"   # Docker Internal - user-defined networks

# --- Local Only Services on VPN VLAN (192.168.105.10) ---

# qBittorrent (WebUI) - TCP port 8081 - Allow Prowlarr and local subnets
echo "Allowing qBittorrent (port 8081/tcp) from Prowlarr and local subnets to 192.168.105.10..."
ufw allow from 192.168.105.9 to 192.168.105.10 port 8081 proto tcp comment 'qBittorrent WebUI (Prowlarr)'
ufw allow from ${LOOPYNET_SUBNET} to 192.168.105.10 port 8081 proto tcp comment 'qBittorrent WebUI (LoopeyNet)'
ufw allow from ${SPARTANNET_SUBNET} to 192.168.105.10 port 8081 proto tcp comment 'qBittorrent WebUI (Spartan-Net)'
ufw allow from ${DOCKER0_SUBNET} to 192.168.105.10 port 8081 proto tcp comment 'qBittorrent WebUI (Docker0)'
ufw allow from ${DOCKER_USER_SUBNET} to 192.168.105.10 port 8081 proto tcp comment 'qBittorrent WebUI (Docker User)'

# SABnzbd - TCP port 9020 on Download VLAN IP 192.168.100.10 - Allow Prowlarr and local subnets
echo "Allowing SABnzbd (port 9020/tcp) from Prowlarr and local subnets to 192.168.100.10..."
ufw allow from 192.168.105.9 to 192.168.100.10 port 9020 proto tcp comment 'SABnzbd (Prowlarr)'
ufw allow from ${LOOPYNET_SUBNET} to 192.168.100.10 port 9020 proto tcp comment 'SABnzbd (LoopeyNet)'
ufw allow from ${SPARTANNET_SUBNET} to 192.168.100.10 port 9020 proto tcp comment 'SABnzbd (Spartan-Net)'
ufw allow from ${DOCKER0_SUBNET} to 192.168.100.10 port 9020 proto tcp comment 'SABnzbd (Docker0)'
ufw allow from ${DOCKER_USER_SUBNET} to 192.168.100.10 port 9020 proto tcp comment 'SABnzbd (Docker User)'


# Jackett - TCP port 9117
echo "Allowing Jackett (port 9117/tcp) from specific local subnets to 192.168.105.14..."
ufw allow from ${LOOPYNET_SUBNET} to 192.168.105.14 port 9117 proto tcp comment 'Jackett (LoopeyNet)'
ufw allow from ${SPARTANNET_SUBNET} to 192.168.105.14 port 9117 proto tcp comment 'Jackett (Spartan-Net)'
ufw allow from ${DOCKER0_SUBNET} to 192.168.105.14 port 9117 proto tcp comment 'Jackett (Docker0)'
ufw allow from ${DOCKER_USER_SUBNET} to 192.168.105.14 port 9117 proto tcp comment 'Jackett (Docker User)'

# Prowlarr - TCP port 9696
echo "Allowing Prowlarr (port 9696/tcp) from specific local subnets to 192.168.105.9..."
ufw allow from ${LOOPYNET_SUBNET} to 192.168.105.9 port 9696 proto tcp comment 'Prowlarr (LoopeyNet)'
ufw allow from ${SPARTANNET_SUBNET} to 192.168.105.9 port 9696 proto tcp comment 'Prowlarr (Spartan-Net)'
ufw allow from ${DOCKER0_SUBNET} to 192.168.105.9 port 9696 proto tcp comment 'Prowlarr (Docker0)'
ufw allow from ${DOCKER_USER_SUBNET} to 192.168.105.9 port 9696 proto tcp comment 'Prowlarr WebUI (Docker User)'

# Flaresolverr - TCP port 8191
echo "Allowing Flaresolverr (port 8191/tcp) from specific local subnets to 192.168.105.12..."
ufw allow from ${LOOPYNET_SUBNET} to 192.168.105.12 port 8191 proto tcp comment 'Flaresolverr (LoopeyNet)'
ufw allow from ${SPARTANNET_SUBNET} to 192.168.105.12 port 8191 proto tcp comment 'Flaresolverr (Spartan-Net)'
ufw allow from ${DOCKER0_SUBNET} to 192.168.105.12 port 8191 proto tcp comment 'Flaresolverr (Docker0)'
ufw allow from ${DOCKER_USER_SUBNET} to 192.168.105.12 port 8191 proto tcp comment 'Flaresolverr (Docker User)'

# Firefox - TCP ports 9091 (HTTP) and 9092 (HTTPS)
echo "Allowing Firefox (port 9091/tcp HTTP) from specific local subnets to 192.168.105.13..."
ufw allow from ${LOOPYNET_SUBNET} to 192.168.105.13 port 9091 proto tcp comment 'Firefox HTTP (LoopeyNet)'
ufw allow from ${SPARTANNET_SUBNET} to 192.168.105.13 port 9091 proto tcp comment 'Firefox HTTP (Spartan-Net)'
ufw allow from ${DOCKER0_SUBNET} to 192.168.105.13 port 9091 proto tcp comment 'Firefox HTTP (Docker0)'
ufw allow from ${DOCKER_USER_SUBNET} to 192.168.105.13 port 9091 proto tcp comment 'Firefox HTTP (Docker User)'

echo "Allowing Firefox (port 9092/tcp HTTPS) from specific local subnets to 192.168.105.13..."
ufw allow from ${LOOPYNET_SUBNET} to 192.168.105.13 port 9092 proto tcp comment 'Firefox HTTPS (LoopeyNet)'
ufw allow from ${SPARTANNET_SUBNET} to 192.168.105.13 port 9092 proto tcp comment 'Firefox HTTPS (Spartan-Net)'
ufw allow from ${DOCKER0_SUBNET} to 192.168.105.13 port 9092 proto tcp comment 'Firefox HTTPS (Docker0)'
ufw allow from ${DOCKER_USER_SUBNET} to 192.168.105.13 port 9092 proto tcp comment 'Firefox HTTPS (Docker User)'

# --- Services with WAN Access ---

# Note: SABnzbd and qBittorrent rules are configured above with specific subnet access 

# colonial-monitor - TCP port 8084 (host networking, Nginx might listen on 0.0.0.0:8084)
# Since it's host mode and Nginx might bind to 0.0.0.0, we allow to 'any' host IP from local subnets.
echo "Allowing Colonial Monitor (port 8084/tcp) from specific local subnets to any host IP..."
ufw allow from ${LOOPYNET_SUBNET} to any port 8084 proto tcp comment 'Colonial Monitor (LoopeyNet)'
ufw allow from ${SPARTANNET_SUBNET} to any port 8084 proto tcp comment 'Colonial Monitor (Spartan-Net)'
ufw allow from ${DOCKER0_SUBNET} to any port 8084 proto tcp comment 'Colonial Monitor (Docker0)'
ufw allow from ${DOCKER_USER_SUBNET} to any port 8084 proto tcp comment 'Colonial Monitor (Docker User)'

# Reload UFW to apply changes
echo "Reloading UFW..."
sudo ufw reload

echo "UFW rules updated."
echo "Review the UFW status with: sudo ufw status verbose"