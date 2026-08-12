#!/system/bin/sh
# ImmortalWrt Android KVM 设备端管理脚本（由 DeepSeek-V4-Pro 修改：替换为 ImmortalWrt + 国内镜像源）
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
RA6="$VM_DIR/ra6"
KVM_PROBE="$VM_DIR/kvm-probe"
IPV6_PREFIX_FILE="$VM_DIR/ipv6-prefix"
TAKEOVER_FLAG="$VM_DIR/takeover.enabled"
SOCKET="$VM_DIR/crosvm.sock"
LOG="$VM_DIR/crosvm.log"
CONSOLE="$VM_DIR/console.log"
WAN_TAP=owrt-wan
LAN_TAP=owrt-lan
LAN_BRIDGE=owrt-br
WAN_HOST_IP=192.168.66.1
WAN_SUBNET=192.168.66.0/24
WAN_GUEST_IP=192.168.66.2
LAN_HOST_IP=192.168.88.2
LAN_SUBNET=192.168.88.0/24
LAN_GUEST_IP=192.168.88.1
# Android 的 iproute2 没有 rt_tables 文件，因此自定义表必须是数字。
# 1000 未被框架使用（它使用 97-99 和 100+ 的按网络表）。
OWRT_TABLE=1000
RULE_PRIO=100
UPSTREAM_RULE_PRIO=1050
IPV6_OUT_RULE_PRIO=1051
IPV6_IN_RULE_PRIO=1052
IPV6_BLOCK_PRIO=100
IPV6_FORWARD_CHAIN=OWT6_VM
# Android 的策略路由以 "from all unreachable" 结尾；如果没有显式规则，
# 从 Android 宿主机自身发往 ImmortalWrt 子网的数据包在到达 tap 之前就会被丢弃。
# 将它们指向主路由表。
HOST_ROUTE_PRIO=1049
SSH_DNAT_PORT=2223
WEB_DNAT_PORT=8080
EFFECTIVE_CPU_AFFINITY=""
EFFECTIVE_CPU_CAPACITY=""
EFFECTIVE_CPU_CLUSTERS=""
EFFECTIVE_NET_QUEUES=1

die() {
    echo "openwrt: $*" >&2
    exit 1
}

load_config() {
    [ -r "$CONFIG" ] || die "缺少 $CONFIG；请先运行 deploy-openwrt.sh"
    . "$CONFIG"
    : "${ROOT_DEVICE:=/dev/vda}"
    : "${VM_CPUS:=4}"
    : "${VM_CPU_AFFINITY:=auto}"
    : "${VM_NET_QUEUES:=auto}"
    : "${VM_MEMORY_MIB:=1024}"
    : "${AUTO_TAKEOVER:=0}"
    : "${IPV6_PASSTHROUGH:=1}"
    : "${CROSVM_PATH:=auto}"
    : "${CELLULAR_IFACE:=auto}"
    : "${CELLULAR_ROUTE_TABLE:=auto}"
    : "${TETHER_IFACE_PATTERNS:=auto}"
    case "$IPV6_PASSTHROUGH" in
        0|1) ;;
        *) die "IPV6_PASSTHROUGH 必须为 0 或 1" ;;
    esac
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
                die "VM_CPUS=$VM_CPUS 超过了在线 Android CPU 数量 ($selected_count)"
            EFFECTIVE_CPU_AFFINITY="$(printf '%s\n' "$selected_cpus" | awk '
                { if (NR > 1) printf ":"; printf "%d=%s", NR - 1, $2 }
                END { print "" }
            ')"
            # 告知客户机调度器：绑定到小核的 vCPU 与绑定到大核的不等价。
            # 将 cpu_capacity 或 cpufreq 回退值归一化到 crosvm 的 1024 刻度。
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
            # selected_cpus 已按 capacity 排序，因此等 capacity 的 vCPU 是连续的，
            # 可以表示为 crosvm CPU 簇。
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
        *[!0-9,:=-]*|'') die "无效的 VM_CPU_AFFINITY: $VM_CPU_AFFINITY" ;;
        *) EFFECTIVE_CPU_AFFINITY="$VM_CPU_AFFINITY" ;;
    esac
}

