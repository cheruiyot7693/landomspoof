# network-toolkit (landomspoof)

A Linux bash toolkit for local network management,
host mapping, and system cleanup.

## Scripts

### scanner.sh
Scans local network, discovers hosts and MACs,
maps a hostname to your local IP in /etc/hosts.

```bash
sudo bash scanner.sh
```

**Features:**
- Detects wlan0 IP and subnet automatically
- Scans LAN via bettercap
- Displays discovered hosts with MACs
- ARP + DNS spoof in single bettercap session
- Auto-cleanup on exit via trap
- Cron installs on first run

## Requirements
- Kali Linux
- bettercap
- bash 5+

## Disclaimer
Built for local lab and educational use only.
