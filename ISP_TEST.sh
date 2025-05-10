#!/bin/bash

# Note: Before running this script, ensure that the ens192 interface is manually configured
# to have internet access for downloading this script.

# Function to calculate network address from IP and mask
function get_network() {
    local ip=$1
    local mask=$2
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    IFS='.' read -r m1 m2 m3 m4 <<< "$mask"
    printf "%d.%d.%d.%d" \
        $((i1 & m1)) \
        $((i2 & m2)) \
        $((i3 & m3)) \
        $((i4 & m4))
}

# Function to display the main menu
function display_menu() {
    clear
    echo "ISP Configuration Menu"
    echo "1. Enter your data"
    echo "2. Configure interfaces (except ens192)"
    echo "3. Configure nftables"
    echo "4. Set time zone"
    echo "5. Set hostname"
    echo "6. Check configuration status"
    echo "7. Remove configurations"
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
            if timedatectl show | grep -q "TimeZone=$TIME_ZONE"; then
                echo "yes"
            elif timedatectl show | grep -q "TimeZone"; then
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

# Function to display and edit data
function edit_data() {
    while true; do
        clear
        echo "Entered Data:"
        echo "1. HQ interface name: $INTERFACE_HQ"
        echo "2. BR interface name: $INTERFACE_BR"
        echo "3. IP for HQ interface: $IP_HQ"
        echo "4. IP for BR interface: $IP_BR"
        echo "5. Hostname: $HOSTNAME"
        echo "6. Time zone: $TIME_ZONE"
        echo "0. Back to main menu"
        read -p "Enter the number to edit (0 to exit): " edit_choice
        case $edit_choice in
            1)
                read -p "Enter new HQ interface name: " INTERFACE_HQ
                ;;
            2)
                read -p "Enter new BR interface name: " INTERFACE_BR
                ;;
            3)
                read -p "Enter new IP for HQ interface (e.g., 172.16.4.1/28): " IP_HQ
                ;;
            4)
                read -p "Enter new IP for BR interface (e.g., 172.16.5.1/28): " IP_BR
                ;;
            5)
                read -p "Enter new hostname: " HOSTNAME
                ;;
            6)
                read -p "Enter new time zone (e.g., Asia/Novosibirsk): " TIME_ZONE
                ;;
            0)
                break
                ;;
            *)
                echo "Invalid choice. Please try again."
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Function to remove configurations
function remove_config() {
    local config=$1
    case $config in
        "interfaces")
            rm -rf /etc/net/ifaces/$INTERFACE_HQ
            rm -rf /etc/net/ifaces/$INTERFACE_BR
            echo "Interface configurations removed."
            ;;
        "nftables")
            nft flush ruleset
            rm -f /etc/nftables/nftables.nft
            systemctl stop nftables
            echo "nftables configurations removed."
            ;;
        "time_zone")
            timedatectl set-timezone UTC  # Reset to UTC
            echo "Time zone reset to UTC."
            ;;
        "hostname")
            echo "localhost" > /etc/hostname
            hostnamectl set-hostname localhost
            echo "Hostname reset to localhost."
            ;;
        "all")
            remove_config "interfaces"
            remove_config "nftables"
            remove_config "time_zone"
            remove_config "hostname"
            echo "All configurations removed."
            ;;
        *)
            echo "Invalid option."
            ;;
    esac
}

# Default values
INTERFACE_HQ="ens224"
INTERFACE_BR="ens256"
IP_HQ="172.16.4.1/28"
IP_BR="172.16.5.1/28"
HOSTNAME="isp"
TIME_ZONE="Asia/Novosibirsk"

