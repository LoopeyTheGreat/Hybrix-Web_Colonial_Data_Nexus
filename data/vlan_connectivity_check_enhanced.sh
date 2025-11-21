#!/bin/bash

# VLAN Connectivity Monitor Script with VPN IP Verification
# Tests connectivity on each VLAN interface and verifies VPN is working by comparing public IPs
# Reports to Uptime Kuma with detailed VPN status

# Configuration
LOG_FILE="/tmp/vlan_connectivity.log"

# Load centralized Uptime Kuma configuration
CONFIG_FILE="/scripts/uptime_kuma_config.env"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
    # Use the VPN verification URL as the base for all VLAN monitoring
    UPTIME_KUMA_BASE_PUSH_URL="${UPTIME_KUMA_VPN_VERIFICATION_PUSH_URL}"
else
    # Fallback configuration
    log_message "⚠️ Using fallback Uptime Kuma URLs - config file not found"
    UPTIME_KUMA_BASE_PUSH_URL=""
fi

# VLAN Interface Configuration
VPN_INTERFACE="ens5"
VPN_IP="192.168.105.10"
DOWNLOAD_INTERFACE="ens4"
DOWNLOAD_IP="192.168.100.10"
MAIN_INTERFACE="ens3"
MAIN_IP="192.168.50.10"

# Test endpoints for public IP detection
IP_CHECK_SERVICES=("icanhazip.com" "ipinfo.io/ip" "api.ipify.org")
DNS_TEST_TARGET="1.1.1.1"

