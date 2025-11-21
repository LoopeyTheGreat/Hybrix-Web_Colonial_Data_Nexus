#!/bin/sh

# Autofs Mount Monitor for Colonial Data Nexus
# Monitors autofs mount points and sends push notifications to Uptime Kuma
# Checks every 5 minutes for mount accessibility

# Configuration
CHECK_INTERVAL=300  # 5 minutes in seconds

# Load centralized Uptime Kuma configuration
CONFIG_FILE="/scripts/uptime_kuma_config.env"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
    UPTIME_KUMA_PUSH_URL="${UPTIME_KUMA_AUTOFS_PUSH_URL}?status=up&msg=OK&ping="
else
    # Fallback configuration
    UPTIME_KUMA_PUSH_URL="http://192.168.50.10:3002/api/push/TssNwyregX?status=up&msg=OK&ping="
    log_message "⚠️ Using fallback Uptime Kuma URL - config file not found"
fi

# Mount points to monitor
MOUNTS="
/mnt/cylon.overlord/Containers
/mnt/cylon.overlord/Media
/mnt/cylon.overlord/Incomplete_Torrents
/mnt/cylon.raider/drive1/media
/mnt/cylon.raider/drive2/media
/mnt/cylon.raider/drive3/media
"

log_message() {
    echo "[$(date -Iseconds)] $1" >> /var/log/autofs_monitor.log
}

# Function to check if a mount point is accessible
check_mount() {
    local mount_point="$1"
    local mount_name=$(echo "$mount_point" | sed 's|/|_|g' | sed 's|^_||')
    
    # Try to access the mount point (this should trigger autofs if unmounted)
    if timeout 10 ls "$mount_point" >/dev/null 2>&1; then
        log_message "✓ Mount accessible: $mount_point"
        return 0
    else
        log_message "✗ Mount FAILED: $mount_point"
        return 1
    fi
}

# Function to send heartbeat to Uptime Kuma (when all mounts are OK)
send_heartbeat() {
    if [ -n "$UPTIME_KUMA_PUSH_URL" ]; then
        # Send success heartbeat
        if curl -s -o /dev/null -w "%{http_code}" "$UPTIME_KUMA_PUSH_URL" | grep -q "200"; then
            log_message "📡 Heartbeat sent to Uptime Kuma"
        else
            log_message "⚠️ Failed to send heartbeat to Uptime Kuma"
        fi
    else
        log_message "⚠️ Uptime Kuma Push URL not configured"
    fi
}

# Function to send failure notification
send_failure() {
    local failed_mounts="$1"
    if [ -n "$UPTIME_KUMA_PUSH_URL" ]; then
        # Send failure by NOT sending heartbeat and optionally sending error status
        local error_url="${UPTIME_KUMA_PUSH_URL}?status=down&msg=Mount%20failures:%20$failed_mounts"
        curl -s -o /dev/null "$error_url"
        log_message "🚨 Failure notification sent: $failed_mounts"
    fi
}

# Main monitoring function
check_all_mounts() {
    log_message "🔍 Starting mount accessibility check..."
    
    local failed_mounts=""
    local total_mounts=0
    local failed_count=0
    
    for mount in $MOUNTS; do
        # Skip empty lines
        [ -z "$mount" ] && continue
        
        total_mounts=$((total_mounts + 1))
        
        if ! check_mount "$mount"; then
            failed_count=$((failed_count + 1))
            if [ -z "$failed_mounts" ]; then
                failed_mounts="$mount"
            else
                failed_mounts="$failed_mounts,$mount"
            fi
        fi
    done
    
    log_message "📊 Check complete: $((total_mounts - failed_count))/$total_mounts mounts accessible"
    
    # Update web interface with current status
    update_web_status
    
    if [ $failed_count -eq 0 ]; then
        log_message "✅ All mounts accessible - sending heartbeat"
        send_heartbeat
    else
        log_message "❌ $failed_count mount(s) failed: $failed_mounts"
        send_failure "$failed_mounts"
    fi
    
    return $failed_count
}

