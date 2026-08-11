#!/system/bin/sh
set -u

VM_DIR=/data/local/openwrt
BUNDLED_CROSVM="$VM_DIR/crosvm"
CROSVM=""
CROSVM_STYLE=""
DISK="$VM_DIR/openwrt.img"
KERNEL="$VM_DIR/Image"
CONFIG="$VM_DIR/vm.conf"
PIDFILE="$VM_DIR/crosvm.pid"
MONITOR_PIDFILE="$VM_DIR/network-monitor.pid"
ACTIVE_MODE_FILE="$VM_DIR/active-tether-mode"
RA6="$VM_DIR/ra6"
KVM_PROBE="$VM_DIR/kvm-probe"
DHCP_RELAY="$VM_DIR/dhcp-relay"
IPV6_PREFIX_FILE="$VM_DIR/ipv6-prefix"
TAKEOVER_FLAG="$VM_DIR/takeover.enabled"
SOCKET="$VM_DIR/crosvm.sock"
LOG="$VM_DIR/crosvm.log"
CONSOLE="$VM_DIR/console.log"
WAN_TAP=owrt-wan
LAN_TAP=owrt-lan
DEFAULT_LAN_BRIDGE=owrt-br
NATIVE_TETHER_BRIDGE=br0
LAN_BRIDGE="$DEFAULT_LAN_BRIDGE"
WAN_HOST_IP=192.168.66.1
WAN_SUBNET=192.168.66.0/24
WAN_GUEST_IP=192.168.66.2
LAN_HOST_IP=192.168.88.2
LAN_SUBNET=192.168.88.0/24
LAN_GUEST_IP=192.168.88.1
# Android's iproute2 has no rt_tables file, so custom tables must be numeric.
# 1000 is unused by the framework (it uses 97-99 and 100+ per-network tables).
OWRT_TABLE=1000
RULE_PRIO=100
ROUTED_TETHER_RULE_PRIO=1053
UPSTREAM_RULE_PRIO=1050
IPV6_OUT_RULE_PRIO=1051
IPV6_IN_RULE_PRIO=1052
IPV6_BLOCK_PRIO=100
IPV6_FORWARD_CHAIN=OWT6_VM
# Android's policy routing ends with "from all unreachable"; without an
# explicit rule, packets from the Android host itself to the OpenWrt subnets
# are dropped before reaching the taps. Point them at the main table.
HOST_ROUTE_PRIO=1049
SSH_DNAT_PORT=2223
WEB_DNAT_PORT=8080
ROUTED_IFACES_FILE="$VM_DIR/routed-tethers"
PROXYARP_IFACES_FILE="$VM_DIR/proxyarp-tethers"
DIRECT_BR0_ADDR_FILE="$VM_DIR/direct-br0.addr"
EFFECTIVE_TETHER_MODE=""
EFFECTIVE_CPU_AFFINITY=""
EFFECTIVE_CPU_CAPACITY=""
EFFECTIVE_CPU_CLUSTERS=""
UNSAFE_NATIVE_BRIDGE=0

die() {
    echo "openwrt: $*" >&2
    exit 1
}

load_config() {
    [ -r "$CONFIG" ] || die "missing $CONFIG; run deploy-openwrt.sh first"
    . "$CONFIG"
    : "${ROOT_DEVICE:=/dev/vda}"
    : "${VM_CPUS:=4}"
    : "${VM_CPU_AFFINITY:=auto}"
    : "${VM_MEMORY_MIB:=1024}"
    : "${AUTO_TAKEOVER:=0}"
    : "${IPV6_PASSTHROUGH:=1}"
    : "${CROSVM_PATH:=auto}"
    : "${CELLULAR_IFACE:=auto}"
    : "${CELLULAR_ROUTE_TABLE:=auto}"
    : "${TETHER_IFACE_PATTERNS:=auto}"
    : "${TETHER_MODE:=auto}"
    case "$IPV6_PASSTHROUGH" in
        0|1) ;;
        *) die "IPV6_PASSTHROUGH must be 0 or 1" ;;
    esac
    case "$TETHER_MODE" in
        auto|bridge|routed|proxyarp|directbr0) ;;
        *) die "TETHER_MODE must be auto, bridge, routed, proxyarp, or directbr0" ;;
    esac
}

resolve_tether_mode() {
    LAN_BRIDGE="$DEFAULT_LAN_BRIDGE"
    platform="$(getprop ro.board.platform 2>/dev/null | tr 'A-Z' 'a-z')"
    soc="$(getprop ro.soc.model 2>/dev/null | tr 'A-Z' 'a-z')"
    product="$(getprop ro.product.device 2>/dev/null | tr 'A-Z' 'a-z')"
    model="$(getprop ro.product.model 2>/dev/null | tr 'A-Z' 'a-z')"
    UNSAFE_NATIVE_BRIDGE=0
    if { [ "$platform" = ums9620 ] || [ "$soc" = t760 ]; } && \
            { [ "$product" = mu300 ] || [ "$model" = f50 ]; } && \
            [ -d /sys/module/sprd_wlan_combo ]; then
        UNSAFE_NATIVE_BRIDGE=1
    fi
    case "$TETHER_MODE" in
        bridge|routed|proxyarp|directbr0) EFFECTIVE_TETHER_MODE="$TETHER_MODE" ;;
        auto)
            # UMS9620's Android 13 sprd_wlan_combo driver corrupts an skb when
            # its native hotspot bridge is extended with another Linux bridge.
            if [ "$UNSAFE_NATIVE_BRIDGE" = 1 ]; then
                EFFECTIVE_TETHER_MODE=proxyarp
            else
                EFFECTIVE_TETHER_MODE=bridge
            fi
            ;;
    esac
    [ "$EFFECTIVE_TETHER_MODE" = directbr0 ] && LAN_BRIDGE="$NATIVE_TETHER_BRIDGE"
}

use_active_tether_mode() {
    [ -r "$ACTIVE_MODE_FILE" ] || return 0
    active_mode="$(cat "$ACTIVE_MODE_FILE" 2>/dev/null)"
    case "$active_mode" in
        bridge|routed|proxyarp|directbr0) EFFECTIVE_TETHER_MODE="$active_mode" ;;
        *) return 0 ;;
    esac
    LAN_BRIDGE="$DEFAULT_LAN_BRIDGE"
    [ "$EFFECTIVE_TETHER_MODE" = directbr0 ] && LAN_BRIDGE="$NATIVE_TETHER_BRIDGE"
}

detect_cellular_iface() {
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        case "$iface" in
            sipa_eth*|rmnet_data*|rmnet*|ccmni*|seth*|pdp*)
                if ip -6 -o addr show dev "$iface" scope global 2>/dev/null | grep -q .; then
                    echo "$iface"
                    return 0
                fi
                ;;
        esac
    done
    for iface in sipa_eth0 rmnet_data0 ccmni0 seth_lte0; do
        [ -e "/sys/class/net/$iface" ] && { echo "$iface"; return 0; }
    done
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        case "$iface" in
            sipa_eth*|rmnet_data*|ccmni*|seth*|pdp*) echo "$iface"; return 0 ;;
        esac
    done
    return 1
}