# Function to log with timestamp
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to get public IP via specific interface
get_public_ip() {
    local interface=$1
    local vlan_name=$2
    
    for service in "${IP_CHECK_SERVICES[@]}"; do
        local public_ip=$(timeout 15 curl -s --interface "$interface" "https://$service" 2>/dev/null | tr -d '\n' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
        
        if [ -n "$public_ip" ] && [[ "$public_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_message "✅ $vlan_name: Public IP detected via $service: $public_ip"
            echo "$public_ip"
            return 0
        fi
    done
    
    log_message "❌ $vlan_name: Failed to detect public IP from all services"
    echo "failed"
    return 1
}

# Function to test interface connectivity
test_interface() {
    local interface=$1
    local interface_ip=$2
    local vlan_name=$3
    local success=0
    local error_msg=""
    
    log_message "Testing $vlan_name VLAN ($interface - $interface_ip)"
    
    # Test 1: Interface is up and has IP
    if ! ip addr show "$interface" | grep -q "inet $interface_ip"; then
        error_msg="❌ Interface $interface does not have IP $interface_ip"
        log_message "$error_msg"
        echo "$error_msg"
        return 1
    fi
    log_message "✅ $vlan_name: Interface UP with correct IP"
    ((success++))
    
    # Test 2: HTTP connectivity test
    local test_service="${IP_CHECK_SERVICES[0]}"
    if timeout 15 curl -s --interface "$interface" "https://$test_service" >/dev/null 2>&1; then
        log_message "✅ $vlan_name: HTTP connectivity successful"
        ((success++))
    else
        error_msg="❌ $vlan_name: HTTP connectivity failed"
        log_message "$error_msg"
    fi
    
    # Test 3: DNS resolution test
    if timeout 10 curl -s --interface "$interface" "https://$DNS_TEST_TARGET" >/dev/null 2>&1; then
        log_message "✅ $vlan_name: DNS resolution successful"
        ((success++))
    else
        log_message "⚠️ $vlan_name: DNS resolution failed (may still work for public IP)"
    fi
    
    # Return status based on success count (need at least interface + HTTP)
    if [ $success -ge 2 ]; then
        log_message "✅ $vlan_name: Overall connectivity GOOD ($success/3 tests passed)"
        return 0
    else
        log_message "❌ $vlan_name: Overall connectivity FAILED ($success/3 tests passed)"
        echo "$error_msg"
        return 1
    fi
}

# Function to compare VPN vs Download public IPs
verify_vpn_functionality() {
    log_message "🔍 Starting VPN functionality verification..."
    
    # Get public IP from Download VLAN (normal internet)
    local download_ip=$(get_public_ip "$DOWNLOAD_INTERFACE" "Download")
    
    # Get public IP from VPN VLAN (should be different if VPN is working)
    local vpn_ip=$(get_public_ip "$VPN_INTERFACE" "VPN")
    
    # Store IPs for reporting
    DOWNLOAD_PUBLIC_IP="$download_ip"
    VPN_PUBLIC_IP="$vpn_ip"
    
    if [ "$download_ip" = "failed" ] && [ "$vpn_ip" = "failed" ]; then
        log_message "❌ VPN Verification: Both VLANs failed to get public IP"
        VPN_STATUS="critical"
        VPN_MESSAGE="Both VPN and Download VLANs cannot reach internet"
        return 2
    elif [ "$download_ip" = "failed" ]; then
        log_message "❌ VPN Verification: Download VLAN cannot get public IP"
        VPN_STATUS="warning"
        VPN_MESSAGE="Download VLAN internet issues, VPN IP: $vpn_ip"
        return 1
    elif [ "$vpn_ip" = "failed" ]; then
        log_message "❌ VPN Verification: VPN VLAN cannot get public IP"
        VPN_STATUS="down"
        VPN_MESSAGE="VPN VLAN no internet access, Download IP: $download_ip"
        return 1
    elif [ "$download_ip" = "$vpn_ip" ]; then
        log_message "🚨 VPN Verification: CRITICAL - VPN and Download show SAME public IP!"
        log_message "   Download VLAN IP: $download_ip"
        log_message "   VPN VLAN IP: $vpn_ip"
        log_message "   This indicates VPN is NOT working properly!"
        VPN_STATUS="down"
        VPN_MESSAGE="VPN FAILED: Same IP as Download ($download_ip) - VPN not protecting traffic!"
        return 1
    else
        log_message "✅ VPN Verification: SUCCESS - Different public IPs detected"
        log_message "   Download VLAN IP: $download_ip"
        log_message "   VPN VLAN IP: $vpn_ip"
        log_message "   VPN is working correctly!"
        VPN_STATUS="up"
        VPN_MESSAGE="VPN Working: Download($download_ip) vs VPN($vpn_ip)"
        return 0
    fi
}

# Function to send status to Uptime Kuma
send_uptime_kuma_status() {
    local monitor_name=$1
    local status=$2
    local message=$3
    local push_url=""
    
    # Select appropriate push URL based on monitor name
    case "$monitor_name" in
        "download-vlan")
            push_url="$UPTIME_KUMA_DOWNLOAD_VLAN_PUSH_URL"
            ;;
        "vpn-vlan")
            push_url="$UPTIME_KUMA_VPN_VLAN_PUSH_URL"
            ;;
        "main-lan")
            push_url="$UPTIME_KUMA_MAIN_LAN_PUSH_URL"
            ;;
        "vpn-verification")
            push_url="$UPTIME_KUMA_VPN_VERIFICATION_PUSH_URL"
            ;;
        "vlan-overall")
            push_url="$UPTIME_KUMA_OVERALL_PUSH_URL"
            ;;
        *)
            log_message "⚠️ Unknown monitor name: $monitor_name"
            return 1
            ;;
    esac
    
    if [ -n "$push_url" ]; then
        local encoded_msg=$(echo "$message" | sed 's/ /%20/g' | sed 's/!/%21/g' | sed 's/(/%28/g' | sed 's/)/%29/g')
        
        if [ "$status" = "up" ]; then
            curl -s "$push_url?status=up&msg=$encoded_msg" >/dev/null 2>&1
        else
            curl -s "$push_url?status=down&msg=$encoded_msg" >/dev/null 2>&1
        fi
        log_message "📡 Sent $status status to Uptime Kuma for $monitor_name: $message"
    else
        log_message "⚠️ No push URL configured for $monitor_name"
    fi
}