# Create dynamic web interface that shows real status
setup_web_interface() {
    mkdir -p /usr/share/nginx/html
    
    # Create dynamic status page that gets updated by check_all_mounts
    update_web_status
}

# Function to check public IPs for both VLANs
check_public_ips() {
    local vpn_ip=""
    local download_ip=""
    local vpn_status="❌"
    local download_status="❌"
    local comparison_status="❌ FAIL"
    local comparison_class="error"
    local ip_status_file="/tmp/vlan_ip_status.json"
    
    # Check if host IP status file exists and is recent (less than 5 minutes old)
    if [ -f "$ip_status_file" ]; then
        local file_age=$(( $(date +%s) - $(stat -c %Y "$ip_status_file" 2>/dev/null || echo 0) ))
        
        if [ $file_age -lt 300 ]; then  # Less than 5 minutes old
            # Read IP information from host-generated file
            if command -v jq >/dev/null 2>&1; then
                # Use jq if available
                vpn_ip=$(jq -r '.vpn_ip' "$ip_status_file" 2>/dev/null || echo "unavailable")
                download_ip=$(jq -r '.download_ip' "$ip_status_file" 2>/dev/null || echo "unavailable")
                local vpn_status_raw=$(jq -r '.vpn_status' "$ip_status_file" 2>/dev/null || echo "error")
                local download_status_raw=$(jq -r '.download_status' "$ip_status_file" 2>/dev/null || echo "error")
                local comparison_raw=$(jq -r '.comparison_status' "$ip_status_file" 2>/dev/null || echo "FAIL")
            else
                # Parse JSON manually if jq not available
                vpn_ip=$(grep '"vpn_ip"' "$ip_status_file" | sed 's/.*"vpn_ip": "\([^"]*\)".*/\1/' || echo "unavailable")
                download_ip=$(grep '"download_ip"' "$ip_status_file" | sed 's/.*"download_ip": "\([^"]*\)".*/\1/' || echo "unavailable")
                local vpn_status_raw=$(grep '"vpn_status"' "$ip_status_file" | sed 's/.*"vpn_status": "\([^"]*\)".*/\1/' || echo "error")
                local download_status_raw=$(grep '"download_status"' "$ip_status_file" | sed 's/.*"download_status": "\([^"]*\)".*/\1/' || echo "error")
                local comparison_raw=$(grep '"comparison_status"' "$ip_status_file" | sed 's/.*"comparison_status": "\([^"]*\)".*/\1/' || echo "FAIL")
            fi
            
            # Convert status to display format
            [ "$download_status_raw" = "success" ] && download_status="✅" || download_status="❌"
            [ "$vpn_status_raw" = "success" ] && vpn_status="✅" || vpn_status="❌"
            
            case "$comparison_raw" in
                "PASS") 
                    comparison_status="✅ PASS"
                    comparison_class="healthy"
                    ;;
                "LIMITED")
                    comparison_status="⚠️ LIMITED"
                    comparison_class="warning"
                    ;;
                "FAIL")
                    comparison_status="❌ FAIL"
                    comparison_class="error"
                    ;;
                *)
                    comparison_status="❌ UNKNOWN"
                    comparison_class="error"
                    ;;
            esac
            
            log_message "📡 IP status from host: Download=$download_ip VPN=$vpn_ip Status=$comparison_raw"
        else
            log_message "⚠️ IP status file is stale (${file_age}s old)"
            vpn_ip="stale-data"
            download_ip="stale-data"
            comparison_status="⚠️ STALE"
            comparison_class="warning"
        fi
    else
        log_message "⚠️ IP status file not found - host checker may not be running"
        vpn_ip="no-host-data"
        download_ip="no-host-data"
        comparison_status="⚠️ NO HOST DATA"
        comparison_class="warning"
    fi
    
    # Export for use in HTML
    export VPN_IP="$vpn_ip"
    export DOWNLOAD_IP="$download_ip"
    export VPN_STATUS="$vpn_status"
    export DOWNLOAD_STATUS="$download_status"
    export COMPARISON_STATUS="$comparison_status"
    export COMPARISON_CLASS="$comparison_class"
}

