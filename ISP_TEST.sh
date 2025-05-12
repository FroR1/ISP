#!/bin/bash

# Функция для вычисления адреса сети из IP и маски
function get_network() {
    local ip_with_mask=$1
    if ! command -v ipcalc &> /dev/null; then
        echo "Ошибка: ipcalc не установлен. Установите его с помощью 'sudo apt-get install ipcalc'."
        exit 1
    fi
    local network=$(ipcalc -n "$ip_with_mask" | grep Network | awk '{print $2}' | cut -d'/' -f1)
    if [ -z "$network" ]; then
        echo "Ошибка вычисления сети для $ip_with_mask."
        exit 1
    fi
    echo "$network"
}

# Функция проверки существования часового пояса
function check_timezone() {
    local tz=$1
    if ! command -v timedatectl &> /dev/null; then
        echo "Ошибка: timedatectl не найден. Установите пакет systemd."
        return 1
    fi
    timedatectl list-timezones | grep -Fxq "$tz"
    return $?
}

# Функция валидации формата IP-адреса
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

# Функция отображения меню
function display_menu() {
    clear
    echo "---------------------"
    echo "ISP Config Menu"
    echo "---------------------"
    echo "1. Ввод или редактирование данных"
    echo "2. Настройка интерфейсов (кроме ens192)"
    echo "3. Настройка nftables"
    echo "4. Установка часового пояса"
    echo "5. Установка имени хоста"
    echo "6. Проверка статуса конфигурации"
    echo "7. Удаление конфигураций"
    echo "0. Выход"
}

# Подменю редактирования данных
function edit_data() {
    while true; do
        clear
        echo "Текущие данные:"
        echo "1. Имя интерфейса HQ: $INTERFACE_HQ"
        echo "2. Имя интерфейса BR: $INTERFACE_BR"
        echo "3. IP для интерфейса HQ: $IP_HQ"
        echo "4. IP для интерфейса BR: $IP_BR"
        echo "5. Имя хоста: $HOSTNAME"
        echo "0. Вернуться в главное меню"
        read -p "Введите номер для редактирования (0 для выхода): " edit_choice
        case $edit_choice in
            1) read -p "Введите новое имя интерфейса HQ: " INTERFACE_HQ ;;
            2) read -p "Введите новое имя интерфейса BR: " INTERFACE_BR ;;
            3)
                while true; do
                    read -p "Введите новый IP для HQ (например, 172.16.4.1/28): " IP_HQ
                    if validate_ip "$IP_HQ"; then break; else echo "Неверный формат IP."; sleep 1; fi
                done
                ;;
            4)
                while true; do
                    read -p "Введите новый IP для BR (например, 172.16.5.1/28): " IP_BR
                    if validate_ip "$IP_BR"; then break; else echo "Неверный формат IP."; sleep 1; fi
                done
                ;;
            5) read -p "Введите новое имя хоста: " HOSTNAME ;;
            0) break ;;
            *) echo "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# Функция настройки часового пояса
function set_timezone() {
    while true; do
        read -p "Введите новый часовой пояс (например, Asia/Novosibirsk): " TIME_ZONE
        if check_timezone "$TIME_ZONE"; then
            if sudo timedatectl set-timezone "$TIME_ZONE"; then
                echo "Часовой пояс установлен: $TIME_ZONE."
                sleep 1
                break
            else
                echo "Ошибка установки часового пояса."
                sleep 1
            fi
        else
            echo "Неверный часовой пояс. Используйте 'timedatectl list-timezones' для списка."
            sleep 2
        fi
    done
}

# Значения по умолчанию
INTERFACE_HQ="ens224"
INTERFACE_BR="ens256"
IP_HQ="172.16.4.1/28"
IP_BR="172.16.5.1/28"
HOSTNAME="isp"
TIME_ZONE="Asia/Novosibirsk"

# Основной цикл
while true; do
    display_menu
    read -p "Введите ваш выбор: " choice
    case $choice in
        1) edit_data ;;
        2)
            if [ -z "$IP_HQ" ] || [ -z "$IP_BR" ]; then
                echo "IP-адреса не установлены. Настройте их в пункте 1."
                sleep 2
                continue
            fi
            sudo apt-get update
            sudo apt-get install -y nftables ipcalc systemd
            for iface in $INTERFACE_HQ $INTERFACE_BR; do
                sudo mkdir -p /etc/net/ifaces/$iface
                echo -e "BOOTPROTO=static\nTYPE=eth\nDISABLED=no\nCONFIG_IPV4=yes" | sudo tee /etc/net/ifaces/$iface/options
                if [ "$iface" = "$INTERFACE_HQ" ]; then
                    echo "$IP_HQ" | sudo tee /etc/net/ifaces/$iface/ipv4address
                elif [ "$iface" = "$INTERFACE_BR" ]; then
                    echo "$IP_BR" | sudo tee /etc/net/ifaces/$iface/ipv4address
                fi
            done
            sudo systemctl restart network
            echo "Интерфейсы настроены."
            sleep 2
            ;;
        3)
            if [ -z "$IP_HQ" ] || [ -z "$IP_BR" ]; then
                echo "IP-адреса не установлены. Настройте их в пункте 1."
                sleep 2
                continue
            fi
            sudo sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
            sudo sysctl -p
            sudo systemctl enable --now nftables
            sudo nft flush ruleset
            sudo nft add table ip nat
            sudo nft add chain ip nat postrouting '{ type nat hook postrouting priority 0; }'
            HQ_PREFIX=$(echo "$IP_HQ" | cut -d'/' -f2)
            BR_PREFIX=$(echo "$IP_BR" | cut -d'/' -f2)
            HQ_NETWORK=$(get_network "$IP_HQ")
            BR_NETWORK=$(get_network "$IP_BR")
            sudo nft add rule ip nat postrouting ip saddr "$HQ_NETWORK/$HQ_PREFIX" oifname "ens192" counter masquerade
            sudo nft add rule ip nat postrouting ip saddr "$BR_NETWORK/$BR_PREFIX" oifname "ens192" counter masquerade
            sudo nft list ruleset | sudo tee /etc/nftables/nftables.nft
            sudo systemctl restart nftables
            echo "nftables настроены."
            sleep 2
            ;;
        4) set_timezone ;;
        5)
            if [ -z "$HOSTNAME" ]; then
                echo "Имя хоста не установлено. Настройте его в пункте 1."
                sleep 2
                continue
            fi
            echo "$HOSTNAME" | sudo tee /etc/hostname
            sudo hostnamectl set-hostname "$HOSTNAME"
            echo "Имя хоста установлено: $HOSTNAME."
            sleep 2
            ;;
        6)
            echo "Статус конфигурации:"
            echo "Имя хоста: $(hostname)"
            echo "Интерфейсы: $(ls /etc/net/ifaces/)"
            echo "nftables: $(sudo nft list ruleset)"
            echo "Часовой пояс: $(timedatectl show | grep Timezone)"
            read -p "Нажмите Enter для продолжения..."
            ;;
        7)
            echo "Удаление конфигураций..."
            sudo rm -rf /etc/net/ifaces/$INTERFACE_HQ /etc/net/ifaces/$INTERFACE_BR
            sudo nft flush ruleset
            sudo systemctl restart nftables
            echo "Конфигурации удалены."
            sleep 2
            ;;
        0) exit 0 ;;
        *) echo "Неверный выбор."; sleep 1 ;;
    esac
done
