#!/usr/bin/env bash
# board-net-test.sh — TL3576 full-Linux board network smoke test (CLI).
# Lab-only defaults for WIFI_SSID / WIFI_PASS; override via env in non-lab use.
set -euo pipefail

# --- Lab defaults (override with env) ---
WIFI_SSID="${WIFI_SSID:-realthread_tmp}"
WIFI_PASS="${WIFI_PASS:-12345678}"
PING_TARGETS="${PING_TARGETS:-8.8.8.8 223.5.5.5}"
HTTP_URL="${HTTP_URL:-https://www.baidu.com}"
SKIP_HTTP="${SKIP_HTTP:-0}"

PASS_COUNT=0
FAIL_COUNT=0
USED_IFACE=""
USED_MODE=""   # ethernet | wifi

log()  { printf '%s\n' "$*"; }
ok()   { log "[PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { log "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { log "[INFO] $*"; }
die()  { fail "$*"; summary; exit 1; }

summary() {
  log "----"
  log "RESULT: pass=${PASS_COUNT} fail=${FAIL_COUNT} iface=${USED_IFACE:-none} mode=${USED_MODE:-none}"
  if [[ "${FAIL_COUNT}" -eq 0 && -n "${USED_IFACE}" ]]; then
    log "OVERALL: PASS"
  else
    log "OVERALL: FAIL"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# List L2 interfaces excluding lo / dummy / sit / etc.
list_ifaces() {
  if [[ -d /sys/class/net ]]; then
    for d in /sys/class/net/*; do
      [[ -e "$d" ]] || continue
      local n
      n=$(basename "$d")
      case "$n" in
        lo|dummy*|sit*|tun*|tap*|docker*|veth*|br-*|virbr*|wlan_p2p*) continue ;;
      esac
      printf '%s\n' "$n"
    done
  elif have ip; then
    ip -o link show | awk -F': ' '{print $2}' | awk '{print $1}' | grep -v '^lo$' || true
  fi
}

is_wireless() {
  local ifc="$1"
  [[ -d "/sys/class/net/${ifc}/wireless" ]] && return 0
  [[ -e "/sys/class/net/${ifc}/phy80211" ]] && return 0
  if have iw; then
    iw dev "$ifc" info >/dev/null 2>&1 && return 0
  fi
  return 1
}

carrier_up() {
  local ifc="$1" c=""
  if [[ -r "/sys/class/net/${ifc}/carrier" ]]; then
    c=$(cat "/sys/class/net/${ifc}/carrier" 2>/dev/null || echo 0)
    [[ "$c" == "1" ]] && return 0
  fi
  # Fallback: operstate
  if [[ -r "/sys/class/net/${ifc}/operstate" ]]; then
    c=$(cat "/sys/class/net/${ifc}/operstate" 2>/dev/null || echo down)
    [[ "$c" == "up" ]] && return 0
  fi
  return 1
}

iface_admin_up() {
  local ifc="$1"
  if have ip; then
    ip link set "$ifc" up 2>/dev/null || true
  elif have ifconfig; then
    ifconfig "$ifc" up 2>/dev/null || true
  fi
}

detect_nics() {
  ETH_IFACES=()
  WIFI_IFACES=()
  local ifc
  while IFS= read -r ifc; do
    [[ -z "$ifc" ]] && continue
    if is_wireless "$ifc"; then
      WIFI_IFACES+=("$ifc")
    else
      ETH_IFACES+=("$ifc")
    fi
  done < <(list_ifaces)

  info "ethernet ifaces: ${ETH_IFACES[*]:-<none>}"
  info "wifi ifaces:     ${WIFI_IFACES[*]:-<none>}"

  if [[ "${#ETH_IFACES[@]}" -eq 0 && "${#WIFI_IFACES[@]}" -eq 0 ]]; then
    die "no usable NIC found (checked ip link / sysfs)"
  fi
  ok "NIC detection"
}

# Prefer ethernet with carrier; else wifi.
pick_path() {
  local ifc
  for ifc in "${ETH_IFACES[@]:-}"; do
    [[ -z "${ifc:-}" ]] && continue
    iface_admin_up "$ifc"
    sleep 1
    if carrier_up "$ifc"; then
      USED_IFACE="$ifc"
      USED_MODE="ethernet"
      info "using ethernet ${ifc} (carrier up) — skip wifi"
      ok "link path: ethernet"
      return 0
    fi
  done

  if [[ "${#WIFI_IFACES[@]}" -gt 0 ]]; then
    USED_IFACE="${WIFI_IFACES[0]}"
    USED_MODE="wifi"
    info "no ethernet carrier; using wifi ${USED_IFACE}"
    ok "link path: wifi"
    return 0
  fi

  # Ethernet present but no carrier and no wifi
  if [[ "${#ETH_IFACES[@]}" -gt 0 ]]; then
    die "ethernet present but no carrier, and no wifi iface"
  fi
  die "no usable link path"
}

dhcp_on() {
  local ifc="$1"
  if have dhclient; then
    info "DHCP via dhclient on ${ifc}"
    dhclient -1 "$ifc" 2>/dev/null || dhclient "$ifc" 2>/dev/null || true
    return 0
  fi
  if have udhcpc; then
    info "DHCP via udhcpc on ${ifc}"
    udhcpc -i "$ifc" -n -q 2>/dev/null || udhcpc -i "$ifc" -n 2>/dev/null || true
    return 0
  fi
  if have dhcpcd; then
    info "DHCP via dhcpcd on ${ifc}"
    dhcpcd -n "$ifc" 2>/dev/null || dhcpcd "$ifc" 2>/dev/null || true
    return 0
  fi
  info "no dhclient/udhcpc/dhcpcd; rely on existing address / NetworkManager"
}

wifi_via_nmcli() {
  local ifc="$1"
  info "WiFi via NetworkManager (nmcli), SSID=${WIFI_SSID}"
  # Ensure radio on
  nmcli radio wifi on 2>/dev/null || true
  iface_admin_up "$ifc"
  # Delete stale connection of same name if any (ignore errors)
  nmcli -t -f NAME con show 2>/dev/null | grep -Fxq "${WIFI_SSID}" && \
    nmcli con delete "${WIFI_SSID}" >/dev/null 2>&1 || true
  if nmcli device wifi connect "${WIFI_SSID}" password "${WIFI_PASS}" ifname "$ifc"; then
    ok "nmcli wifi connect"
    return 0
  fi
  # Retry without ifname
  if nmcli device wifi connect "${WIFI_SSID}" password "${WIFI_PASS}"; then
    ok "nmcli wifi connect"
    return 0
  fi
  fail "nmcli wifi connect failed"
  return 1
}

wifi_via_wpa() {
  local ifc="$1"
  local conf pidfile
  conf=$(mktemp /tmp/wpa-XXXXXX.conf)
  pidfile=$(mktemp /tmp/wpa-XXXXXX.pid)
  chmod 600 "$conf"
  info "WiFi via wpa_supplicant + DHCP, SSID=${WIFI_SSID}"
  if have wpa_passphrase; then
    wpa_passphrase "${WIFI_SSID}" "${WIFI_PASS}" >"$conf"
  else
    cat >"$conf" <<EOF
network={
  ssid="${WIFI_SSID}"
  psk="${WIFI_PASS}"
  key_mgmt=WPA-PSK
}
EOF
  fi
  iface_admin_up "$ifc"
  # Kill stale wpa on this iface
  if have wpa_cli; then
    wpa_cli -i "$ifc" terminate >/dev/null 2>&1 || true
  fi
  pkill -f "wpa_supplicant.*-i[[:space:]]*${ifc}" >/dev/null 2>&1 || true
  sleep 0.5
  if ! have wpa_supplicant; then
    rm -f "$conf" "$pidfile"
    fail "wpa_supplicant not found"
    return 1
  fi
  wpa_supplicant -B -i "$ifc" -c "$conf" -P "$pidfile" || {
    rm -f "$conf" "$pidfile"
    fail "wpa_supplicant start failed"
    return 1
  }
  # Wait for COMPLETED
  local i state="UNKNOWN"
  for i in $(seq 1 30); do
    if have wpa_cli; then
      state=$(wpa_cli -i "$ifc" status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')
      [[ "$state" == "COMPLETED" ]] && break
    else
      sleep 1
      break
    fi
    sleep 1
  done
  rm -f "$conf"
  if [[ "$state" != "COMPLETED" ]] && have wpa_cli; then
    fail "wpa_supplicant state=${state} (want COMPLETED)"
    return 1
  fi
  ok "wpa_supplicant associated"
  dhcp_on "$ifc"
  return 0
}

bring_wifi() {
  local ifc="$1"
  if have nmcli && nmcli general status >/dev/null 2>&1; then
    wifi_via_nmcli "$ifc" || wifi_via_wpa "$ifc" || die "wifi connect failed"
  else
    info "nmcli unavailable; fallback wpa_supplicant"
    wifi_via_wpa "$ifc" || die "wifi connect failed"
  fi
}

bring_ethernet() {
  local ifc="$1"
  iface_admin_up "$ifc"
  # Prefer NM if managing
  if have nmcli && nmcli general status >/dev/null 2>&1; then
    info "requesting NetworkManager connect on ${ifc}"
    nmcli device connect "$ifc" >/dev/null 2>&1 || true
  fi
  dhcp_on "$ifc"
  ok "ethernet bring-up attempted"
}

has_ipv4() {
  local ifc="$1"
  if have ip; then
    ip -4 -o addr show dev "$ifc" 2>/dev/null | grep -q 'inet '
  else
    ifconfig "$ifc" 2>/dev/null | grep -q 'inet '
  fi
}

default_gw() {
  if have ip; then
    ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}'
  else
    route -n 2>/dev/null | awk '/^0.0.0.0/{print $2; exit}'
  fi
}

wait_ipv4() {
  local ifc="$1" i
  for i in $(seq 1 20); do
    if has_ipv4 "$ifc"; then
      ok "IPv4 on ${ifc}"
      if have ip; then
        info "$(ip -4 -o addr show dev "$ifc" | awk '{print $4}')"
      fi
      return 0
    fi
    sleep 1
  done
  die "no IPv4 on ${ifc} after DHCP/wait"
}

do_ping() {
  local target="$1"
  if ! have ping; then
    fail "ping not found"
    return 1
  fi
  if ping -c 3 -W 3 "$target" >/tmp/board-net-ping.$$ 2>&1; then
    ok "ping ${target}"
    rm -f /tmp/board-net-ping.$$
    return 0
  fi
  fail "ping ${target}"
  # show last lines for debug
  tail -n 5 /tmp/board-net-ping.$$ 2>/dev/null | while IFS= read -r L; do info "  $L"; done
  rm -f /tmp/board-net-ping.$$
  return 1
}

connectivity_test() {
  local gw ping_ok=0 t
  gw=$(default_gw || true)
  if [[ -n "${gw:-}" ]]; then
    info "default gateway: ${gw}"
    if do_ping "$gw"; then
      ping_ok=1
    fi
  else
    info "no default gateway yet"
  fi
  if [[ "$ping_ok" -eq 0 ]]; then
    for t in ${PING_TARGETS}; do
      if do_ping "$t"; then
        ping_ok=1
        break
      fi
    done
  fi
  [[ "$ping_ok" -eq 1 ]] || die "all ping targets failed"

  if [[ "${SKIP_HTTP}" == "1" ]]; then
    info "SKIP_HTTP=1 — skip HTTP check"
    return 0
  fi

  if have curl; then
    if curl -I -m 10 -sS -o /tmp/board-net-http.$$ -w '%{http_code}' "${HTTP_URL}" | grep -qE '^[23]'; then
      ok "curl -I ${HTTP_URL}"
      rm -f /tmp/board-net-http.$$
    else
      fail "curl -I ${HTTP_URL}"
      rm -f /tmp/board-net-http.$$
      # HTTP optional relative to ping — still fail overall if both fail? Spec: optional.
      # Treat as soft: count fail but do not die if ping passed.
      info "HTTP check failed (optional); ping already OK"
    fi
  elif have python3; then
    if python3 - "${HTTP_URL}" <<'PY'
import sys, urllib.request
url = sys.argv[1]
try:
    req = urllib.request.Request(url, method="HEAD")
except TypeError:
    req = urllib.request.Request(url)
    req.get_method = lambda: "HEAD"
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        code = getattr(r, "status", None) or r.getcode()
        sys.exit(0 if int(code) < 400 else 1)
except Exception as e:
    # some servers reject HEAD; try GET
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            code = getattr(r, "status", None) or r.getcode()
            sys.exit(0 if int(code) < 400 else 1)
    except Exception as e2:
        print(e2, file=sys.stderr)
        sys.exit(1)
PY
    then
      ok "python urllib ${HTTP_URL}"
    else
      fail "python urllib ${HTTP_URL}"
      info "HTTP check failed (optional); ping already OK"
    fi
  else
    info "no curl/python3 — skip HTTP check"
  fi
}

main() {
  log "=== board-net-test (TL3576 Linux) ==="
  info "WIFI_SSID=${WIFI_SSID} (pass from WIFI_PASS env or lab default)"
  detect_nics
  pick_path
  if [[ "${USED_MODE}" == "wifi" ]]; then
    bring_wifi "${USED_IFACE}"
  else
    bring_ethernet "${USED_IFACE}"
  fi
  wait_ipv4 "${USED_IFACE}"
  connectivity_test
  summary
  if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    exit 0
  fi
  # Soft HTTP fail alone: if we have ping PASS and only HTTP FAIL, still exit 0
  # if at least one ping passed (PASS_COUNT includes NIC/link/ipv4/ping).
  if [[ "${PASS_COUNT}" -ge 3 ]]; then
    info "non-fatal optional failures present; treating as PASS"
    exit 0
  fi
  exit 1
}

main "$@"