resolve_cpu_affinity() {
    EFFECTIVE_CPU_AFFINITY=""
    EFFECTIVE_CPU_CAPACITY=""
    EFFECTIVE_CPU_CLUSTERS=""
    case "$VM_CPU_AFFINITY" in
        none) return 0 ;;
        auto)
            selected_cpus="$(
                for cpu_path in /sys/devices/system/cpu/cpu[0-9]*; do
                    cpu_id="${cpu_path##*cpu}"
                    if [ -r "$cpu_path/online" ] && [ "$(cat "$cpu_path/online" 2>/dev/null)" != 1 ]; then
                        continue
                    fi
                    cpu_score="$(cat "$cpu_path/cpu_capacity" 2>/dev/null)"
                    [ -n "$cpu_score" ] || cpu_score="$(cat "$cpu_path/cpufreq/cpuinfo_max_freq" 2>/dev/null)"
                    case "$cpu_score" in *[!0-9]*|'') cpu_score=0 ;; esac
                    echo "$cpu_score $cpu_id"
                done | sort -k1,1nr -k2,2n | head -n "$VM_CPUS"
            )"
            selected_count="$(printf '%s\n' "$selected_cpus" | sed '/^$/d' | wc -l | tr -d ' ')"
            [ "$selected_count" = "$VM_CPUS" ] || \
                die "VM_CPUS=$VM_CPUS exceeds the number of online Android CPUs ($selected_count)"
            EFFECTIVE_CPU_AFFINITY="$(printf '%s\n' "$selected_cpus" | awk '
                { if (NR > 1) printf ":"; printf "%d=%s", NR - 1, $2 }
                END { print "" }
            ')"
            # Tell the guest scheduler that a vCPU pinned to a little core is
            # not equivalent to one pinned to a big core. Normalize either
            # cpu_capacity or the cpufreq fallback to crosvm's 1024 scale.
            EFFECTIVE_CPU_CAPACITY="$(printf '%s\n' "$selected_cpus" | awk '
                NR == 1 { max = $1 }
                {
                    capacity = max > 0 ? int(($1 * 1024 + max / 2) / max) : 1024
                    if (capacity < 1) capacity = 1
                    if (NR > 1) printf ","
                    printf "%d=%d", NR - 1, capacity
                }
                END { print "" }
            ')"
            # selected_cpus is capacity-sorted, so equal-capacity vCPUs are
            # contiguous and can be represented as crosvm CPU clusters.
            EFFECTIVE_CPU_CLUSTERS="$(printf '%s\n' "$selected_cpus" | awk '
                function emit(first, last) {
                    if (output != "") output = output " "
                    output = output (first == last ? first : first "-" last)
                }
                NR == 1 { previous = $1; first = 0; next }
                $1 != previous { emit(first, NR - 2); first = NR - 1; previous = $1 }
                END { if (NR > 0) emit(first, NR - 1); print output }
            ')"
            ;;
        *[!0-9,:=-]*|'') die "invalid VM_CPU_AFFINITY: $VM_CPU_AFFINITY" ;;
        *) EFFECTIVE_CPU_AFFINITY="$VM_CPU_AFFINITY" ;;
    esac
}

