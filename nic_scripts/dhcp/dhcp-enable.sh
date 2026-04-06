
#!/usr/bin/env bash
# dhcp-all-one.sh
# One-run, integrated DHCP setup for RHEL 9 / SLES / Ubuntu.
# IPv4 DHCP only (kept simple). It uses NetworkManager when available,
# otherwise wicked (SLES) or netplan (Ubuntu Server).
# It also cleans duplicate dhcp-* profiles and sets autoconnect=yes.

set -euo pipefail

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }

has_cmd()   { command -v "$1" >/dev/null 2>&1; }
is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
os_id()     { awk -F= '/^ID=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null; }

# List physical ethernet-like interfaces (skip loopback & typical virtuals)
list_ifaces() {
  ip -o link show | awk -F': ' '{print $2}' | while read -r if; do
    case "$if" in
      lo|veth*|docker*|br*|virbr*|wg*|tun*|tap*|vt*|macvtap*|team*|bond*|bridge*|vlan*)
        continue ;;
    esac
    if ip -o link show "$if" | grep -q "link/ether"; then
      echo "$if"
    fi
  done
}

bring_up_link() {
  local if="$1"
  ip link set "$if" up || true
}

########################################
# NetworkManager path (preferred)      #
########################################
nm_enable() {
  if ! is_active NetworkManager; then
    warn "NetworkManager not active; enabling it."
    systemctl enable --now NetworkManager >/dev/null 2>&1 || warn "Could not enable NetworkManager"
  fi
}

nm_bound_conn_for_dev() {
  # Return first ethernet connection name bound to device
  local dev="$1"
  nmcli -g NAME,DEVICE,TYPE connection show \
    | awk -F: -v d="$dev" '$2==d && $3=="ethernet"{print $1}' \
    | head -n1
}

nm_cleanup_duplicates_for_dev() {
  local dev="$1"
  local target_name="dhcp-$dev"

  # Gather all ethernet connections that have the same dhcp-$dev name
  # Keep the one that is ACTIVE/bound to the device, delete others
  nmcli -f NAME,UUID,TYPE,DEVICE,ACTIVE connection show \
    | awk -v name="$target_name" -F'  +' '$1==name && $3=="ethernet"{print $1"\t"$2"\t"$4"\t"$5}' \
    | while IFS=$'\t' read -r name uuid device active; do
        if [[ "$device" == "$dev" || "$active" == "yes" ]]; then
          log "Keeping $name (UUID $uuid) for $dev"
        else
          log "Deleting duplicate $name (UUID $uuid) for $dev"
          nmcli connection delete "$uuid" >/dev/null 2>&1 || true
        fi
      done
}

nm_set_dhcp_for_dev() {
  local dev="$1"

  # Make sure NM manages and sees the device
  nmcli device set "$dev" managed yes >/dev/null 2>&1 || true

  # Prefer an existing profile already bound to this device
  local con
  con="$(nm_bound_conn_for_dev "$dev")"
  if [[ -n "${con:-}" ]]; then
    log "Configuring existing NM connection '$con' for $dev (DHCP, autoconnect)"
    nmcli connection modify "$con" \
      ipv4.method auto \
      ipv6.method ignore \
      connection.autoconnect yes
    nmcli connection up "$con" >/dev/null 2>&1 || nmcli device connect "$dev" >/dev/null 2>&1 || true
  else
    local new="dhcp-$dev"
    log "Creating NM connection '$new' for $dev (DHCP, autoconnect)"
    nmcli connection add type ethernet ifname "$dev" con-name "$new" \
      ipv4.method auto \
      ipv6.method ignore \
      connection.autoconnect yes
    nmcli connection up "$new" >/dev/null 2>&1 || nmcli device connect "$dev" >/dev/null 2>&1 || true
  fi

  # Clean duplicate dhcp-* profiles for this device
  nm_cleanup_duplicates_for_dev "$dev"

  bring_up_link "$dev"
}

configure_networkmanager_all() {
  if ! has_cmd nmcli; then return 1; fi
  nm_enable

  local any=0
  while IFS= read -r if; do
    nm_set_dhcp_for_dev "$if"
    any=1
  done < <(list_ifaces)

  if [[ $any -eq 0 ]]; then
    warn "No ethernet interfaces found for NetworkManager."
    return 1
  fi
  return 0
}

#####################
# wicked (SLES)     #
#####################
wicked_set_dhcp_for_dev() {
  local dev="$1"
  local f="/etc/sysconfig/network/ifcfg-$dev"
  log "Writing $f (DHCP)"
  cat > "$f" <<EOF
BOOTPROTO='dhcp'
STARTMODE='auto'
EOF
  wicked ifup "$dev" >/dev/null 2>&1 || wicked ifreload "$dev" >/dev/null 2>&1 || true
  bring_up_link "$dev"
}

configure_wicked_all() {
  if ! is_active wicked; then return 1; fi
  local any=0
  while IFS= read -r if; do
    wicked_set_dhcp_for_dev "$if"
    any=1
  done < <(list_ifaces)
  systemctl enable --now wicked >/dev/null 2>&1 || warn "Could not enable wicked"
  [[ $any -eq 1 ]]
}

#####################
# netplan (Ubuntu)  #
#####################
write_netplan_dhcp_all() {
  local f="/etc/netplan/99-dhcp-all.yaml"
  log "Writing netplan $f"
  cat > "$f" <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
EOF

  while IFS= read -r if; do
    cat >> "$f" <<EOF
    $if:
      dhcp4: true
      optional: true
EOF
  done < <(list_ifaces)

  if has_cmd netplan; then
    netplan apply >/dev/null 2>&1 || warn "netplan apply failed"
  fi
}

configure_netplan_all() {
  if ! has_cmd netplan; then return 1; fi
  write_netplan_dhcp_all
  return 0
}

########
# Main #
########
main() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo bash $0"
    exit 1
  fi

  local id
  id="$(os_id || echo unknown)"
  log "Detected OS ID: $id"

  # Prefer NetworkManager (works for RHEL 9, SLES with NM, Ubuntu with NM)
  if configure_networkmanager_all; then
    log "✅ DHCP configured via NetworkManager."
    exit 0
  fi

  # SLES wicked
  if configure_wicked_all; then
    log "✅ DHCP configured via wicked."
    exit 0
  fi

  # Ubuntu netplan
  if configure_netplan_all; then
    log "✅ DHCP configured via netplan."
    exit 0
  fi

  warn "❌ No supported network stack found. Ensure NetworkManager, wicked, or netplan is installed."
  exit 1
}

main
``

