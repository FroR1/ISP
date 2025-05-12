#!/bin/bash

# ISP Configuration Script
# This script configures network interfaces, nftables, hostname, and timezone for an ISP setup.
# Target distribution: ALT Linux (uses /etc/net/ifaces for network configuration).
# Logs actions to /var/log/isp_config.log.

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

# Log file for script actions
LOG_FILE="/var/log/isp_config.log"

# Function to log messages
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
    echo "$1"
}

# Initialize log file
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE" 2>/dev/null || { echo "Error: Cannot create log file at $LOG_FILE." >&2; exit 1; }
fi
chmod 644 "$LOG_FILE" 2>/dev/null || { echo "Error: Cannot set permissions on log file." >&2; exit 1; }

log_message "Starting ISP configuration script..."

# Check for required commands
REQUIRED_COMMANDS=("apt-get" "timedatectl" "systemctl" "nft" "ip")
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        log_message "Error: Required command '$cmd' not found. Please install the necessary package."
        exit 1
    fi
done

# Check and install required packages (nftables, tzdata)
REQUIRED_PACKAGES=("nftables" "tzdata")
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        log_message "Package '$pkg' not found. Attempting to install..."
        apt-get update >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to update package lists."; exit 1; }
        apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to install $pkg."; exit 1; }
        log_message "Package '$pkg' installed successfully."
    fi
done

# Function to calculate network address from IP and mask
get_network() {
    local ip_with_mask=$1
    if ! [[ $ip_with_mask =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        log_message "Error: Invalid IP format: $ip_with_mask"
        return 1
    fi
    local ip=$(echo "$ip_with_mask" | cut -d'/' -f1)
    local prefix=$(echo "$ip_with_mask" | cut -d'/' -f2)
    if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ]; then
        log_message "Error: Invalid prefix: $prefix (must be 0-32)"
        return 1
    fi
    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"
    for oct in $oct1 $oct2 $oct3 $oct4; do
        if [ "$oct" -lt 0 ] || [ "$oct" -gt 255 ]; then
            log_message "Error: Invalid octet: $oct (must be 0-255)"
            return 1
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

# Function to validate IP address format
validate_ip() {
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

# Function to check if timezone exists
check_timezone() {
    local tz=$1
    if ! timedatectl list-timezones > /tmp/tzlist.log 2>>"$LOG_FILE"; then
        log_message "Error: Failed to list timezones with timedatectl."
        return 1
    fi
    if grep -Fxq "$tz" /tmp/tzlist.log; then
        rm -f /tmp/tzlist.log
        return 0
    else
        rm -f /tmp/tzlist.log
        return 1
    fi
}

# Default values
INTERFACE_HQ="ens224"
INTERFACE_BR="ens256"
INTERFACE_OUT="ens192"
IP_HQ="172.16.4.1/28"
IP_BR="172.16.5.1/28"
HOSTNAME="isp"
TIME_ZONE="Asia/Novosibirsk"

# Function to display menu
display_menu() {
    clear
    echo "---------------------"
    echo "ISP Config Menu"
    echo "---------------------"
    echo "1. Enter or edit data"
    echo "2. Configure network interfaces"
    echo "3. Configure nftables (NAT)"
    echo "4. Set hostname"
    echo "5. Set time zone to Asia/Novosibirsk"
    echo "6. Check configuration status"
    echo "7. Remove configurations"
    echo "8. Show help"
    echo "0. Exit"
}

# Function to edit data
edit_data() {
    while true; do
        clear
        echo "Current Data:"
        echo "1. HQ interface: ${INTERFACE_HQ:-Not set}"
        echo "2. BR interface: ${INTERFACE_BR:-Not set}"
        echo "3. Outgoing interface: ${INTERFACE_OUT:-Not set}"
        echo "4. IP for HQ: ${IP_HQ:-Not set}"
        echo "5. IP for BR: ${IP_BR:-Not set}"
        echo "6. Hostname: ${HOSTNAME:-Not set}"
        echo "7. Set time zone"
        echo "8. Enter all new data"
        echo "9. Show network map"
        echo "0. Back to main menu"
        read -p "Select an option: " choice
        case $choice in
            1) read -p "Enter HQ interface name: " INTERFACE_HQ ;;
            2) read -p "Enter BR interface name: " INTERFACE_BR ;;
            3) read -p "Enter outgoing interface name: " INTERFACE_OUT ;;
            4)
                while true; do
                    read -p "Enter IP for HQ (e.g., 172.16.4.1/28): " IP_HQ
                    if validate_ip "$IP_HQ"; then break; else
                        echo "Invalid IP format. Use format like 172.16.4.1/28."
                        read -p "Press Enter to try again..."
                    fi
                done
                ;;
            5)
                while true; do
                    read -p "Enter IP for BR (e.g., 172.16.5.1/28): " IP_BR
                    if validate_ip "$IP_BR"; then break; else
                        echo "Invalid IP format. Use format like 172.16.5.1/28."
                        read -p "Press Enter to try again..."
                    fi
                done
                ;;
            6) read -p "Enter hostname: " HOSTNAME ;;
            7)
                while true; do
                    read -p "Enter time zone (e.g., Asia/Novosibirsk): " TIME_ZONE
                    if check_timezone "$TIME_ZONE"; then
                        timedatectl set-timezone "$TIME_ZONE" >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to set timezone to $TIME_ZONE."; continue; }
                        log_message "Time zone set to $TIME_ZONE."
                        break
                    else
                        echo "Invalid time zone. Use 'timedatectl list-timezones' to see valid options."
                        read -p "Press Enter to try again..."
                    fi
                done
                ;;
            8)
                read -p "Enter HQ interface name: " INTERFACE_HQ
                read -p "Enter BR interface name: " INTERFACE_BR
                read -p "Enter outgoing interface name: " INTERFACE_OUT
                while true; do
                    read -p "Enter IP for HQ (e.g., 172.16.4.1/28): " IP_HQ
                    if validate_ip "$IP_HQ"; then break; else
                        echo "Invalid IP format. Use format like 172.16.4.1/28."
                        read -p "Press Enter to try again..."
                    fi
                done
                while true; do
                    read -p "Enter IP for BR (e.g., 172.16.5.1/28): " IP_BR
                    if validate_ip "$IP_BR"; then break; else
                        echo "Invalid IP format. Use format like 172.16.5.1/28."
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
                read -p "Press Enter to return..."
                ;;
            0) break ;;
            *) echo "Invalid choice."; read -p "Press Enter to continue..." ;;
        esac
    done
}