resolve_device_config() {
    case "$CROSVM_PATH" in
        auto)
            for candidate in \
                    /apex/com.android.virt/bin/crosvm \
                    /system/bin/crosvm /system_ext/bin/crosvm /vendor/bin/crosvm; do
                if [ -x "$candidate" ]; then
                    CROSVM="$candidate"
                    break
                fi
            done
            [ -n "$CROSVM" ] || CROSVM="$BUNDLED_CROSVM"
            ;;
        bundled) CROSVM="$BUNDLED_CROSVM" ;;
        /*) CROSVM="$CROSVM_PATH" ;;
        *) die "CROSVM_PATH must be auto, bundled, or an absolute device path" ;;
    esac
    [ -x "$CROSVM" ] || die "crosvm is not executable: $CROSVM"

    crosvm_help="$("$CROSVM" run --help 2>&1)"
    if echo "$crosvm_help" | grep -q -- '--block'; then
        CROSVM_STYLE=block
    elif echo "$crosvm_help" | grep -q -- '--rwdisk'; then
        CROSVM_STYLE=rwdisk
    else
        die "unsupported crosvm command line: neither --block nor --rwdisk is available"
    fi
    resolve_cpu_affinity
    if [ -n "$EFFECTIVE_CPU_AFFINITY" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-affinity'; then
        die "selected crosvm does not support --cpu-affinity"
    fi
    if [ -n "$EFFECTIVE_CPU_CAPACITY" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-capacity'; then
        die "selected crosvm does not support --cpu-capacity"
    fi
    if [ -n "$EFFECTIVE_CPU_CLUSTERS" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-cluster'; then
        die "selected crosvm does not support --cpu-cluster"
    fi

    if [ "$CELLULAR_IFACE" = auto ]; then
        CELLULAR_IFACE="$(detect_cellular_iface)" || \
            die "cannot detect cellular interface; set CELLULAR_IFACE in config.env"
    fi
    [ -e "/sys/class/net/$CELLULAR_IFACE" ] || \
        die "cellular interface does not exist: $CELLULAR_IFACE"
    [ "$CELLULAR_ROUTE_TABLE" = auto ] && CELLULAR_ROUTE_TABLE="$CELLULAR_IFACE"
    resolve_tether_mode
}

matches_tether_pattern() {
    iface="$1"
    [ "$TETHER_IFACE_PATTERNS" = auto ] && return 0
    for pattern in $TETHER_IFACE_PATTERNS; do
        case "$iface" in $pattern) return 0 ;; esac
    done
    return 1
}

is_tether_candidate() {
    iface="$1"
    case "$iface" in
        lo|dummy*|tun*|ip6tnl*|sit*|gre*|gretap*|erspan*|vowifi*|owrt-*|owx-*) return 1 ;;
    esac
    [ "$iface" = "$CELLULAR_IFACE" ] && return 1
    matches_tether_pattern "$iface" && is_tethered "$iface"
}

# Potential downstreams must be protected before Android reports TetheredState.
# Otherwise IpServer can leak its first .0.x/42.x DHCP offer during USB gadget
# recreation, before the network monitor has attached the interface to OpenWrt.
is_tether_capable() {
    iface="$1"
    if [ "$TETHER_IFACE_PATTERNS" != auto ]; then
        matches_tether_pattern "$iface"
        return
    fi
    case "$iface" in
        sipa_usb*|rndis*|wlan*|softap*|ap_br_wlan*|ap_br_softap*|bt-pan) return 0 ;;
    esac
    return 1
}

is_running() {
    [ -r "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    [ -d "/proc/$pid" ] || return 1
    tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$CROSVM"
}

ensure_jump() {
    table="$1"
    parent="$2"
    child="$3"
    if ! iptables -t "$table" -C "$parent" -j "$child" 2>/dev/null; then
        iptables -t "$table" -I "$parent" 1 -j "$child"
    fi
}

delete_jump_and_chain() {
    table="$1"
    parent="$2"
    child="$3"
    while iptables -t "$table" -C "$parent" -j "$child" 2>/dev/null; do
        iptables -t "$table" -D "$parent" -j "$child" || break
    done
    iptables -t "$table" -F "$child" 2>/dev/null || true
    iptables -t "$table" -X "$child" 2>/dev/null || true
}

delete_ip6_jump_and_chain() {
    parent="$1"
    child="$2"
    while ip6tables -C "$parent" -j "$child" 2>/dev/null; do
        ip6tables -D "$parent" -j "$child" || break
    done
    ip6tables -F "$child" 2>/dev/null || true
    ip6tables -X "$child" 2>/dev/null || true
}

ensure_ip6_jump() {
    parent="$1"
    child="$2"
    if ! ip6tables -C "$parent" -j "$child" 2>/dev/null; then
        ip6tables -I "$parent" 1 -j "$child"
    fi
}

is_tethered() {
    dumpsys tethering 2>/dev/null | grep -q "^[[:space:]]*$1 - TetheredState"
}

bridge_attach() {
    iface="$1"
    [ -e "/sys/class/net/$iface" ] || return 0
    if [ -d "/sys/class/net/$iface/bridge" ]; then
        tag="$(printf '%s' "$iface" | tr -cd 'A-Za-z0-9' | cut -c1-7)"
        connector_host="owx-${tag}h"
        connector_peer="owx-${tag}p"
        if [ ! -e "/sys/class/net/$connector_host" ]; then
            ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' > "$VM_DIR/bridge-$iface.addr"
            ip link add "$connector_host" type veth peer name "$connector_peer"
            ip link set dev "$connector_host" master "$LAN_BRIDGE"
            ip link set dev "$connector_peer" master "$iface"
            ip link set dev "$connector_host" up
            ip link set dev "$connector_peer" up
            touch "$VM_DIR/bridge-$iface.connector"
        fi
        ip -4 addr flush dev "$iface" 2>/dev/null || true
        ip link set dev "$iface" up
        return 0
    fi
    current_master="$(basename "$(readlink "/sys/class/net/$iface/master" 2>/dev/null)" 2>/dev/null)"
    if [ "$current_master" != "$LAN_BRIDGE" ]; then
        ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' > "$VM_DIR/bridge-$iface.addr"
        ip link set dev "$iface" master "$LAN_BRIDGE"
    fi
    # Android's IpServer may re-add its 42-49.x IPv4 address after an upstream
    # change. Keep IPv4 DHCP/routing on OpenWrt, but retain Android's global
    # IPv6 address so its cellular RA and IPv6 forwarding continue to work.
    ip -4 addr flush dev "$iface" 2>/dev/null || true
    ip link set dev "$iface" up
}

bridge_detach() {
    iface="$1"
    [ -e "/sys/class/net/$iface" ] || return 0
    if [ -e "$VM_DIR/bridge-$iface.connector" ]; then
        tag="$(printf '%s' "$iface" | tr -cd 'A-Za-z0-9' | cut -c1-7)"
        ip link delete "owx-${tag}h" 2>/dev/null || true
        if [ -s "$VM_DIR/bridge-$iface.addr" ]; then
            while read -r saved_addr; do
                [ -n "$saved_addr" ] && ip -4 addr add "$saved_addr" dev "$iface" 2>/dev/null || true
            done < "$VM_DIR/bridge-$iface.addr"
        fi
        rm -f "$VM_DIR/bridge-$iface.addr" "$VM_DIR/bridge-$iface.connector"
        return 0
    fi
    current_master="$(basename "$(readlink "/sys/class/net/$iface/master" 2>/dev/null)" 2>/dev/null)"
    [ "$current_master" = "$LAN_BRIDGE" ] || return 0
    ip link set dev "$iface" nomaster
    if [ -s "$VM_DIR/bridge-$iface.addr" ]; then
        while read -r saved_addr; do
            [ -n "$saved_addr" ] && ip -4 addr add "$saved_addr" dev "$iface" 2>/dev/null || true
        done < "$VM_DIR/bridge-$iface.addr"
    fi
    rm -f "$VM_DIR/bridge-$iface.addr"
}

sync_bridge_ports() {
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        if is_tether_candidate "$iface"; then
            bridge_attach "$iface"
        elif [ -e "$VM_DIR/bridge-$iface.addr" ] || \
                [ -e "$VM_DIR/bridge-$iface.connector" ]; then
            bridge_detach "$iface"
        fi
    done
}

ensure_owrt_routes() {
    if [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
        ip route replace "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE" table "$OWRT_TABLE"
        ip route replace default via "$LAN_GUEST_IP" dev "$LAN_BRIDGE" onlink table "$OWRT_TABLE"
    else
        ip route replace "$LAN_SUBNET" dev "$LAN_BRIDGE" table "$OWRT_TABLE"
        ip route replace default via "$LAN_GUEST_IP" dev "$LAN_BRIDGE" table "$OWRT_TABLE"
    fi
    ip route replace "$WAN_SUBNET" dev "$WAN_TAP" table "$OWRT_TABLE"
}

clear_routed_tethers() {
    while ip -4 rule del priority "$ROUTED_TETHER_RULE_PRIO" 2>/dev/null; do :; done
    delete_jump_and_chain nat PREROUTING OWT_RPRE
    rm -f "$ROUTED_IFACES_FILE"
}

stop_dhcp_relay() {
    iface="$1"
    pidfile="$VM_DIR/dhcp-relay-$iface.pid"
    if [ -r "$pidfile" ]; then
        relay_pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$relay_pid" ] && [ -r "/proc/$relay_pid/cmdline" ] && \
                tr '\000' ' ' < "/proc/$relay_pid/cmdline" | grep -q "$DHCP_RELAY"; then
            kill "$relay_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$pidfile"
}

restore_proxyarp_iface() {
    iface="$1"
    stop_dhcp_relay "$iface"
    ip route del "$LAN_SUBNET" dev "$iface" metric 42700 2>/dev/null || true
    saved="$VM_DIR/proxyarp-$iface.original"
    if [ -r "$saved" ] && [ -w "/proc/sys/net/ipv4/conf/$iface/proxy_arp" ]; then
        cat "$saved" > "/proc/sys/net/ipv4/conf/$iface/proxy_arp"
    fi
    rm -f "$saved"
}

clear_proxyarp_tethers() {
    if [ -r "$PROXYARP_IFACES_FILE" ]; then
        while read -r iface; do
            [ -n "$iface" ] && restore_proxyarp_iface "$iface"
        done < "$PROXYARP_IFACES_FILE"
    fi
    for pidfile in "$VM_DIR"/dhcp-relay-*.pid; do
        [ -e "$pidfile" ] || continue
        iface="${pidfile##*/dhcp-relay-}"
        iface="${iface%.pid}"
        stop_dhcp_relay "$iface"
    done
    saved="$VM_DIR/proxyarp-$LAN_BRIDGE.original"
    if [ -r "$saved" ] && [ -w "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp" ]; then
        cat "$saved" > "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp"
    fi
    rm -f "$saved" "$PROXYARP_IFACES_FILE"
    ip route del "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE" 2>/dev/null || true
}

ensure_dhcp_relay() {
    iface="$1"
    pidfile="$VM_DIR/dhcp-relay-$iface.pid"
    if [ -r "$pidfile" ]; then
        relay_pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$relay_pid" ] && [ -r "/proc/$relay_pid/cmdline" ] && \
                tr '\000' ' ' < "/proc/$relay_pid/cmdline" | grep -Fq "$DHCP_RELAY $iface $LAN_TAP"; then
            return 0
        fi
    fi
    stop_dhcp_relay "$iface"
    nohup "$DHCP_RELAY" "$iface" "$LAN_TAP" \
        </dev/null >"$VM_DIR/dhcp-relay-$iface.log" 2>&1 &
    echo "$!" > "$pidfile"
}

sync_proxyarp_tethers() {
    desired="$VM_DIR/proxyarp-tethers.next"
    : > "$desired"
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        echo "$iface" >> "$desired"
    done

    if [ -r "$PROXYARP_IFACES_FILE" ]; then
        while read -r iface; do
            [ -n "$iface" ] || continue
            grep -Fxq "$iface" "$desired" 2>/dev/null || restore_proxyarp_iface "$iface"
        done < "$PROXYARP_IFACES_FILE"
    fi

    clear_routed_tethers
    ensure_owrt_routes
    ip route replace "$LAN_GUEST_IP/32" dev "$LAN_BRIDGE"
    saved="$VM_DIR/proxyarp-$LAN_BRIDGE.original"
    if [ ! -r "$saved" ]; then
        cat "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp" > "$saved"
    fi
    echo 1 > "/proc/sys/net/ipv4/conf/$LAN_BRIDGE/proxy_arp"

    while read -r iface; do
        [ -n "$iface" ] || continue
        saved="$VM_DIR/proxyarp-$iface.original"
        if [ ! -r "$saved" ]; then
            cat "/proc/sys/net/ipv4/conf/$iface/proxy_arp" > "$saved"
        fi
        echo 1 > "/proc/sys/net/ipv4/conf/$iface/proxy_arp"
        # The /32 keeps OpenWrt itself on owrt-br; the less-specific route
        # sends all leased clients back to the untouched Android tether port.
        ip route replace "$LAN_SUBNET" dev "$iface" metric 42700
        ip -4 rule add priority "$ROUTED_TETHER_RULE_PRIO" iif "$iface" lookup "$OWRT_TABLE"
        ensure_dhcp_relay "$iface"
    done < "$desired"
    mv -f "$desired" "$PROXYARP_IFACES_FILE"
}

