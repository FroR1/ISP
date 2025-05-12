#!/bin/bash

# Function to log errors and exit Harvest Moon
function log_error() {
    echo "Error: $1" >&2
    exit 1
}

# Check for required commands
for cmd in dpkg apt-get timedatectl systemctl nft ip; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found. Please install the necessary package."
    fi
done

# Check and install tzdata
if ! dpkg -l | grep -q tzdata; then
    echo "Installing tzdata to provide timezone data..."
    apt-get update || log_error "Failed to update package lists."
    apt-get install -y tzdata || log_error "Failed to install tzdata. Please install it manually with 'apt-get install tzdata'."
fi

# Function to calculate network address from IP and mask
function get_network() {
    local ip_with_mask=$1
    if ! [[ $ip_with_mask =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        log_error "Invalid IP format: $ip_with_mask"
    }
    local ip=$(echo "$ip_with_mask" | cut -d'/' -f1)
    local prefix=$(echo "$ip_with_mask" | cut -d'/' -f2)
    if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ]; then
        log_error "Invalid prefix: $prefix (must be 0-32)"
    }
    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"
    for oct in $oct1 $oct2 $oct3 $oct4; do
        if [ "$oct" -lt 0 ] || [ "$oct" -gt 255 ]; then
            log_error "Invalid octet: $oct (must be 0-255)"
        fi
    done
    local ip_num=$(( (oct1 << 24) + (oct2 << 16) + (oct3 << 8) + oct4 ))
    local bits=$((32 - prefix))
    local mask=$(( (0xffffffff << bits) & 0xffffffff ))
    local net_num=$((ip_num & mask))
    local net_oct1=$(( (net_num >> 24) & 0xff ))
    local net_oct2=$(( (net_num >> 16) & 0xff ))
    local net_oct3=$(( (net_num >> 8) & 0xff ))
    local net_oct4=$(( net_num & 0xff ))
    echo "${net_oct1}.${net_oct2}.${net_oct3}.${net_oct4}/${prefix}"
}

# Function to check if timezone exists
function check_timezone() {
    local tz=$1
    if ! timedatectl list-timezones > /tmp/tzlist.log 2>&1; then
        log_error "Failed to list timezones with timedatectl. Check /tmp/tzlist.log for details."
    fi
    if grep -Fxq "$tz" /tmp/tzlist.log; then
        return 0
    else
        return 1
    fi
}

# Function to set timezone to Asia/Novosibirsk
function set_timezone_novosibirsk() {
    local tz="Asia/Novosibirsk"
    if check_timezone "$tz"; then
        timedatectl set-timezone "$tz" || log_error "Failed to set timezone to $tz."
        echo "Time zone set to $tz."
        TIME_ZONE="$tz"
    else
        echo "Time zone $tz is invalid. Use 'timedatectl list-timezones' to see valid options."
    fi
    read -p "Press Enter to continue..."
}

# Function to display menu
function display_menu() {
    clear
    echo "---------------------"
    echo "ISP Config Menu"
    echo "---------------------"
    echo "1. Enter or edit your data"
    echo "2. Configure interfaces (except $INTERFACE_OUT)"
    echo "3. Configure nftables"
    echo "4. Set hostname"
    echo "5. Set time zone to Asia/Novosibirsk"
    echo "6. Check configuration status"
    echo "7. Remove configurations"
    echo "8. Show help"
    echo "0. Exit"
}

# Function to check configuration status
function check_config() {
    local config=$1
    case $config in
        "hostname")
            if [ -f /etc/hostname ] && [ "$(cat /etc/hostname)" = "$HOSTNAME" ]; then
                echo "yes"
            elif [ -f /etc/hostname ]; then
                echo "no"
            else
                echo "error"
            fi
            ;;
        "interfaces")
            if [ -d /etc/net/ifaces/$INTERFACE_HQ ] && [ -d /etc/net/ifaces/$INTERFACE_BR ]; then
                if grep -q "BOOTPROTO=static" /etc/net/ifaces/$INTERFACE_HQ/options && \
                   grep -q "BOOTPROTO=static" /etc/net/ifaces/$INTERFACE_BR/options; then
                    echo "yes"
                else
                    echo "no"
                fi
            else
                echo "error"
            fi
            ;;
        "nftables")
            if systemctl is-active --quiet nftables && nft list ruleset | grep -q "masquerade"; then
                echo "yes"
            elif systemctl is-active --quiet nftables; then
                echo "no"
            else
                echo "not configured"
            fi
            ;;
        "time_zone")
            local current_tz=$(timedatectl show | grep Timezone | cut -d'=' -f2)
            if [ "$current_tz" = "$TIME_ZONE" ]; then
                echo "yes"
            elif [ -n "$current_tz" ]; then
                echo "no"
            else
                echo "not configured"
            fi
            ;;
        *)
            echo "error"
            ;;
    esac
}

