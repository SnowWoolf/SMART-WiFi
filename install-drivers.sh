#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/SnowWoolf/SMART-WiFi/main}"
KVER="$(uname -r)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

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

log "Kernel: $KVER"
log "Arch:   $(uname -m)"

mkdir -p "$STAGE"

log "Fetching modules"
fetch_file "wifi-modules/8192eu.ko" "$STAGE/8192eu.ko"
fetch_file "wifi-modules/8821cu.ko" "$STAGE/8821cu.ko"
fetch_file "wifi-modules/mt7601u.ko" "$STAGE/mt7601u.ko"

log "Creating module directories"
mkdir -p "/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtl8192eu"
mkdir -p "/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtl8821cu"
mkdir -p "/lib/modules/$KVER/kernel/drivers/net/wireless/mediatek/mt7601u"

log "Installing modules"
install -m 0644 "$STAGE/8192eu.ko" "/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtl8192eu/8192eu.ko"
install -m 0644 "$STAGE/8821cu.ko" "/lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtl8821cu/8821cu.ko"
install -m 0644 "$STAGE/mt7601u.ko" "/lib/modules/$KVER/kernel/drivers/net/wireless/mediatek/mt7601u/mt7601u.ko"

log "Writing autoload config"
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/smart-wifi.conf <<'EOF'
8192eu
8821cu
mt7601u
EOF

log "Blacklisting conflicting generic modules"
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/smart-wifi-blacklist.conf <<'EOF'
blacklist rtl8192cu
blacklist rtl8xxxu
EOF

log "Running depmod"
depmod -a

log "Powering USB Wi-Fi"
powerlines '{"iface":"/dev/uspd_usb_device", "state":"on"}' || true
sleep 3

log "Trying to load drivers now"
modprobe 8192eu 2>/dev/null || true
modprobe 8821cu 2>/dev/null || true
modprobe mt7601u 2>/dev/null || true

log "Done"
echo
echo "Installed:"
echo "  /lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtl8192eu/8192eu.ko"
echo "  /lib/modules/$KVER/kernel/drivers/net/wireless/realtek/rtl8821cu/8821cu.ko"
echo "  /lib/modules/$KVER/kernel/drivers/net/wireless/mediatek/mt7601u/mt7601u.ko"
echo
echo "One-line install:"
echo "  curl -fsSL https://raw.githubusercontent.com/SnowWoolf/SMART-WiFi/main/install.sh | bash"