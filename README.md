# ImmortalWrt VM for W210DS / Android 13 ARM64

> 由 DeepSeek-V4-Pro 修改：已替换为 ImmortalWrt + 国内 USTC 镜像源，速度更快。

在已 Root、具备 KVM/TUN 的 ARM64 Android 设备上，通过 `crosvm` 运行 ImmortalWrt。
主分支面向 W210DS，并使用其系统 crosvm；MU300/F50 的安全路由方案位于
`mu300-routed` 分支。
本项目完全独立于 Debian VM，不会读写 Debian 的镜像、缓存或设备目录。

## 当前功能

- ImmortalWrt 25.12.1、Linux 6.12 ARM64
- 6 vCPU、1 GiB 内存（均可配置）
- 8 GiB 稀疏虚拟磁盘；初次只传输 128 MiB，设备端按需占用空间
- 安装时自动读取 Android 厂商、型号、设备名和 SoC，LuCI 不再显示未知型号
- Android 本机、SIM/APN 和应用流量保持由 Android 管理，不经 ImmortalWrt
- USB 共享和 Wi-Fi 热点作为二层端口动态加入 `owrt-br`
- 热点客户端直接从 ImmortalWrt DHCP 获取 `192.168.88.x`，保留真实 MAC
- Wi-Fi STA 或蜂窝网络自动成为 ImmortalWrt WAN 上游
- 自动探测系统 crosvm、蜂窝接口和 Android 当前共享接口；系统没有 crosvm 时
  回退到项目内置的 Android 13 兼容静态 ARM64 版本

## 安装

需要 Windows 有线 ADB、WSL，以及手机端 KernelSU/Magisk root 权限。

```bash
cd /mnt/c/Users/kano/Desktop/212ds/openwrt-vm
chmod +x deploy-openwrt.sh
./deploy-openwrt.sh install
```

默认密码为 `openwrt`。首次安装时可以覆盖参数：

```bash
OPENWRT_PASSWORD='新密码' VM_CPUS=4 VM_CPU_AFFINITY=auto VM_MEMORY_MIB=1024 DISK_SIZE=8G \
  ./deploy-openwrt.sh install
```

推荐直接编辑项目根目录的 `config.env`。其中：

```bash
DEVICE_MODEL=auto  # 安装时从目标 ADB 设备自动生成；也可手动填写显示名称

VM_CPUS=4              # 默认使用四个 vCPU
VM_CPU_AFFINITY=auto   # 自动一一绑定到当前 Android 最快的四个在线核心
VM_NET_QUEUES=auto     # 支持时启用与 vCPU 数量相同的 virtio-net 多队列
# VM_CPU_AFFINITY=none             # 不绑核，交给 Android 调度
# VM_CPU_AFFINITY='0=4:1=5:2=6:3=0' # 也可以显式指定 guest=host 映射

# 使用 auto 时还会向 ImmortalWrt 描述大小核 capacity 和 cluster，
# 让 Clash 等重负载优先调度到大核。

AUTO_TAKEOVER=0  # Android/SIM/应用直连，只有热点和 USB 客户端走 ImmortalWrt
AUTO_TAKEOVER=1  # Android 本机应用流量也由 ImmortalWrt 接管

IPV6_PASSTHROUGH=0  # ImmortalWrt 发布 LAN IPv6，并经其防火墙/NAT66 出口
IPV6_PASSTHROUGH=1  # Android 将蜂窝公网 IPv6 前缀直通热点/USB

CROSVM_PATH=auto             # auto / bundled / 设备上的绝对路径
CELLULAR_IFACE=auto          # 例如 sipa_eth0；auto 会按地址和常见命名探测
CELLULAR_ROUTE_TABLE=auto    # auto 默认使用最终探测到的蜂窝接口名
TETHER_IFACE_PATTERNS=auto   # 或 "sipa_usb* wlan* softap* eth* br*"
```

同平台设备建议先保留全部 `auto`。如果厂商改了接口命名，只改这里，不需要改
`device/openwrt.sh`。部署器会在启动前检查 ARM64 ABI、KVM/vGIC、TUN/TAP、
Linux bridge、crosvm 命令行兼容性和接口配置，失败时会给出具体项目。

修改后可直接同步到现有设备，不需要重新构建镜像：

```bash
./deploy-openwrt.sh show-config
./deploy-openwrt.sh apply-config
```

也可以通过 `OPENWRT_CONFIG=/path/to/another.env` 使用另一份配置文件；环境变量
优先于 `config.env` 中的默认值。

首次安装会下载官方镜像、校验 SHA-256、生成预配置 rootfs，再上传到
`/data/local/openwrt`。如果目标设备已经存在 `openwrt.img`，`install` 会直接
拒绝执行，不会覆盖包含已安装软件和用户配置的现有虚拟磁盘。应先备份，确认
备份有效后仅在明确需要重装时执行 `uninstall`，然后才能重新安装。
部署器会在扩展后比较镜像的逻辑大小与实际分配块数；如果设备文件系统不支持
稀疏文件，会在启动 VM 前停止安装，避免意外实际占用完整的 8 GiB。

## 备份

```bash
./deploy-openwrt.sh backup
./deploy-openwrt.sh backup /path/to/my-openwrt.img.gz
```

备份时脚本会短暂停止 VM，保证 ext4 镜像状态一致；完成或传输失败后都会恢复
原先的运行状态。8 GiB 稀疏镜像在 Android 端压缩后再经 ADB 传输，本地文件
大小主要取决于实际已用空间，而不是固定占用 8 GiB。默认保存到 `backups/`，
同时生成 `.sha256` 校验文件和记录设备序列号、逻辑/实际占用大小的 `.info`。