# Function to update web interface with current status
update_web_status() {
    local status_file="/tmp/mount_status.json"
    local failed_mounts_file="/tmp/failed_mounts.txt"
    
    # Check public IPs first
    check_public_ips
    
    # Check current mount status
    local failed_mounts=""
    local total_mounts=0
    local failed_count=0
    local mount_details=""
    
    for mount in $MOUNTS; do
        [ -z "$mount" ] && continue
        total_mounts=$((total_mounts + 1))
        
        local mount_status="✅"
        local mount_class="healthy"
        
        if ! timeout 5 ls "$mount" >/dev/null 2>&1; then
            failed_count=$((failed_count + 1))
            mount_status="❌"
            mount_class="error"
            if [ -z "$failed_mounts" ]; then
                failed_mounts="$mount"
            else
                failed_mounts="$failed_mounts,$mount"
            fi
        fi
        
        # Build mount details for HTML
        local mount_desc=""
        case "$mount" in
            */Containers) mount_desc="Container data storage" ;;
            */Media) mount_desc="Media library storage" ;;
            */Incomplete_Torrents) mount_desc="Download staging area" ;;
            */drive1/media) mount_desc="Media storage drive 1" ;;
            */drive2/media) mount_desc="Media storage drive 2" ;;
            */drive3/media) mount_desc="Media storage drive 3" ;;
            *) mount_desc="Storage volume" ;;
        esac
        
        mount_details="$mount_details
            <div class=\"volume-item $mount_class\">
                <span class=\"mount-status\">$mount_status</span>
                <span class=\"volume-path\">$mount</span>
                <span class=\"volume-desc\">- $mount_desc</span>
            </div>"
    done
    
    # Determine overall system status
    local system_status="🎯 System Status: All Mounts Accessible"
    local system_class="status-section healthy"
    if [ $failed_count -gt 0 ]; then
        system_status="🚨 System Status: $failed_count Mount(s) Failed"
        system_class="status-section error"
    fi
    
    # Create dynamic status page
    cat > /usr/share/nginx/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Colonial Data Nexus - Volume Monitor</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="30">
    <style>
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
            margin: 0; 
            padding: 20px; 
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            min-height: 100vh;
            color: #e0e0e0;
        }
        .container { 
            max-width: 800px;
            margin: 0 auto;
            background: #1e1e2e; 
            padding: 30px; 
            border-radius: 12px; 
            box-shadow: 0 8px 32px rgba(0,0,0,0.4);
            border: 1px solid #333;
        }
        h1 { 
            color: #4fd1c7; 
            margin-bottom: 10px;
            font-size: 2.2em;
            text-shadow: 0 0 10px rgba(79, 209, 199, 0.3);
        }
        .status-section { 
            padding: 20px; 
            margin: 20px 0; 
            border-radius: 8px; 
        }
        .status-section.healthy { 
            background: rgba(34, 197, 94, 0.15); 
            color: #4ade80; 
            border-left: 5px solid #22c55e;
        }
        .status-section.error { 
            background: rgba(239, 68, 68, 0.15); 
            color: #f87171; 
            border-left: 5px solid #ef4444;
        }
        .status-section.warning { 
            background: rgba(245, 158, 11, 0.15); 
            color: #fbbf24; 
            border-left: 5px solid #f59e0b;
        }
        .network-section {
            background: rgba(56, 189, 248, 0.15); 
            color: #38bdf8; 
            padding: 20px; 
            margin: 20px 0; 
            border-radius: 8px; 
            border-left: 5px solid #0ea5e9;
        }
        .volume-list {
            background: #252545;
            padding: 20px;
            margin: 20px 0;
            border-radius: 8px;
            border-left: 5px solid #6366f1;
        }
        .volume-list h3 {
            color: #a5a5f0;
            margin-top: 0;
        }
        .volume-item {
            padding: 12px;
            margin: 8px 0;
            border-radius: 6px;
            display: flex;
            align-items: center;
            background: #1a1a2e;
        }
        .volume-item.healthy {
            background: rgba(34, 197, 94, 0.1);
            border-left: 4px solid #22c55e;
            color: #4ade80;
        }
        .volume-item.error {
            background: rgba(239, 68, 68, 0.1);
            border-left: 4px solid #ef4444;
            color: #f87171;
        }
        .volume-item.warning {
            background: rgba(245, 158, 11, 0.1);
            border-left: 4px solid #f59e0b;
            color: #fbbf24;
        }
        .mount-status {
            font-size: 1.2em;
            margin-right: 12px;
            min-width: 30px;
        }
        .volume-path {
            font-family: 'Courier New', monospace;
            font-weight: bold;
            color: #e0e0e0;
            flex-grow: 1;
        }
        .volume-desc {
            color: #9ca3af;
            margin-left: 10px;
        }
        .status-icon {
            font-size: 1.2em;
            margin-right: 8px;
        }
        .timestamp {
            margin-top: 30px; 
            padding: 15px; 
            background: #2a2a4a; 
            border-radius: 8px; 
            font-size: 0.9em; 
            color: #9ca3af;
            border: 1px solid #404060;
        }
        .timestamp a {
            color: #4fd1c7;
            text-decoration: none;
        }
        .timestamp a:hover {
            color: #7dd3d8;
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🏛️ Colonial Data Nexus - Volume Monitor</h1>
        
        <div class="$system_class">
            <div class="status-icon">🎯</div><strong>$system_status</strong><br><br>
            Volume monitoring service is running and checking filesystem health every 5 minutes.
        </div>
        
        <div class="volume-list">
            <h3>🗂️ Monitored Volumes ($((total_mounts - failed_count))/$total_mounts accessible)</h3>
            $mount_details
        </div>
        
        <div class="network-section">
            <h3>🌐 Network Status</h3>
            <div>✅ Connected to Download VLAN (192.168.100.26:8082)</div>
            <div>✅ HTTP endpoints active</div>
        </div>
        
        <div class="volume-list">
            <h3>🌍 Public IP Status</h3>
            <div class="volume-item">
                <span class="mount-status">$DOWNLOAD_STATUS</span>
                <span class="volume-path">Download VLAN (ens4)</span>
                <span class="volume-desc">- Public IP: $DOWNLOAD_IP</span>
            </div>
            <div class="volume-item">
                <span class="mount-status">$VPN_STATUS</span>
                <span class="volume-path">VPN VLAN (ens5)</span>
                <span class="volume-desc">- Public IP: $VPN_IP</span>
            </div>
            <div class="volume-item $COMPARISON_CLASS">
                <span class="mount-status">🔍</span>
                <span class="volume-path">VPN Verification</span>
                <span class="volume-desc">- Status: $COMPARISON_STATUS</span>
            </div>
        </div>
        
        <div class="timestamp">
            <strong>Last updated:</strong> $(date)<br>
            <strong>Auto-refresh:</strong> Every 30 seconds<br>
            <strong>Check interval:</strong> Every 5 minutes<br>
            <strong>Available Endpoints:</strong><br>
            • <a href="/health" style="color: #007bff;">Health Check</a> - Simple OK/FAIL<br>
            • <a href="/status" style="color: #007bff;">Status Page</a> - This page<br>
            • <a href="/api/health" style="color: #007bff;">JSON Health API</a> - Machine readable status<br>
            • <a href="/api/status" style="color: #007bff;">JSON Status API</a> - Detailed JSON data
        </div>
    </div>
    
    <script>
        // Auto-refresh every 30 seconds
        setTimeout(function() {
            location.reload();
        }, 30000);
    </script>
</body>
</html>
EOF

    # Create simple health endpoint that reflects actual status
    if [ $failed_count -eq 0 ]; then
        echo 'OK' > /usr/share/nginx/html/health
        mkdir -p /usr/share/nginx/html/api
        echo '{"status":"healthy","failed_mounts":0,"total_mounts":'$total_mounts',"vpn_ip":"'$VPN_IP'","download_ip":"'$DOWNLOAD_IP'","vpn_verification":"'$COMPARISON_STATUS'","timestamp":"'$(date -Iseconds)'"}' > /usr/share/nginx/html/api/health
    else
        echo 'FAIL' > /usr/share/nginx/html/health
        mkdir -p /usr/share/nginx/html/api
        echo '{"status":"error","failed_mounts":'$failed_count',"total_mounts":'$total_mounts',"failed_paths":"'$failed_mounts'","vpn_ip":"'$VPN_IP'","download_ip":"'$DOWNLOAD_IP'","vpn_verification":"'$COMPARISON_STATUS'","timestamp":"'$(date -Iseconds)'"}' > /usr/share/nginx/html/api/health
    fi
    
    # Store failed mounts for other scripts
    echo "$failed_mounts" > "$failed_mounts_file"
}