# Function to configure network interfaces
configure_interfaces() {
    if [ -z "$IP_HQ" ] || [ -z "$IP_BR" ] || [ -z "$INTERFACE_HQ" ] || [ -z "$INTERFACE_BR" ]; then
        log_message "Error: Interface names or IP addresses not set. Please set them in option 1."
        read -p "Press Enter to continue..."
        return 1
    fi

    # Check if interfaces exist
    for iface in "$INTERFACE_HQ" "$INTERFACE_BR"; do
        if ! ip link show "$iface" &>/dev/null; then
            log_message "Error: Interface $iface does not exist."
            read -p "Press Enter to continue..."
            return 1
        fi
        if [ -d "/etc/net/ifaces/$iface" ]; then
            read -p "Configuration for $iface exists. Overwrite? (y/n): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_message "Skipping interface $iface configuration."
                continue
            fi
        fi
    done

    # Configure interfaces (ALT Linux specific: /etc/net/ifaces)
    for iface in "$INTERFACE_HQ" "$INTERFACE_BR"; do
        mkdir -p "/etc/net/ifaces/$iface" >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to create directory for $iface."; return 1; }
        echo -e "BOOTPROTO=static\nTYPE=eth\nDISABLED=no\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$iface/options" 2>>"$LOG_FILE" || { log_message "Error: Failed to write options for $iface."; return 1; }
        if [ "$iface" = "$INTERFACE_HQ" ]; then
            echo "$IP_HQ" > "/etc/net/ifaces/$iface/ipv4address" 2>>"$LOG_FILE" || { log_message "Error: Failed to set IP for $iface."; return 1; }
        elif [ "$iface" = "$INTERFACE_BR" ]; then
            echo "$IP_BR" > "/etc/net/ifaces/$iface/ipv4address" 2>>"$LOG_FILE" || { log_message "Error: Failed to set IP for $iface."; return 1; }
        fi
    done

    # Restart network service (ALT Linux specific)
    systemctl restart network >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to restart network service."; return 1; }
    log_message "Interfaces $INTERFACE_HQ and $INTERFACE_BR configured."
    read -p "Press Enter to continue..."
}

