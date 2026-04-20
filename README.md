# StatekMatka_V3 - Raspberry Pi Router

## Configuration
- **Hardware**: Raspberry Pi 5, TP-Link TL-SG105 Gigabit Switch.
- **Network**: eth0 (WAN) -> wlan0 (LAN/Hotspot).
- **IP Range**: 10.42.0.0/24 (NetworkManager default).

## Security
- **UFW**: Incoming denied, NAT masquerading enabled on eth0.
- **SSH**: Public-key only.
- **Updates**: Automated via `unattended-upgrades`.

## Setup
```bash
chmod +x mothership_deploy.sh
sudo ./mothership_deploy.sh