#!/bin/bash
set -euo pipefail
# set -e  → exit immediately if any command fails
# set -u  → treat unset variables as errors
# set -o pipefail → if any command in a pipe fails, the whole pipe fails
# Together these prevent the script from silently continuing after an error.

# RPi Router Deployment Script
# Targets: Debian Trixie / Raspberry Pi OS (Pi 5)
# Sets up the Pi as a Wi-Fi hotspot that shares an Ethernet (eth0) uplink.
# Clients connect to wlan0, traffic is NATed out through eth0.

# =============================================================================
# USER INPUT
# =============================================================================

read -rp "Enter hotspot SSID: " WIFI_SSID
# -s hides the typed characters so the password isn't visible on screen
read -rsp "Enter hotspot password (min 8 chars): " WIFI_PASS
echo  # move to a new line after the hidden password input

if [ ${#WIFI_PASS} -lt 8 ]; then
    echo "Error: Wi-Fi password must be at least 8 characters." >&2
    exit 1
fi

# =============================================================================
# VARIABLES
# =============================================================================

WLAN_IF="wlan0"   # Wi-Fi interface — becomes the hotspot (LAN side)
WAN_IF="eth0"     # Ethernet interface — upstream internet connection (WAN side)
HOTSPOT_NAME="rpi-hotspot"  # NetworkManager connection profile name

# =============================================================================
# 1. SYSTEM LOCALIZATION AND WLAN REGULATORY DOMAIN
# =============================================================================
# Wi-Fi hardware is region-locked: without a country code the radio may refuse
# to transmit or operate only on a reduced set of channels. PL = Poland.

sudo raspi-config nonint do_change_locale en_US.UTF-8
sudo raspi-config nonint do_configure_keyboard us
sudo raspi-config nonint do_wifi_country PL

# =============================================================================
# 2. ENABLE IPv4 FORWARDING
# =============================================================================
# By default Linux does not forward packets between interfaces — it only
# processes packets addressed to itself. Enabling ip_forward tells the kernel
# to act as a router and pass packets from wlan0 to eth0 (and vice versa).
# Writing to sysctl.d makes the setting survive reboots.

sudo tee /etc/sysctl.d/99-ip-forward.conf >/dev/null <<EOF
net.ipv4.ip_forward=1
EOF

# --system reloads all sysctl config files, including the one we just wrote
sudo sysctl --system

# =============================================================================
# 3. INSTALL REQUIRED PACKAGES
# =============================================================================

sudo apt update
sudo apt install -y network-manager ufw unattended-upgrades

# NetworkManager manages both the hotspot and the upstream Ethernet connection.
# Make sure it is running before we try to configure connections with nmcli.
sudo systemctl enable NetworkManager
sudo systemctl start NetworkManager

# =============================================================================
# 4. CREATE WI-FI HOTSPOT
# =============================================================================
# NetworkManager's "shared" IPv4 mode does three things automatically:
#   - Runs a dnsmasq instance to serve DHCP and DNS to connected clients
#   - Assigns the Pi a static IP on wlan0 (default 10.42.0.1/24)
#   - Adds an iptables MASQUERADE rule so client traffic is NATed out via eth0
#
# We use explicit `connection add` + `connection modify` rather than the
# `device wifi hotspot` shortcut so every parameter is visible and auditable.

# Remove any existing profile with the same name to ensure a clean slate
if nmcli -t -f NAME connection show | grep -q "^${HOTSPOT_NAME}$"; then
    sudo nmcli connection delete "$HOTSPOT_NAME"
fi

# Create the base Wi-Fi connection profile
sudo nmcli connection add \
    type wifi \
    ifname "$WLAN_IF" \
    con-name "$HOTSPOT_NAME" \
    autoconnect yes \
    ssid "$WIFI_SSID"

# Configure it as a WPA2 access point with shared (NATed) IPv4
sudo nmcli connection modify "$HOTSPOT_NAME" \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    ipv4.method shared \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$WIFI_PASS"

# Bring the hotspot up immediately
sudo nmcli connection up "$HOTSPOT_NAME"

# =============================================================================
# 5. DISABLE WI-FI POWER MANAGEMENT
# =============================================================================
# Power-save mode lets the Wi-Fi radio sleep between packets to conserve
# battery. On a router this causes latency spikes and dropped connections.
# Setting wifi.powersave = 2 (disabled) via NetworkManager's config directory
# is the correct method on NM-managed systems — it persists across reboots and
# interface restarts without needing a separate hook script.

sudo mkdir -p /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf >/dev/null <<EOF
[connection]
wifi.powersave = 2
EOF

# Restart NM to apply the power-save config
sudo systemctl restart NetworkManager

# =============================================================================
# 6. FIREWALL (UFW)
# =============================================================================
# UFW is a front-end for iptables. We configure it to:
#   - Block unsolicited incoming connections by default
#   - Allow only the services hotspot clients actually need (DHCP, DNS)
#   - Forward hotspot traffic to the internet but NOT to the upstream LAN
#   - Rate-limit SSH to slow down brute-force attempts

# Enable IPv6 support in UFW so rules apply to both protocol stacks
sudo sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw || true

# Wipe any existing UFW rules so this script is idempotent and the result
# is always predictable, regardless of prior state
sudo ufw --force reset

# --- Default policies ---
# Deny all unsolicited inbound traffic unless a rule explicitly allows it
sudo ufw default deny incoming
# Allow all outbound traffic from the Pi itself
sudo ufw default allow outgoing
# Deny all forwarded (routed) traffic unless a rule explicitly allows it
sudo ufw default deny routed

# --- SSH ---
# `limit` allows SSH but automatically blocks IPs that attempt more than
# 6 connections in 30 seconds — basic brute-force protection
sudo ufw limit ssh

# --- Hotspot client services ---
# Clients need to reach the Pi on these ports to get an IP address and
# resolve DNS names. We restrict the rules to wlan0 so they don't apply
# to the upstream eth0 interface.
sudo ufw allow in on "$WLAN_IF" to any port 67 proto udp  # DHCP
sudo ufw allow in on "$WLAN_IF" to any port 53            # DNS (UDP + TCP)

# --- Forwarding: allow hotspot → internet, block hotspot → upstream LAN ---
# This rule permits routed traffic from the hotspot subnet out through eth0.
sudo ufw route allow in on "$WLAN_IF" out on "$WAN_IF"

# Block forwarding to RFC1918 private address ranges.
# These cover virtually all home and office LAN subnets, so hotspot clients
# cannot reach devices on the upstream network (NAS, printers, other PCs, etc.)
# even though NATed internet traffic is still allowed.
sudo ufw route reject out on "$WAN_IF" to 10.0.0.0/8       # Class A private
sudo ufw route reject out on "$WAN_IF" to 172.16.0.0/12     # Class B private
sudo ufw route reject out on "$WAN_IF" to 192.168.0.0/16    # Class C private

# Enable the firewall. --force skips the interactive "are you sure?" prompt.
sudo ufw --force enable

# =============================================================================
# 7. AUTOMATED SECURITY UPDATES
# =============================================================================
# unattended-upgrades automatically downloads and installs security patches
# daily, keeping the router up to date without manual intervention.

sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# =============================================================================
# DONE
# =============================================================================

echo "----------------------------------------"
echo "Router setup complete!"
echo "SSID     : $WIFI_SSID"
echo "LAN iface: $WLAN_IF  (hotspot, 10.42.0.1/24)"
echo "WAN iface: $WAN_IF   (upstream Ethernet)"
echo "----------------------------------------"