# Function to configure nftables via /etc/nftables/nftables.nft
configure_nftables() {
    if [ -z "$IP_HQ" ] || [ -z "$IP_BR" ] || [ -z "$INTERFACE_OUT" ]; then
        log_message "Error: IP addresses or outgoing interface not set. Please set them in option 1."
        read -p "Press Enter to continue..."
        return 1
    fi

    # Check if outgoing interface exists
    if ! ip link show "$INTERFACE_OUT" &>/dev/null; then
        log_message "Error: Outgoing interface $INTERFACE_OUT does not exist."
        read -p "Press Enter to continue..."
        return 1
    fi

    # Enable IP forwarding
    if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        sed -i '/^net.ipv4.ip_forward/c\net.ipv4.ip_forward = 1' /etc/sysctl.conf 2>>"$LOG_FILE" || { log_message "Error: Failed to modify sysctl.conf."; return 1; }
    elif grep -q "^#net.ipv4.ip_forward" /etc/sysctl.conf; then
        sed -i 's/^#net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf 2>>"$LOG_FILE" || { log_message "Error: Failed to modify sysctl.conf."; return 1; }
    else
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf 2>>"$LOG_FILE" || { log_message "Error: Failed to append to sysctl.conf."; return 1; }
    fi
    sysctl -p >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to apply sysctl settings."; return 1; }

    # Calculate networks for masquerading
    HQ_NETWORK=$(get_network "$IP_HQ") || { log_message "Error: Failed to calculate HQ network."; return 1; }
    BR_NETWORK=$(get_network "$IP_BR") || { log_message "Error: Failed to calculate BR network."; return 1; }
    log_message "HQ Network: $HQ_NETWORK"
    log_message "BR Network: $BR_NETWORK"

    read -p "Proceed with nftables configuration? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_message "nftables configuration skipped."
        read -p "Press Enter to continue..."
        return 0
    fi

    # Enable and start nftables service
    systemctl enable --now nftables >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to enable or start nftables."; return 1; }

    # Create nftables configuration directory
    mkdir -p /etc/nftables >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to create /etc/nftables directory."; return 1; }

    # Write nftables configuration
    cat > /etc/nftables/nftables.nft 2>>"$LOG_FILE" << EOF || { log_message "Error: Failed to write to /etc/nftables/nftables.nft."; return 1; }
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

    chmod 644 /etc/nftables/nftables.nft 2>>"$LOG_FILE" || { log_message "Error: Failed to set permissions on /etc/nftables/nftables.nft."; return 1; }
    systemctl restart nftables >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to restart nftables."; return 1; }
    log_message "nftables configured via /etc/nftables/nftables.nft."
    read -p "Press Enter to continue..."
}

# Function to set hostname
set_hostname() {
    if [ -z "$HOSTNAME" ]; then
        log_message "Error: Hostname not set. Please set it in option 1."
        read -p "Press Enter to continue..."
        return 1
    fi
    echo "$HOSTNAME" > /etc/hostname 2>>"$LOG_FILE" || { log_message "Error: Failed to write to /etc/hostname."; return 1; }
    hostnamectl set-hostname "$HOSTNAME" >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to set hostname."; return 1; }
    log_message "Hostname set to $HOSTNAME."
    read -p "Press Enter to continue..."
}