sync_routed_tethers() {
    desired=""
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        desired="${desired}${iface}
"
    done
    clear_proxyarp_tethers
    clear_routed_tethers
    ensure_owrt_routes
    iptables -t nat -N OWT_RPRE 2>/dev/null || true
    iptables -t nat -F OWT_RPRE
    printf '%s' "$desired" | while read -r iface; do
        [ -n "$iface" ] || continue
        ip -4 rule add priority "$ROUTED_TETHER_RULE_PRIO" iif "$iface" lookup "$OWRT_TABLE"
        # Android advertises itself as DNS. Send client DNS to OpenWrt so its
        # dnsmasq/PassWall policy is still applied in routed fallback mode.
        iptables -t nat -A OWT_RPRE -i "$iface" -p udp --dport 53 \
            -j DNAT --to-destination "$LAN_GUEST_IP:53"
        iptables -t nat -A OWT_RPRE -i "$iface" -p tcp --dport 53 \
            -j DNAT --to-destination "$LAN_GUEST_IP:53"
    done
    ensure_jump nat PREROUTING OWT_RPRE
    printf '%s' "$desired" > "$ROUTED_IFACES_FILE"
}

save_direct_br0_state() {
    [ -d "/sys/class/net/$NATIVE_TETHER_BRIDGE/bridge" ] || \
        die "native tether bridge does not exist: $NATIVE_TETHER_BRIDGE"
    if [ ! -r "$DIRECT_BR0_ADDR_FILE" ]; then
        ip -4 -o addr show dev "$NATIVE_TETHER_BRIDGE" 2>/dev/null | \
            awk '{print $4}' > "$DIRECT_BR0_ADDR_FILE"
    fi
}

restart_android_tether_dns() {
    command -v ndc >/dev/null 2>&1 || return 0
    ndc tether status 2>/dev/null | grep -q 'Tethering services started' || return 0
    if ! ndc tether stop >/dev/null 2>&1 || ! ndc tether start >/dev/null 2>&1; then
        echo "openwrt: warning: could not restart Android tether DNS" >&2
        return 1
    fi
}

sync_direct_br0() {
    save_direct_br0_state
    clear_routed_tethers
    clear_proxyarp_tethers
    [ -e "/sys/class/net/$LAN_TAP" ] || return 0
    current_master="$(basename "$(readlink "/sys/class/net/$LAN_TAP/master" 2>/dev/null)" 2>/dev/null)"
    if [ "$current_master" != "$NATIVE_TETHER_BRIDGE" ]; then
        ip link set dev "$LAN_TAP" nomaster 2>/dev/null || true
        ip link set dev "$LAN_TAP" master "$NATIVE_TETHER_BRIDGE"
    fi
    ip link set dev "$LAN_TAP" up
    ip link set dev "$NATIVE_TETHER_BRIDGE" up
    # Keep Android IpServer's original address as a secondary address and add
    # OpenWrt's management address alongside it. Removing Android's address
    # makes this vendor's dnsmasq 2.51 spin forever while rebuilding listeners.
    # DHCP suppression still prevents clients from receiving Android's subnet.
    if ! ip -4 -o addr show dev "$NATIVE_TETHER_BRIDGE" 2>/dev/null | \
            awk '{print $4}' | grep -Fxq "$LAN_HOST_IP/24"; then
        ip -4 addr add "$LAN_HOST_IP/24" dev "$NATIVE_TETHER_BRIDGE"
        # dnsmasq 2.51 loops in check_dns_listeners after any address change.
        # Recreate only netd's tether DNS child once; hotspot/AP state stays up.
        restart_android_tether_dns || true
    fi
}

restore_direct_br0() {
    ip link set dev "$LAN_TAP" nomaster 2>/dev/null || true
    if [ -e "/sys/class/net/$NATIVE_TETHER_BRIDGE" ] && [ -r "$DIRECT_BR0_ADDR_FILE" ]; then
        ip -4 addr flush dev "$NATIVE_TETHER_BRIDGE" 2>/dev/null || true
        while read -r saved_addr; do
            [ -n "$saved_addr" ] && \
                ip -4 addr add "$saved_addr" dev "$NATIVE_TETHER_BRIDGE" 2>/dev/null || true
        done < "$DIRECT_BR0_ADDR_FILE"
        restart_android_tether_dns || true
    fi
    rm -f "$DIRECT_BR0_ADDR_FILE"
}

sync_tether_network() {
    case "$EFFECTIVE_TETHER_MODE" in
        routed) sync_routed_tethers ;;
        proxyarp) sync_proxyarp_tethers ;;
        directbr0) sync_direct_br0 ;;
        *) sync_bridge_ports ;;
    esac
}

cellular_ipv6_prefix() {
    ip -6 -o addr show dev "$CELLULAR_IFACE" scope global 2>/dev/null | awk '
        NR == 1 {
            split($4, cidr, "/")
            split(cidr[1], h, ":")
            if (h[1] != "" && h[2] != "" && h[3] != "" && h[4] != "")
                print h[1] ":" h[2] ":" h[3] ":" h[4] "::"
        }'
}

stop_ra6_port() {
    iface="$1"
    pidfile="$VM_DIR/ra6-$iface.pid"
    if [ -r "$pidfile" ]; then
        ra_pid="$(cat "$pidfile" 2>/dev/null)"
        if [ -n "$ra_pid" ] && [ -r "/proc/$ra_pid/cmdline" ] && \
                tr '\000' ' ' < "/proc/$ra_pid/cmdline" | grep -q "$RA6"; then
            kill "$ra_pid" 2>/dev/null || true
            # ra6 sends withdrawal advertisements on SIGTERM. Wait for those
            # frames before a replacement announces a new prefix, otherwise
            # a late withdrawal could invalidate the new default route.
            wait_count=0
            while [ "$wait_count" -lt 20 ] && [ -e "/proc/$ra_pid" ]; do
                sleep 0.1
                wait_count=$((wait_count + 1))
            done
        fi
    fi
    rm -f "$pidfile"
}

stop_ipv6_downstream() {
    for path in "$VM_DIR"/ra6-*.pid; do
        [ -e "$path" ] || continue
        iface="${path##*/ra6-}"
        iface="${iface%.pid}"
        stop_ra6_port "$iface"
    done
    while ip -6 rule del priority "$IPV6_OUT_RULE_PRIO" 2>/dev/null; do :; done
    while ip -6 rule del priority "$IPV6_IN_RULE_PRIO" 2>/dev/null; do :; done
    old_prefix="$(cat "$IPV6_PREFIX_FILE" 2>/dev/null)"
    [ -n "$old_prefix" ] && ip -6 route del "$old_prefix/64" dev "$LAN_BRIDGE" table main 2>/dev/null || true
    [ -n "$old_prefix" ] && ip -6 route del "$old_prefix/64" dev "$WAN_TAP" table main 2>/dev/null || true
    ip -6 addr del fe80::1/64 dev "$LAN_BRIDGE" 2>/dev/null || true
    ip -6 addr del fe80::1/64 dev "$WAN_TAP" 2>/dev/null || true
    delete_ip6_jump_and_chain FORWARD "$IPV6_FORWARD_CHAIN"
    delete_ip6_jump_and_chain OUTPUT OWT6_OUT
    rm -f "$IPV6_PREFIX_FILE"
}