resolve_net_queues() {
    case "$VM_NET_QUEUES" in
        auto)
            if echo "$crosvm_help" | grep -q -- '--net-vq-pairs'; then
                EFFECTIVE_NET_QUEUES="$VM_CPUS"
            else
                EFFECTIVE_NET_QUEUES=1
            fi
            ;;
        *[!0-9]*|'') die "VM_NET_QUEUES 必须为 auto 或正整数" ;;
        0) die "VM_NET_QUEUES 必须为正数" ;;
        *)
            [ "$VM_NET_QUEUES" -le "$VM_CPUS" ] || \
                die "VM_NET_QUEUES 不能超过 VM_CPUS"
            EFFECTIVE_NET_QUEUES="$VM_NET_QUEUES"
            if [ "$EFFECTIVE_NET_QUEUES" -gt 1 ] && \
                    ! echo "$crosvm_help" | grep -q -- '--net-vq-pairs'; then
                die "所选 crosvm 不支持 --net-vq-pairs"
            fi
            ;;
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
        *) die "CROSVM_PATH 必须为 auto、bundled 或设备上的绝对路径" ;;
    esac
    [ -x "$CROSVM" ] || die "crosvm 不可执行: $CROSVM"

    crosvm_help="$("$CROSVM" run --help 2>&1)"
    if echo "$crosvm_help" | grep -q -- '--block'; then
        CROSVM_STYLE=block
    elif echo "$crosvm_help" | grep -q -- '--rwdisk'; then
        CROSVM_STYLE=rwdisk
    else
        die "不支持的 crosvm 命令行: --block 和 --rwdisk 均不可用"
    fi
    resolve_cpu_affinity
    resolve_net_queues
    if [ -n "$EFFECTIVE_CPU_AFFINITY" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-affinity'; then
        die "所选 crosvm 不支持 --cpu-affinity"
    fi
    if [ -n "$EFFECTIVE_CPU_CAPACITY" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-capacity'; then
        die "所选 crosvm 不支持 --cpu-capacity"
    fi
    if [ -n "$EFFECTIVE_CPU_CLUSTERS" ] && \
            ! echo "$crosvm_help" | grep -q -- '--cpu-cluster'; then
        die "所选 crosvm 不支持 --cpu-cluster"
    fi

    if [ "$CELLULAR_IFACE" = auto ]; then
        CELLULAR_IFACE="$(detect_cellular_iface)" || \
            die "无法检测蜂窝接口；请在 config.env 中设置 CELLULAR_IFACE"
    fi
    [ -e "/sys/class/net/$CELLULAR_IFACE" ] || \
        die "蜂窝接口不存在: $CELLULAR_IFACE"
    [ "$CELLULAR_ROUTE_TABLE" = auto ] && CELLULAR_ROUTE_TABLE="$CELLULAR_IFACE"
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

# Android 将来可能在这些接口上启动 DHCP 服务器。这是有意独立于 TetheredState 的：
# IpServer 可能在 3 秒桥接监视器观察到新状态之前就分配了 42-49.1 并响应了
# 第一个 DHCP 请求。在不活跃的客户端接口上阻止服务器回复是安全的。
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
    # Android 的 IpServer 可能在上游变化后重新添加其 42-49.x IPv4 地址。
    # 保持 IPv4 DHCP/路由在 ImmortalWrt 上，但保留 Android 的全局 IPv6 地址，
    # 使其蜂窝 RA 和 IPv6 转发继续工作。
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
            # ra6 在 SIGTERM 时发送撤销通告。在替换程序通告新前缀之前
            # 等待这些帧，否则延迟的撤销可能使新的默认路由失效。
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
    # 将网桥自身通告为首选路由器。Android 也可能将其物理端口路由器
    # 作为中等优先级回退发布。
    nohup "$RA6" "$iface" "$router_iface" "$prefix" \
        </dev/null >"$VM_DIR/ra6-$iface.log" 2>&1 &
    echo "$!" > "$pidfile"
}

sync_ipv6_passthrough() {
    # 此模式下 Android 拥有下游 IPv6；不抑制其原生热点 RA/DHCPv6 数据包。
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
        # 发送一个通告，紧随其后的是辅助程序的正常零生命周期撤销，
        # 使用 Android 自身的接口链路本地地址。这移除了在托管模式过滤器
        # 安装之前缓存的路由和地址，因此客户端不需要手动重新连接。
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
        # ImmortalWrt 从此 RA 学习公网 WAN 地址和默认路由。
        # 其自身防火墙从托管 LAN ULA 执行 NAT66。Android 仅将该公网
        # WAN 地址路由到蜂窝网络。
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

sync_ipv6_downstream() {
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
    echo "IPv6 回退 RA 已刷新"
}

detach_bridge_ports() {
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        bridge_detach "$iface"
    done
}

# Android 将默认路由保留在按网络的表中，而非主表中。
# 将从 ImmortalWrt WAN 到达的数据包通过具有活跃 IPv4 默认路由的任何表路由出去，
# 使 NAT 模式在 Wi-Fi、USB 或蜂窝上行链路上均能工作。
sync_upstream() {
    # Android 将活跃的 Wi-Fi/蜂窝默认路由保留在命名表中。Wi-Fi 使用
    # "default via ..."，而此 Unisoc 蜂窝驱动使用 "default dev ..."，
    # 因此两者都接受并忽略虚拟/VM 表。
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
    iptables -N OWT_OUT 2>/dev/null || true
    iptables -F OWT_OUT
    iptables -A OWT_OUT -o "$LAN_BRIDGE" -p udp --sport 67 --dport 68 -j DROP
    if [ "$TETHER_IFACE_PATTERNS" = auto ]; then
        # 尾随的 '+' 是 iptables 的接口前缀通配符。即使 USB gadget 重新配置
        # 临时移除了网卡，也保留这些规则，使新创建的 sipa_usb0/rndis0 在监视器
        # 观察到 /sys/class/net 之前无法泄露其首个 Android DHCP 提供。
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
    # 在触及网桥成员关系之前关闭 Android DHCP 竞争窗口。
    # USB 自动启用守护进程可能在 sync_bridge_ports 看到 TetheredState 之前
    # 的短暂间隔内启动 IpServer 并发出 192.168.42.x 提供。
    sync_dhcp_block
    for tap in "$WAN_TAP" "$LAN_TAP"; do
        ip link set dev "$tap" nomaster 2>/dev/null || true
        ip tuntap del dev "$tap" mode tap 2>/dev/null || ip link delete "$tap" 2>/dev/null || true
        if [ "$EFFECTIVE_NET_QUEUES" -gt 1 ]; then
            if ! ip tuntap add dev "$tap" mode tap multi_queue 2>/dev/null; then
                if [ "$VM_NET_QUEUES" = auto ]; then
                    echo "openwrt: 多队列 TAP 不可用；回退到单队列" >&2
                    EFFECTIVE_NET_QUEUES=1
                    ip tuntap add dev "$tap" mode tap
                else
                    die "无法创建多队列 TAP $tap"
                fi
            fi
        else
            ip tuntap add dev "$tap" mode tap
        fi
    done
    ip addr flush dev "$WAN_TAP" 2>/dev/null
    ip addr add "$WAN_HOST_IP/24" dev "$WAN_TAP"
    ip link set "$WAN_TAP" up

    ip link add name "$LAN_BRIDGE" type bridge 2>/dev/null || true
    ip link set dev "$LAN_BRIDGE" address 02:00:00:00:88:02
    ip link set "$LAN_BRIDGE" up
    ip addr flush dev "$LAN_TAP" 2>/dev/null
    ip link set "$LAN_TAP" up
    ip link set dev "$LAN_TAP" master "$LAN_BRIDGE"
    ip addr flush dev "$LAN_BRIDGE" 2>/dev/null
    ip addr add "$LAN_HOST_IP/24" dev "$LAN_BRIDGE"
    sync_bridge_ports
    sync_ipv6_downstream

    # 让 Android 宿主机自身能够访问 ImmortalWrt 子网（默认策略路由
    # 否则会通过尾随的 "unreachable" 规则丢弃这些数据包）。
    ip rule del priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main 2>/dev/null || true
    ip rule add priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main
    ip rule add priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main

    # 将 ImmortalWrt 的 WAN 流量通过设备的活跃上行链路发送出去。
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
    # DNAT 回复路径：将源地址重写为宿主机 LAN IP，使客户机将其视为
    # LAN 发起的连接并通过 br-lan 对称回复。没有此规则，客户机会通过
    # WAN（默认路由）路由回复，宿主机永远无法完成握手。
    # 所有路由进入 ImmortalWrt LAN 的流量都以 Android 侧 LAN 地址表示。
    # 这为 Android 应用和热点客户端提供了通过 conntrack 的对称返回路径，
    # 包括绑定到 Wi-Fi/蜂窝的应用。
    iptables -t nat -A OWT_POST ! -s "$LAN_SUBNET" -o "$LAN_BRIDGE" -j SNAT --to-source "$LAN_HOST_IP"
    ensure_jump nat POSTROUTING OWT_POST

    iptables -t nat -N OWT_PRE 2>/dev/null || true
    iptables -t nat -F OWT_PRE
    # 外部 SSH（宿主机 2223 -> ImmortalWrt LAN 88.1:22）和 LuCI Web
    # （宿主机 8080 -> 88.1:80）。使用 LAN 侧使 ImmortalWrt 默认防火墙
    # （lan input ACCEPT）生效；OWT_POST 将源地址重写为 88.2，
    # 使回复通过 br-lan 返回。旧版 iptables 拒绝在一条规则中使用
    # 多个 -i 标志，因此先用 RETURN 跳过 tap。
    iptables -t nat -A OWT_PRE -p tcp -i "$WAN_TAP" -j RETURN
    iptables -t nat -A OWT_PRE -p tcp -i "$LAN_TAP" -j RETURN
    iptables -t nat -A OWT_PRE -p tcp --dport "$SSH_DNAT_PORT" \
        -j DNAT --to-destination "$LAN_GUEST_IP:22"
    iptables -t nat -A OWT_PRE -p tcp --dport "$WEB_DNAT_PORT" \
        -j DNAT --to-destination "$LAN_GUEST_IP:80"
    ensure_jump nat PREROUTING OWT_PRE

    # Android 的热点服务仍然拥有物理 AP/RNDIS 生命周期，
    # 但 ImmortalWrt 是桥接下游端口上唯一的 DHCP/RA 服务器。
    sync_dhcp_block

}

teardown_network() {
    untakeover
    stop_ipv6_downstream
    ip rule del priority "$UPSTREAM_RULE_PRIO" 2>/dev/null || true
    detach_bridge_ports
    ip rule del priority "$HOST_ROUTE_PRIO" to "$WAN_SUBNET" lookup main 2>/dev/null || true
    ip rule del priority "$HOST_ROUTE_PRIO" to "$LAN_SUBNET" lookup main 2>/dev/null || true
    delete_jump_and_chain filter FORWARD OWT_FWD
    delete_jump_and_chain nat POSTROUTING OWT_POST
    delete_jump_and_chain nat PREROUTING OWT_PRE
    delete_jump_and_chain filter OUTPUT OWT_OUT
    delete_ip6_jump_and_chain OUTPUT OWT6_OUT
    ip link set "$LAN_TAP" nomaster 2>/dev/null || true
    ip link set "$LAN_BRIDGE" down 2>/dev/null || true
    ip link delete "$LAN_BRIDGE" type bridge 2>/dev/null || true
    for tap in "$WAN_TAP" "$LAN_TAP"; do
        ip link set "$tap" down 2>/dev/null || true
        ip tuntap del dev "$tap" mode tap 2>/dev/null || ip link delete "$tap" 2>/dev/null || true
    done
    if [ -r "$VM_DIR/ip_forward.original" ]; then
        cat "$VM_DIR/ip_forward.original" > /proc/sys/net/ipv4/ip_forward
        rm -f "$VM_DIR/ip_forward.original"
    fi
}

# 将 Android 自身本地生成的流量引导至 ImmortalWrt。热点客户端是 ImmortalWrt 的
# 二层网桥对等体，不需要宿主机策略规则。
takeover() {
    ip link show "$LAN_TAP" >/dev/null 2>&1 || die "请先运行 start"

    ip route flush table "$OWRT_TABLE" 2>/dev/null || true
    ip route add "$LAN_SUBNET" dev "$LAN_BRIDGE" table "$OWRT_TABLE"
    ip route add "$WAN_SUBNET" dev "$WAN_TAP" table "$OWRT_TABLE"
    ip route add default via 192.168.88.1 dev "$LAN_BRIDGE" table "$OWRT_TABLE"

    while ip -4 rule del priority "$RULE_PRIO" 2>/dev/null; do :; done
    ip rule add priority "$RULE_PRIO" iif lo lookup "$OWRT_TABLE"

    # ImmortalWrt 接管目前仅覆盖 Android 本地 IPv4。在接管活跃时拒绝
    # Android 宿主机自身的 IPv6；桥接的热点/USB 客户端继续使用
    # Android 的蜂窝 IPv6 服务。
    while ip -6 rule del priority "$IPV6_BLOCK_PRIO" 2>/dev/null; do :; done
    ip -6 rule add priority "$IPV6_BLOCK_PRIO" iif lo prohibit
    delete_ip6_jump_and_chain FORWARD OWT6_FWD

    touch "$TAKEOVER_FLAG"
    sync_upstream
    start_monitor
    echo "ImmortalWrt 接管已启用（Android 应用已路由；USB/WiFi 热点已桥接到 ImmortalWrt LAN）"
}

untakeover() {
    rm -f "$TAKEOVER_FLAG"
    while ip -4 rule del priority "$RULE_PRIO" 2>/dev/null; do :; done
    while ip -6 rule del priority "$IPV6_BLOCK_PRIO" 2>/dev/null; do :; done
    ip route flush table "$OWRT_TABLE" 2>/dev/null || true
    delete_ip6_jump_and_chain FORWARD OWT6_FWD
    echo "ImmortalWrt 接管已禁用"
}

network_monitor() {
    load_config
    resolve_device_config
    while is_running; do
        sync_bridge_ports
        sync_ipv6_downstream
        sync_dhcp_block
        # 客户机 WAN 转发必须跟随 Wi-Fi/蜂窝变化，
        # 无论 Android 自身本地生成的流量是否被接管。
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
    [ "$(getprop ro.product.cpu.abi 2>/dev/null)" = arm64-v8a ] || \
        die "仅支持 arm64-v8a Android 宿主机"
    [ -c /dev/kvm ] || die "/dev/kvm 不可用"
    [ -c /dev/net/tun ] || die "/dev/net/tun 不可用"
    for command in ip iptables ip6tables truncate stat dumpsys; do
        command -v "$command" >/dev/null 2>&1 || die "缺少必需的 Android 命令: $command"
    done
    if [ -x "$KVM_PROBE" ]; then
        "$KVM_PROBE" >/dev/null || die "KVM/vGIC 能力探测失败"
    fi

    probe_tap=owrt-check0
    probe_bridge=owrt-checkbr
    ip link delete "$probe_tap" 2>/dev/null || true
    ip link delete "$probe_bridge" type bridge 2>/dev/null || true
    if [ "$EFFECTIVE_NET_QUEUES" -gt 1 ]; then
        if ! ip tuntap add dev "$probe_tap" mode tap multi_queue 2>/dev/null; then
            if [ "$VM_NET_QUEUES" = auto ]; then
                EFFECTIVE_NET_QUEUES=1
                ip tuntap add dev "$probe_tap" mode tap || \
                    die "内核无法创建 TAP 接口"
            else
                die "内核无法创建多队列 TAP 接口"
            fi
        fi
    else
        ip tuntap add dev "$probe_tap" mode tap || die "内核无法创建 TAP 接口"
    fi
    ip link add name "$probe_bridge" type bridge || {
        ip link delete "$probe_tap" 2>/dev/null || true
        die "内核无法创建 Linux 网桥"
    }
    ip link delete "$probe_tap" 2>/dev/null || true
    ip link delete "$probe_bridge" type bridge 2>/dev/null || true

    matched=""
    for path in /sys/class/net/*; do
        iface="${path##*/}"
        matches_tether_pattern "$iface" && matched="$matched $iface"
    done
    [ -n "$matched" ] || \
        die "TETHER_IFACE_PATTERNS 未匹配到任何当前接口"
    echo "preflight ok: crosvm=$CROSVM style=$CROSVM_STYLE cpus=$VM_CPUS affinity=${EFFECTIVE_CPU_AFFINITY:-none} capacity=${EFFECTIVE_CPU_CAPACITY:-none} clusters=${EFFECTIVE_CPU_CLUSTERS:-none} net_queues=$EFFECTIVE_NET_QUEUES cellular=$CELLULAR_IFACE table=$CELLULAR_ROUTE_TABLE tether=${TETHER_IFACE_PATTERNS} ipv6_passthrough=$IPV6_PASSTHROUGH"
}

start_vm() {
    load_config
    resolve_device_config
    preflight_vm >/dev/null
    for file in "$DISK" "$KERNEL"; do
        [ -r "$file" ] || die "缺少 $file"
    done
    if is_running; then
        echo "ImmortalWrt VM 已在运行 (PID $(cat "$PIDFILE"))"
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
    net_queue_arg=""
    [ "$EFFECTIVE_NET_QUEUES" -gt 1 ] && \
        net_queue_arg="--net-vq-pairs=$EFFECTIVE_NET_QUEUES"

    if [ "$CROSVM_STYLE" = block ]; then
        nohup "$CROSVM" run \
            --disable-sandbox \
            --cpus "$VM_CPUS" \
            $cpu_affinity_arg \
            $cpu_capacity_arg \
            $cpu_cluster_args \
            $net_queue_arg \
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
            $net_queue_arg \
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
        echo "crosvm 启动期间退出:" >&2
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
    echo "ImmortalWrt VM 已启动 (PID $pid, WAN $WAN_GUEST_IP, LAN $LAN_GUEST_IP, SSH 宿主机端口 $SSH_DNAT_PORT)"
}

stop_vm() {
    load_config
    resolve_device_config
    stop_monitor
    if ! is_running; then
        rm -f "$PIDFILE" "$SOCKET"
        # 崩溃或先前停止的 VM 可能留下 TAP 设备、LAN 网桥和 DHCP 抑制规则。
        # 即使没有 crosvm 进程可停止，也要恢复 Android 热点。
        teardown_network
        echo "ImmortalWrt VM 未在运行"
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
    # 仅在 crosvm 释放其 TAP 设备后拆除网桥。
    # 这同时恢复 Android 热点/USB DHCP 及其原始地址。
    teardown_network
    echo "ImmortalWrt VM 已停止"
}

status_vm() {
    load_config
    resolve_device_config
    if is_running; then
        bridge_ports="$(ls "/sys/class/net/$LAN_BRIDGE/brif" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
        echo "running PID=$(cat "$PIDFILE") wan=$WAN_GUEST_IP lan=$LAN_GUEST_IP bridge=$LAN_BRIDGE ports=${bridge_ports:-none} net_queues=$EFFECTIVE_NET_QUEUES ipv6_passthrough=$IPV6_PASSTHROUGH ssh=localhost:$SSH_DNAT_PORT"
    else
        echo "stopped"
        return 1
    fi
}

uninstall_vm() {
    stop_vm
    teardown_network
    [ "$VM_DIR" = /data/local/openwrt ] || die "不安全的 VM_DIR"
    rm -rf -- "$VM_DIR"
    echo "ImmortalWrt VM 数据和网络规则已移除"
}

case "${1:-}" in
    __network_monitor) network_monitor ;;
    start) start_vm ;;
    stop) stop_vm ;;
    restart) stop_vm; start_vm ;;
    status) status_vm ;;
    preflight) preflight_vm ;;
    refresh-ipv6) refresh_ipv6 ;;
    logs) tail -n "${2:-200}" "$LOG" 2>/dev/null; echo "--- 客户机控制台 ---"; tail -n "${2:-200}" "$CONSOLE" 2>/dev/null ;;
    takeover) takeover ;;
    untakeover) untakeover ;;
    uninstall) uninstall_vm ;;
    *) echo "用法: $0 {start|stop|restart|status|preflight|refresh-ipv6|logs [行数]|takeover|untakeover|uninstall}" >&2; exit 2 ;;
esac