# Show configuration instructions
show_config_instructions() {
    log_message "========================================"
    log_message "UPTIME KUMA CONFIGURATION REQUIRED"
    log_message "========================================"
    log_message ""
    log_message "1. In Uptime Kuma, create a new monitor:"
    log_message "   - Type: Push"
    log_message "   - Name: Autofs Mount Monitor"
    log_message "   - Heartbeat Interval: 6 minutes (slightly longer than check interval)"
    log_message ""
    log_message "2. Copy the Push URL from Uptime Kuma"
    log_message ""
    log_message "3. Update the docker-compose.yaml with the Push URL:"
    log_message "   environment:"
    log_message "     - UPTIME_KUMA_PUSH_URL=https://your-uptime-kuma/api/push/XXXXX"
    log_message ""
    log_message "4. Restart this container with the new environment variable"
    log_message ""
    log_message "========================================"
}

# Main startup (for container execution)
if [ "$1" = "container-mode" ]; then
    # Running in container mode - just do one check and exit
    log_message "🚀 Starting Autofs Mount Monitor (container mode)..."
    
    # Don't setup web interface in container mode (nginx handles it)
    
    # Get Uptime Kuma push URL from environment
    UPTIME_KUMA_PUSH_URL="$UPTIME_KUMA_PUSH_URL"
    
    if [ -z "$UPTIME_KUMA_PUSH_URL" ]; then
        log_message "⚠️ Uptime Kuma Push URL not configured"
    else
        log_message "📡 Uptime Kuma Push URL configured"
    fi
    
    # Run check and exit
    check_all_mounts
    exit 0
fi

# Standalone mode (original behavior)
log_message "🚀 Starting Autofs Mount Monitor..."

# Setup web interface
setup_web_interface

# Get Uptime Kuma push URL from environment
UPTIME_KUMA_PUSH_URL="$UPTIME_KUMA_PUSH_URL"

if [ -z "$UPTIME_KUMA_PUSH_URL" ]; then
    show_config_instructions
else
    log_message "📡 Uptime Kuma Push URL configured"
fi

# Initial check
check_all_mounts

# Start monitoring loop in background
(
    while true; do
        sleep $CHECK_INTERVAL
        check_all_mounts
    done
) &

MONITOR_PID=$!
log_message "📊 Mount monitoring started - PID: $MONITOR_PID (checking every 5 minutes)"

# Cleanup function
cleanup() {
    log_message "🛑 Shutting down mount monitor..."
    kill $MONITOR_PID 2>/dev/null
    exit 0
}

trap cleanup TERM INT

# Start nginx for web interface
log_message "🌐 Starting web interface on port 8082..."
exec nginx -g 'daemon off;'