# Function to validate IP address format
function validate_ip() {
    local ip_with_mask=$1
    if [[ $ip_with_mask =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local ip=$(echo "$ip_with_mask" | cut -d'/' -f1)
        local prefix=$(echo "$ip_with_mask" | cut -d'/' -f2)
        if [[ $ip =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]; then
            return 0
        fi
    fi
    return 1
}

# Function to display and edit data
function edit_data() {
    while true; do
        clear
        echo "Current Data:"
        echo "1. HQ interface name: ${INTERFACE_HQ:-Not set}"
        echo "2. BR interface name: ${INTERFACE_BR:-Not set}"
        echo "3. Outgoing interface name: ${INTERFACE_OUT:-Not set}"
        echo "4. IP for HQ interface: ${IP_HQ:-Not set}"
        echo "5. IP for BR interface: ${IP_BR:-Not set}"
        echo "6. Hostname: ${HOSTNAME:-Not set}"
        echo "7. Set time zone"
        echo "8. Enter new data"
        echo "9. Show network map"
        echo "0. Back to main menu"
        read -p "Enter the number to edit or 7 to set time zone or 8 to enter new data (0 to exit): " edit_choice
        case $edit_choice in
            1) read -p "Enter new HQ interface name: " INTERFACE_HQ ;;
            2) read -p "Enter new BR interface name: " INTERFACE_BR ;;
            3) read -p "Enter new outgoing interface name: " INTERFACE_OUT ;;
            4)
                while true; do
                    read -p "Enter new IP for HQ interface (e.g., 172.16.2.15/24): " IP_HQ
                    if validate_ip "$IP_HQ"; then break; else
                        echo "Invalid IP format. Use format like 172.16.2.15/24 (octets 0-255, prefix 0-32)."
                        read -p "Press Enter to try again..."
                    fi
                done
                ;;
            5)
                while true; do
                    read -p "Enter new IP for BR interface (e.g., 172.16.33.1/24): " IP_BR
                    if validate_ip "$IP_BR"; then break; else
                        echo "Invalid IP format. Use format like 172.16.33.1/24 (octets 0-255, prefix 0-32)."
                        read -p "Press Enter to try again..."
                    fi
                done
                ;;
            6) read -p "Enter new hostname: " HOSTNAME ;;
            7)
                while true; do
                    read -p "Enter new time zone (e.g., Asia/Novosibirsk): " TIME_ZONE
                    if check_timezone "$TIME_ZONE"; then
                        timedatectl set-timezone "$TIME_ZONE" || log_error "Failed to set timezone to $TIME_ZONE."
                        echo "Time zone set to $TIME_ZONE."
                        break
                    else
                        echo "Invalid time zone: $TIME_ZONE. Use 'timedatectl list-timezones' to see valid options."
                    fi
                    read -p "Press Enter to try again..."
                done
                ;;
            8)
                read -p "Enter HQ interface name: " INTERFACE_HQ
                read -p "Enter BR interface name: " INTERFACE_BR
                read -p "Enter outgoing interface name: " INTERFACE_OUT
                while true; do
                    read -p "Enter IP for HQ interface (e.g., 172.16.2.15/24): " IP_HQ
                    if validate_ip "$IP_HQ"; then break; else
                        echo "Invalid IP format. Use format like 172.16.2.15/24 (octets 0-255, prefix 0-32)."
                        read -p "Press Enter to try again..."
                    fi
                done
                while true; do
                    read -p "Enter IP for BR interface (e.g., 172.16.33.1/24): " IP_BR
                    if validate_ip "$IP_BR"; then break; else
                        echo "Invalid IP format. Use format like 172.16.33.1/24 (octets 0-255, prefix 0-32)."
                        read -p "Press Enter to try again..."
                    fi
                done
                read -p "Enter hostname: " HOSTNAME
                ;;
            9)
                clear
                echo "=== Network Map ==="
                echo "  +----------------+"
                echo "  |   Internet     |"
                echo "  +----------------+"
                echo "          |"
                echo "          | ($INTERFACE_OUT)"
                echo "          |"
                echo "  +----------------+    +----------------+"
                echo "  | $INTERFACE_HQ  |----| $INTERFACE_BR  |"
                echo "  | IP: ${IP_HQ:-Not set}    |    | IP: ${IP_BR:-Not set}    |"
                echo "  +----------------+    +----------------+"
                echo "Press Enter to return..."
                read
                ;;
            0) break ;;
            *) echo "Invalid choice."; read -p "Press Enter to continue..." ;;
        esac
    done
}

