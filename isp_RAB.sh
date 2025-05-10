#!/bin/bash

# Ensure the script is executable
chmod +x "$0" 2>/dev/null

# Check if /bin/bash exists, fallback to /bin/sh if not
if [ ! -f /bin/bash ]; then
    echo "Warning: /bin/bash not found, attempting to use /bin/sh"
    if [ -f /bin/sh ]; then
        exec /bin/sh "$0" "$@"
    else
        echo "Error: No suitable shell found (/bin/bash or /bin/sh)"
        exit 1
    fi
fi

# Global variable declarations
declare -g isp_int1 isp_int2 isp_int3 isp_ip_int2 isp_ip_int3 isp_hostname
declare -g net_int2 net_int3
declare -g interfaces_configured=false nftables_configured=false hostname_configured=false timezone_configured=false
LOG_FILE="/var/log/isp_config.log"

# Function to log messages
log() {
    echo "[$(date)] $1" | tee -a "$LOG_FILE"
}

# Function to display usage instructions
show_usage() {
    echo "Usage: $0"
    echo "The script will prompt you for network interface and configuration details."
    echo "Follow the on-screen instructions."
}

# Function to validate non-empty input
validate_input() {
    if [[ -z "$1" ]]; then
        echo "Error: Field cannot be empty. Please try again."
        return 1
    fi
    return 0
}

# Function to validate IP/subnet format
validate_ip() {
    local ip_subnet=$1
    if [[ ! $ip_subnet =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Error: Invalid IP/subnet format. Use e.g., 192.168.1.1/24."
        return 1
    fi
    local mask=$(echo "$ip_subnet" | awk -F/ '{print $2}')
    if (( mask < 0 || mask > 32 )); then
        echo "Error: Invalid subnet mask. Must be between 0 and 32."
        return 1
    fi
    return 0
}

# Function to validate network interface existence
validate_interface() {
    local iface=$1
    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "Error: Interface $iface does not exist."
        return 1
    fi
    return 0
}

# Function to calculate network address
calculate_network() {
    local ip_subnet=$1
    local ip=$(echo "$ip_subnet" | awk -F/ '{print $1}')
    local mask=$(echo "$ip_subnet" | awk -F/ '{print $2}')
    # Simple calculation for demo purposes (assumes /24 for simplicity)
    local net_addr=$(echo "$ip" | sed 's/\.[0-9]\+$/.0/')
    echo "$net_addr/$mask"
}

# Data collection function
collect_data() {
    show_usage
    
    read -p "Enter the name of the first interface (DHCP): " isp_int1
    while ! validate_input "$isp_int1" || ! validate_interface "$isp_int1"; do
        read -p "Enter the name of the first interface (DHCP): " isp_int1
    done

    read -p "Enter the name of the second interface: " isp_int2
    while ! validate_input "$isp_int2" || ! validate_interface "$isp_int2"; do
        read -p "Enter the name of the second interface: " isp_int2
    done

    read -p "Enter the name of the third interface: " isp_int3
    while ! validate_input "$isp_int3" || ! validate_interface "$isp_int3"; do
        read -p "Enter the name of the third interface: " isp_int3
    done

    read -p "Enter IP/subnet for second interface (e.g., 192.168.1.1/24): " isp_ip_int2
    while ! validate_input "$isp_ip_int2" || ! validate_ip "$isp_ip_int2"; do
        read -p "Enter IP/subnet for second interface (e.g., 192.168.1.1/24): " isp_ip_int2
    done

    read -p "Enter IP/subnet for third interface (e.g., 192.168.2.1/24): " isp_ip_int3
    while ! validate_input "$isp_ip_int3" || ! validate_ip "$isp_ip_int3"; do
        read -p "Enter IP/subnet for third interface (e.g., 192.168.2.1/24): " isp_ip_int3
    done

    read -p "Enter hostname (e.g., myserver): " isp_hostname
    while ! validate_input "$isp_hostname"; do
        read -p "Enter hostname (e.g., myserver): " isp_hostname
    done

    # Calculate networks
    net_int2=$(calculate_network "$isp_ip_int2")
    net_int3=$(calculate_network "$isp_ip_int3")

    # Confirmation
    echo "You entered:"
    echo "First interface (DHCP): $isp_int1"
    echo "Second interface: $isp_int2"
    echo "Third interface: $isp_int3"
    echo "Second interface IP: $isp_ip_int2"
    echo "Third interface IP: $isp_ip_int3"
    echo "Hostname: $isp_hostname"
    echo "Second interface network: $net_int2"
    echo "Third interface network: $net_int3"
    
    read -p "Proceed with these settings? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "Aborting configuration"
        echo "Aborting configuration"
        exit 1
    fi
    log "Configuration data collected successfully"
}

# Interface configuration function
configure_interfaces() {
    if [[ -z "$isp_int2" || -z "$isp_ip_int2" || -z "$isp_int3" || -z "$isp_ip_int3" ]]; then
        echo "Error: Please collect data first (option 1)"
        return 1
    fi

    log "Configuring network interfaces..."
    
    # Clean up previous configurations
    rm -rf "/etc/net/ifaces/$isp_int2" "/etc/net/ifaces/$isp_int3"
    mkdir -p "/etc/net/ifaces/$isp_int2" "/etc/net/ifaces/$isp_int3"

    cat <<EOF > "/etc/net/ifaces/$isp_int2/options"
BOOTPROTO=static
TYPE=eth
DISABLED=no
CONFIG_IPV4=yes
EOF

    cp "/etc/net/ifaces/$isp_int2/options" "/etc/net/ifaces/$isp_int3/options"

    echo "$isp_ip_int2" > "/etc/net/ifaces/$isp_int2/ipv4address"
    echo "$isp_ip_int3" > "/etc/net/ifaces/$isp_int3/ipv4address"

    systemctl restart network || {
        log "Error: Failed to restart network service"
        echo "Error: Failed to restart network service"
        return 1
    }
    interfaces_configured=true
    log "Network interfaces configured successfully"
}

# Time and hostname configuration
configure_time() {
    log "Configuring hostname and timezone..."
    echo "$isp_hostname" > /etc/hostname
    # Set timezone to Asia/Novosibirsk as per exam requirements
    apt-get install -y tzdata && timedatectl set-timezone Asia/Novosibirsk || {
        log "Error: Failed to configure timezone"
        echo "Error: Failed to configure timezone"
        return 1
    }
    hostname_configured=true
    timezone_configured=true
    log "Hostname and timezone configured successfully"
}

# Nftables configuration function
configure_nftables() {
    if [[ -z "$net_int2" || -z "$net_int3" || -z "$isp_int1" ]]; then
        echo "Error: Please collect data first (option 1)"
        return 1
    fi

    log "Configuring nftables..."
    
    # Enable IP forwarding
    sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
    sysctl -p || {
        log "Error: Failed to enable IP forwarding"
        echo "Error: Failed to enable IP forwarding"
        return 1
    }

    # Install nftables
    apt-get update && apt-get install -y nftables || {
        log "Error: Failed to install nftables"
        echo "Error: Failed to install nftables"
        return 1
    }
    systemctl enable --now nftables || {
        log "Error: Failed to enable nftables"
        echo "Error: Failed to enable nftables"
        return 1
    }

    # Explicitly remove the old nftables configuration file
    if [ -f /etc/nftables/nftables.nft ]; then
        rm -f /etc/nftables/nftables.nft
        log "Removed old nftables configuration file"
    fi

    # Create new nftables configuration file with masquerade rules
    cat > /etc/nftables/nftables.nft <<EOF
#!/usr/sbin/nft -f
table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 0; policy accept;
        ip saddr $net_int2 oifname "$isp_int1" counter masquerade
        ip saddr $net_int3 oifname "$isp_int1" counter masquerade
    }
}
EOF
    log "Created new nftables configuration file"

    # Apply nftables rules
    nft -f /etc/nftables/nftables.nft || {
        log "Error: Failed to apply nftables rules"
        echo "Error: Failed to apply nftables rules"
        return 1
    }

    systemctl restart nftables || {
        log "Error: Failed to restart nftables service"
        echo "Error: Failed to restart nftables service"
        return 1
    }
    nftables_configured=true
    log "Nftables configured successfully with masquerade rules for $net_int2 and $net_int3"
}