ensure_ra6_port() {
    iface="$1"
    prefix="$2"
    router_iface="${3:-$LAN_BRIDGE}"
    pidfile="$VM_DIR/ra6-$iface.pid"
    if [ -r "$pidfile" ]; then
        ra_pid="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$ra_pid" ] && [ -d "/proc/$ra_pid" ] && return 0
    fi
    stop_ra6_port "$iface"
    # Advertise the bridge itself as the preferred router. Android may also
    # publish its physical-port router as a medium-preference fallback.
    nohup "$RA6" "$iface" "$router_iface" "$prefix" \
        </dev/null >"$VM_DIR/ra6-$iface.log" 2>&1 &
    echo "$!" > "$pidfile"
}

sync_ipv6_passthrough() {
    # Android owns downstream IPv6 in this mode; do not suppress its native
    # tethering RA/DHCPv6 packets.
    delete_ip6_jump_and_chain OUTPUT OWT6_OUT
    [ -x "$RA6" ] || return 0
    prefix="$(cellular_ipv6_prefix)"
    if [ -z "$prefix" ]; then
        stop_ipv6_downstream
        return 0
    fi

    current_prefix="$(cat "$IPV6_PREFIX_FILE" 2>/dev/null)"
    if [ "$current_prefix" != "$prefix" ]; then
        stop_ipv6_downstream
        ip -6 addr replace fe80::1/64 dev "$LAN_BRIDGE"
        ip -6 route replace "$prefix/64" dev "$LAN_BRIDGE" metric 64 table main
        ip -6 rule add priority "$IPV6_OUT_RULE_PRIO" iif "$LAN_BRIDGE" lookup "$CELLULAR_ROUTE_TABLE"
        ip -6 rule add priority "$IPV6_IN_RULE_PRIO" iif "$CELLULAR_IFACE" to "$prefix/64" lookup main
        echo "$prefix" > "$IPV6_PREFIX_FILE"
    fi

    active_ra="$VM_DIR/ra6-active"
    : > "$active_ra"
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        if [ -d "$path/bridge" ]; then
            for member_path in "$path"/brif/*; do
                [ -e "$member_path" ] || continue
                member="${member_path##*/}"
                case "$member" in owx-*) continue ;; esac
                ensure_ra6_port "$member" "$prefix"
                echo "$member" >> "$active_ra"
            done
        else
            current_master="$(basename "$(readlink "$path/master" 2>/dev/null)" 2>/dev/null)"
            if [ "$current_master" = "$LAN_BRIDGE" ]; then
                ensure_ra6_port "$iface" "$prefix"
                echo "$iface" >> "$active_ra"
            fi
        fi
    done
    for pidfile in "$VM_DIR"/ra6-*.pid; do
        [ -e "$pidfile" ] || continue
        iface="${pidfile##*/ra6-}"
        iface="${iface%.pid}"
        grep -Fxq "$iface" "$active_ra" 2>/dev/null || stop_ra6_port "$iface"
    done
    rm -f "$active_ra"
}


sync_managed_ipv6_ra_block() {
    ip6tables -N OWT6_OUT 2>/dev/null || true
    ip6tables -F OWT6_OUT
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        ip6tables -A OWT6_OUT -o "$iface" -p ipv6-icmp --icmpv6-type 134 -j DROP
        ip6tables -A OWT6_OUT -o "$iface" -p udp --sport 547 --dport 546 -j DROP
        if [ -d "$path/bridge" ]; then
            for member_path in "$path"/brif/*; do
                [ -e "$member_path" ] || continue
                member="${member_path##*/}"
                case "$member" in owx-*) continue ;; esac
                ip6tables -A OWT6_OUT -o "$member" -p ipv6-icmp --icmpv6-type 134 -j DROP
                ip6tables -A OWT6_OUT -o "$member" -p udp --sport 547 --dport 546 -j DROP
            done
        fi
    done
    ensure_ip6_jump OUTPUT OWT6_OUT
}


withdraw_native_ipv6_ra() {
    prefix="$1"
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        # Send one advertisement followed immediately by the helper's normal
        # zero-lifetime withdrawal, using Android's own interface link-local.
        # This removes routes/addresses cached before the managed-mode filter
        # was installed, so clients do not need to reconnect manually.
        "$RA6" "$iface" "$iface" "$prefix" \
            >"$VM_DIR/withdraw-$iface.log" 2>&1 &
        withdraw_pid=$!
        sleep 1
        kill "$withdraw_pid" 2>/dev/null || true
        wait "$withdraw_pid" 2>/dev/null || true
    done
}


sync_ipv6_managed() {
    [ -x "$RA6" ] || return 0
    prefix="$(cellular_ipv6_prefix)"
    if [ -z "$prefix" ]; then
        stop_ipv6_downstream
        return 0
    fi

    current_prefix="$(cat "$IPV6_PREFIX_FILE" 2>/dev/null)"
    if [ "$current_prefix" != "$prefix" ]; then
        stop_ipv6_downstream
        # OpenWrt learns a public WAN address and default route from this RA.
        # Its own firewall performs NAT66 from the managed LAN ULA. Android
        # only routes that public WAN address to the cellular network.
        ip -6 addr replace fe80::1/64 dev "$WAN_TAP"
        ip -6 route replace "$prefix/64" dev "$WAN_TAP" metric 64 table main
        ip -6 rule add priority "$IPV6_OUT_RULE_PRIO" iif "$WAN_TAP" lookup "$CELLULAR_ROUTE_TABLE"
        ip -6 rule add priority "$IPV6_IN_RULE_PRIO" iif "$CELLULAR_IFACE" to "$prefix/64" lookup main
        echo "$prefix" > "$IPV6_PREFIX_FILE"
        sync_managed_ipv6_ra_block
        withdraw_native_ipv6_ra "$prefix"
    fi

    ip6tables -N "$IPV6_FORWARD_CHAIN" 2>/dev/null || true
    ip6tables -F "$IPV6_FORWARD_CHAIN"
    ip6tables -A "$IPV6_FORWARD_CHAIN" -i "$WAN_TAP" -j ACCEPT
    ip6tables -A "$IPV6_FORWARD_CHAIN" -o "$WAN_TAP" -j ACCEPT
    ensure_ip6_jump FORWARD "$IPV6_FORWARD_CHAIN"
    sync_managed_ipv6_ra_block
    ensure_ra6_port "$WAN_TAP" "$prefix" "$WAN_TAP"
}

sync_routed_ipv6_policy() {
    delete_ip6_jump_and_chain FORWARD OWT6_ROUTED
    [ "$IPV6_PASSTHROUGH" = 1 ] && return 0
    ip6tables -N OWT6_ROUTED 2>/dev/null || true
    ip6tables -F OWT6_ROUTED
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_candidate "$iface" || continue
        ip6tables -A OWT6_ROUTED -i "$iface" -j REJECT
        ip6tables -A OWT6_ROUTED -o "$iface" -j REJECT
    done
    ensure_ip6_jump FORWARD OWT6_ROUTED
}