## 管理

```bash
./deploy-openwrt.sh status
./deploy-openwrt.sh backup
./deploy-openwrt.sh preflight
./deploy-openwrt.sh refresh-ipv6  # 撤销旧 RA 并重新发布当前蜂窝前缀
./deploy-openwrt.sh start
./deploy-openwrt.sh stop
./deploy-openwrt.sh restart
./deploy-openwrt.sh logs 200
./deploy-openwrt.sh ssh
```

也可以完全脱离电脑端部署脚本，在 Android 的 ADB root shell 中管理已经安装的
VM：

```sh
adb shell
su
/data/local/openwrt/openwrt.sh status
/data/local/openwrt/openwrt.sh start
/data/local/openwrt/openwrt.sh stop
/data/local/openwrt/openwrt.sh restart
/data/local/openwrt/openwrt.sh logs 200
```

或者直接从电脑执行单条命令：

```sh
adb shell "su 0 sh -c '/data/local/openwrt/openwrt.sh status'"
adb shell "su 0 sh -c '/data/local/openwrt/openwrt.sh start'"
adb shell "su 0 sh -c '/data/local/openwrt/openwrt.sh stop'"
adb shell "su 0 sh -c '/data/local/openwrt/openwrt.sh restart'"
```

应始终使用 `openwrt.sh` 启停，不要直接 `kill` crosvm；管理脚本会同时建立或
还原 TAP、网桥、转发规则、DHCP 防护及 Android 网络状态。镜像备份和恢复仍应
使用电脑端的 `deploy-openwrt.sh backup` 与 `deploy-openwrt.sh restore`。

修改 `device/openwrt.sh` 后，不需要重新构建和上传镜像：

```bash
./deploy-openwrt.sh update          # 更新设备脚本并重启 ImmortalWrt
./deploy-openwrt.sh update-script   # 只更新脚本，暂不重启
./deploy-openwrt.sh apply-config    # 同步 AUTO_TAKEOVER 并重启
./deploy-openwrt.sh show-config     # 显示当前生效的本地配置
```

项目携带的 crosvm 位于 `assets/crosvm/android13/crosvm`。一般不需要自行编译；
如需审计或重建，源码版本、补丁、锁文件和许可证位于 `tools/crosvm-a13`：

```bash
./tools/crosvm-a13/build.sh
```

其他命令：

```bash
./deploy-openwrt.sh prepare         # 仅下载并生成本地镜像
./deploy-openwrt.sh takeover        # 可选：临时让 Android 应用流量经过 ImmortalWrt
./deploy-openwrt.sh untakeover      # 恢复 Android 本机直连（默认状态）
./deploy-openwrt.sh uninstall       # 删除设备端 VM 和项目网络规则
./deploy-openwrt.sh purge-local     # 删除本项目的本地 cache/build
```

## 网络

| 用途 | 地址/接口 |
| --- | --- |
| ImmortalWrt LAN / LuCI / SSH | `192.168.88.1` |
| Android 软桥管理地址 | `192.168.88.2` (`owrt-br`) |
| ImmortalWrt WAN | `192.168.66.2` (`eth0`) |
| Android WAN 端 | `192.168.66.1` (`owrt-wan`) |

普通 Wi-Fi STA 不会加入 LAN 桥；只有 Android 报告接口进入
`TetheredState` 时，USB/Wi-Fi 热点接口才会自动加入 `owrt-br`。关闭共享后
接口会自动退出软桥并交还给 Android。

如果 Android 共享本身已经使用 `br0` 等网桥，脚本会建立一对临时 veth，把
现有网桥与 `owrt-br` 相连；不会把一个 bridge 直接 enslave 到另一个 bridge，
也不会和设备中其他未处于 `TetheredState` 的网桥冲突。若 ADB TCP 正好经过
这个共享网桥，应用配置或启动 VM 时连接可能短暂中断，推荐保留有线 ADB。

`192.168.88.2` 只用于 Android 宿主与 ImmortalWrt LAN 的管理/回程，不会成为
Android 的默认路由。ImmortalWrt 仅管理桥接的热点和 USB 客户端；蜂窝拨号、
SIM/APN、Android 应用及普通 Wi-Fi STA 始终由 Android 网络栈管理。

IPv4 始终由 ImmortalWrt DHCP/NAT 和防火墙管理。IPv6 由
`IPV6_PASSTHROUGH` 决定。设为 `0` 时，设备管理器把蜂窝公网 `/64` 发布到
ImmortalWrt WAN；ImmortalWrt 在 LAN 发布自己管理的 ULA，并通过 ImmortalWrt NAT66、
防火墙和可选代理后从公网 WAN 地址出站。客户端 IPv6 此时会经过 ImmortalWrt。

设为 `1` 时，Android 将蜂窝公网前缀直接发布到桥接的热点/USB 端口；客户端
获得公网地址，但 IPv6 绕过 ImmortalWrt 防火墙。修改后执行
`./deploy-openwrt.sh apply-config` 会重启 VM 并切换模式。

直通模式下 Android 原生共享 RA 保持中优先级，项目自带 RA 仅作为低优先级
兜底；ImmortalWrt 管理模式则会抑制 Android 在热点/USB 上发出的 RA/DHCPv6，
避免客户端同时绕过 ImmortalWrt。蜂窝前缀变化、热点关闭或管理器停止时，辅助
程序会主动发送撤销 RA，并使用较短生命周期，避免客户端保留失效前缀。
