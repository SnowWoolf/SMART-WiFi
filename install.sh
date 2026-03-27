#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/SnowWoolf/SMART-WiFi/main}"
KVER="$(uname -r)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

log() { echo "[install] $*"; }

fetch_file() {
    local rel="$1"
    local dst="$2"

    if [[ -f "$rel" ]]; then
        cp -f "$rel" "$dst"
    else
        curl -fsSL "$REPO_RAW/$rel" -o "$dst"
    fi
}

install_module_if_exists() {
    local src="$1"
    local dst_dir="$2"
    local dst_name="$3"

    if [[ -f "$src" ]]; then
        mkdir -p "$dst_dir"
        install -m 0644 "$src" "$dst_dir/$dst_name"
        log "Installed $(basename "$src") -> $dst_dir/$dst_name"
    fi
}

power_usb_wifi() {
    if command -v powerlines >/dev/null 2>&1; then
        log "Using powerlines to enable USB Wi-Fi power"
        powerlines '{"iface":"/dev/uspd_usb_device", "state":"on"}' || true
        sleep 2
        return 0
    fi

    if [[ -w /sys/class/leds/USB_PW_ON/brightness ]]; then
        log "Using /sys/class/leds/USB_PW_ON/brightness to enable USB Wi-Fi power"
        echo 1 > /sys/class/leds/USB_PW_ON/brightness
        sleep 2
        return 0
    fi

    log "USB Wi-Fi power control not found, continuing without explicit power-on"
    return 0
}

log "Kernel: $KVER"
log "Arch:   $(uname -m)"

mkdir -p "$TMPDIR"

log "Fetching repository files"
fetch_file "wifi.conf" "$TMPDIR/wifi.conf"
fetch_file "setup-wifi.sh" "$TMPDIR/setup-wifi.sh"
fetch_file "wifi-modules/8192eu.ko" "$TMPDIR/8192eu.ko"
fetch_file "wifi-modules/8821cu.ko" "$TMPDIR/8821cu.ko"
fetch_file "wifi-modules/mt7601u.ko" "$TMPDIR/mt7601u.ko"

log "Installing config and runtime script"
mkdir -p /etc/smart-wifi
install -m 0644 "$TMPDIR/wifi.conf" /etc/smart-wifi/wifi.conf
install -m 0755 "$TMPDIR/setup-wifi.sh" /usr/local/bin/setup-wifi.sh

log "Installing kernel modules"
install_module_if_exists "$TMPDIR/8192eu.ko" \
    "/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtl8192eu" \
    "8192eu.ko"

install_module_if_exists "$TMPDIR/8821cu.ko" \
    "/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtl8821cu" \
    "8821cu.ko"

install_module_if_exists "$TMPDIR/mt7601u.ko" \
    "/lib/modules/$KVER/kernel/drivers/net/wireless/mediatek/mt7601u" \
    "mt7601u.ko"

log "Blacklisting conflicting generic drivers"
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/smart-wifi-blacklist.conf <<'EOF'
blacklist rtl8192cu
blacklist rtl8xxxu
EOF

log "Writing autoload config"
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/smart-wifi.conf <<'EOF'
8192eu
8821cu
mt7601u
EOF

log "Running depmod"
depmod -a

power_usb_wifi

log "Trying to load available drivers"
modprobe 8192eu 2>/dev/null || true
modprobe 8821cu 2>/dev/null || true
modprobe mt7601u 2>/dev/null || true

log "Creating systemd service"
cat > /etc/systemd/system/smart-wifi.service <<'EOF'
[Unit]
Description=SMART WiFi setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-wifi.sh

[Install]
WantedBy=multi-user.target
EOF

log "Disabling old rc.local Wi-Fi launch, if present"
if [[ -f /etc/rc.local ]]; then
    sed -i '\|/usr/local/bin/wifi-start.sh|d' /etc/rc.local || true
fi

log "Enabling service"
systemctl daemon-reload
systemctl enable smart-wifi.service

log "Starting service now"
systemctl restart smart-wifi.service || true

echo
echo "Done."
