#!/usr/bin/env bash
set -euo pipefail

# nmcli_bond_balance_rr_wizard.sh
# Interactive wizard to create Linux bonding (team/bond) on RHEL using NetworkManager (nmcli).
# Default configuration matches your current validated setup:
#   - Bond mode: balance-rr (round-robin)
#   - xmit_hash_policy: layer2
#   - miimon: 1ms (aggressive link monitoring; matches your current /proc/net/bonding output style)
#   - IPv4: DHCP by default (optional static)
#   - IPv6: left default (link-local will exist automatically)
#
# Usage:
#   sudo bash nmcli_bond_balance_rr_wizard.sh
#   sudo bash nmcli_bond_balance_rr_wizard.sh --cleanup   # delete bonds created by this script

CREATED_TAG="created-by-nmcli-bond-wizard"

red() { printf "\033[31m%s\033[0m\n" "$*"; }
grn() { printf "\033[32m%s\033[0m\n" "$*"; }
ylw() { printf "\033[33m%s\033[0m\n" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { red "Missing required command: $1"; exit 1; }; }
need nmcli
need ip

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  red "Run as root: sudo bash $0"
  exit 1
fi

nmcli -t -f RUNNING general status | grep -q '^running$' || {
  red "NetworkManager is not running. Start it: systemctl start NetworkManager"
  exit 1
}

cleanup() {
  ylw "Cleanup mode: deleting connections tagged '$CREATED_TAG' (if any)."
  mapfile -t CONNS < <(nmcli -t -f NAME,UUID connection show | awk -F: -v t="$CREATED_TAG" '1{print $1}')
  # We tag via connection.autoconnect-slaves and connection.id (name) suffix; easiest is grep in nmcli connection show
  mapfile -t TO_DEL < <(nmcli -f NAME connection show | awk 'NR>1{print $0}' | sed 's/^ *//' | grep -F "[$CREATED_TAG]" || true)
  if [[ ${#TO_DEL[@]} -eq 0 ]]; then
    ylw "No tagged connections found. Nothing to delete."
    exit 0
  fi
  for c in "${TO_DEL[@]}"; do
    ylw "Deleting: $c"
    nmcli connection delete "$c" || true
  done
  grn "Cleanup complete."
  exit 0
}

if [[ ${1:-} == "--cleanup" ]]; then
  cleanup
fi

printf "\n=== Bond/Teaming Wizard (balance-rr) ===\n"

# Show interfaces (exclude lo)
printf "\nAvailable interfaces (excluding lo):\n"
ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | nl -w2 -s') '

printf "\nDefaults (matches your validated setup):\n"
printf "  - mode: balance-rr (round-robin)\n"
printf "  - xmit_hash_policy: layer2\n"
printf "  - miimon: 1 ms\n"
printf "  - IPv4: DHCP (unless you choose static)\n\n"

read -rp "Number of bonds to create [1]: " BCOUNT
BCOUNT=${BCOUNT:-1}
if ! [[ "$BCOUNT" =~ ^[0-9]+$ ]] || [[ "$BCOUNT" -lt 1 ]]; then
  red "Invalid number: $BCOUNT"
  exit 1
fi

read -rp "Starting bond index (bond0 => 0) [0]: " START
START=${START:-0}
if ! [[ "$START" =~ ^[0-9]+$ ]]; then
  red "Invalid start index: $START"
  exit 1
fi

# IP selection
cat <<'EOF'
IP configuration for each bond:
  1) DHCP (default)
  2) Static IPv4
  3) No IP (L2 only)
EOF
read -rp "Choose [1-3] (default 1): " IPSEL
IPSEL=${IPSEL:-1}

# Optional MTU (blank = keep default)
read -rp $'MTU for bond (blank = keep default 1500): ' MTU

get_static() {
  read -rp "  IPv4 address/prefix (e.g. 172.18.148.238/16): " IPADDR
  read -rp "  Gateway (optional): " GW
  read -rp "  DNS (comma-separated, optional): " DNS
}

iface_exists() { ip link show "$1" >/dev/null 2>&1; }

