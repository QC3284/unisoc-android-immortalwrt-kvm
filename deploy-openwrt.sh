#!/usr/bin/env bash
# ImmortalWrt Android KVM 部署脚本（由 DeepSeek-V4-Pro 修改：替换为 ImmortalWrt + 国内镜像源）
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${OPENWRT_CONFIG:-$SCRIPT_DIR/config.env}"
if [[ -r "$CONFIG_FILE" ]]; then
    # 这是一个受信任的 shell 风格项目配置文件。环境变量可以覆盖其中的默认值，
    # 因为 config.env 使用 ${VAR:-...} 语法。
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
else
    echo "deploy-openwrt: 找不到配置文件: $CONFIG_FILE" >&2
    exit 1
fi
CACHE_DIR="$SCRIPT_DIR/cache"
BUILD_DIR="$SCRIPT_DIR/build"
BUNDLED_CROSVM="$SCRIPT_DIR/assets/crosvm/android13/crosvm"
DEVICE_DIR=/data/local/openwrt
STAGE_DIR=/data/local/tmp/openwrt-deploy
RESTORE_STAGE=/data/local/tmp/openwrt-restore
if [[ -z "${ADB_BIN:-}" ]]; then
    # 独立于设备数量选择可执行文件。 `adb get-state` 在存在多个设备时
    # 会返回错误，这不应被误认为 adb 未安装。
    for adb_candidate in adb.exe adb; do
        command -v "$adb_candidate" >/dev/null 2>&1 || continue
        ADB_BIN="$(command -v "$adb_candidate")"
        break
    done
    : "${ADB_BIN:=adb}"
fi
OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.1}"
OPENWRT_TARGET="${OPENWRT_TARGET:-armsr/armv8}"
OPENWRT_PASSWORD="${OPENWRT_PASSWORD:-root}"
DEVICE_MODEL="${DEVICE_MODEL:-auto}"
RESOLVED_DEVICE_MODEL=""
DISK_SIZE="${DISK_SIZE:-8G}"
# 官方 ext4 镜像约 104 MiB。仅保留少量安全余量用于首次启动的软件包元数据；
# Android 在上传后将其稀疏扩展到 DISK_SIZE，ImmortalWrt 在线扩展 ext4。
TRANSFER_DISK_SIZE="${TRANSFER_DISK_SIZE:-128M}"
VM_CPUS="${VM_CPUS:-4}"
VM_CPU_AFFINITY="${VM_CPU_AFFINITY:-auto}"
VM_NET_QUEUES="${VM_NET_QUEUES:-auto}"
VM_MEMORY_MIB="${VM_MEMORY_MIB:-1024}"
AUTO_TAKEOVER="${AUTO_TAKEOVER:-0}"
IPV6_PASSTHROUGH="${IPV6_PASSTHROUGH:-1}"
CROSVM_PATH="${CROSVM_PATH:-auto}"
CELLULAR_IFACE="${CELLULAR_IFACE:-auto}"
CELLULAR_ROUTE_TABLE="${CELLULAR_ROUTE_TABLE:-auto}"
TETHER_IFACE_PATTERNS="${TETHER_IFACE_PATTERNS:-auto}"
TETHER_MODE="${TETHER_MODE:-auto}"
# 使用中国科学技术大学 (USTC) 镜像站下载 ImmortalWrt，国内速度最快
BASE_URL="https://mirrors.ustc.edu.cn/immortalwrt/releases/$OPENWRT_VERSION/targets/$OPENWRT_TARGET"
TARGET_BASENAME="${OPENWRT_TARGET//\//-}"
KERNEL_NAME="immortalwrt-$OPENWRT_VERSION-$TARGET_BASENAME-generic-kernel.bin"
ROOTFS_NAME="immortalwrt-$OPENWRT_VERSION-$TARGET_BASENAME-generic-ext4-rootfs.img.gz"
WAN_HOST_IP=192.168.66.1
WAN_GUEST_IP=192.168.66.2
LAN_HOST_IP=192.168.88.2
LAN_GUEST_IP=192.168.88.1
WAN_DNS1="${WAN_DNS1:-223.5.5.5}"
WAN_DNS2="${WAN_DNS2:-8.8.8.8}"
ADB_PROBE_TIMEOUT_SECONDS="${ADB_PROBE_TIMEOUT_SECONDS:-5}"
ADB_CONTROL_TIMEOUT_SECONDS="${ADB_CONTROL_TIMEOUT_SECONDS:-45}"

say() { printf '\n==> %s\n' "$*"; }
die() { echo "deploy-openwrt: $*" >&2; exit 1; }

adb_cmd() {
    if [[ -n "${ADB_SERIAL:-}" ]]; then
        "$ADB_BIN" -s "$ADB_SERIAL" "$@"
    else
        "$ADB_BIN" "$@"
    fi
}

adb_timed_cmd() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        if [[ -n "${ADB_SERIAL:-}" ]]; then
            timeout --foreground "${seconds}s" "$ADB_BIN" -s "$ADB_SERIAL" "$@"
        else
            timeout --foreground "${seconds}s" "$ADB_BIN" "$@"
        fi
    else
        adb_cmd "$@"
    fi
}

adb_probe_cmd() {
    local attempt rc=1
    for attempt in 1 2; do
        if adb_timed_cmd "$ADB_PROBE_TIMEOUT_SECONDS" "$@"; then
            return 0
        else
            rc=$?
        fi
        # 不要将用户的 Ctrl-C/终止信号误判为 root 或设备错误。
        case "$rc" in 130|143) return "$rc" ;; esac
    done
    return "$rc"
}

