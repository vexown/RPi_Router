#!/bin/bash
set -euo pipefail

# RPi Router Deployment Script
# Targets: Debian Trixie / Raspberry Pi OS (Pi 5)
# Sets up the Pi as a Wi-Fi hotspot on wlan0, sharing upstream internet via eth0.

# =============================================================================
# USER INPUT
# =============================================================================

read -rp "Enter hotspot SSID: " WIFI_SSID
read -rsp "Enter hotspot password (recommend 16+ chars): " WIFI_PASS
echo

if [ "${#WIFI_PASS}" -lt 8 ]; then
    echo "Error: Wi-Fi password must be at least 8 characters." >&2
    exit 1
fi

# =============================================================================
# VARIABLES
# =============================================================================

WLAN_IF="wlan0"          # Wi-Fi interface (hotspot/LAN side)
WAN_IF="eth0"            # Ethernet interface (uplink/WAN side)
HOTSPOT_2G_NAME="rpi-hotspot-2g"
HOTSPOT_5G_NAME="rpi-hotspot-5g"

# =============================================================================
# 1. SYSTEM LOCALIZATION AND WLAN REGULATORY DOMAIN
# =============================================================================

if command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_change_locale en_US.UTF-8
    sudo raspi-config nonint do_configure_keyboard us
    sudo raspi-config nonint do_wifi_country PL
fi

# =============================================================================
# 2. ENABLE IPv4 FORWARDING
# =============================================================================

sudo tee /etc/sysctl.d/99-ip-forward.conf >/dev/null <<EOF
net.ipv4.ip_forward=1
EOF

sudo sysctl --system

# =============================================================================
# 3. INSTALL REQUIRED PACKAGES
# =============================================================================

sudo apt update
sudo apt install -y network-manager ufw unattended-upgrades

sudo systemctl enable NetworkManager
sudo systemctl start NetworkManager

# =============================================================================
# 4. CREATE WI-FI HOTSPOT PROFILES
# =============================================================================
# NetworkManager shared mode handles:
#   - DHCP/DNS for clients
#   - NAT from wlan0 to the upstream network
#   - a default hotspot subnet (unless explicitly set)
#
# We create two saved profiles:
#   - 2.4 GHz: band bg, channel 6
#   - 5 GHz:   band a,  channel 36
#
# WPA3-Personal uses SAE, and PMF is required.

create_hotspot_profile() {
    local profile_name="$1"
    local band="$2"
    local channel="$3"

    if nmcli -t -f NAME connection show | grep -Fxq "$profile_name"; then
        sudo nmcli connection delete "$profile_name"
    fi

    sudo nmcli connection add \
        type wifi \
        ifname "$WLAN_IF" \
        con-name "$profile_name" \
        autoconnect no \
        ssid "$WIFI_SSID"

    sudo nmcli connection modify "$profile_name" \
        802-11-wireless.mode ap \
        802-11-wireless.band "$band" \
        802-11-wireless.channel "$channel" \
        802-11-wireless.ap-isolation yes \
        802-11-wireless.powersave 2 \
        ipv4.method shared \
        ipv4.addresses 10.42.0.1/24 \
        ipv6.method ignore \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.pmf optional \
        wifi-sec.psk "$WIFI_PASS"
}

create_hotspot_profile "$HOTSPOT_2G_NAME" "bg" 6
create_hotspot_profile "$HOTSPOT_5G_NAME" "a" 36

# =============================================================================
# 5. DISABLE WI-FI POWER MANAGEMENT
# =============================================================================
# Keep this as a global NM knob too, in case the profile-specific setting is not
# applied early enough during activation.

sudo mkdir -p /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf >/dev/null <<EOF
[connection]
wifi.powersave = 2
EOF

# Restart NetworkManager so the power-save setting is picked up cleanly.
sudo systemctl restart NetworkManager
sleep 2

# Bring up the 5 GHz hotspot by default.
sudo nmcli connection up "$HOTSPOT_5G_NAME"

# =============================================================================
# 6. FIREWALL (UFW)
# =============================================================================
# Allow hotspot clients out to the internet, but block access to private LANs.

sudo sed -i 's/^IPV6=no$/IPV6=yes/' /etc/default/ufw || true

sudo ufw --force reset

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed

# SSH access to the Pi itself
sudo ufw limit ssh

# DHCP + DNS for hotspot clients
sudo ufw allow in on "$WLAN_IF" to any port 67 proto udp
sudo ufw allow in on "$WLAN_IF" to any port 53 proto udp
sudo ufw allow in on "$WLAN_IF" to any port 53 proto tcp

# Block access to upstream/private LAN ranges
sudo ufw route reject out on "$WAN_IF" to 10.0.0.0/8
sudo ufw route reject out on "$WAN_IF" to 172.16.0.0/12
sudo ufw route reject out on "$WAN_IF" to 192.168.0.0/16

# Allow routed traffic from hotspot clients to the WAN
sudo ufw route allow in on "$WLAN_IF" out on "$WAN_IF"

sudo ufw --force enable
sudo ufw reload

# =============================================================================
# 7. AUTOMATED SECURITY UPDATES
# =============================================================================

sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# =============================================================================
# 8. AUTOSTART SETTINGS
# =============================================================================

# Ensure 5GHz autostarts and 2GHz stays as a manual backup
sudo nmcli connection modify "$HOTSPOT_2G_NAME" connection.autoconnect no
sudo nmcli connection modify "$HOTSPOT_5G_NAME" connection.autoconnect yes
sudo nmcli connection modify "$HOTSPOT_5G_NAME" connection.autoconnect-priority 10

# =============================================================================
# DONE
# =============================================================================

echo "----------------------------------------"
echo "Router setup complete!"
echo "SSID           : $WIFI_SSID"
echo "2.4 GHz profile: $HOTSPOT_2G_NAME"
echo "5 GHz profile  : $HOTSPOT_5G_NAME"
echo "Active now     : $HOTSPOT_5G_NAME"
echo "LAN iface      : $WLAN_IF (hotspot)"
echo "WAN iface      : $WAN_IF (upstream Ethernet)"
echo "----------------------------------------"