# Function to remove configurations with backup
function remove_config() {
    local config=$1
    case $config in
        "interfaces")
            local backup_dir="/etc/isp_backup/$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$backup_dir" || log_error "Failed to create backup directory."
            cp -r /etc/net/ifaces/* "$backup_dir/" 2>/dev/null
            rm -rf "/etc/net/ifaces/$INTERFACE_HQ" "/etc/net/ifaces/$INTERFACE_BR"
            echo "Interface configurations removed. Backup created in $backup_dir/."
            ;;
        "nftables")
            local backup_dir="/etc/isp_backup/$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$backup_dir" || log_error "Failed to create backup directory."
            cp -r /etc/nftables/* "$backup_dir/" 2>/dev/null
            rm -f /etc/nftables/nftables.nft /etc/nftables/nftables.nft.bak /etc/nftables/nftables.nft.*
            systemctl stop nftables || log_error "Failed to stop nftables service."
            echo "nftables configurations removed. Backup created in $backup_dir/."
            ;;
        "time_zone")
            timedatectl set-timezone UTC || log_error "Failed to set timezone to UTC."
            TIME_ZONE="UTC"
            echo "Time zone reset to UTC."
            ;;
        "hostname")
            echo "localhost" > /etc/hostname || log_error "Failed to write to /etc/hostname."
            hostnamectl set-hostname localhost || log_error "Failed to set hostname to localhost."
            HOSTNAME="localhost"
            echo "Hostname reset to localhost."
            ;;
        "all")
            remove_config "interfaces"
            remove_config "nftables"
            remove_config "time_zone"
            remove_config "hostname"
            echo "All configurations removed."
            ;;
        *) echo "Invalid option." ;;
    esac
}

# Function to display help
function show_help() {
    clear
    echo "ISP Configuration Script Help"
    echo "1. Enter or edit your data: Set or modify interface names, IPs, hostname, and time zone."
    echo "2. Configure interfaces: Sets up interfaces (except $INTERFACE_OUT) with static IPs."
    echo "3. Configure nftables: Sets up NAT with masquerade for specified IPs."
    echo "4. Set hostname: Apply the specified hostname."
    echo "5. Set time zone to Asia/Novosibirsk: Sets the system time zone."
    echo "6. Check configuration status: Shows current status of all settings."
    echo "7. Remove configurations: Deletes configurations with backup."
    echo "8. Show help: Displays this help message."
    echo "0. Exit: Exits the script."
    read -p "Press Enter to return to menu..."
}

# Default values
INTERFACE_HQ="ens224"
INTERFACE_BR="ens256"
INTERFACE_OUT="ens192"
IP_HQ="172.16.4.1/28"
IP_BR="172.16.5.1/28"
HOSTNAME="isp"
TIME_ZONE="Asia/Novosibirsk"

# Main loop
while true; do
    display_menu
    read -p "Enter your choice: " choice
    case $choice in
        1) edit_data ;;
        2)
            if [ -z "$IP_HQ" ] || [ -z "$IP_BR" ]; then
                echo "IP addresses not set. Please set them in option 1 first."
                read -p "Press Enter to continue..."
                continue
            fi
            for iface in "$INTERFACE_HQ" "$INTERFACE_BR"; do
                if ! ip link show "$iface" &>/dev/null; then
                    log_error "Interface $iface does not exist. Please check your configuration."
                fi
                if [ -d "/etc/net/ifaces/$iface" ]; then
                    read -p "Configuration for $iface exists. Overwrite? (y/n): " confirm
                    [[ ! "$confirm" =~ ^[Yy]$ ]] && continue
                fi
            done
            apt-get update || log_error "Failed to update package lists."
            apt-get install -y nftables tzdata || log_error "Failed to install required packages."
            for iface in "$INTERFACE_HQ" "$INTERFACE_BR"; do
                mkdir -p "/etc/net/ifaces/$iface" || log_error "Failed to create directory for $iface."
                echo -e "BOOTPROTO=static\nTYPE=eth\nDISABLED=no\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$iface/options" || log_error "Failed to write options for $iface."
                if [ "$iface" = "$INTERFACE_HQ" ]; then
                    echo "$IP_HQ" > "/etc/net/ifaces/$iface/ipv4address" || log_error "Failed to set IP for $iface."
                elif [ "$iface" = "$INTERFACE_BR" ]; then
                    echo "$IP_BR" > "/etc/net/ifaces/$iface/ipv4address" || log_error "Failed to set IP for $iface."
                fi
            done
            systemctl restart network || log_error "Failed to restart network service."
            echo "Interfaces configured."
            read -p "Press Enter to continue..."
            ;;
        3)
            if [ -z "$IP_HQ" ] || [ -z "$IP_BR" ]; then
                echo "IP addresses not set. Please set them in option 1 first."
                read -p "Press Enter to continue..."
                continue
            fi
            if ! ip link show "$INTERFACE_OUT" &>/dev/null; then
                log_error "Outgoing interface $INTERFACE_OUT does not exist. Please check your configuration."
            fi
            if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
                sed -i '/^net.ipv4.ip_forward/c\net.ipv4.ip_forward = 1' /etc/sysctl.conf || log_error "Failed to modify sysctl.conf."
            elif grep -q "^#net.ipv4.ip_forward" /etc/sysctl.conf; then
                sed -i 's/^#net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf || log_error "Failed to modify sysctl.conf."
            else
                echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf || log_error "Failed to append to sysctl.conf."
            fi
            sysctl -p || log_error "Failed to apply sysctl settings."
            HQ_NETWORK=$(get_network "$IP_HQ") || log_error "Failed to calculate HQ network."
            BR_NETWORK=$(get_network "$IP_BR") || log_error "Failed to calculate BR network."
            echo "The following network addresses will be used for masquerading:"
            echo "HQ Network: $HQ_NETWORK"
            echo "BR Network: $BR_NETWORK"
            read -p "Proceed with nftables configuration? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                systemctl enable --now nftables || log_error "Failed to enable or start nftables."
                # Create the directory if it doesn't exist
                mkdir -p /etc/nftables || log_error "Failed to create /etc/nftables directory."
                # Flush existing rules
                nft flush ruleset || log_error "Failed to flush nftables ruleset."
                # Write the nftables configuration to /etc/nftables/nftables.nft
                cat > /etc/nftables/nftables.nft << EOF || log_error "Failed to write to /etc/nftables/nftables.nft."
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 0; policy accept;
        ip saddr $HQ_NETWORK oifname "$INTERFACE_OUT" counter masquerade
        ip saddr $BR_NETWORK oifname "$INTERFACE_OUT" counter masquerade
    }
}
EOF
                # Set proper permissions for the file
                chmod 644 /etc/nftables/nftables.nft || log_error "Failed to set permissions on /etc/nftables/nftables.nft."
                # Reload the nftables service to apply the new configuration
                systemctl restart nftables || log_error "Failed to restart nftables."
                echo "nftables configured via /etc/nftables/nftables.nft."
            else
                echo "nftables configuration skipped."
            fi
            read -p "Press Enter to continue..."
            ;;
        4)
            if [ -z "$HOSTNAME" ]; then
                echo "Hostname not set. Please set it in option 1 first."
                read -p "Press Enter to continue..."
                continue
            fi
            echo "$HOSTNAME" > /etc/hostname || log_error "Failed to write to /etc/hostname."
            hostnamectl set-hostname "$HOSTNAME" || log_error "Failed to set hostname."
            echo "Hostname set to $HOSTNAME."
            read -p "Press Enter to continue..."
            ;;
        5) set_timezone_novosibirsk ;;
        6)
            while true; do
                clear
                echo "Configuration Status:"
                echo "Hostname ---> $(check_config "hostname")"
                echo "Interfaces (except $INTERFACE_OUT) ---> $(check_config "interfaces")"
                echo "nftables ---> $(check_config "nftables")"
                echo "Time Zone ---> $(check_config "time_zone")"
                echo "0. Back to menu"
                read -p "Enter your choice: " sub_choice
                [ "$sub_choice" = "0" ] && break
                echo "Invalid choice. Press 0 to go back."
                read -p "Press Enter to continue..."
            done
            ;;
        7)
            while true; do
                clear
                echo "Remove Configurations Menu"
                echo "1. Remove interface configurations"
                echo "2. Remove nftables configurations"
                echo "3. Remove time zone configuration"
                echo "4. Remove hostname configuration"
                echo "5. Remove all configurations"
                echo "0. Back to main menu"
                read -p "Enter your choice: " remove_choice
                case $remove_choice in
                    1) remove_config "interfaces"; read -p "Press Enter to continue..." ;;
                    2) remove_config "nftables"; read -p "Press Enter to continue..." ;;
                    3) remove_config "time_zone"; read -p "Press Enter to continue..." ;;
                    4) remove_config "hostname"; read -p "Press Enter to continue..." ;;
                    5) remove_config "all"; read -p "Press Enter to continue..." ;;
                    0) break ;;
                    *) echo "Invalid choice."; read -p "Press Enter to continue..." ;;
                esac
            done
            ;;
        8) show_help ;;
        0) clear; exit 0 ;;
        *) echo "Invalid choice."; read -p "Press Enter to continue..." ;;
    esac
done