# adb.exe (Windows) 无法读取 WSL 路径；需要时进行转换。
adb_path() {
    if [[ "$ADB_BIN" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

device_manager() {
    local args="${*:-status}"
    local rc
    adb_timed_cmd "$ADB_CONTROL_TIMEOUT_SECONDS" shell \
        "su 0 sh -c '$DEVICE_DIR/openwrt.sh $args'" || {
        rc=$?
        if [[ "$rc" == 124 ]]; then
            echo "deploy-openwrt: ADB 控制命令超时 (${ADB_CONTROL_TIMEOUT_SECONDS}s): $args" >&2
        fi
        return "$rc"
    }
}

device_has_manager() {
    local rc
    if adb_probe_cmd shell "su 0 sh -c 'test -x $DEVICE_DIR/openwrt.sh'" >/dev/null 2>&1; then
        return 0
    else
        rc=$?
    fi
    case "$rc" in 130|143) exit "$rc" ;; esac
    return "$rc"
}

device_has_image() {
    local rc
    if adb_probe_cmd shell "su 0 sh -c 'test -f $DEVICE_DIR/openwrt.img'" >/dev/null 2>&1; then
        return 0
    else
        rc=$?
    fi
    case "$rc" in 130|143) exit "$rc" ;; esac
    return "$rc"
}

force_remove_device_vm() {
    # 此路径仅在显式卸载请求后、设备端管理器缺失或损坏时使用。
    # 一个全零的可执行文件被 sh 解释时仍可能返回成功，因此命令状态
    # 不足以证明卸载确实发生了。
    adb_cmd shell "su 0 sh -c '
        for pidfile in $DEVICE_DIR/network-monitor.pid $DEVICE_DIR/crosvm.pid; do
            if test -r \"\$pidfile\"; then
                pid=\$(cat \"\$pidfile\" 2>/dev/null)
                case \"\$pid\" in *[!0-9]*|\"\") ;; *) kill \"\$pid\" 2>/dev/null || true ;; esac
            fi
        done
        ip link delete owrt-br type bridge 2>/dev/null || true
        ip link delete owrt-wan 2>/dev/null || true
        ip link delete owrt-lan 2>/dev/null || true
        rm -rf -- $DEVICE_DIR
    '"
}

refuse_existing_image() {
    if device_has_image; then
        die "目标已包含 $DEVICE_DIR/openwrt.img；请先运行 'backup' 备份，仅在确定要替换时运行 'uninstall'"
    fi
}

select_device() {
    [[ -n "${ADB_SERIAL:-}" ]] && return 0

    local devices=() installed=() serial device_list
    device_list="$(adb_probe_cmd devices)" || die "ADB 设备列表获取失败或超时"
    mapfile -t devices < <(printf '%s\n' "$device_list" | tr -d '\r' | \
        awk 'NR > 1 && $2 == "device" { print $1 }')
    case "${#devices[@]}" in
        0) die "未找到在线的 ADB 设备" ;;
        1) ADB_SERIAL="${devices[0]}"; return 0 ;;
    esac

    # 管理命令可以安全地识别已包含本项目管理器的唯一设备。
    # 全新安装仍需显式指定序列号，因为猜测目标设备是不安全的。
    for serial in "${devices[@]}"; do
        if adb_timed_cmd "$ADB_PROBE_TIMEOUT_SECONDS" -s "$serial" shell \
                "su 0 sh -c 'test -x $DEVICE_DIR/openwrt.sh'" >/dev/null 2>&1; then
            installed+=("$serial")
        fi
    done
    if ((${#installed[@]} == 1)); then
        ADB_SERIAL="${installed[0]}"
        echo "deploy-openwrt: 自动选择已安装的设备 $ADB_SERIAL" >&2
        return 0
    fi
    die "多个 ADB 设备在线 (${devices[*]})；请在 config.env 或环境变量中设置 ADB_SERIAL"
}

check_device() {
    local rc
    command -v "$ADB_BIN" >/dev/null 2>&1 || die "$ADB_BIN 未找到"
    select_device
    adb_probe_cmd get-state >/dev/null || {
        rc=$?
        case "$rc" in 130|143) return "$rc" ;; esac
        die "ADB 设备探测失败或超时"
    }
    adb_probe_cmd shell "su 0 sh -c 'exit 0'" >/dev/null 2>&1 || {
        rc=$?
        case "$rc" in 130|143) return "$rc" ;; esac
        [[ "$rc" == 124 ]] && die "ADB root 探测超时"
        die "root shell 不可用（需要 KernelSU/Magisk 权限）"
    }
}

read_device_property() {
    adb_cmd shell "getprop $1" 2>/dev/null | tr -d '\r\n'
}

validate_device_model() {
    local model="$1"
    [[ -n "$model" ]] || die "DEVICE_MODEL 解析为空值"
    [[ "$model" != *"'"* && "$model" != *$'\n'* && "$model" != *$'\r'* ]] || \
        die "DEVICE_MODEL 不能包含引号或换行符"
    ((${#model} <= 120)) || die "DEVICE_MODEL 过长（最多 120 个字符）"
}

resolve_device_model() {
    if [[ "$DEVICE_MODEL" != auto ]]; then
        validate_device_model "$DEVICE_MODEL"
        RESOLVED_DEVICE_MODEL="$DEVICE_MODEL"
        return
    fi

    local manufacturer model device soc platform label soc_label
    manufacturer="$(read_device_property ro.product.manufacturer)"
    model="$(read_device_property ro.product.model)"
    device="$(read_device_property ro.product.device)"
    soc="$(read_device_property ro.soc.model)"
    platform="$(read_device_property ro.board.platform)"

    if [[ -n "$device" && -n "$model" && "${device,,}" != "${model,,}" ]]; then
        label="$device/$model"
    else
        label="${model:-${device:-Android ARM64}}"
    fi
    [[ -n "$manufacturer" ]] && label="$manufacturer $label"
    if [[ -n "$soc" && -n "$platform" && "${soc,,}" != "${platform,,}" ]]; then
        soc_label="$soc / $platform"
    else
        soc_label="${soc:-$platform}"
    fi
    [[ -n "$soc_label" ]] && label="$label ($soc_label)"
    validate_device_model "$label"
    RESOLVED_DEVICE_MODEL="$label"
    echo "deploy-openwrt: 检测到设备型号: $RESOLVED_DEVICE_MODEL" >&2
}

validate_config() {
    [[ "$AUTO_TAKEOVER" == 0 || "$AUTO_TAKEOVER" == 1 ]] || \
        die "AUTO_TAKEOVER 必须为 0 或 1"
    [[ "$IPV6_PASSTHROUGH" == 0 || "$IPV6_PASSTHROUGH" == 1 ]] || \
        die "IPV6_PASSTHROUGH 必须为 0 或 1"
    [[ "$DEVICE_MODEL" == auto ]] || validate_device_model "$DEVICE_MODEL"
    [[ "$VM_CPUS" =~ ^[1-9][0-9]*$ ]] || die "VM_CPUS 必须为正整数"
    [[ "$VM_CPU_AFFINITY" == auto || "$VM_CPU_AFFINITY" == none || \
       "$VM_CPU_AFFINITY" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ || \
       "$VM_CPU_AFFINITY" =~ ^[0-9]+=[0-9]+(:[0-9]+=[0-9]+)*$ ]] || \
        die "VM_CPU_AFFINITY 必须为 auto、none、CPU 集合或 guest=host 映射"
    [[ "$VM_NET_QUEUES" == auto || "$VM_NET_QUEUES" =~ ^[1-9][0-9]*$ ]] || \
        die "VM_NET_QUEUES 必须为 auto 或正整数"
    if [[ "$VM_NET_QUEUES" != auto ]] && ((VM_NET_QUEUES > VM_CPUS)); then
        die "VM_NET_QUEUES 不能超过 VM_CPUS"
    fi
    [[ "$VM_MEMORY_MIB" =~ ^[1-9][0-9]*$ ]] || die "VM_MEMORY_MIB 必须为正整数"
    [[ "$CROSVM_PATH" == auto || "$CROSVM_PATH" == bundled || "$CROSVM_PATH" == /* ]] || \
        die "CROSVM_PATH 必须为 auto、bundled 或设备上的绝对路径"
    [[ "$CROSVM_PATH" =~ ^[A-Za-z0-9_./-]+$ ]] || die "无效的 CROSVM_PATH"
    [[ "$CELLULAR_IFACE" =~ ^(auto|[A-Za-z0-9_.-]+)$ ]] || die "无效的 CELLULAR_IFACE"
    [[ "$CELLULAR_ROUTE_TABLE" =~ ^(auto|[A-Za-z0-9_.-]+)$ ]] || die "无效的 CELLULAR_ROUTE_TABLE"
    [[ -n "$TETHER_IFACE_PATTERNS" && "$TETHER_IFACE_PATTERNS" =~ ^[A-Za-z0-9_.*?+-]+([[:space:]]+[A-Za-z0-9_.*?+-]+)*$ ]] || \
        die "无效的 TETHER_IFACE_PATTERNS"
    [[ "$TETHER_MODE" == auto || "$TETHER_MODE" == bridge || "$TETHER_MODE" == routed || "$TETHER_MODE" == proxyarp || "$TETHER_MODE" == directbr0 ]] || \
        die "TETHER_MODE 必须为 auto、bridge、routed、proxyarp 或 directbr0"
}

install_dependencies() {
    local missing=()
    for cmd in curl gzip e2fsck resize2fs virt-copy-in virt-copy-out sha256sum openssl file aarch64-linux-gnu-gcc; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return
    say "正在安装 WSL 依赖: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y curl gzip e2fsprogs libguestfs-tools openssl file gcc-aarch64-linux-gnu
}

build_tools() {
    mkdir -p "$BUILD_DIR/tools"
    say "正在构建 Android ARM64 IPv6 RA 辅助程序"
    aarch64-linux-gnu-gcc -O2 -static -s -Wall -Wextra \
        -o "$BUILD_DIR/tools/ra6" "$SCRIPT_DIR/tools/ra6.c"
    file "$BUILD_DIR/tools/ra6"
    say "正在构建 Android ARM64 KVM/vGIC 预检辅助程序"
    aarch64-linux-gnu-gcc -O2 -static -s -Wall -Wextra \
        -o "$BUILD_DIR/tools/kvm-probe" "$SCRIPT_DIR/tools/kvm_probe.c"
    file "$BUILD_DIR/tools/kvm-probe"
    say "正在构建 Android ARM64 DHCP 帧中继"
    aarch64-linux-gnu-gcc -O2 -static -s -Wall -Wextra \
        -o "$BUILD_DIR/tools/dhcp-relay" "$SCRIPT_DIR/tools/dhcp_relay.c"
    file "$BUILD_DIR/tools/dhcp-relay"
    [[ -x "$BUNDLED_CROSVM" ]] || chmod +x "$BUNDLED_CROSVM" 2>/dev/null || true
    [[ -x "$BUNDLED_CROSVM" ]] || die "缺少内置 crosvm: $BUNDLED_CROSVM"
    file "$BUNDLED_CROSVM" | grep -q 'ARM aarch64.*statically linked' || \
        die "内置 crosvm 不是静态 ARM64 可执行文件"
}

write_vm_config() {
    local output="$1"
    cat > "$output" <<EOF
ROOT_DEVICE='/dev/vda'
VM_CPUS='$VM_CPUS'
VM_CPU_AFFINITY='$VM_CPU_AFFINITY'
VM_NET_QUEUES='$VM_NET_QUEUES'
VM_MEMORY_MIB='$VM_MEMORY_MIB'
DISK_SIZE='$DISK_SIZE'
AUTO_TAKEOVER='$AUTO_TAKEOVER'
IPV6_PASSTHROUGH='$IPV6_PASSTHROUGH'
CROSVM_PATH='$CROSVM_PATH'
CELLULAR_IFACE='$CELLULAR_IFACE'
CELLULAR_ROUTE_TABLE='$CELLULAR_ROUTE_TABLE'
TETHER_IFACE_PATTERNS='$TETHER_IFACE_PATTERNS'
TETHER_MODE='$TETHER_MODE'
EOF
}

verify_device_sha256() {
    local local_file="$1" remote_file="$2" expected actual
    expected="$(sha256sum "$local_file" | awk '{print $1}')"
    actual="$(adb_cmd shell "su 0 sh -c 'sha256sum $remote_file'" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || \
        die "设备文件校验失败: $remote_file (期望 $expected, 实际 ${actual:-无哈希})"
}

download_image() {
    mkdir -p "$CACHE_DIR"
    for f in "$KERNEL_NAME" "$ROOTFS_NAME" sha256sums; do
        if [[ ! -s "$CACHE_DIR/$f" ]]; then
            say "正在下载 $f"
            curl -fL --retry 3 -o "$CACHE_DIR/$f.part" "$BASE_URL/$f"
            mv "$CACHE_DIR/$f.part" "$CACHE_DIR/$f"
        fi
    done
    say "正在校验 ImmortalWrt SHA-256 校验和"
    (cd "$CACHE_DIR" && sha256sum -c --ignore-missing sha256sums 2>&1 | grep -Ei "OK|FAILED") || true
    (cd "$CACHE_DIR" && sha256sum -c --ignore-missing sha256sums) >/dev/null || die "校验和不匹配"
}

prepare_image() {
    validate_config
    [[ "$DISK_SIZE" =~ ^[1-9][0-9]*[KMG]$ ]] || die "无效的 DISK_SIZE: $DISK_SIZE"
    [[ "$TRANSFER_DISK_SIZE" =~ ^[1-9][0-9]*[KMG]$ ]] || die "无效的 TRANSFER_DISK_SIZE: $TRANSFER_DISK_SIZE"
    [[ "$BUILD_DIR" == "$SCRIPT_DIR/build" ]] || die "不安全的 BUILD_DIR: $BUILD_DIR"
    rm -rf -- "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    export LIBGUESTFS_BACKEND=direct

    say "正在解压根文件系统"
    gzip -dc "$CACHE_DIR/$ROOTFS_NAME" > "$BUILD_DIR/openwrt.img"

    # 预置 /etc/config/network。ImmortalWrt 的 /bin/config_generate 仅在文件不存在时
    # 创建它，因此我们的静态 WAN/LAN 设置在首次启动后仍然有效。
    # eth0 = 第一个 crosvm tap (owrt-wan, WAN 侧), eth1 = 第二个 tap (owrt-lan)。
    cat > "$BUILD_DIR/network" <<EOF
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config device
	option name 'br-lan'
	option type 'bridge'
	option macaddr '02:00:00:00:88:01'
	list ports 'eth1'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '$LAN_GUEST_IP'
	option netmask '255.255.255.0'
	option ip6assign '64'

config interface 'wan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '$WAN_GUEST_IP'
	option netmask '255.255.255.0'
	option gateway '$WAN_HOST_IP'
	list dns '$WAN_DNS1'
	list dns '$WAN_DNS2'

config interface 'wan6'
	option device 'eth0'
	option proto 'dhcpv6'
	option reqaddress 'try'
	option reqprefix 'no'
	option extendprefix '1'
EOF
    say "正在将网络配置嵌入根文件系统"
    virt-copy-in -a "$BUILD_DIR/openwrt.img" "$BUILD_DIR/network" /etc/config/

    # crosvm 的 ARM 平台没有设备树模型。发布物理设备/SoC 名称，
    # 使 ubus 和 LuCI 不会将型号显示为 "?"。
    local image_model="${RESOLVED_DEVICE_MODEL:-$DEVICE_MODEL}"
    [[ "$image_model" == auto ]] && image_model="Generic Android ARM64 Host"
    validate_device_model "$image_model"
    local escaped_model="$image_model"
    escaped_model="${escaped_model//\\/\\\\}"
    escaped_model="${escaped_model//&/\\&}"
    escaped_model="${escaped_model//|/\\|}"
    sed "s|@DEVICE_MODEL@|$escaped_model|g" \
        "$SCRIPT_DIR/device/rc.local" > "$BUILD_DIR/rc.local"
    say "正在将硬件型号嵌入根文件系统: $image_model"
    virt-copy-in -a "$BUILD_DIR/openwrt.img" "$BUILD_DIR/rc.local" /etc/

    say "正在设置 root 密码"
    hash="$(openssl passwd -6 "$OPENWRT_PASSWORD")"
    virt-copy-out -a "$BUILD_DIR/openwrt.img" /etc/shadow "$BUILD_DIR/"
    sed -i "s|^root:[^:]*:|root:$hash:|" "$BUILD_DIR/shadow"
    virt-copy-in -a "$BUILD_DIR/openwrt.img" "$BUILD_DIR/shadow" /etc/

    say "正在将传输镜像扩展到 $TRANSFER_DISK_SIZE"
    # 运行两次：第一次修复出厂镜像，第二次清除 needs-fsck 标志，
    # 使 resize2fs 不会尝试交互式运行 e2fsck。
    # e2fsck 在纠正错误时返回 1，这在这里是可以接受的。
    for pass in 1 2; do
        local rc=0
        e2fsck -fy "$BUILD_DIR/openwrt.img" || rc=$?
        ((rc <= 1)) || die "e2fsck 失败，返回码=$rc"
    done
    # ImmortalWrt 出厂 ext4 镜像逻辑大小约 300 MiB（稀疏），解压后约 300 MiB。
    # 不能缩小，只在不小于目标大小时才执行 truncate。
    local cur_bytes target_bytes
    cur_bytes=$(stat -c%s "$BUILD_DIR/openwrt.img")
    case "$TRANSFER_DISK_SIZE" in
        *M) target_bytes=$(( ${TRANSFER_DISK_SIZE%M} * 1048576 )) ;;
        *G) target_bytes=$(( ${TRANSFER_DISK_SIZE%G} * 1073741824 )) ;;
        *K) target_bytes=$(( ${TRANSFER_DISK_SIZE%K} * 1024 )) ;;
        *)  target_bytes=$TRANSFER_DISK_SIZE ;;
    esac
    if (( cur_bytes < target_bytes )); then
        truncate -s "$TRANSFER_DISK_SIZE" "$BUILD_DIR/openwrt.img"
    fi
    resize2fs -f "$BUILD_DIR/openwrt.img"

    cp "$CACHE_DIR/$KERNEL_NAME" "$BUILD_DIR/Image"
    file "$BUILD_DIR/Image"

    # 完整性检查：验证嵌入的文件可读且包含我们的设置。
    rm -rf "$BUILD_DIR/check" "$BUILD_DIR/check2"
    mkdir -p "$BUILD_DIR/check" "$BUILD_DIR/check2"
    virt-copy-out -a "$BUILD_DIR/openwrt.img" /etc/config/network "$BUILD_DIR/check"
    grep -q "$WAN_GUEST_IP" "$BUILD_DIR/check/network" || die "网络配置未嵌入"
    virt-copy-out -a "$BUILD_DIR/openwrt.img" /etc/shadow "$BUILD_DIR/check2"
    grep -q "^root:\\\$6\\\$" "$BUILD_DIR/check2/shadow" || die "root 密码未嵌入"
    rm -rf "$BUILD_DIR/check3"
    mkdir -p "$BUILD_DIR/check3"
    virt-copy-out -a "$BUILD_DIR/openwrt.img" /etc/rc.local "$BUILD_DIR/check3"
    grep -Fq "$image_model" "$BUILD_DIR/check3/rc.local" || die "硬件型号未嵌入"
    grep -q "resize2fs /dev/vda" "$BUILD_DIR/check3/rc.local" || die "在线根文件系统扩展未嵌入"

    write_vm_config "$BUILD_DIR/vm.conf"
    build_tools
    say "镜像已准备: $BUILD_DIR/openwrt.img ($(du -h "$BUILD_DIR/openwrt.img" | cut -f1) 逻辑大小)"
}

deploy() {
    check_device
    # 在下载/构建工作之前拒绝，然后在分阶段镜像移动到目标位置之前再次检查。
    # `install` 绝不能是隐式的重装操作，因为客户机磁盘包含用户数据。
    refuse_existing_image
    resolve_device_model
    install_dependencies
    download_image
    prepare_image

    say "正在上传 ImmortalWrt VM 分阶段文件"
    adb_cmd shell "rm -rf $STAGE_DIR && mkdir -p $STAGE_DIR"
    adb_cmd push "$(adb_path "$BUILD_DIR/openwrt.img")" "$STAGE_DIR/openwrt.img"
    verify_device_sha256 "$BUILD_DIR/openwrt.img" "$STAGE_DIR/openwrt.img"
    say "正在稀疏扩展镜像到 $DISK_SIZE"
    local sparse_stats logical blocks allocated
    sparse_stats="$(adb_cmd shell "su 0 sh -c 'command -v truncate >/dev/null && truncate -s $DISK_SIZE $STAGE_DIR/openwrt.img && echo logical=\$(stat -c %s $STAGE_DIR/openwrt.img) && echo blocks=\$(stat -c %b $STAGE_DIR/openwrt.img)'" | tr -d '\r')" || \
        die "无法扩展或检查 Android 镜像"
    logical="$(awk -F= '$1 == "logical" { print $2 }' <<<"$sparse_stats")"
    blocks="$(awk -F= '$1 == "blocks" { print $2 }' <<<"$sparse_stats")"
    [[ "$logical" =~ ^[0-9]+$ && "$blocks" =~ ^[0-9]+$ ]] || \
        die "Android 返回的稀疏镜像统计数据无效: $sparse_stats"
    # 在宿主机 Bash 中进行此比较。Android 13 Toybox `test` 可能拒绝或错误比较
    # 超出其整数范围的逻辑大小（此处为 8 GiB）。
    allocated=$((blocks * 512))
    echo "logical=$logical allocated=$allocated"
    ((allocated < logical)) || die "Android 存储不支持所需的稀疏镜像"
    adb_cmd push "$(adb_path "$BUILD_DIR/Image")" "$STAGE_DIR/Image"
    adb_cmd push "$(adb_path "$BUILD_DIR/vm.conf")" "$STAGE_DIR/vm.conf"
    adb_cmd push "$(adb_path "$SCRIPT_DIR/device/openwrt.sh")" "$STAGE_DIR/openwrt.sh"
    adb_cmd push "$(adb_path "$BUILD_DIR/tools/ra6")" "$STAGE_DIR/ra6"
    adb_cmd push "$(adb_path "$BUILD_DIR/tools/kvm-probe")" "$STAGE_DIR/kvm-probe"
    adb_cmd push "$(adb_path "$BUILD_DIR/tools/dhcp-relay")" "$STAGE_DIR/dhcp-relay"
    adb_cmd push "$(adb_path "$BUNDLED_CROSVM")" "$STAGE_DIR/crosvm"

    verify_device_sha256 "$BUILD_DIR/Image" "$STAGE_DIR/Image"
    verify_device_sha256 "$BUILD_DIR/vm.conf" "$STAGE_DIR/vm.conf"
    verify_device_sha256 "$SCRIPT_DIR/device/openwrt.sh" "$STAGE_DIR/openwrt.sh"
    verify_device_sha256 "$BUILD_DIR/tools/ra6" "$STAGE_DIR/ra6"
    verify_device_sha256 "$BUILD_DIR/tools/kvm-probe" "$STAGE_DIR/kvm-probe"
    verify_device_sha256 "$BUILD_DIR/tools/dhcp-relay" "$STAGE_DIR/dhcp-relay"
    verify_device_sha256 "$BUNDLED_CROSVM" "$STAGE_DIR/crosvm"

    refuse_existing_image
    adb_cmd shell "su 0 sh -c 'mkdir -p $DEVICE_DIR && mv $STAGE_DIR/openwrt.img $DEVICE_DIR/openwrt.img && mv $STAGE_DIR/Image $DEVICE_DIR/Image && mv $STAGE_DIR/vm.conf $DEVICE_DIR/vm.conf && mv $STAGE_DIR/openwrt.sh $DEVICE_DIR/openwrt.sh && mv $STAGE_DIR/ra6 $DEVICE_DIR/ra6 && mv $STAGE_DIR/kvm-probe $DEVICE_DIR/kvm-probe && mv $STAGE_DIR/dhcp-relay $DEVICE_DIR/dhcp-relay && mv $STAGE_DIR/crosvm $DEVICE_DIR/crosvm && chmod 700 $DEVICE_DIR $DEVICE_DIR/openwrt.sh $DEVICE_DIR/ra6 $DEVICE_DIR/kvm-probe $DEVICE_DIR/dhcp-relay $DEVICE_DIR/crosvm && chmod 600 $DEVICE_DIR/openwrt.img $DEVICE_DIR/Image $DEVICE_DIR/vm.conf && chown -R root:root $DEVICE_DIR && rmdir $STAGE_DIR && sync'"
    verify_device_sha256 "$BUILD_DIR/Image" "$DEVICE_DIR/Image"
    verify_device_sha256 "$BUILD_DIR/vm.conf" "$DEVICE_DIR/vm.conf"
    verify_device_sha256 "$SCRIPT_DIR/device/openwrt.sh" "$DEVICE_DIR/openwrt.sh"
    verify_device_sha256 "$BUILD_DIR/tools/ra6" "$DEVICE_DIR/ra6"
    verify_device_sha256 "$BUILD_DIR/tools/kvm-probe" "$DEVICE_DIR/kvm-probe"
    verify_device_sha256 "$BUILD_DIR/tools/dhcp-relay" "$DEVICE_DIR/dhcp-relay"
    verify_device_sha256 "$BUNDLED_CROSVM" "$DEVICE_DIR/crosvm"
    device_manager preflight
    device_manager start

    cat <<EOF

ImmortalWrt 正在启动。首次启动需要 30-60 秒。
SSH:      ssh root@192.168.88.1           （从受管理的 USB/热点客户端）
Web:      http://192.168.88.1             （LuCI，从 ImmortalWrt LAN 访问）
密码:     $OPENWRT_PASSWORD
拓扑:     WAN 192.168.66.2 <-> 宿主机 192.168.66.1 (NAT 出口)
          LAN 192.168.88.1 <-> owrt-br 192.168.88.2 (DHCP 100-249)
          USB/WiFi 使用 TETHER_MODE=$TETHER_MODE (auto 在设备上解析)
接管:     AUTO_TAKEOVER=$AUTO_TAKEOVER (在 config.env 中配置)
IPv6:     IPV6_PASSTHROUGH=$IPV6_PASSTHROUGH (0=ImmortalWrt 托管, 1=Android 直通)
状态:     ./deploy-openwrt.sh status
日志:     ./deploy-openwrt.sh logs
卸载:     ./deploy-openwrt.sh uninstall
EOF
}

update_manager() {
    local restart="${1:-1}"
    install_dependencies
    check_device
    device_has_manager || die "ImmortalWrt 未安装；请先运行 install"
    build_tools
    say "正在仅上传设备管理器"
    adb_cmd push "$(adb_path "$SCRIPT_DIR/device/openwrt.sh")" /data/local/tmp/openwrt.sh.new
    adb_cmd push "$(adb_path "$BUILD_DIR/tools/ra6")" /data/local/tmp/ra6.new
    adb_cmd push "$(adb_path "$BUILD_DIR/tools/kvm-probe")" /data/local/tmp/kvm-probe.new
    adb_cmd push "$(adb_path "$BUILD_DIR/tools/dhcp-relay")" /data/local/tmp/dhcp-relay.new
    adb_cmd push "$(adb_path "$BUNDLED_CROSVM")" /data/local/tmp/crosvm.new
    adb_cmd shell "su 0 sh -c 'cp /data/local/tmp/openwrt.sh.new $DEVICE_DIR/openwrt.sh && cp /data/local/tmp/ra6.new $DEVICE_DIR/ra6.next && cp /data/local/tmp/kvm-probe.new $DEVICE_DIR/kvm-probe.next && cp /data/local/tmp/dhcp-relay.new $DEVICE_DIR/dhcp-relay.next && cp /data/local/tmp/crosvm.new $DEVICE_DIR/crosvm.next && chown root:root $DEVICE_DIR/openwrt.sh $DEVICE_DIR/ra6.next $DEVICE_DIR/kvm-probe.next $DEVICE_DIR/dhcp-relay.next $DEVICE_DIR/crosvm.next && chmod 700 $DEVICE_DIR/openwrt.sh $DEVICE_DIR/ra6.next $DEVICE_DIR/kvm-probe.next $DEVICE_DIR/dhcp-relay.next $DEVICE_DIR/crosvm.next && mv -f $DEVICE_DIR/ra6.next $DEVICE_DIR/ra6 && mv -f $DEVICE_DIR/kvm-probe.next $DEVICE_DIR/kvm-probe && mv -f $DEVICE_DIR/dhcp-relay.next $DEVICE_DIR/dhcp-relay && mv -f $DEVICE_DIR/crosvm.next $DEVICE_DIR/crosvm && rm -f /data/local/tmp/openwrt.sh.new /data/local/tmp/ra6.new /data/local/tmp/kvm-probe.new /data/local/tmp/dhcp-relay.new /data/local/tmp/crosvm.new && sync'"
    verify_device_sha256 "$SCRIPT_DIR/device/openwrt.sh" "$DEVICE_DIR/openwrt.sh"
    verify_device_sha256 "$BUILD_DIR/tools/ra6" "$DEVICE_DIR/ra6"
    verify_device_sha256 "$BUILD_DIR/tools/kvm-probe" "$DEVICE_DIR/kvm-probe"
    verify_device_sha256 "$BUILD_DIR/tools/dhcp-relay" "$DEVICE_DIR/dhcp-relay"
    verify_device_sha256 "$BUNDLED_CROSVM" "$DEVICE_DIR/crosvm"
    sync_device_config
    device_manager preflight
    if [[ "$restart" == 1 ]]; then
        device_manager restart
        echo "设备管理器已更新，ImmortalWrt 已重启"
    else
        device_manager refresh-ipv6
        echo "设备管理器已更新；未请求重启"
    fi
}

sync_device_config() {
    validate_config
    check_device
    device_has_manager || die "ImmortalWrt 未安装；请先运行 install"
    mkdir -p "$BUILD_DIR"
    write_vm_config "$BUILD_DIR/vm.conf.sync"
    adb_cmd push "$(adb_path "$BUILD_DIR/vm.conf.sync")" /data/local/tmp/openwrt-vm.conf.new
    adb_cmd shell "su 0 sh -c 'chown root:root /data/local/tmp/openwrt-vm.conf.new && chmod 600 /data/local/tmp/openwrt-vm.conf.new && mv -f /data/local/tmp/openwrt-vm.conf.new $DEVICE_DIR/vm.conf && sync'"
    verify_device_sha256 "$BUILD_DIR/vm.conf.sync" "$DEVICE_DIR/vm.conf"
}

apply_config() {
    sync_device_config
    device_manager restart
    echo "配置已应用 (AUTO_TAKEOVER=$AUTO_TAKEOVER)"
}

require_install() {
    check_device
    device_has_manager || die "ImmortalWrt 未安装；请先运行 install"
}

read_vm_status() {
    local output rc=0
    if output="$(device_manager status | tr -d '\r')"; then
        :
    else
        rc=$?
    fi
    case "$output" in
        running*|stopped)
            printf '%s\n' "$output"
            return 0
            ;;
    esac
    echo "deploy-openwrt: 无法查询 VM 状态 (rc=$rc): ${output:-无状态返回}" >&2
    return 1
}

backup_vm() {
    (($# <= 1)) || die "用法: ./deploy-openwrt.sh backup [输出文件.img.gz]"
    check_device
    device_has_manager || die "ImmortalWrt 未安装；没有可备份的内容"
    device_has_image || die "设备管理器存在但 $DEVICE_DIR/openwrt.img 缺失"

    local serial_safe timestamp output output_dir output_name partial status kernel_sha256
    local was_running=0
    serial_safe="${ADB_SERIAL//[^A-Za-z0-9_.-]/_}"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    output="${1:-$SCRIPT_DIR/backups/openwrt-${serial_safe}-${timestamp}.img.gz}"
    output_dir="$(dirname -- "$output")"
    output_name="$(basename -- "$output")"
    partial="$output.part"
    mkdir -p -- "$output_dir"
    [[ ! -e "$output" && ! -e "$partial" && ! -e "$output.sha256" && ! -e "$output.info" ]] || \
        die "备份输出已存在: $output"
    command -v gzip >/dev/null 2>&1 || die "本地 gzip 是验证备份所必需的"
    adb_cmd shell "su 0 sh -c 'command -v gzip >/dev/null'" >/dev/null 2>&1 || \
        die "设备端 gzip 不可用"
    kernel_sha256="$(adb_cmd shell "su 0 sh -c 'sha256sum $DEVICE_DIR/Image'" | tr -d '\r' | awk '{print $1}')"
    [[ "$kernel_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || die "无法记录 VM 内核校验和"

    status="$(read_vm_status)" || die "备份前无法确定 VM 状态"
    case "$status" in
        running*)
            was_running=1
            say "正在停止 ImmortalWrt 以进行一致性磁盘备份"
            device_manager stop
            ;;
        stopped) ;;
        *) die "无法确定 VM 状态: $status" ;;
    esac

    # 如果传输或验证失败，仅删除不完整的本地文件，
    # 并将 VM 恢复到之前的运行状态。
    trap 'rm -f -- "${partial:-}"; if [[ "${was_running:-0}" == 1 ]]; then device_manager start >/dev/null 2>&1 || true; fi' EXIT

    local image_stats
    image_stats="$(adb_cmd shell "su 0 sh -c 'logical=\$(stat -c %s $DEVICE_DIR/openwrt.img) && blocks=\$(stat -c %b $DEVICE_DIR/openwrt.img) && echo logical_bytes=\$logical && echo allocated_bytes=\$((blocks * 512))'" | tr -d '\r')"
    say "正在将 VM 磁盘备份到 $output"
    adb_cmd exec-out "su 0 sh -c 'exec gzip -1 -c $DEVICE_DIR/openwrt.img'" > "$partial"
    [[ -s "$partial" ]] || die "设备返回了空备份"
    gzip -t -- "$partial" || die "备份 gzip 验证失败"
    mv -- "$partial" "$output"
    (
        cd -- "$output_dir"
        sha256sum -- "$output_name" > "$output_name.sha256"
    )
    printf 'adb_serial=%s\ncreated_at=%s\nopenwrt_version=%s\nkernel_sha256=%s\n%s\n' \
        "$ADB_SERIAL" "$(date --iso-8601=seconds)" "$OPENWRT_VERSION" "$kernel_sha256" \
        "$image_stats" > "$output.info"

    if [[ "$was_running" == 1 ]]; then
        say "正在重启 ImmortalWrt"
        device_manager start
        was_running=0
    fi
    trap - EXIT
    echo "VM 备份完成: $output ($(du -h "$output" | cut -f1))"
    echo "SHA-256: $output.sha256"
}

build_restore_helper() {
    local helper_description
    mkdir -p "$BUILD_DIR/tools"
    say "正在构建 Android ARM64 稀疏恢复辅助程序"
    aarch64-linux-gnu-gcc -O2 -static -s -Wall -Wextra \
        -o "$BUILD_DIR/tools/sparse-writer" "$SCRIPT_DIR/tools/sparse_writer.c"
    helper_description="$(file "$BUILD_DIR/tools/sparse-writer")" || \
        die "无法检查稀疏恢复辅助程序"
    echo "$helper_description"
    [[ "$helper_description" == *"ARM aarch64"* && "$helper_description" == *"statically linked"* ]] || \
        die "稀疏恢复辅助程序不是静态 ARM64 可执行文件"
    return 0
}

restore_vm() {
    (($# == 1)) || die "用法: ./deploy-openwrt.sh restore 备份文件.img.gz"
    local backup="$1" checksum_file="$1.sha256" info_file="$1.info"
    local expected_checksum actual_checksum expected_logical=0 expected_kernel=""
    local actual_kernel image_stats logical allocated status
    local was_running=0 old_saved=0 restore_complete=0
    local remote_backup="$RESTORE_STAGE/backup.img.gz"
    local remote_image="$RESTORE_STAGE/openwrt.img"
    local remote_helper="$RESTORE_STAGE/sparse-writer"
    local old_image="$DEVICE_DIR/openwrt.img.restore-old"

    [[ -f "$backup" ]] || die "备份不存在: $backup"
    [[ -f "$checksum_file" ]] || die "备份校验和缺失: $checksum_file"
    command -v gzip >/dev/null 2>&1 || die "本地 gzip 是必需的"
    gzip -t -- "$backup" || die "备份 gzip 验证失败"
    read -r expected_checksum _ < "$checksum_file" || true
    [[ "$expected_checksum" =~ ^[0-9a-fA-F]{64}$ ]] || die "无效的校验和文件: $checksum_file"
    expected_checksum="${expected_checksum,,}"
    actual_checksum="$(sha256sum -- "$backup" | awk '{print $1}')"
    [[ "$actual_checksum" == "$expected_checksum" ]] || \
        die "备份校验和不匹配 (期望 $expected_checksum, 实际 $actual_checksum)"
    if [[ -r "$info_file" ]]; then
        expected_logical="$(awk -F= '$1 == "logical_bytes" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$info_file")"
        : "${expected_logical:=0}"
        expected_kernel="$(awk -F= '$1 == "kernel_sha256" { print tolower($2); exit }' "$info_file")"
        [[ -z "$expected_kernel" || "$expected_kernel" =~ ^[0-9a-f]{64}$ ]] || \
            die "$info_file 中的内核校验和无效"
    fi

    check_device
    device_has_manager || die "ImmortalWrt VM shell 未安装；请先运行 install，然后再恢复"
    device_has_image || die "已安装的 VM 镜像缺失: $DEVICE_DIR/openwrt.img"
    if [[ -n "$expected_kernel" ]]; then
        actual_kernel="$(adb_cmd shell "su 0 sh -c 'sha256sum $DEVICE_DIR/Image'" | tr -d '\r' | awk '{print tolower($1)}')"
        [[ "$actual_kernel" == "$expected_kernel" ]] || \
            die "备份内核与已安装的 VM shell 不匹配；请先重新安装匹配的 ImmortalWrt 版本"
    else
        echo "deploy-openwrt: 旧版备份没有内核校验和；使用当前安装的内核" >&2
    fi
    adb_cmd shell "su 0 sh -c 'test ! -e $old_image'" >/dev/null 2>&1 || \
        die "之前的恢复镜像仍然存在: $old_image"
    install_dependencies
    build_restore_helper

    status="$(read_vm_status)" || \
        die "恢复前无法查询 VM 状态；请检查 ADB 连接"
    case "$status" in
        running*)
            was_running=1
            say "正在停止 ImmortalWrt 以进行镜像恢复"
            device_manager stop
            ;;
        stopped) ;;
        *) die "无法确定 VM 状态: $status" ;;
    esac

    restore_rollback() {
        local rc=$?
        set +e
        if [[ "$restore_complete" != 1 && "$old_saved" == 1 ]]; then
            device_manager stop >/dev/null 2>&1 || true
            adb_cmd shell "su 0 sh -c 'rm -f $DEVICE_DIR/openwrt.img && mv $old_image $DEVICE_DIR/openwrt.img && chmod 600 $DEVICE_DIR/openwrt.img && chown root:root $DEVICE_DIR/openwrt.img && sync'" >/dev/null 2>&1 || true
        fi
        adb_cmd shell "su 0 sh -c 'rm -rf -- $RESTORE_STAGE'" >/dev/null 2>&1 || true
        if [[ "$was_running" == 1 ]]; then
            device_manager start >/dev/null 2>&1 || true
        fi
        return "$rc"
    }
    trap restore_rollback EXIT

    say "正在上传并验证备份"
    # adb push 以 Android shell 用户身份运行，因此分阶段目录必须由该用户创建。
    # Root 仍然拥有上传后的文件，并在使用前执行最终的镜像替换。
    adb_cmd shell "su 0 sh -c 'rm -rf -- $RESTORE_STAGE'"
    adb_cmd shell "mkdir -p '$RESTORE_STAGE' && chmod 700 '$RESTORE_STAGE'"
    adb_cmd push "$(adb_path "$backup")" "$remote_backup"
    adb_cmd push "$(adb_path "$BUILD_DIR/tools/sparse-writer")" "$remote_helper"
    adb_cmd shell "su 0 sh -c 'chown root:root $remote_backup $remote_helper && chmod 600 $remote_backup && chmod 700 $remote_helper'"
    verify_device_sha256 "$backup" "$remote_backup"
    verify_device_sha256 "$BUILD_DIR/tools/sparse-writer" "$remote_helper"

    say "正在恢复稀疏 VM 镜像"
    adb_cmd shell "su 0 sh -c 'rm -f $remote_image && gzip -dc $remote_backup | $remote_helper $remote_image && chmod 600 $remote_image && chown root:root $remote_image && sync'"
    image_stats="$(adb_cmd shell "su 0 sh -c 'logical=\$(stat -c %s $remote_image) && blocks=\$(stat -c %b $remote_image) && echo logical=\$logical && echo allocated=\$((blocks * 512))'" | tr -d '\r')"
    logical="$(awk -F= '$1 == "logical" { print $2 }' <<<"$image_stats")"
    allocated="$(awk -F= '$1 == "allocated" { print $2 }' <<<"$image_stats")"
    [[ "$logical" =~ ^[0-9]+$ && "$allocated" =~ ^[0-9]+$ && "$logical" -ge 16777216 ]] || \
        die "恢复的镜像统计数据无效: $image_stats"
    if ((expected_logical > 0 && logical != expected_logical)); then
        die "恢复的逻辑大小不匹配 (期望 $expected_logical, 实际 $logical)"
    fi
    echo "logical=$logical allocated=$allocated"

    say "正在原子替换 VM 磁盘"
    adb_cmd shell "su 0 sh -c 'mv $DEVICE_DIR/openwrt.img $old_image && mv $remote_image $DEVICE_DIR/openwrt.img && chmod 600 $DEVICE_DIR/openwrt.img && chown root:root $DEVICE_DIR/openwrt.img && sync'"
    old_saved=1
    device_manager preflight
    if [[ "$was_running" == 1 ]]; then
        device_manager start
    fi
    adb_cmd shell "su 0 sh -c 'rm -f $old_image && rm -rf -- $RESTORE_STAGE && sync'"
    old_saved=0
    restore_complete=1
    trap - EXIT
    echo "VM 镜像已从以下备份恢复: $backup"
    echo "已恢复磁盘: logical=$logical allocated=$allocated"
}

show_help() {
    cat <<EOF
用法: ./deploy-openwrt.sh 命令

部署:
  install          构建并安装 ImmortalWrt，然后启动它
  backup [文件]    短暂停止并将当前 VM 磁盘保存为 .img.gz
  restore 文件     验证备份并恢复到已安装的 VM shell 中
  prepare          仅下载并准备本地镜像
  update           更新设备端工具并重启 ImmortalWrt
  update-script    更新设备端工具但不重启 ImmortalWrt
  uninstall        移除设备端 VM 和项目网络规则
  purge-local      删除本项目的本地缓存和构建输出

配置:
  show-config      显示当前生效的本地配置
  apply-config     上传 config.env 设置并重启 ImmortalWrt
  preflight        检查 crosvm、KVM、TUN/TAP、网桥和接口
  refresh-ipv6     撤销过期的回退 RA 并通告当前前缀

运行时:
  start | stop | restart | status
  logs [行数]      显示宿主机和客户机日志（默认: 200 行）
  ssh              连接到 ImmortalWrt (192.168.88.1)
  takeover         将 Android 应用 IPv4 路由到 ImmortalWrt
  untakeover       保持 Android/SIM/应用流量在 Android 上

当无法自动选择目标设备时，使用 ADB_SERIAL=序列号。
EOF
}

case "${1:-help}" in
    help|-h|--help) show_help ;;
    install|deploy) deploy ;;
    backup) shift; backup_vm "$@" ;;
    restore) shift; restore_vm "$@" ;;
    prepare) install_dependencies; download_image; prepare_image ;;
    update) update_manager 1 ;;
    update-script) update_manager 0 ;;
    apply-config) apply_config ;;
    show-config)
        validate_config
        printf 'CONFIG_FILE=%s\nOPENWRT_VERSION=%s\nOPENWRT_TARGET=%s\nDEVICE_MODEL=%s\nDISK_SIZE=%s\nTRANSFER_DISK_SIZE=%s\nVM_CPUS=%s\nVM_CPU_AFFINITY=%s\nVM_NET_QUEUES=%s\nVM_MEMORY_MIB=%s\nAUTO_TAKEOVER=%s\nIPV6_PASSTHROUGH=%s\nCROSVM_PATH=%s\nCELLULAR_IFACE=%s\nCELLULAR_ROUTE_TABLE=%s\nTETHER_IFACE_PATTERNS=%s\nTETHER_MODE=%s\nWAN_DNS1=%s\nWAN_DNS2=%s\n' \
            "$CONFIG_FILE" "$OPENWRT_VERSION" "$OPENWRT_TARGET" "$DEVICE_MODEL" "$DISK_SIZE" \
            "$TRANSFER_DISK_SIZE" "$VM_CPUS" "$VM_CPU_AFFINITY" "$VM_NET_QUEUES" "$VM_MEMORY_MIB" "$AUTO_TAKEOVER" "$IPV6_PASSTHROUGH" \
            "$CROSVM_PATH" "$CELLULAR_IFACE" "$CELLULAR_ROUTE_TABLE" "$TETHER_IFACE_PATTERNS" "$TETHER_MODE" \
            "$WAN_DNS1" "$WAN_DNS2"
        ;;
    preflight) require_install; device_manager preflight ;;
    refresh-ipv6) require_install; device_manager refresh-ipv6 ;;
    start) require_install; device_manager start ;;
    stop) require_install; device_manager stop ;;
    restart) require_install; device_manager restart ;;
    status) require_install; device_manager status ;;
    logs)
        [[ "${2:-200}" =~ ^[1-9][0-9]*$ ]] || die "日志行数必须为正整数"
        require_install
        device_manager logs "${2:-200}"
        ;;
    ssh) exec ssh root@192.168.88.1 ;;
    takeover) require_install; device_manager takeover ;;
    untakeover) require_install; device_manager untakeover ;;
    uninstall)
        check_device
        if device_has_manager; then
            # 损坏/全零的管理器仍然是可执行的，`sh file` 可能在不做任何事情的情况下
            # 成功退出。始终验证后置条件并在需要时回退到精确的项目目录清理。
            device_manager uninstall || true
            if adb_cmd shell "su 0 sh -c 'test ! -e $DEVICE_DIR'" >/dev/null 2>&1; then
                :
            else
                echo "deploy-openwrt: 设备管理器未移除 $DEVICE_DIR；正在使用恢复清理" >&2
                force_remove_device_vm
            fi
        elif device_has_image || adb_cmd shell "su 0 sh -c 'test -d $DEVICE_DIR'" >/dev/null 2>&1; then
            echo "deploy-openwrt: 设备管理器缺失；正在使用恢复清理" >&2
            force_remove_device_vm
        else
            echo "设备端 ImmortalWrt VM 已经不存在"
        fi
        adb_cmd shell "su 0 sh -c 'test ! -e $DEVICE_DIR'" >/dev/null 2>&1 || \
            die "无法移除 $DEVICE_DIR"
        echo "设备端 ImmortalWrt VM 已移除。下载缓存保留在 $CACHE_DIR"
        ;;
    purge-local)
        [[ "$CACHE_DIR" == "$SCRIPT_DIR/cache" && "$BUILD_DIR" == "$SCRIPT_DIR/build" ]] || die "不安全的本地路径"
        rm -rf -- "$CACHE_DIR" "$BUILD_DIR"
        echo "本地 ImmortalWrt 缓存/构建文件已删除"
        ;;
    *)
        echo "deploy-openwrt: 未知命令: $1" >&2
        show_help >&2
        exit 2
        ;;
esac
