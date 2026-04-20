#!/bin/bash

# StatekMatka_V3 Deployment Script
# Targets: Debian Trixie / Raspberry Pi OS (Pi 5)

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
sudo nmcli device wifi hotspot ifname wlan0 ssid StatekMatka_V3 password okonalfa
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
sudo ufw default allow routed

# Allow SSH and internal hotspot traffic
sudo ufw allow ssh
sudo ufw allow in on wlan0

# Inject NAT table rules at the beginning of the configuration
sudo sed -i '1i # NAT rules\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.42.0.0/24 -o eth0 -j MASQUERADE\nCOMMIT\n' /etc/ufw/before.rules

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