sync_ipv6_downstream() {
    # The safe routed/proxy-ARP modes cannot advertise OpenWrt's LAN prefix
    # without extending br0. Honour the switch by passing Android IPv6 at 1
    # and blocking downstream IPv6 at 0 so it cannot silently bypass OpenWrt.
    if [ "$EFFECTIVE_TETHER_MODE" = routed ] || [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
        sync_routed_ipv6_policy
        return 0
    fi
    if [ "$IPV6_PASSTHROUGH" = 1 ]; then
        sync_ipv6_passthrough
    else
        sync_ipv6_managed
    fi
}

refresh_ipv6() {
    load_config
    resolve_device_config
    stop_ipv6_downstream
    is_running && sync_ipv6_downstream
    echo "IPv6 fallback RA refreshed"
}

detach_bridge_ports() {
    clear_routed_tethers
    clear_proxyarp_tethers
    if [ "$EFFECTIVE_TETHER_MODE" = directbr0 ]; then
        restore_direct_br0
        return 0
    fi
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        bridge_detach "$iface"
    done
}

# Android keeps default routes in per-network tables, not in the main table.
# Route packets arriving from OpenWrt's WAN out through whichever table has the
# active IPv4 default, so NAT mode works on WiFi, USB or cellular upstream.
sync_upstream() {
    # Android keeps the active Wi-Fi/cellular default in a named table. Wi-Fi
    # uses "default via ...", while this Unisoc cellular driver uses
    # "default dev ...", so accept both and ignore dummy/VM tables.
    upstream="$(ip -4 route show table all 2>/dev/null | awk -v owrt_table="$OWRT_TABLE" '
        /^default / {
            table = ""
            dev = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "table") table = $(i + 1)
                if ($i == "dev") dev = $(i + 1)
            }
            if (table != "" && table != owrt_table && table != "dummy0" &&
                    dev != "owrt-wan" && dev != "owrt-lan" && dev != "owrt-br") {
                print table
                exit
            }
        }')"
    [ -n "$upstream" ] || return 0
    current_upstream="$(ip -4 rule show priority "$UPSTREAM_RULE_PRIO" 2>/dev/null | awk '{print $NF; exit}')"
    [ "$current_upstream" = "$upstream" ] && return 0
    ip rule del priority "$UPSTREAM_RULE_PRIO" 2>/dev/null || true
    ip rule add priority "$UPSTREAM_RULE_PRIO" iif "$WAN_TAP" lookup "$upstream"
}

sync_dhcp_block() {
    if [ "$EFFECTIVE_TETHER_MODE" = routed ]; then
        delete_jump_and_chain filter OUTPUT OWT_OUT
        return 0
    fi
    iptables -N OWT_OUT 2>/dev/null || true
    iptables -F OWT_OUT
    iptables -A OWT_OUT -o "$LAN_BRIDGE" -p udp --sport 67 --dport 68 -j DROP
    if [ "$TETHER_IFACE_PATTERNS" = auto ]; then
        # A trailing '+' is iptables' interface-prefix wildcard and remains
        # effective even while gadget reconfiguration removes the netdev.
        for iface_prefix in sipa_usb+ rndis+ wlan+ softap+ ap_br_wlan+ ap_br_softap+; do
            iptables -A OWT_OUT -o "$iface_prefix" -p udp --sport 67 --dport 68 -j DROP
        done
        iptables -A OWT_OUT -o bt-pan -p udp --sport 67 --dport 68 -j DROP
    fi
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        is_tether_capable "$iface" || continue
        iptables -A OWT_OUT -o "$iface" -p udp --sport 67 --dport 68 -j DROP
        if [ -d "$path/bridge" ]; then
            for member_path in "$path"/brif/*; do
                [ -e "$member_path" ] || continue
                member="${member_path##*/}"
                iptables -A OWT_OUT -o "$member" -p udp --sport 67 --dport 68 -j DROP
            done
        fi
    done
    ensure_jump filter OUTPUT OWT_OUT
}