free_device() {
  local dev="$1"
  local ac
  ac=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$dev" '$2==d{print $1; exit}') || true
  if [[ -n "${ac:-}" ]]; then
    ylw "Bringing down active connection '$ac' on device $dev"
    nmcli connection down "$ac" || true
  fi
}

create_one_bond() {
  local idx="$1"
  local bond="bond${idx}"
  local con="Bond-${bond} [$CREATED_TAG]"

  printf "\n--- Configure %s ---\n" "$bond"
  read -rp "Interfaces for $bond (space-separated, e.g. ens2f0np0 ens2f1np1): " IFACES
  if [[ -z "${IFACES// }" ]]; then
    red "No interfaces provided for $bond"
    exit 1
  fi

  # Validate interfaces
  local count=0
  for i in $IFACES; do
    ((count++)) || true
    iface_exists "$i" || { red "Interface not found: $i"; exit 1; }
  done
  if [[ $count -lt 2 ]]; then
    red "Bond requires at least 2 interfaces (you provided $count)."
    exit 1
  fi

  # Free devices (disconnect any active NM connection)
  for i in $IFACES; do
    free_device "$i"
  done

  # Create bond
  ylw "Creating bond connection: $con (ifname=$bond)"
  nmcli connection add type bond ifname "$bond" con-name "$con" mode balance-rr >/dev/null

  # Tag + options
  nmcli connection modify "$con" connection.autoconnect yes
  if [[ -n "${MTU:-}" ]]; then
    nmcli connection modify "$con" 802-3-ethernet.mtu "$MTU" || true
  fi

  # Match your validated style/options
  # miimon=1 provides very fast link detection (your current output shows polling interval 1ms)
  nmcli connection modify "$con" bond.options "miimon=1,xmit_hash_policy=layer2" || true

  # Add slaves
  local n=0
  for i in $IFACES; do
    n=$((n+1))
    local s="${bond} port ${n} [$CREATED_TAG]"
    ylw "Adding slave: $i -> $bond (connection: $s)"
    nmcli connection add type bond-slave ifname "$i" con-name "$s" master "$con" >/dev/null
  done

  # IP config
  case "$IPSEL" in
    1)
      nmcli connection modify "$con" ipv4.method auto
      ;;
    2)
      get_static
      nmcli connection modify "$con" ipv4.method manual ipv4.addresses "$IPADDR" \
        ${GW:+ipv4.gateway "$GW"} \
        ${DNS:+ipv4.dns "${DNS//,/ }"}
      ;;
    3)
      nmcli connection modify "$con" ipv4.method disabled
      ;;
  esac

  # Bring up bond
  ylw "Bringing up $bond"
  nmcli connection up "$con" >/dev/null

  grn "$bond is up. Quick checks:"
  nmcli -f NAME,TYPE,DEVICE connection show --active | grep -E "${bond}|Bond-${bond}" || true
  echo
  if [[ -r "/proc/net/bonding/$bond" ]]; then
    echo "===== /proc/net/bonding/$bond ====="
    cat "/proc/net/bonding/$bond"
  else
    ylw "Bond status file not found yet: /proc/net/bonding/$bond"
  fi
}

printf "\nThis will create %s bond(s) starting from bond%s.\n" "$BCOUNT" "$START"
read -rp "Proceed? [y/N]: " GO
GO=${GO:-N}
[[ "$GO" =~ ^[Yy]$ ]] || { ylw "Aborted."; exit 0; }

for i in $(seq 0 $((BCOUNT-1))); do
  create_one_bond $((START+i))
done

printf "\n=== Done ===\n"
cat <<'EOF'
Verification commands:
  ls -1 /proc/net/bonding/
  cat /proc/net/bonding/bond0
  nmcli connection show --active
  ip -br link
  ip -br addr

Cleanup (delete only connections created by this script):
  sudo bash nmcli_bond_balance_rr_wizard.sh --cleanup

   if above didnt cleanup use below

 nmcli -t -f UUID,TYPE con show | awk -F: '$2=="bond" || $2=="bond-slave" {print $1}' | while read -r u; do nmcli con delete uuid "$u"; done && systemctl restart NetworkManager

EOF
