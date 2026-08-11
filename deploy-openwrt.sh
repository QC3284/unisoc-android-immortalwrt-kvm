#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${OPENWRT_CONFIG:-$SCRIPT_DIR/config.env}"
if [[ -r "$CONFIG_FILE" ]]; then
    # This is a trusted shell-style project configuration file. Environment
    # variables can override its defaults because config.env uses ${VAR:-...}.
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
else
    echo "deploy-openwrt: missing configuration file: $CONFIG_FILE" >&2
    exit 1
fi
CACHE_DIR="$SCRIPT_DIR/cache"
BUILD_DIR="$SCRIPT_DIR/build"
BUNDLED_CROSVM="$SCRIPT_DIR/assets/crosvm/android13/crosvm"
DEVICE_DIR=/data/local/openwrt
STAGE_DIR=/data/local/tmp/openwrt-deploy
RESTORE_STAGE=/data/local/tmp/openwrt-restore
if [[ -z "${ADB_BIN:-}" ]]; then
    # Pick the executable independently of device count. `adb get-state`
    # returns an error when several devices are present, which must not be
    # mistaken for a missing adb installation.
    for adb_candidate in adb.exe adb; do
        command -v "$adb_candidate" >/dev/null 2>&1 || continue
        ADB_BIN="$(command -v "$adb_candidate")"
        break
    done
    : "${ADB_BIN:=adb}"
fi
OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.5}"
OPENWRT_TARGET="${OPENWRT_TARGET:-armsr/armv8}"
OPENWRT_PASSWORD="${OPENWRT_PASSWORD:-openwrt}"
DEVICE_MODEL="${DEVICE_MODEL:-auto}"
RESOLVED_DEVICE_MODEL=""
DISK_SIZE="${DISK_SIZE:-8G}"
# The official ext4 image is about 104 MiB. Keep only a small safety margin
# for first-boot package metadata; Android extends it sparsely to DISK_SIZE
# after upload and OpenWrt grows ext4 online.
TRANSFER_DISK_SIZE="${TRANSFER_DISK_SIZE:-128M}"
VM_CPUS="${VM_CPUS:-4}"
VM_CPU_AFFINITY="${VM_CPU_AFFINITY:-auto}"
VM_MEMORY_MIB="${VM_MEMORY_MIB:-1024}"
AUTO_TAKEOVER="${AUTO_TAKEOVER:-0}"
IPV6_PASSTHROUGH="${IPV6_PASSTHROUGH:-1}"
CROSVM_PATH="${CROSVM_PATH:-auto}"
CELLULAR_IFACE="${CELLULAR_IFACE:-auto}"
CELLULAR_ROUTE_TABLE="${CELLULAR_ROUTE_TABLE:-auto}"
TETHER_IFACE_PATTERNS="${TETHER_IFACE_PATTERNS:-auto}"
TETHER_MODE="${TETHER_MODE:-auto}"
BASE_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/$OPENWRT_TARGET"
TARGET_BASENAME="${OPENWRT_TARGET//\//-}"
KERNEL_NAME="openwrt-$OPENWRT_VERSION-$TARGET_BASENAME-generic-kernel.bin"
ROOTFS_NAME="openwrt-$OPENWRT_VERSION-$TARGET_BASENAME-generic-ext4-rootfs.img.gz"
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
        # Do not turn a user's Ctrl-C/termination into a root or device error.
        case "$rc" in 130|143) return "$rc" ;; esac
    done
    return "$rc"
}

# adb.exe (Windows) cannot read WSL paths; convert them when needed.
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
            echo "deploy-openwrt: ADB control command timed out after ${ADB_CONTROL_TIMEOUT_SECONDS}s: $args" >&2
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
    # This path is used only after an explicit uninstall request when the
    # device-side manager is missing or damaged.  A zero-filled executable can
    # still return success when interpreted by sh, so command status alone is
    # not sufficient evidence that uninstall actually happened.
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
        die "target already contains $DEVICE_DIR/openwrt.img; run 'backup' first and 'uninstall' only when you intend to replace it"
    fi
}