setup_network() {
    echo "$EFFECTIVE_TETHER_MODE" > "$ACTIVE_MODE_FILE"
    # Install the DHCP guard before TAP/bridge changes close the lifecycle race.
    sync_dhcp_block
    for tap in "$WAN_TAP" "$LAN_TAP"; do
        ip tuntap add dev "$tap" mode tap 2>/dev/null || true
    done
    ip addr flush dev "$WAN_TAP" 2>/dev/null
    ip addr add "$WAN_HOST_IP/24" dev "$WAN_TAP"
    ip link set "$WAN_TAP" up

    if [ "$EFFECTIVE_TETHER_MODE" = directbr0 ]; then
        save_direct_br0_state
        ip addr flush dev "$LAN_TAP" 2>/dev/null
        ip link set "$LAN_TAP" up
        sync_direct_br0
    else
        ip link add name "$LAN_BRIDGE" type bridge 2>/dev/null || true
        ip link set dev "$LAN_BRIDGE" address 02:00:00:00:88:02
        ip link set "$LAN_BRIDGE" up
        ip addr flush dev "$LAN_TAP" 2>/dev/null
        ip link set "$LAN_TAP" up
        ip link set dev "$LAN_TAP" master "$LAN_BRIDGE"
        ip addr flush dev "$LAN_BRIDGE" 2>/dev/null
        if [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
            ip addr add "$LAN_HOST_IP/32" dev "$LAN_BRIDGE"
        else
            ip addr add "$LAN_HOST_IP/24" dev "$LAN_BRIDGE"
        fi
        sync_tether_network
    fi
    sync_ipv6_downstream

    # Let the Android host itself reach the OpenWrt subnets (default policy
    # routing would otherwise drop these via the trailing "unreachable" rule).
    ip rule del priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main 2>/dev/null || true
    ip rule add priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main
    ip rule add priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main

    # Send OpenWrt's WAN traffic out the device's active upstream.
    sync_upstream

    if [ ! -f "$VM_DIR/ip_forward.original" ]; then
        cat /proc/sys/net/ipv4/ip_forward > "$VM_DIR/ip_forward.original"
    fi
    echo 1 > /proc/sys/net/ipv4/ip_forward

    iptables -N OWT_FWD 2>/dev/null || true
    iptables -F OWT_FWD
    iptables -A OWT_FWD -i "$WAN_TAP" -j ACCEPT
    iptables -A OWT_FWD -o "$WAN_TAP" -j ACCEPT
    iptables -A OWT_FWD -i "$LAN_TAP" -j ACCEPT
    iptables -A OWT_FWD -o "$LAN_TAP" -j ACCEPT
    iptables -A OWT_FWD -i "$LAN_BRIDGE" -j ACCEPT
    iptables -A OWT_FWD -o "$LAN_BRIDGE" -j ACCEPT
    ensure_jump filter FORWARD OWT_FWD

    iptables -t nat -N OWT_POST 2>/dev/null || true
    iptables -t nat -F OWT_POST
    iptables -t nat -A OWT_POST -s "$WAN_SUBNET" -j MASQUERADE
    # DNAT reply path: rewrite the source to the host LAN IP so the guest
    # sees a LAN-originated connection and replies symmetrically via br-lan.
    # Without this the guest routes replies out its WAN (default route) and
    # the host never completes the handshake.
    # All traffic routed into OpenWrt's LAN is represented by the Android-side
    # LAN address. This gives Android apps and tethered clients a symmetric
    # return path through conntrack, including apps bound to Wi-Fi/cellular.
    iptables -t nat -A OWT_POST ! -s "$LAN_SUBNET" -o "$LAN_BRIDGE" -j SNAT --to-source "$LAN_HOST_IP"
    ensure_jump nat POSTROUTING OWT_POST

    iptables -t nat -N OWT_PRE 2>/dev/null || true
    iptables -t nat -F OWT_PRE
    # External SSH (host 2223 -> OpenWrt LAN 88.1:22) and LuCI web
    # (host 8080 -> 88.1:80). The LAN side is used so OpenWrt default
    # firewall (lan input ACCEPT) applies; OWT_POST rewrites the source to
    # 88.2 so replies come back through br-lan. legacy iptables rejects
    # multiple -i flags in one rule, so skip the taps with RETURN first.
    iptables -t nat -A OWT_PRE -p tcp -i "$WAN_TAP" -j RETURN
    iptables -t nat -A OWT_PRE -p tcp -i "$LAN_TAP" -j RETURN
    iptables -t nat -A OWT_PRE -p tcp --dport "$SSH_DNAT_PORT" \
        -j DNAT --to-destination "$LAN_GUEST_IP:22"
    iptables -t nat -A OWT_PRE -p tcp --dport "$WEB_DNAT_PORT" \
        -j DNAT --to-destination "$LAN_GUEST_IP:80"
    ensure_jump nat PREROUTING OWT_PRE

    # Android owns AP/RNDIS lifecycle. Bridge mode moves DHCP/RA to OpenWrt;
    # Routed fallback retains Android DHCP. Proxy-ARP and bridge modes suppress
    # Android DHCP so OpenWrt is the only server clients can hear.
    sync_dhcp_block

}

teardown_network() {
    untakeover
    stop_ipv6_downstream
    ip rule del priority "$UPSTREAM_RULE_PRIO" 2>/dev/null || true
    detach_bridge_ports
    ip route flush table "$OWRT_TABLE" 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main 2>/dev/null || true
    delete_jump_and_chain filter FORWARD OWT_FWD
    delete_jump_and_chain nat POSTROUTING OWT_POST
    delete_jump_and_chain nat PREROUTING OWT_PRE
    delete_jump_and_chain filter OUTPUT OWT_OUT
    delete_ip6_jump_and_chain OUTPUT OWT6_OUT
    delete_ip6_jump_and_chain FORWARD OWT6_ROUTED
    ip link set "$LAN_TAP" nomaster 2>/dev/null || true
    if [ "$EFFECTIVE_TETHER_MODE" != directbr0 ]; then
        ip link set "$LAN_BRIDGE" down 2>/dev/null || true
        ip link delete "$LAN_BRIDGE" type bridge 2>/dev/null || true
    fi
    for tap in "$WAN_TAP" "$LAN_TAP"; do
        ip link set "$tap" down 2>/dev/null || true
        ip tuntap del dev "$tap" mode tap 2>/dev/null || ip link delete "$tap" 2>/dev/null || true
    done
    if [ -r "$VM_DIR/ip_forward.original" ]; then
        cat "$VM_DIR/ip_forward.original" > /proc/sys/net/ipv4/ip_forward
        rm -f "$VM_DIR/ip_forward.original"
    fi
    rm -f "$ACTIVE_MODE_FILE"
}

# Steer Android's own locally generated traffic through OpenWrt. Tethered
# clients use either a real Layer-2 bridge or their mode-specific ingress rule.
takeover() {
    ip link show "$LAN_TAP" >/dev/null 2>&1 || die "run start first"

    ip route flush table "$OWRT_TABLE" 2>/dev/null || true
    ensure_owrt_routes

    while ip -4 rule del priority "$RULE_PRIO" 2>/dev/null; do :; done
    ip rule add priority "$RULE_PRIO" iif lo lookup "$OWRT_TABLE"

    # OpenWrt takeover currently covers Android's local IPv4 only. Reject the
    # Android host's own IPv6 while takeover is active; bridged hotspot/USB
    # clients keep using Android's cellular IPv6 service.
    while ip -6 rule del priority "$IPV6_BLOCK_PRIO" 2>/dev/null; do :; done
    ip -6 rule add priority "$IPV6_BLOCK_PRIO" iif lo prohibit
    delete_ip6_jump_and_chain FORWARD OWT6_FWD

    touch "$TAKEOVER_FLAG"
    sync_upstream
    start_monitor
    echo "OpenWrt takeover enabled (Android apps routed; tether mode $EFFECTIVE_TETHER_MODE)"
}

untakeover() {
    rm -f "$TAKEOVER_FLAG"
    while ip -4 rule del priority "$RULE_PRIO" 2>/dev/null; do :; done
    while ip -6 rule del priority "$IPV6_BLOCK_PRIO" 2>/dev/null; do :; done
    if [ "$EFFECTIVE_TETHER_MODE" = routed ] || [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
        ensure_owrt_routes
    else
        ip route flush table "$OWRT_TABLE" 2>/dev/null || true
    fi
    delete_ip6_jump_and_chain FORWARD OWT6_FWD
    echo "OpenWrt takeover disabled"
}

network_monitor() {
    load_config
    resolve_device_config
    use_active_tether_mode
    while is_running; do
        sync_tether_network
        sync_ipv6_downstream
        sync_dhcp_block
        # Guest WAN forwarding must follow Wi-Fi/cellular changes regardless
        # of whether Android's own locally generated traffic is taken over.
        sync_upstream
        sleep 3
    done
}

start_monitor() {
    if [ -r "$MONITOR_PIDFILE" ]; then
        monitor_pid="$(cat "$MONITOR_PIDFILE" 2>/dev/null)"
        [ -n "$monitor_pid" ] && [ -d "/proc/$monitor_pid" ] && return 0
    fi
    nohup "$0" __network_monitor </dev/null >/dev/null 2>&1 &
    echo "$!" > "$MONITOR_PIDFILE"
}

stop_monitor() {
    if [ -r "$MONITOR_PIDFILE" ]; then
        monitor_pid="$(cat "$MONITOR_PIDFILE" 2>/dev/null)"
        [ -n "$monitor_pid" ] && kill "$monitor_pid" 2>/dev/null || true
    fi
    rm -f "$MONITOR_PIDFILE"
}

preflight_vm() {
    load_config
    resolve_device_config
    if [ "$UNSAFE_NATIVE_BRIDGE" = 1 ] && [ "$EFFECTIVE_TETHER_MODE" = bridge ]; then
        die "TETHER_MODE=bridge is unsafe on MU300/UMS9620 sprd_wlan_combo; use auto, proxyarp, or routed"
    fi
    if [ "$EFFECTIVE_TETHER_MODE" = directbr0 ]; then
        [ -d "/sys/class/net/$NATIVE_TETHER_BRIDGE/bridge" ] || \
            die "TETHER_MODE=directbr0 requires native bridge $NATIVE_TETHER_BRIDGE"
        for member_path in "/sys/class/net/$NATIVE_TETHER_BRIDGE/brif"/owrt-* \
                "/sys/class/net/$NATIVE_TETHER_BRIDGE/brif"/owx-*; do
            [ -e "$member_path" ] || continue
            member="${member_path##*/}"
            [ "$member" = "$LAN_TAP" ] || \
                die "directbr0 refuses unexpected project port $member on $NATIVE_TETHER_BRIDGE"
        done
    fi
    [ "$(getprop ro.product.cpu.abi 2>/dev/null)" = arm64-v8a ] || \
        die "only arm64-v8a Android hosts are supported"
    [ -c /dev/kvm ] || die "/dev/kvm is unavailable"
    [ -c /dev/net/tun ] || die "/dev/net/tun is unavailable"
    if [ "$EFFECTIVE_TETHER_MODE" = proxyarp ]; then
        [ -x "$DHCP_RELAY" ] || die "DHCP relay is missing or not executable: $DHCP_RELAY"
        [ -w /proc/sys/net/ipv4/conf/all/proxy_arp ] || die "kernel Proxy ARP controls are unavailable"
        # This branch's safety contract is stronger than merely avoiding the
        # old connector name: no project-created interface may ever be a port
        # of a vendor-owned tether bridge on the affected Wi-Fi driver.
        for bridge_path in /sys/class/net/*/bridge; do
            [ -e "$bridge_path" ] || continue
            bridge="${bridge_path%/bridge}"
            bridge="${bridge##*/}"
            is_tether_candidate "$bridge" || continue
            for member_path in "/sys/class/net/$bridge/brif"/*; do
                [ -e "$member_path" ] || continue
                member="${member_path##*/}"
                case "$member" in
                    owrt-*|owx-*) die "unsafe project port $member is attached to native tether bridge $bridge" ;;
                esac
            done
        done
    fi
    for command in ip iptables ip6tables truncate stat dumpsys; do
        command -v "$command" >/dev/null 2>&1 || die "required Android command is missing: $command"
    done
    if [ -x "$KVM_PROBE" ]; then
        "$KVM_PROBE" >/dev/null || die "KVM/vGIC capability probe failed"
    fi

    probe_tap=owrt-check0
    probe_bridge=owrt-checkbr
    ip link delete "$probe_tap" 2>/dev/null || true
    ip link delete "$probe_bridge" type bridge 2>/dev/null || true
    ip tuntap add dev "$probe_tap" mode tap || die "kernel cannot create TAP interfaces"
    ip link add name "$probe_bridge" type bridge || {
        ip link delete "$probe_tap" 2>/dev/null || true
        die "kernel cannot create Linux bridges"
    }
    ip link delete "$probe_tap" 2>/dev/null || true
    ip link delete "$probe_bridge" type bridge 2>/dev/null || true

    matched=""
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        matches_tether_pattern "$iface" && matched="$matched $iface"
    done
    [ -n "$matched" ] || \
        die "TETHER_IFACE_PATTERNS matches no current interface"
    echo "preflight ok: crosvm=$CROSVM style=$CROSVM_STYLE cpus=$VM_CPUS affinity=${EFFECTIVE_CPU_AFFINITY:-none} capacity=${EFFECTIVE_CPU_CAPACITY:-none} clusters=${EFFECTIVE_CPU_CLUSTERS:-none} cellular=$CELLULAR_IFACE table=$CELLULAR_ROUTE_TABLE tether=${TETHER_IFACE_PATTERNS} mode=$EFFECTIVE_TETHER_MODE ipv6_passthrough=$IPV6_PASSTHROUGH"
}