# Function to check functionality
check_function() {
    log "Checking configuration..."
    if ping -c3 77.88.8.8; then
        log "Ping to 77.88.8.8 successful"
        echo "Ping successful"
    else
        log "Ping to 77.88.8.8 failed"
        echo "Ping failed. Check network configuration."
    fi
    if nft list ruleset; then
        log "Nftables rules listed successfully"
        echo "Nftables rules listed successfully"
    else
        log "Error: Failed to list nftables rules"
        echo "Error: Failed to list nftables rules"
    fi
}

# Function to show configuration status
show_config_status() {
    echo "Configuration Status:"
    echo "Interfaces: $( [[ "$interfaces_configured" == "true" ]] && echo "yes" || echo "no" )"
    echo "Nftables: $( [[ "$nftables_configured" == "true" ]] && echo "yes" || echo "no" )"
    echo "Hostname: $( [[ "$hostname_configured" == "true" ]] && echo "yes" || echo "no" )"
    echo "Timezone: $( [[ "$timezone_configured" == "true" ]] && echo "yes" || echo "no" )"
    log "Displayed configuration status"

    # Prompt for return to menu
    read -p "Enter 0 to return to menu or press Enter: " return_choice
    if [[ "$return_choice" == "0" || -z "$return_choice" ]]; then
        # Do nothing, return to menu automatically
        :
    fi
}

# Menu display function
show_menu() {
    clear
    echo "Menu:"
    echo "1. Collect configuration data"
    echo "2. Configure network interfaces"
    echo "3. Configure hostname and timezone"
    echo "4. Configure Nftables"
    echo "5. Check configuration"
    echo "6. Show configuration status"
    echo "0. Exit"
    read -p "Select an option: " choice
    case $choice in
        1) collect_data ;;
        2) configure_interfaces ;;
        3) configure_time ;;
        4) configure_nftables ;;
        5) check_function ;;
        6) show_config_status ;;
        0) log "Exiting script"; exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
}

# Check for required utilities
check_dependencies() {
    for cmd in ip awk sed; do
        if ! command -v $cmd >/dev/null; then
            log "Error: $cmd is not installed"
            echo "Error: $cmd is not installed"
            exit 1
        fi
    done
}

# Main execution loop
main() {
    check_dependencies
    log "Script started"
    while true; do
        show_menu
    done
}

main