# Main loop
while true; do
    display_menu
    read -p "Enter your choice: " choice
    case $choice in
        1)
            read -p "Enter HQ interface name: " INTERFACE_HQ
            read -p "Enter BR interface name: " INTERFACE_BR
            read -p "Enter IP for HQ interface (e.g., 172.16.4.1/28): " IP_HQ
            read -p "Enter IP for BR interface (e.g., 172.16.5.1/28): " IP_BR
            read -p "Enter hostname: " HOSTNAME
            read -p "Enter time zone (e.g., Asia/Novosibirsk): " TIME_ZONE
            edit_data
            ;;
        2)
            apt-get update
            apt-get install -y mc wget nftables ipcalc
            for iface in $INTERFACE_HQ $INTERFACE_BR; do
                mkdir -p /etc/net/ifaces/$iface
                echo -e "BOOTPROTO=static\nTYPE=eth\nDISABLED=no\nCONFIG_IPV4=yes" > /etc/net/ifaces/$iface/options
                if [ "$iface" = "$INTERFACE_HQ" ]; then
                    echo $IP_HQ > /etc/net/ifaces/$iface/ipv4address
                elif [ "$iface" = "$INTERFACE_BR" ]; then
                    echo $IP_BR > /etc/net/ifaces/$iface/ipv4address
                fi
            done
            systemctl restart network
            ;;
        3)
            sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
            sysctl -p
            systemctl enable --now nftables
            nft flush ruleset
            nft add table ip nat
            nft add chain ip nat postrouting '{ type nat hook postrouting priority 0; }'
            # Calculate network addresses from user input
            HQ_IP=$(echo $IP_HQ | cut -d'/' -f1)
            HQ_MASK=$(ipcalc -m $IP_HQ | cut -d'=' -f2)
            BR_IP=$(echo $IP_BR | cut -d'/' -f1)
            BR_MASK=$(ipcalc -m $IP_BR | cut -d'=' -f2)
            HQ_PREFIX=$(echo $IP_HQ | cut -d'/' -f2)
            BR_PREFIX=$(echo $IP_BR | cut -d'/' -f2)
            HQ_NETWORK=$(get_network $HQ_IP $HQ_MASK)
            BR_NETWORK=$(get_network $BR_IP $BR_MASK)
            nft add rule ip nat postrouting ip saddr $HQ_NETWORK/$HQ_PREFIX oifname "ens192" counter masquerade
            nft add rule ip nat postrouting ip saddr $BR_NETWORK/$BR_PREFIX oifname "ens192" counter masquerade
            nft list ruleset > /etc/nftables/nftables.nft
            systemctl restart nftables
            ;;
        4)
            timedatectl set-timezone $TIME_ZONE
            ;;
        5)
            echo $HOSTNAME > /etc/hostname
            hostnamectl set-hostname $HOSTNAME
            ;;
        6)
            while true; do
                clear
                echo "Configuration Status:"
                echo "Hostname ---> $(check_config "hostname")"
                echo "Interfaces (except ens192) ---> $(check_config "interfaces")"
                echo "nftables ---> $(check_config "nftables")"
                echo "Time Zone ---> $(check_config "time_zone")"
                echo "0. Back to menu"
                read -p "Enter your choice: " sub_choice
                if [ "$sub_choice" = "0" ]; then
                    break
                else
                    echo "Invalid choice. Press 0 to go back."
                    read -p "Press Enter to continue..."
                fi
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
                echo "6. Remove everything done by this script"
                echo "0. Back to main menu"
                read -p "Enter your choice: " remove_choice
                case $remove_choice in
                    1)
                        remove_config "interfaces"
                        ;;
                    2)
                        remove_config "nftables"
                        ;;
                    3)
                        remove_config "time_zone"
                        ;;
                    4)
                        remove_config "hostname"
                        ;;
                    5)
                        remove_config "all"
                        ;;
                    6)
                        remove_config "all"
                        # Additional cleanup
                        rm -f /etc/nftables/nftables.nft
                        systemctl stop nftables
                        systemctl disable nftables
                        sed -i 's/net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf
                        sysctl -p
                        echo "Everything done by this script has been removed."
                        ;;
                    0)
                        break
                        ;;
                    *)
                        echo "Invalid choice. Please try again."
                        read -p "Press Enter to continue..."
                        ;;
                esac
            done
            ;;
        0)
            clear
            exit 0
            ;;
        *)
            echo "Invalid choice. Please try again."
            read -p "Press Enter to continue..."
            ;;
    esac
done