start_vm() {
    load_config
    resolve_device_config
    preflight_vm >/dev/null
    for file in "$DISK" "$KERNEL"; do
        [ -r "$file" ] || die "missing $file"
    done
    if is_running; then
        echo "OpenWrt VM is already running (PID $(cat "$PIDFILE"))"
        exit 0
    fi
    rm -f "$PIDFILE" "$SOCKET"
    : > "$LOG"
    : > "$CONSOLE"
    setup_network
    cpu_affinity_arg=""
    [ -n "$EFFECTIVE_CPU_AFFINITY" ] && \
        cpu_affinity_arg="--cpu-affinity=$EFFECTIVE_CPU_AFFINITY"
    cpu_capacity_arg=""
    [ -n "$EFFECTIVE_CPU_CAPACITY" ] && \
        cpu_capacity_arg="--cpu-capacity=$EFFECTIVE_CPU_CAPACITY"
    cpu_cluster_args=""
    for cpu_cluster in $EFFECTIVE_CPU_CLUSTERS; do
        cpu_cluster_args="$cpu_cluster_args --cpu-cluster=$cpu_cluster"
    done

    if [ "$CROSVM_STYLE" = block ]; then
        nohup "$CROSVM" run \
            --disable-sandbox \
            --cpus "$VM_CPUS" \
            $cpu_affinity_arg \
            $cpu_capacity_arg \
            $cpu_cluster_args \
            --mem "$VM_MEMORY_MIB" \
            --socket "$SOCKET" \
            --serial "type=file,path=$CONSOLE,hardware=serial,num=1,console" \
            --block "path=$DISK,root=false" \
            --tap-name "$WAN_TAP" \
            --tap-name "$LAN_TAP" \
            --params "root=$ROOT_DEVICE rw rootwait console=ttyS0 console=ttyAMA0 owrt_ipv6_passthrough=$IPV6_PASSTHROUGH" \
            "$KERNEL" </dev/null >>"$LOG" 2>&1 &
    else
        nohup "$CROSVM" run \
            --disable-sandbox \
            --cpus "$VM_CPUS" \
            $cpu_affinity_arg \
            $cpu_capacity_arg \
            $cpu_cluster_args \
            --mem "$VM_MEMORY_MIB" \
            --socket "$SOCKET" \
            --serial "type=file,path=$CONSOLE,hardware=serial,num=1,console" \
            --rwdisk "$DISK" \
            --tap-name "$WAN_TAP" \
            --tap-name "$LAN_TAP" \
            --params "root=$ROOT_DEVICE rw rootwait console=ttyS0 console=ttyAMA0 owrt_ipv6_passthrough=$IPV6_PASSTHROUGH" \
            "$KERNEL" </dev/null >>"$LOG" 2>&1 &
    fi
    pid=$!
    echo "$pid" > "$PIDFILE"
    sleep 2
    if ! is_running; then
        echo "crosvm exited during startup:" >&2
        tail -n 80 "$LOG" >&2
        rm -f "$PIDFILE"
        exit 1
    fi
    if [ "$AUTO_TAKEOVER" = 1 ]; then
        takeover
    else
        untakeover >/dev/null
    fi
    start_monitor
    echo "OpenWrt VM started (PID $pid, WAN $WAN_GUEST_IP, LAN $LAN_GUEST_IP, SSH host port $SSH_DNAT_PORT)"
}

stop_vm() {
    load_config
    resolve_device_config
    use_active_tether_mode
    stop_monitor
    if ! is_running; then
        rm -f "$PIDFILE" "$SOCKET"
        # A crashed or previously stopped VM may leave TAP devices, the LAN
        # bridge and DHCP-suppression rules behind.  Restore Android tethering
        # even when there is no crosvm process left to stop.
        teardown_network
        echo "OpenWrt VM is not running"
        return 0
    fi
    pid="$(cat "$PIDFILE")"
    "$CROSVM" stop "$SOCKET" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
    n=0
    while [ "$n" -lt 10 ] && [ -d "/proc/$pid" ]; do
        sleep 1
        n=$((n + 1))
    done
    if [ -d "/proc/$pid" ]; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE" "$SOCKET"
    # Tear the bridge down only after crosvm has released its TAP devices.
    # This also restores Android hotspot/USB DHCP and their original addresses.
    teardown_network
    echo "OpenWrt VM stopped"
}

status_vm() {
    load_config
    resolve_device_config
    use_active_tether_mode
    if is_running; then
        bridge_ports="$(ls "/sys/class/net/$LAN_BRIDGE/brif" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
        echo "running PID=$(cat "$PIDFILE") wan=$WAN_GUEST_IP lan=$LAN_GUEST_IP tether_mode=$EFFECTIVE_TETHER_MODE bridge=$LAN_BRIDGE ports=${bridge_ports:-none} ipv6_passthrough=$IPV6_PASSTHROUGH ssh=localhost:$SSH_DNAT_PORT"
    else
        echo "stopped"
        return 1
    fi
}

uninstall_vm() {
    stop_vm
    teardown_network
    [ "$VM_DIR" = /data/local/openwrt ] || die "unsafe VM_DIR"
    rm -rf -- "$VM_DIR"
    echo "OpenWrt VM data and networking rules removed"
}

case "${1:-}" in
    __network_monitor) network_monitor ;;
    start) start_vm ;;
    stop) stop_vm ;;
    restart) stop_vm; start_vm ;;
    status) status_vm ;;
    preflight) preflight_vm ;;
    refresh-ipv6) refresh_ipv6 ;;
    logs) tail -n "${2:-200}" "$LOG" 2>/dev/null; echo "--- guest console ---"; tail -n "${2:-200}" "$CONSOLE" 2>/dev/null ;;
    takeover) takeover ;;
    untakeover) untakeover ;;
    uninstall) uninstall_vm ;;
    *) echo "usage: $0 {start|stop|restart|status|preflight|refresh-ipv6|logs [lines]|takeover|untakeover|uninstall}" >&2; exit 2 ;;
esac
