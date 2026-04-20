#!/bin/bash
set -euo pipefail

# RPi Router Deployment Script
# Targets: Debian Trixie / Raspberry Pi OS (Pi 5)

# Prompt for Wi-Fi credentials
read -rp "Enter hotspot SSID: " WIFI_SSID
read -rsp "Enter hotspot password (min 8 chars): " WIFI_PASS
echo
if [ ${#WIFI_PASS} -lt 8 ]; then
    echo "Error: Wi-Fi password must be at least 8 characters." >&2
    exit 1
fi

# 1. System Localization and WLAN Regulatory Domain
# Configures locale and country code to enable the Wi-Fi radio hardware
sudo raspi-config nonint do_change_locale en_US.UTF-8
sudo raspi-config nonint do_configure_keyboard us
sudo raspi-config nonint do_wifi_country PL

# 2. Enable IPv4 Forwarding
# Creates dedicated sysctl config to allow packet routing between interfaces
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ip-forward.conf
sudo sysctl -p /etc/sysctl.d/99-ip-forward.conf

# 3. Configure Wi-Fi Hotspot
# Creates access point via NetworkManager with autoconnect enabled
sudo nmcli device wifi hotspot ifname wlan0 ssid "$WIFI_SSID" password "$WIFI_PASS"
sudo nmcli connection modify Hotspot connection.autoconnect yes

# 4. Disable Wi-Fi Power Management
# Ensures low-latency wireless performance by preventing interface sleep
sudo bash -c 'cat > /etc/network/if-up.d/off-power-save <<EOF
#!/bin/sh
iw dev wlan0 set power_save off
EOF'
sudo chmod +x /etc/network/if-up.d/off-power-save
sudo iw dev wlan0 set power_save off

# 5. Firewall & NAT Configuration (UFW)
# Installs UFW and sets up MASQUERADE for the 10.42.0.0/24 subnet
sudo apt update && sudo apt install ufw -y

# Explicitly enable IPv6 support in UFW
sudo sed -i 's/IPV6=no/IPV6=yes/g' /etc/default/ufw

# Set default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed

# Rate-limit SSH and allow DNS/DHCP from hotspot clients only
sudo ufw limit ssh
sudo ufw allow in on wlan0 to any port 53
sudo ufw allow in on wlan0 to any port 67

# Allow forwarding from hotspot subnet to the upstream interface only
sudo ufw allow in on wlan0 out on eth0 from 10.42.0.0/24

# Inject NAT table rules only if not already present
if ! sudo grep -q "MASQUERADE" /etc/ufw/before.rules; then
    sudo sed -i '1i # NAT rules\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.42.0.0/24 -o eth0 -j MASQUERADE\nCOMMIT\n' /etc/ufw/before.rules
fi

# Enable firewall non-interactively
echo "y" | sudo ufw enable
sudo ufw reload

# 6. Automated Security Updates
# Configures unattended-upgrades for daily package maintenance
sudo apt install unattended-upgrades -y
sudo bash -c 'cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF'

echo "Deployment finished"
