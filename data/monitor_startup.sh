#!/bin/sh

# Colonial Data Nexus Monitor Startup Script
# Handles proper background process management for container lifecycle

echo "[$(date -Iseconds)] Starting Colonial Data Nexus Monitor..."

# Install curl for health checks and monitoring
apk add --no-cache curl

# Create log directory
mkdir -p /var/log

# Validate Uptime Kuma configuration
echo "[$(date -Iseconds)] Validating Uptime Kuma configuration..."
if [ -f "/scripts/uptime_kuma_config.env" ]; then
    # Source the config and check for placeholder values
    . /scripts/uptime_kuma_config.env
    if echo "$UPTIME_KUMA_VPN_VLAN_PUSH_URL" | grep -q "abc123\|MONITOR_ID"; then
        echo "[$(date -Iseconds)] ⚠️  WARNING: Uptime Kuma config contains placeholder URLs"
        echo "[$(date -Iseconds)] Please update uptime_kuma_config.env with actual push monitor URLs"
        echo "[$(date -Iseconds)] See UPTIME_KUMA_SETUP.md for instructions"
    else
        echo "[$(date -Iseconds)] ✅ Uptime Kuma configuration looks valid"
    fi
else
    echo "[$(date -Iseconds)] ❌ Uptime Kuma config file not found!"
fi

# Function to cleanup background processes on exit
cleanup() {
    echo "[$(date -Iseconds)] Shutting down monitor processes..."
    
    # Kill background monitoring processes
    if [ -n "$AUTOFS_PID" ]; then
        kill $AUTOFS_PID 2>/dev/null
        echo "[$(date -Iseconds)] Stopped autofs monitor (PID: $AUTOFS_PID)"
    fi
    
    if [ -n "$VLAN_PID" ]; then
        kill $VLAN_PID 2>/dev/null
        echo "[$(date -Iseconds)] Stopped VLAN monitor (PID: $VLAN_PID)"
    fi
    
    # Kill any remaining background processes
    jobs -p | xargs -r kill 2>/dev/null
    
    echo "[$(date -Iseconds)] Monitor shutdown complete"
    exit 0
}

# Set up signal handlers for graceful shutdown
trap cleanup TERM INT

# Start autofs monitoring in background (truly silent)
echo "[$(date -Iseconds)] Starting autofs mount monitoring..."
(while true; do 
    /scripts/autofs_monitor.sh container-mode 2>/dev/null 1>/dev/null
    sleep 300
done) &
AUTOFS_PID=$!
echo "[$(date -Iseconds)] Autofs monitor started (PID: $AUTOFS_PID)"

# Start VLAN connectivity monitoring in background (truly silent)
echo "[$(date -Iseconds)] Starting VLAN connectivity monitoring..."
(while true; do 
    /scripts/vlan_connectivity_check.sh 2>/dev/null 1>/dev/null
    sleep 300
done) &
VLAN_PID=$!
echo "[$(date -Iseconds)] VLAN monitor started (PID: $VLAN_PID)"

# Log the monitoring status
echo "[$(date -Iseconds)] Background monitoring active:"
echo "  - Autofs Monitor: PID $AUTOFS_PID (checking every 5 minutes)"
echo "  - VLAN Monitor: PID $VLAN_PID (checking every 5 minutes)"
echo "  - Logs: /var/log/autofs_monitor.log and /tmp/vlan_connectivity.log"
echo "  - Silent operation: No console output from monitors"

# Start nginx in foreground (keeps container running)
echo "[$(date -Iseconds)] Starting nginx web interface..."
exec nginx -g 'daemon off;'