# Function to set timezone to Asia/Novosibirsk
set_timezone_novosibirsk() {
    local tz="Asia/Novosibirsk"
    if check_timezone "$tz"; then
        timedatectl set-timezone "$tz" >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to set timezone to $tz."; return 1; }
        TIME_ZONE="$tz"
        log_message "Time zone set to $tz."
    else
        log_message "Error: Time zone $tz is invalid. Use 'timedatectl list-timezones' to see valid options."
    fi
    read -p "Press Enter to continue..."
}

# Function to check configuration status
check_config() {
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

# Function to remove configurations with backup
remove_config() {
    local config=$1
    local backup_dir="/etc/isp_backup/$(date +%Y%m%d_%H%M%S)"
    case $config in
        "interfaces")
            mkdir -p "$backup_dir" >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to create backup directory."; return 1; }
            cp -r /etc/net/ifaces/* "$backup_dir/" 2>>"$LOG_FILE"
            rm -rf "/etc/net/ifaces/$INTERFACE_HQ" "/etc/net/ifaces/$INTERFACE_BR" 2>>"$LOG_FILE"
            log_message "Interface configurations removed. Backup created in $backup_dir."
            ;;
        "nftables")
            mkdir -p "$backup_dir" >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to create backup directory."; return 1; }
            cp -r /etc/nftables/* "$backup_dir/" 2>>"$LOG_FILE"
            rm -f /etc/nftables/nftables.nft /etc/nftables/nftables.nft.bak /etc/nftables/nftables.nft.* 2>>"$LOG_FILE"
            systemctl stop nftables >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to stop nftables service."; return 1; }
            log_message "nftables configurations removed. Backup created in $backup_dir."
            ;;
        "time_zone")
            timedatectl set-timezone UTC >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to set timezone to UTC."; return 1; }
            TIME_ZONE="UTC"
            log_message "Time zone reset to UTC."
            ;;
        "hostname")
            echo "localhost" > /etc/hostname 2>>"$LOG_FILE" || { log_message "Error: Failed to write to /etc/hostname."; return 1; }
            hostnamectl set-hostname localhost >> "$LOG_FILE" 2>&1 || { log_message "Error: Failed to set hostname to localhost."; return 1; }
            HOSTNAME="localhost"
            log_message "Hostname reset to localhost."
            ;;
        "all")
            remove_config "interfaces"
            remove_config "nftables"
            remove_config "time_zone"
            remove_config "hostname"
            log_message "All configurations removed."
            ;;
        *) log_message "Invalid option."; return 1 ;;
    esac
}

# Function to display help
show_help() {
    clear
    echo "ISP Configuration Script Help"
    echo "1. Enter or edit data: Modify interface names, IPs, hostname, and time zone."
    echo "2. Configure network interfaces: Set up interfaces with static IPs (ALT Linux specific)."
    echo "3. Configure nftables (NAT): Set up NAT with masquerade for specified networks."
    echo "4. Set hostname: Apply the specified hostname."
    echo "5. Set time zone to Asia/Novosibirsk: Set the system time zone."
    echo "6. Check configuration status: Display the status of all settings."
    echo "7. Remove configurations: Delete configurations with backup."
    echo "8. Show help: Display this help message."
    echo "0. Exit: Exit the script."
    read -p "Press Enter to return to menu..."
}

# Main loop
while true; do
    display_menu
    read -p "Enter your choice: " choice
    case $choice in
        1) edit_data ;;
        2) configure_interfaces ;;
        3) configure_nftables ;;
        4) set_hostname ;;
        5) set_timezone_novosibirsk ;;
        6)
            while true; do
                clear
                echo "Configuration Status:"
                echo "Hostname ---> $(check_config "hostname")"
                echo "Interfaces ---> $(check_config "interfaces")"
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
        0) log_message "Exiting ISP configuration script."; clear; exit 0 ;;
        *) echo "Invalid choice."; read -p "Press Enter to continue..." ;;
    esac
done