select_device() {
    [[ -n "${ADB_SERIAL:-}" ]] && return 0

    local devices=() installed=() serial device_list
    device_list="$(adb_probe_cmd devices)" || die "ADB device listing failed or timed out"
    mapfile -t devices < <(printf '%s\n' "$device_list" | tr -d '\r' | \
        awk 'NR > 1 && $2 == "device" { print $1 }')
    case "${#devices[@]}" in
        0) die "no online ADB device found" ;;
        1) ADB_SERIAL="${devices[0]}"; return 0 ;;
    esac

    # Management commands can safely identify the unique device that already
    # contains this project's manager. Fresh installs still require an
    # explicit serial because choosing the target by guess would be unsafe.
    for serial in "${devices[@]}"; do
        if adb_timed_cmd "$ADB_PROBE_TIMEOUT_SECONDS" -s "$serial" shell \
                "su 0 sh -c 'test -x $DEVICE_DIR/openwrt.sh'" >/dev/null 2>&1; then
            installed+=("$serial")
        fi
    done
    if ((${#installed[@]} == 1)); then
        ADB_SERIAL="${installed[0]}"
        echo "deploy-openwrt: auto-selected installed device $ADB_SERIAL" >&2
        return 0
    fi
    die "multiple ADB devices are online (${devices[*]}); set ADB_SERIAL in config.env or the environment"
}

check_device() {
    local rc
    command -v "$ADB_BIN" >/dev/null 2>&1 || die "$ADB_BIN not found"
    select_device
    adb_probe_cmd get-state >/dev/null || {
        rc=$?
        case "$rc" in 130|143) return "$rc" ;; esac
        die "ADB device probe failed or timed out"
    }
    adb_probe_cmd shell "su 0 sh -c 'exit 0'" >/dev/null 2>&1 || {
        rc=$?
        case "$rc" in 130|143) return "$rc" ;; esac
        [[ "$rc" == 124 ]] && die "ADB root probe timed out"
        die "root shell is unavailable (KernelSU/Magisk permission required)"
    }
}

read_device_property() {
    adb_cmd shell "getprop $1" 2>/dev/null | tr -d '\r\n'
}

