#!/bin/bash

# Define the JSON content
JSON_CONTENT='{
  "bip": "172.17.0.1/24",
  "default-address-pools": [
    {"base": "172.25.0.0/20", "size": 24}
  ],
  "dns": ["192.168.50.10", "192.168.50.20", "1.1.1.1", "1.0.0.3"],
  "dns-opts": ["ndots:2", "timeout:2", "attempts:2"],
  "dns-search": [],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5",
    "compress": "true"
  },
  "storage-driver": "overlay2",
  "live-restore": false,
  "features": {
    "buildkit": true
  },
  "ipv6": false,
  "iptables": true,
  "ip6tables": false,
  "experimental": false,
  "max-concurrent-downloads": 5,
  "max-concurrent-uploads": 3,
  "shutdown-timeout": 30
}'

DAEMON_JSON_FILE="/etc/docker/daemon.json"
DOCKER_DIR=$(dirname "$DAEMON_JSON_FILE")

echo ">>> Removing DNS search domain from network interfaces..."

# Remove or comment out dns-search from /etc/network/interfaces
INTERFACES_FILE="/etc/network/interfaces"
if [ -f "$INTERFACES_FILE" ]; then
  echo "Checking for dns-search entries in $INTERFACES_FILE..."
  
  # Check if dns-search loopey.net exists
  if grep -q "^\s*dns-search\s*loopey\.net" "$INTERFACES_FILE"; then
    echo "Found dns-search loopey.net in $INTERFACES_FILE. Commenting it out..."
    
    # Create a backup
    sudo cp "$INTERFACES_FILE" "${INTERFACES_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Comment out the dns-search line
    sudo sed -i 's/^\(\s*\)dns-search\s*loopey\.net/\1# dns-search loopey.net # Commented out by Docker networking script/' "$INTERFACES_FILE"
    
    if [ $? -eq 0 ]; then
      echo "Successfully commented out dns-search loopey.net in $INTERFACES_FILE"
      echo "A backup was created at ${INTERFACES_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
      
      # Note: Network interface changes require a reboot or interface restart to take effect
      echo "NOTE: Network interface changes will take effect after next reboot or interface restart."
    else
      echo "ERROR: Failed to modify $INTERFACES_FILE"
      exit 1
    fi
  else
    echo "No problematic dns-search entries found in $INTERFACES_FILE"
  fi
else
  echo "WARNING: $INTERFACES_FILE not found"
fi

echo ">>> Configuring Docker daemon settings..."

# Create the directory /etc/docker if it doesn't exist
if [ ! -d "$DOCKER_DIR" ]; then
  echo "Creating directory $DOCKER_DIR..."
  sudo mkdir -p "$DOCKER_DIR"
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create directory $DOCKER_DIR. Exiting."
    exit 1
  fi
  echo "Directory $DOCKER_DIR created successfully."
else
  echo "Directory $DOCKER_DIR already exists."
fi

# Write the JSON content to /etc/docker/daemon.json
echo "Writing configuration to $DAEMON_JSON_FILE..."
echo "$JSON_CONTENT" | sudo tee "$DAEMON_JSON_FILE" > /dev/null
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to write to $DAEMON_JSON_FILE. Exiting."
  exit 1
fi
echo "Configuration written to $DAEMON_JSON_FILE successfully."

# Restart the Docker service
echo "Restarting Docker service..."
sudo systemctl restart docker
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to restart Docker service. Please check Docker status."
  # Attempt to show Docker status for diagnostics
  sudo systemctl status docker --no-pager
  exit 1
fi

echo "Docker service restarted successfully."
echo ">>> Docker daemon configuration complete."

echo ""
echo "=== NEXT STEPS ==="
echo "1. The dns-search entry has been removed from /etc/network/interfaces"
echo "2. For network changes to take full effect, consider restarting the network interface:"
echo "   sudo ifdown ens3 && sudo ifup ens3"
echo "3. Or reboot the system for all changes to take effect"
echo "4. Deploy this script to all Docker Swarm nodes"
echo "5. Test Docker Swarm services to verify external domain resolution"
echo ""

exit 0