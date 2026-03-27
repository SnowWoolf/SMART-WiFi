#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/SnowWoolf/SMART-WiFi/main}"
CONF_PATH="/etc/smart-wifi/wifi.conf"
HOSTAPD_CONF="/etc/hostapd/hostapd-smartwifi.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/smartwifi-ap.conf"

log() { echo "[setup-wifi] $*"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

fetch_default_config() {
    mkdir -p /etc/smart-wifi
    if [[ ! -f "$CONF_PATH" ]]; then
        log "Downloading default wifi.conf"
        curl -fsSL "$REPO_RAW/wifi.conf" -o "$CONF_PATH"
    fi
}

load_config() {
    # shellcheck source=/dev/null
    source "$CONF_PATH"
}

install_pkgs() {
    if ! need_cmd hostapd || ! need_cmd dnsmasq; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y hostapd dnsmasq
    fi
}

power_usb() {
    powerlines '{"iface":"/dev/uspd_usb_device", "state":"on"}' || true
    sleep 3
}

load_modules() {
    modprobe 8192eu 2>/dev/null || true
    modprobe 8821cu 2>/dev/null || true
    modprobe mt7601u 2>/dev/null || true
    sleep 3
}

list_wifi_ifaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -E '^(wlan[0-9]+|wifi[0-9]+|wlx[0-9a-f]+)$' || true
}

pick_ifaces() {
    mapfile -t IFACES < <(list_wifi_ifaces)

    AP_REAL_IFACE=""
    STA_REAL_IFACE=""

    if [[ ${#IFACES[@]} -eq 0 ]]; then
        log "No Wi-Fi interfaces found"
        return 1
    fi

    if [[ ${#IFACES[@]} -eq 1 ]]; then
        AP_REAL_IFACE="${IFACES[0]}"
        STA_REAL_IFACE="${IFACES[0]}"
    else
        AP_REAL_IFACE="${IFACES[0]}"
        STA_REAL_IFACE="${IFACES[1]}"
    fi

    log "Detected Wi-Fi ifaces: ${IFACES[*]}"
    log "AP_REAL_IFACE=$AP_REAL_IFACE"
    log "STA_REAL_IFACE=$STA_REAL_IFACE"
}

stop_existing_wifi() {
    killall wpa_supplicant 2>/dev/null || true
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
}

setup_ap_conf() {
    cat > "$HOSTAPD_CONF" <<EOF
interface=$AP_REAL_IFACE
driver=nl80211
ssid=$AP_SSID
hw_mode=$AP_HW_MODE
channel=$AP_CHANNEL
country_code=$AP_COUNTRY
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$AP_PASSPHRASE
EOF

    cat > "$DNSMASQ_CONF" <<EOF
interface=$AP_REAL_IFACE
bind-interfaces
dhcp-range=$DHCP_START,$DHCP_END,$DHCP_LEASE
dhcp-option=option:router,$AP_ADDR
dhcp-option=option:dns-server,$AP_ADDR
address=/#/$AP_ADDR
EOF
}

setup_ap_runtime() {
    log "Starting AP mode on $AP_REAL_IFACE"

    ip link set "$AP_REAL_IFACE" down || true
    ip addr flush dev "$AP_REAL_IFACE" || true
    ip addr add "$AP_ADDR/$AP_PREFIX" dev "$AP_REAL_IFACE"
    ip link set "$AP_REAL_IFACE" up

    iw reg set "$AP_COUNTRY" || true

    mkdir -p /run/hostapd
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd-smartwifi.conf"|' /etc/default/hostapd || true

    systemctl unmask hostapd || true
    systemctl restart dnsmasq
    systemctl restart hostapd

    # Разрешаем только HTTP на WEB_PORT и DNS/DHCP для клиентов AP
    iptables -t nat -C PREROUTING -i "$AP_REAL_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$WEB_PORT" 2>/dev/null || \
        iptables -t nat -A PREROUTING -i "$AP_REAL_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$WEB_PORT"

    iptables -C INPUT -i "$AP_REAL_IFACE" -p tcp --dport "$WEB_PORT" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i "$AP_REAL_IFACE" -p tcp --dport "$WEB_PORT" -j ACCEPT

    iptables -C INPUT -i "$AP_REAL_IFACE" -p udp --dport 67:68 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i "$AP_REAL_IFACE" -p udp --dport 67:68 -j ACCEPT

    iptables -C INPUT -i "$AP_REAL_IFACE" -p udp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i "$AP_REAL_IFACE" -p udp --dport 53 -j ACCEPT

    iptables -C INPUT -i "$AP_REAL_IFACE" -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -i "$AP_REAL_IFACE" -p tcp --dport 53 -j ACCEPT

    iptables -C FORWARD -i "$AP_REAL_IFACE" -j DROP 2>/dev/null || \
        iptables -A FORWARD -i "$AP_REAL_IFACE" -j DROP
}

setup_sta_runtime() {
    [[ -n "${STA_SSID:-}" ]] || { log "STA_SSID is empty, skipping STA"; return 0; }

    log "Starting STA mode on $STA_REAL_IFACE"

    mkdir -p /etc/wifi /run/wpa_supplicant

    if [[ "${STA_HIDDEN:-0}" == "1" ]]; then
        cat > /etc/wifi/sta-wpa.conf <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
    ssid="$STA_SSID"
    psk="$STA_PSK"
    scan_ssid=1
}
EOF
    else
        wpa_passphrase "$STA_SSID" "$STA_PSK" > /etc/wifi/sta-wpa.conf
        {
            echo 'ctrl_interface=/run/wpa_supplicant'
            echo 'update_config=1'
            cat /etc/wifi/sta-wpa.conf
        } > /etc/wifi/sta-wpa.conf.tmp
        mv /etc/wifi/sta-wpa.conf.tmp /etc/wifi/sta-wpa.conf
    fi

    ip link set "$STA_REAL_IFACE" up || true
    wpa_supplicant -B -i "$STA_REAL_IFACE" -c /etc/wifi/sta-wpa.conf || true
    sleep 5
    udhcpc -n -q -i "$STA_REAL_IFACE" || true
}

main() {
    fetch_default_config
    load_config
    install_pkgs
    power_usb
    load_modules
    pick_ifaces
    stop_existing_wifi

    if [[ "${AP_ENABLED:-0}" == "1" && "${STA_ENABLED:-0}" == "1" ]]; then
        log "Both AP and STA are enabled"
        if [[ "${ALLOW_CONCURRENT:-0}" != "1" ]]; then
            log "ALLOW_CONCURRENT=0, running AP only"
            setup_ap_conf
            setup_ap_runtime
            exit 0
        fi

        if [[ "$AP_REAL_IFACE" == "$STA_REAL_IFACE" ]]; then
            log "Only one Wi-Fi interface found; concurrent mode may fail"
        fi

        setup_ap_conf
        setup_ap_runtime
        setup_sta_runtime
        exit 0
    fi

    if [[ "${AP_ENABLED:-0}" == "1" ]]; then
        setup_ap_conf
        setup_ap_runtime
    fi

    if [[ "${STA_ENABLED:-0}" == "1" ]]; then
        setup_sta_runtime
    fi
}

main "$@"