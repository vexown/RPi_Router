# RPi Router — Raspberry Pi 5

A Raspberry Pi 5 configured as a Wi-Fi hotspot router. Clients connect via `wlan0`; traffic is NATed out through `eth0` to the upstream internet connection.

## Hardware

| Component | Details |
|-----------|---------|
| SBC | Raspberry Pi 5 |
| Switch | TP-Link TL-SG105 Gigabit |
| WAN | `eth0` — upstream Ethernet |
| LAN | `wlan0` — Wi-Fi hotspot |

## Network

- **Hotspot subnet**: `10.42.0.0/24` (Pi is `10.42.0.1`)
- **DHCP/DNS**: Managed automatically by NetworkManager shared mode
- **NAT**: Handled by NetworkManager shared mode (iptables MASQUERADE)
- **Channel**: 2.4 GHz, channel 6

## Security

- **Firewall**: UFW — default deny incoming, default deny routed
- **LAN isolation**: RFC1918 ranges blocked on `eth0`; hotspot clients cannot reach upstream LAN devices
- **SSH**: Rate-limited via `ufw limit ssh`; use public-key auth
- **IPv6**: Disabled on hotspot interface to prevent NAT bypass
- **Updates**: Automated daily via `unattended-upgrades`

## Setup

```bash
chmod +x rpi_router_deploy.sh
sudo ./rpi_router_deploy.sh
```

The script will prompt for the hotspot SSID and password (min 8 characters).

## Roadmap

- [x] **WPA3**: Upgrade hotspot security from WPA2-PSK to WPA3-SAE for stronger client authentication
- [x] **5 GHz**: Add a 5 GHz band AP profile (`802-11-wireless.band a`) alongside the existing 2.4 GHz one
- [ ] **DNS-level ad blocking**: Integrate [Pi-hole](https://pi-hole.net) or [AdGuard Home](https://adguard.com/adguard-home.html) as the upstream DNS resolver for network-wide filtering
- [ ] **Remote access**: [WireGuard](https://www.wireguard.com) VPN server for secure home-to-anywhere tunneling
- [ ] **Monitoring**: [Prometheus](https://prometheus.io) + [Grafana](https://grafana.com) dashboard for real-time bandwidth and connection tracking
- [ ] **Local storage**: NAS integration (e.g. Samba or NFS) for network-wide file sharing