# Main monitoring function
main() {
    log_message "🔍 Starting Enhanced VLAN connectivity check with VPN verification"
    
    local overall_status="up"
    local failed_vlans=""
    local vpn_connectivity_ok=false
    local download_connectivity_ok=false
    
    # Test Download VLAN first
    if test_interface "$DOWNLOAD_INTERFACE" "$DOWNLOAD_IP" "Download"; then
        send_uptime_kuma_status "download-vlan" "up" "Download VLAN connectivity OK"
        download_connectivity_ok=true
    else
        send_uptime_kuma_status "download-vlan" "down" "Download VLAN connectivity FAILED"
        overall_status="down"
        failed_vlans="$failed_vlans Download"
    fi
    
    # Test VPN VLAN
    if test_interface "$VPN_INTERFACE" "$VPN_IP" "VPN"; then
        send_uptime_kuma_status "vpn-vlan" "up" "VPN VLAN connectivity OK"
        vpn_connectivity_ok=true
    else
        send_uptime_kuma_status "vpn-vlan" "down" "VPN VLAN connectivity FAILED"
        overall_status="down"
        failed_vlans="$failed_vlans VPN"
    fi
    
    # Test Main LAN (optional - for completeness)
    if test_interface "$MAIN_INTERFACE" "$MAIN_IP" "Main"; then
        send_uptime_kuma_status "main-lan" "up" "Main LAN connectivity OK"
    else
        send_uptime_kuma_status "main-lan" "down" "Main LAN connectivity FAILED"
        # Don't fail overall status for main LAN issues
    fi
    
    # VPN Functionality Verification (only if both VLANs have basic connectivity)
    if [ "$vpn_connectivity_ok" = true ] || [ "$download_connectivity_ok" = true ]; then
        log_message "🔒 Performing VPN functionality verification..."
        verify_vpn_functionality
        vpn_check_result=$?
        
        # Send VPN verification status to Uptime Kuma
        send_uptime_kuma_status "vpn-verification" "$VPN_STATUS" "$VPN_MESSAGE"
        
        # Add VPN status to overall report
        if [ $vpn_check_result -ne 0 ]; then
            if [ "$VPN_STATUS" = "critical" ]; then
                overall_status="down"
                failed_vlans="$failed_vlans VPN-Critical"
            elif [ "$VPN_STATUS" = "down" ]; then
                overall_status="down"
                failed_vlans="$failed_vlans VPN-NotWorking"
            fi
        fi
        
        # Detailed logging
        log_message "📊 Public IP Summary:"
        log_message "   Download VLAN Public IP: ${DOWNLOAD_PUBLIC_IP:-unknown}"
        log_message "   VPN VLAN Public IP: ${VPN_PUBLIC_IP:-unknown}"
        log_message "   VPN Status: $VPN_STATUS"
        
    else
        log_message "⚠️ Skipping VPN verification - no VLAN connectivity"
        send_uptime_kuma_status "vpn-verification" "down" "Cannot verify VPN - no VLAN connectivity"
        overall_status="down"
    fi
    
    # Overall status report
    if [ "$overall_status" = "up" ]; then
        local success_msg="All VLANs operational, VPN working correctly"
        if [ -n "$VPN_PUBLIC_IP" ] && [ -n "$DOWNLOAD_PUBLIC_IP" ]; then
            success_msg="$success_msg (Download:${DOWNLOAD_PUBLIC_IP}, VPN:${VPN_PUBLIC_IP})"
        fi
        log_message "🎉 All VLAN connectivity tests PASSED with VPN verification"
        send_uptime_kuma_status "vlan-overall" "up" "$success_msg"
    else
        log_message "⚠️ VLAN connectivity issues detected:$failed_vlans"
        send_uptime_kuma_status "vlan-overall" "down" "VLAN issues:$failed_vlans"
    fi
    
    log_message "✅ Enhanced VLAN connectivity check complete"
    echo "VLAN Check Complete - See $LOG_FILE for details"
}

# Run the check
main "$@"