validate_device_model() {
    local model="$1"
    [[ -n "$model" ]] || die "DEVICE_MODEL resolved to an empty value"
    [[ "$model" != *"'"* && "$model" != *$'\n'* && "$model" != *$'\r'* ]] || \
        die "DEVICE_MODEL cannot contain quotes or newlines"
    ((${#model} <= 120)) || die "DEVICE_MODEL is too long (maximum 120 characters)"
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
    echo "deploy-openwrt: detected device model: $RESOLVED_DEVICE_MODEL" >&2
}

validate_config() {
    [[ "$AUTO_TAKEOVER" == 0 || "$AUTO_TAKEOVER" == 1 ]] || \
        die "AUTO_TAKEOVER must be 0 or 1"
    [[ "$IPV6_PASSTHROUGH" == 0 || "$IPV6_PASSTHROUGH" == 1 ]] || \
        die "IPV6_PASSTHROUGH must be 0 or 1"
    [[ "$DEVICE_MODEL" == auto ]] || validate_device_model "$DEVICE_MODEL"
    [[ "$VM_CPUS" =~ ^[1-9][0-9]*$ ]] || die "VM_CPUS must be a positive integer"
    [[ "$VM_CPU_AFFINITY" == auto || "$VM_CPU_AFFINITY" == none || \
       "$VM_CPU_AFFINITY" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ || \
       "$VM_CPU_AFFINITY" =~ ^[0-9]+=[0-9]+(:[0-9]+=[0-9]+)*$ ]] || \
        die "VM_CPU_AFFINITY must be auto, none, a CPU set, or a guest=host mapping"
    [[ "$VM_MEMORY_MIB" =~ ^[1-9][0-9]*$ ]] || die "VM_MEMORY_MIB must be a positive integer"
    [[ "$CROSVM_PATH" == auto || "$CROSVM_PATH" == bundled || "$CROSVM_PATH" == /* ]] || \
        die "CROSVM_PATH must be auto, bundled, or an absolute device path"
    [[ "$CROSVM_PATH" =~ ^[A-Za-z0-9_./-]+$ ]] || die "invalid CROSVM_PATH"
    [[ "$CELLULAR_IFACE" =~ ^(auto|[A-Za-z0-9_.-]+)$ ]] || die "invalid CELLULAR_IFACE"
    [[ "$CELLULAR_ROUTE_TABLE" =~ ^(auto|[A-Za-z0-9_.-]+)$ ]] || die "invalid CELLULAR_ROUTE_TABLE"
    [[ -n "$TETHER_IFACE_PATTERNS" && "$TETHER_IFACE_PATTERNS" =~ ^[A-Za-z0-9_.*?+-]+([[:space:]]+[A-Za-z0-9_.*?+-]+)*$ ]] || \
        die "invalid TETHER_IFACE_PATTERNS"
    [[ "$TETHER_MODE" == auto || "$TETHER_MODE" == bridge || "$TETHER_MODE" == routed || "$TETHER_MODE" == proxyarp || "$TETHER_MODE" == directbr0 ]] || \
        die "TETHER_MODE must be auto, bridge, routed, proxyarp, or directbr0"
}

install_dependencies() {
    local missing=()
    for cmd in curl gzip e2fsck resize2fs virt-copy-in virt-copy-out sha256sum openssl file aarch64-linux-gnu-gcc; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return
    say "Installing WSL dependencies: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y curl gzip e2fsprogs libguestfs-tools openssl file gcc-aarch64-linux-gnu
}

build_tools() {
    mkdir -p "$BUILD_DIR/tools"
    say "Building Android ARM64 IPv6 RA helper"
    aarch64-linux-gnu-gcc -O2 -static -s -Wall -Wextra \
        -o "$BUILD_DIR/tools/ra6" "$SCRIPT_DIR/tools/ra6.c"
    file "$BUILD_DIR/tools/ra6"
    say "Building Android ARM64 KVM/vGIC preflight helper"
    aarch64-linux-gnu-gcc -O2 -static -s -Wall -Wextra \
        -o "$BUILD_DIR/tools/kvm-probe" "$SCRIPT_DIR/tools/kvm_probe.c"
    file "$BUILD_DIR/tools/kvm-probe"
    say "Building Android ARM64 DHCP frame relay"
    aarch64-linux-gnu-gcc -O2 -static -s -Wall -Wextra \
        -o "$BUILD_DIR/tools/dhcp-relay" "$SCRIPT_DIR/tools/dhcp_relay.c"
    file "$BUILD_DIR/tools/dhcp-relay"
    [[ -x "$BUNDLED_CROSVM" ]] || die "missing bundled crosvm: $BUNDLED_CROSVM"
    file "$BUNDLED_CROSVM" | grep -q 'ARM aarch64.*statically linked' || \
        die "bundled crosvm is not a static ARM64 executable"
}

write_vm_config() {
    local output="$1"
    cat > "$output" <<EOF
ROOT_DEVICE='/dev/vda'
VM_CPUS='$VM_CPUS'
VM_CPU_AFFINITY='$VM_CPU_AFFINITY'
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
        die "device file verification failed: $remote_file (expected $expected, got ${actual:-no hash})"
}

download_image() {
    mkdir -p "$CACHE_DIR"
    for f in "$KERNEL_NAME" "$ROOTFS_NAME" sha256sums; do
        if [[ ! -s "$CACHE_DIR/$f" ]]; then
            say "Downloading $f"
            curl -fL --retry 3 -o "$CACHE_DIR/$f.part" "$BASE_URL/$f"
            mv "$CACHE_DIR/$f.part" "$CACHE_DIR/$f"
        fi
    done
    say "Verifying OpenWrt SHA-256 checksums"
    (cd "$CACHE_DIR" && sha256sum -c --ignore-missing sha256sums 2>&1 | grep -Ei "OK|FAILED") || true
    (cd "$CACHE_DIR" && sha256sum -c --ignore-missing sha256sums) >/dev/null || die "checksum mismatch"
}

prepare_image() {
    validate_config
    [[ "$DISK_SIZE" =~ ^[1-9][0-9]*[KMG]$ ]] || die "invalid DISK_SIZE: $DISK_SIZE"
    [[ "$TRANSFER_DISK_SIZE" =~ ^[1-9][0-9]*[KMG]$ ]] || die "invalid TRANSFER_DISK_SIZE: $TRANSFER_DISK_SIZE"
    [[ "$BUILD_DIR" == "$SCRIPT_DIR/build" ]] || die "unsafe BUILD_DIR: $BUILD_DIR"
    rm -rf -- "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    export LIBGUESTFS_BACKEND=direct

    say "Unpacking rootfs"
    gzip -dc "$CACHE_DIR/$ROOTFS_NAME" > "$BUILD_DIR/openwrt.img"

    # Bake /etc/config/network. OpenWrt's /bin/config_generate only creates it
    # when missing, so our static WAN/LAN setup survives first boot.
    # eth0 = first crosvm tap (owrt-wan, WAN side), eth1 = second tap (owrt-lan).
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

config interface 'wan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '$WAN_GUEST_IP'
	option netmask '255.255.255.0'
	option gateway '$WAN_HOST_IP'
	list dns '$WAN_DNS1'
	list dns '$WAN_DNS2'
EOF
    say "Baking network config into rootfs"
    virt-copy-in -a "$BUILD_DIR/openwrt.img" "$BUILD_DIR/network" /etc/config/

    # crosvm's ARM platform has no device-tree model. Publish the physical
    # device/SoC name so ubus and LuCI do not show the model as "?".
    local image_model="${RESOLVED_DEVICE_MODEL:-$DEVICE_MODEL}"
    [[ "$image_model" == auto ]] && image_model="Generic Android ARM64 Host"
    validate_device_model "$image_model"
    local escaped_model="$image_model"
    escaped_model="${escaped_model//\\/\\\\}"
    escaped_model="${escaped_model//&/\\&}"
    escaped_model="${escaped_model//|/\\|}"
    sed "s|@DEVICE_MODEL@|$escaped_model|g" \
        "$SCRIPT_DIR/device/rc.local" > "$BUILD_DIR/rc.local"
    say "Baking hardware model into rootfs: $image_model"
    virt-copy-in -a "$BUILD_DIR/openwrt.img" "$BUILD_DIR/rc.local" /etc/

    say "Setting root password"
    hash="$(openssl passwd -6 "$OPENWRT_PASSWORD")"
    virt-copy-out -a "$BUILD_DIR/openwrt.img" /etc/shadow "$BUILD_DIR/"
    sed -i "s|^root:[^:]*:|root:$hash:|" "$BUILD_DIR/shadow"
    virt-copy-in -a "$BUILD_DIR/openwrt.img" "$BUILD_DIR/shadow" /etc/

    say "Growing transfer image to $TRANSFER_DISK_SIZE"
    # Run twice: the first pass fixes the factory image, the second clears the
    # needs-fsck flag so resize2fs does not try to run e2fsck interactively.
    # e2fsck returns 1 when it corrected errors, which is fine here.
    for pass in 1 2; do
        local rc=0
        e2fsck -fy "$BUILD_DIR/openwrt.img" || rc=$?
        ((rc <= 1)) || die "e2fsck failed with rc=$rc"
    done
    truncate -s "$TRANSFER_DISK_SIZE" "$BUILD_DIR/openwrt.img"
    resize2fs "$BUILD_DIR/openwrt.img"

    cp "$CACHE_DIR/$KERNEL_NAME" "$BUILD_DIR/Image"
    file "$BUILD_DIR/Image"

    # Sanity-check the baked files are readable and contain our settings.
    rm -rf "$BUILD_DIR/check" "$BUILD_DIR/check2"
    mkdir -p "$BUILD_DIR/check" "$BUILD_DIR/check2"
    virt-copy-out -a "$BUILD_DIR/openwrt.img" /etc/config/network "$BUILD_DIR/check"
    grep -q "$WAN_GUEST_IP" "$BUILD_DIR/check/network" || die "network config not baked"
    virt-copy-out -a "$BUILD_DIR/openwrt.img" /etc/shadow "$BUILD_DIR/check2"
    grep -q "^root:\\\$6\\\$" "$BUILD_DIR/check2/shadow" || die "root password not baked"
    rm -rf "$BUILD_DIR/check3"
    mkdir -p "$BUILD_DIR/check3"
    virt-copy-out -a "$BUILD_DIR/openwrt.img" /etc/rc.local "$BUILD_DIR/check3"
    grep -Fq "$image_model" "$BUILD_DIR/check3/rc.local" || die "hardware model not baked"
    grep -q "resize2fs /dev/vda" "$BUILD_DIR/check3/rc.local" || die "online rootfs growth not baked"

    write_vm_config "$BUILD_DIR/vm.conf"
    build_tools
    say "Image prepared: $BUILD_DIR/openwrt.img ($(du -h "$BUILD_DIR/openwrt.img" | cut -f1) logical)"
}

deploy() {
    check_device
    # Refuse before doing downloads/build work, then check again immediately
    # before the staged image is moved into place.  `install` must never be an
    # implicit reinstall operation because the guest disk contains user data.
    refuse_existing_image
    resolve_device_model
    install_dependencies
    download_image
    prepare_image

    say "Uploading OpenWrt VM staging files"
    adb_cmd shell "rm -rf $STAGE_DIR && mkdir -p $STAGE_DIR"
    adb_cmd push "$(adb_path "$BUILD_DIR/openwrt.img")" "$STAGE_DIR/openwrt.img"
    verify_device_sha256 "$BUILD_DIR/openwrt.img" "$STAGE_DIR/openwrt.img"
    say "Sparsely extending image to $DISK_SIZE"
    local sparse_stats logical blocks allocated
    sparse_stats="$(adb_cmd shell "su 0 sh -c 'command -v truncate >/dev/null && truncate -s $DISK_SIZE $STAGE_DIR/openwrt.img && echo logical=\$(stat -c %s $STAGE_DIR/openwrt.img) && echo blocks=\$(stat -c %b $STAGE_DIR/openwrt.img)'" | tr -d '\r')" || \
        die "failed to extend or inspect the Android image"
    logical="$(awk -F= '$1 == "logical" { print $2 }' <<<"$sparse_stats")"
    blocks="$(awk -F= '$1 == "blocks" { print $2 }' <<<"$sparse_stats")"
    [[ "$logical" =~ ^[0-9]+$ && "$blocks" =~ ^[0-9]+$ ]] || \
        die "invalid sparse image statistics returned by Android: $sparse_stats"
    # Perform this comparison in host Bash. Android 13 Toybox `test` can
    # reject or miscompare logical sizes above its integer range (8 GiB here).
    allocated=$((blocks * 512))
    echo "logical=$logical allocated=$allocated"
    ((allocated < logical)) || die "Android storage does not support the required sparse image"
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

OpenWrt is booting. First boot takes 30-60s.
SSH:      ssh root@192.168.88.1           (from a managed USB/hotspot client)
Web:      http://192.168.88.1             (LuCI from the OpenWrt LAN)
Password: $OPENWRT_PASSWORD
Topology: WAN 192.168.66.2 <-> host 192.168.66.1 (NAT out)
          LAN 192.168.88.1 <-> owrt-br 192.168.88.2 (DHCP 100-249)
          USB/WiFi use TETHER_MODE=$TETHER_MODE (auto is resolved on-device)
Takeover: AUTO_TAKEOVER=$AUTO_TAKEOVER (configured in config.env)
IPv6:     IPV6_PASSTHROUGH=$IPV6_PASSTHROUGH (0=OpenWrt managed, 1=Android passthrough)
Status:   ./deploy-openwrt.sh status
Logs:     ./deploy-openwrt.sh logs
Remove:   ./deploy-openwrt.sh uninstall
EOF
}

update_manager() {
    local restart="${1:-1}"
    install_dependencies
    check_device
    device_has_manager || die "OpenWrt is not installed; run install first"
    build_tools
    say "Uploading device manager only"
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
        echo "Device manager updated and OpenWrt restarted"
    else
        device_manager refresh-ipv6
        echo "Device manager updated; restart was not requested"
    fi
}

sync_device_config() {
    validate_config
    check_device
    device_has_manager || die "OpenWrt is not installed; run install first"
    mkdir -p "$BUILD_DIR"
    write_vm_config "$BUILD_DIR/vm.conf.sync"
    adb_cmd push "$(adb_path "$BUILD_DIR/vm.conf.sync")" /data/local/tmp/openwrt-vm.conf.new
    adb_cmd shell "su 0 sh -c 'chown root:root /data/local/tmp/openwrt-vm.conf.new && chmod 600 /data/local/tmp/openwrt-vm.conf.new && mv -f /data/local/tmp/openwrt-vm.conf.new $DEVICE_DIR/vm.conf && sync'"
    verify_device_sha256 "$BUILD_DIR/vm.conf.sync" "$DEVICE_DIR/vm.conf"
}

apply_config() {
    sync_device_config
    device_manager restart
    echo "Configuration applied (AUTO_TAKEOVER=$AUTO_TAKEOVER)"
}

require_install() {
    check_device
    device_has_manager || die "OpenWrt is not installed; run install first"
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
    echo "deploy-openwrt: cannot query VM state (rc=$rc): ${output:-no status returned}" >&2
    return 1
}

backup_vm() {
    (($# <= 1)) || die "usage: ./deploy-openwrt.sh backup [OUTPUT.img.gz]"
    check_device
    device_has_manager || die "OpenWrt is not installed; nothing to back up"
    device_has_image || die "device manager exists but $DEVICE_DIR/openwrt.img is missing"

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
        die "backup output already exists: $output"
    command -v gzip >/dev/null 2>&1 || die "local gzip is required to verify the backup"
    adb_cmd shell "su 0 sh -c 'command -v gzip >/dev/null'" >/dev/null 2>&1 || \
        die "device gzip is unavailable"
    kernel_sha256="$(adb_cmd shell "su 0 sh -c 'sha256sum $DEVICE_DIR/Image'" | tr -d '\r' | awk '{print $1}')"
    [[ "$kernel_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || die "cannot record VM kernel checksum"

    status="$(read_vm_status)" || die "cannot determine VM state before backup"
    case "$status" in
        running*)
            was_running=1
            say "Stopping OpenWrt for a consistent disk backup"
            device_manager stop
            ;;
        stopped) ;;
        *) die "cannot determine VM state: $status" ;;
    esac

    # If transfer or verification fails, remove only the incomplete local file
    # and restore the VM to its previous running state.
    trap 'rm -f -- "${partial:-}"; if [[ "${was_running:-0}" == 1 ]]; then device_manager start >/dev/null 2>&1 || true; fi' EXIT

    local image_stats
    image_stats="$(adb_cmd shell "su 0 sh -c 'logical=\$(stat -c %s $DEVICE_DIR/openwrt.img) && blocks=\$(stat -c %b $DEVICE_DIR/openwrt.img) && echo logical_bytes=\$logical && echo allocated_bytes=\$((blocks * 512))'" | tr -d '\r')"
    say "Backing up the VM disk to $output"
    adb_cmd exec-out "su 0 sh -c 'exec gzip -1 -c $DEVICE_DIR/openwrt.img'" > "$partial"
    [[ -s "$partial" ]] || die "device returned an empty backup"
    gzip -t -- "$partial" || die "backup gzip verification failed"
    mv -- "$partial" "$output"
    (
        cd -- "$output_dir"
        sha256sum -- "$output_name" > "$output_name.sha256"
    )
    printf 'adb_serial=%s\ncreated_at=%s\nopenwrt_version=%s\nkernel_sha256=%s\n%s\n' \
        "$ADB_SERIAL" "$(date --iso-8601=seconds)" "$OPENWRT_VERSION" "$kernel_sha256" \
        "$image_stats" > "$output.info"

    if [[ "$was_running" == 1 ]]; then
        say "Restarting OpenWrt"
        device_manager start
        was_running=0
    fi
    trap - EXIT
    echo "VM backup completed: $output ($(du -h "$output" | cut -f1))"
    echo "SHA-256: $output.sha256"
}

build_restore_helper() {
    local helper_description
    mkdir -p "$BUILD_DIR/tools"
    say "Building Android ARM64 sparse restore helper"
    aarch64-linux-gnu-gcc -O2 -static -s -Wall -Wextra \
        -o "$BUILD_DIR/tools/sparse-writer" "$SCRIPT_DIR/tools/sparse_writer.c"
    helper_description="$(file "$BUILD_DIR/tools/sparse-writer")" || \
        die "cannot inspect sparse restore helper"
    echo "$helper_description"
    [[ "$helper_description" == *"ARM aarch64"* && "$helper_description" == *"statically linked"* ]] || \
        die "sparse restore helper is not a static ARM64 executable"
    return 0
}

restore_vm() {
    (($# == 1)) || die "usage: ./deploy-openwrt.sh restore BACKUP.img.gz"
    local backup="$1" checksum_file="$1.sha256" info_file="$1.info"
    local expected_checksum actual_checksum expected_logical=0 expected_kernel=""
    local actual_kernel image_stats logical allocated status
    local was_running=0 old_saved=0 restore_complete=0
    local remote_backup="$RESTORE_STAGE/backup.img.gz"
    local remote_image="$RESTORE_STAGE/openwrt.img"
    local remote_helper="$RESTORE_STAGE/sparse-writer"
    local old_image="$DEVICE_DIR/openwrt.img.restore-old"

    [[ -f "$backup" ]] || die "backup does not exist: $backup"
    [[ -f "$checksum_file" ]] || die "backup checksum is missing: $checksum_file"
    command -v gzip >/dev/null 2>&1 || die "local gzip is required"
    gzip -t -- "$backup" || die "backup gzip verification failed"
    read -r expected_checksum _ < "$checksum_file" || true
    [[ "$expected_checksum" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid checksum file: $checksum_file"
    expected_checksum="${expected_checksum,,}"
    actual_checksum="$(sha256sum -- "$backup" | awk '{print $1}')"
    [[ "$actual_checksum" == "$expected_checksum" ]] || \
        die "backup checksum mismatch (expected $expected_checksum, got $actual_checksum)"
    if [[ -r "$info_file" ]]; then
        expected_logical="$(awk -F= '$1 == "logical_bytes" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$info_file")"
        : "${expected_logical:=0}"
        expected_kernel="$(awk -F= '$1 == "kernel_sha256" { print tolower($2); exit }' "$info_file")"
        [[ -z "$expected_kernel" || "$expected_kernel" =~ ^[0-9a-f]{64}$ ]] || \
            die "invalid kernel checksum in $info_file"
    fi

    check_device
    device_has_manager || die "OpenWrt VM shell is not installed; run install first, then restore"
    device_has_image || die "installed VM image is missing: $DEVICE_DIR/openwrt.img"
    if [[ -n "$expected_kernel" ]]; then
        actual_kernel="$(adb_cmd shell "su 0 sh -c 'sha256sum $DEVICE_DIR/Image'" | tr -d '\r' | awk '{print tolower($1)}')"
        [[ "$actual_kernel" == "$expected_kernel" ]] || \
            die "backup kernel does not match the installed VM shell; reinstall the matching OpenWrt version first"
    else
        echo "deploy-openwrt: legacy backup has no kernel checksum; using the currently installed kernel" >&2
    fi
    adb_cmd shell "su 0 sh -c 'test ! -e $old_image'" >/dev/null 2>&1 || \
        die "a previous recovery image still exists: $old_image"
    install_dependencies
    build_restore_helper

    status="$(read_vm_status)" || \
        die "cannot query VM state before restore; check the ADB connection"
    case "$status" in
        running*)
            was_running=1
            say "Stopping OpenWrt for image restore"
            device_manager stop
            ;;
        stopped) ;;
        *) die "cannot determine VM state: $status" ;;
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

    say "Uploading and verifying backup"
    # adb push runs as Android's shell user, so the staging directory must be
    # created by that user.  Root still owns the uploaded files before they are
    # consumed and performs the final image replacement.
    adb_cmd shell "su 0 sh -c 'rm -rf -- $RESTORE_STAGE'"
    adb_cmd shell "mkdir -p '$RESTORE_STAGE' && chmod 700 '$RESTORE_STAGE'"
    adb_cmd push "$(adb_path "$backup")" "$remote_backup"
    adb_cmd push "$(adb_path "$BUILD_DIR/tools/sparse-writer")" "$remote_helper"
    adb_cmd shell "su 0 sh -c 'chown root:root $remote_backup $remote_helper && chmod 600 $remote_backup && chmod 700 $remote_helper'"
    verify_device_sha256 "$backup" "$remote_backup"
    verify_device_sha256 "$BUILD_DIR/tools/sparse-writer" "$remote_helper"

    say "Restoring sparse VM image"
    adb_cmd shell "su 0 sh -c 'rm -f $remote_image && gzip -dc $remote_backup | $remote_helper $remote_image && chmod 600 $remote_image && chown root:root $remote_image && sync'"
    image_stats="$(adb_cmd shell "su 0 sh -c 'logical=\$(stat -c %s $remote_image) && blocks=\$(stat -c %b $remote_image) && echo logical=\$logical && echo allocated=\$((blocks * 512))'" | tr -d '\r')"
    logical="$(awk -F= '$1 == "logical" { print $2 }' <<<"$image_stats")"
    allocated="$(awk -F= '$1 == "allocated" { print $2 }' <<<"$image_stats")"
    [[ "$logical" =~ ^[0-9]+$ && "$allocated" =~ ^[0-9]+$ && "$logical" -ge 16777216 ]] || \
        die "restored image has invalid statistics: $image_stats"
    if ((expected_logical > 0 && logical != expected_logical)); then
        die "restored logical size mismatch (expected $expected_logical, got $logical)"
    fi
    echo "logical=$logical allocated=$allocated"

    say "Atomically replacing the VM disk"
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
    echo "VM image restored from: $backup"
    echo "Restored disk: logical=$logical allocated=$allocated"
}

show_help() {
    cat <<EOF
Usage: ./deploy-openwrt.sh COMMAND

Deployment:
  install          Build and install OpenWrt, then start it
  backup [FILE]    Stop briefly and save the current VM disk as .img.gz
  restore FILE     Verify and restore a backup into an installed VM shell
  prepare          Download and prepare the local image only
  update           Update device tools and restart OpenWrt
  update-script    Update device tools without restarting OpenWrt
  uninstall        Remove the device-side VM and project network rules
  purge-local      Remove this project's local cache and build output

Configuration:
  show-config      Show the effective local configuration
  apply-config     Upload config.env settings and restart OpenWrt
  preflight        Check crosvm, KVM, TUN/TAP, bridge and interfaces
  refresh-ipv6     Withdraw stale fallback RA and advertise current prefix

Runtime:
  start | stop | restart | status
  logs [LINES]     Show host and guest logs (default: 200 lines)
  ssh              Connect to OpenWrt at 192.168.88.1
  takeover         Route Android application IPv4 through OpenWrt
  untakeover       Keep Android/SIM/application traffic on Android

Use ADB_SERIAL=SERIAL when the target cannot be selected automatically.
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
        printf 'CONFIG_FILE=%s\nOPENWRT_VERSION=%s\nOPENWRT_TARGET=%s\nDEVICE_MODEL=%s\nDISK_SIZE=%s\nTRANSFER_DISK_SIZE=%s\nVM_CPUS=%s\nVM_CPU_AFFINITY=%s\nVM_MEMORY_MIB=%s\nAUTO_TAKEOVER=%s\nIPV6_PASSTHROUGH=%s\nCROSVM_PATH=%s\nCELLULAR_IFACE=%s\nCELLULAR_ROUTE_TABLE=%s\nTETHER_IFACE_PATTERNS=%s\nTETHER_MODE=%s\nWAN_DNS1=%s\nWAN_DNS2=%s\n' \
            "$CONFIG_FILE" "$OPENWRT_VERSION" "$OPENWRT_TARGET" "$DEVICE_MODEL" "$DISK_SIZE" \
            "$TRANSFER_DISK_SIZE" "$VM_CPUS" "$VM_CPU_AFFINITY" "$VM_MEMORY_MIB" "$AUTO_TAKEOVER" "$IPV6_PASSTHROUGH" \
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
        [[ "${2:-200}" =~ ^[1-9][0-9]*$ ]] || die "log line count must be a positive integer"
        require_install
        device_manager logs "${2:-200}"
        ;;
    ssh) exec ssh root@192.168.88.1 ;;
    takeover) require_install; device_manager takeover ;;
    untakeover) require_install; device_manager untakeover ;;
    uninstall)
        check_device
        if device_has_manager; then
            # A damaged/all-zero manager is still executable and `sh file`
            # exits successfully without doing anything. Always verify the
            # postcondition and fall back to the exact project directory.
            device_manager uninstall || true
            if adb_cmd shell "su 0 sh -c 'test ! -e $DEVICE_DIR'" >/dev/null 2>&1; then
                :
            else
                echo "deploy-openwrt: device manager did not remove $DEVICE_DIR; using recovery cleanup" >&2
                force_remove_device_vm
            fi
        elif device_has_image || adb_cmd shell "su 0 sh -c 'test -d $DEVICE_DIR'" >/dev/null 2>&1; then
            echo "deploy-openwrt: device manager is missing; using recovery cleanup" >&2
            force_remove_device_vm
        else
            echo "Device-side OpenWrt VM is already absent"
        fi
        adb_cmd shell "su 0 sh -c 'test ! -e $DEVICE_DIR'" >/dev/null 2>&1 || \
            die "failed to remove $DEVICE_DIR"
        echo "Device-side OpenWrt VM was removed. Download cache remains in $CACHE_DIR"
        ;;
    purge-local)
        [[ "$CACHE_DIR" == "$SCRIPT_DIR/cache" && "$BUILD_DIR" == "$SCRIPT_DIR/build" ]] || die "unsafe local paths"
        rm -rf -- "$CACHE_DIR" "$BUILD_DIR"
        echo "Local OpenWrt cache/build files removed"
        ;;
    *)
        echo "deploy-openwrt: unknown command: $1" >&2
        show_help >&2
        exit 2
        ;;
esac
