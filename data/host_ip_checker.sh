#!/bin/bash

# Host IP Checker - Runs on host to check VPN and Download VLAN IPs
# Writes results to file that container can read

OUTPUT_FILE="/tmp/vlan_ip_status.json"
LOG_FILE="/tmp/host_ip_checker.log"

log_message() {
    echo "[$(date -Iseconds)] $1" | tee -a "$LOG_FILE"
}

check_vlan_ips() {
    local vpn_ip=""
    local download_ip=""
    local vpn_status="error"
    local download_status="error"
    local comparison_status="FAIL"
    
    log_message "🔍 Checking VLAN public IPs..."
    
    # Check Download VLAN IP (ens4 interface)
    log_message "📡 Checking Download VLAN (ens4)..."
    download_ip=$(timeout 10 curl -s --interface ens4 --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$download_ip" ] && [[ "$download_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        download_status="ok"
        log_message "✅ Download VLAN IP: $download_ip"
    else
        download_ip="unavailable"
        log_message "❌ Download VLAN IP failed"
    fi
    
    # Check VPN VLAN IP (ens5 interface)
    log_message "📡 Checking VPN VLAN (ens5)..."
    vpn_ip=$(timeout 10 curl -s --interface ens5 --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$vpn_ip" ] && [[ "$vpn_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        vpn_status="ok"
        log_message "✅ VPN VLAN IP: $vpn_ip"
    else
        vpn_ip="unavailable"
        log_message "❌ VPN VLAN IP failed"
    fi
    
    # Compare IPs (VPN working if IPs are different)
    if [ "$vpn_status" = "ok" ] && [ "$download_status" = "ok" ] && [ "$vpn_ip" != "$download_ip" ]; then
        comparison_status="PASS"
        log_message "✅ VPN verification PASS: IPs are different ($vpn_ip != $download_ip)"
    elif [ "$vpn_status" = "ok" ] && [ "$download_status" = "ok" ] && [ "$vpn_ip" = "$download_ip" ]; then
        comparison_status="FAIL-SAME"
        log_message "❌ VPN verification FAIL: IPs are the same ($vpn_ip = $download_ip)"
    else
        comparison_status="FAIL-UNAVAILABLE"
        log_message "❌ VPN verification FAIL: One or both IPs unavailable"
    fi
    
    # Write results to JSON file
    cat > "$OUTPUT_FILE" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "vpn_ip": "$vpn_ip",
    "download_ip": "$download_ip",
    "vpn_status": "$vpn_status",
    "download_status": "$download_status",
    "comparison_status": "$comparison_status",
    "vpn_working": $([ "$comparison_status" = "PASS" ] && echo "true" || echo "false")
}
EOF
    
    log_message "📝 Results written to $OUTPUT_FILE"
}

# Run the check
check_vlan_ips

# If run with --loop, keep checking every 2 minutes
if [ "$1" = "--loop" ]; then
    log_message "🔄 Starting continuous monitoring (every 2 minutes)..."
    while true; do
        sleep 120  # 2 minutes
        check_vlan_ips
    done
fi
