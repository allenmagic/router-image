#
# distros/alpine/service.sh —— Alpine (OpenRC) 服务启用
#   被 setup.sh source 调用
#   定义 enable_router_services() 函数
#

enable_router_services() {
    echo "[service] === 启用路由器服务 ==="

    # --- 系统基础服务 ---
    # sysctl：应用 /etc/sysctl.d/*（含 90-router.conf 的 ip_forward=1）。
    # 4decfe3 加了 base/init/openrc/sysctl 但漏了接线 → 从未进 runlevel →
    # ip_forward 干净启动后是 0，NAT/转发全失效（NAS 出网断，仅手动
    # sysctl/echo 才恢复）。boot 级、bootmisc 前（depend 已声明）。
    _enable_service sysctl boot
    _enable_service bootmisc boot
    # 运行时状态目录（sysinit：/run 下目录准备，先于一切 default 级服务）
    _enable_service run-state sysinit
    # 宿主可选持久状态盘（stateDisk）：/dev/vdb 挂到 state/，先于身份类服务
    _enable_service mount-state sysinit
    # devpts：交互式 SSH 需要 /dev/pts（精简镜像不自动挂，见 base/init/openrc/devpts）
    _enable_service devpts sysinit
    # host key 在 /run/ssh 生成（依赖 run-state，先于 sshd）
    _enable_service sshd-keys sysinit
    # 回环：Alpine 的 openrc 带 loopback 服务但默认不注册（Gentoo 的 stage3 已在
    # boot runlevel 注册，故只有这边缺）。放 boot 而非 default，是为了在 default
    # 里任何服务起来之前 lo 就已就绪，不留竞态。
    # 不注册的后果：lo 一直是 <LOOPBACK> DOWN 且无地址（内核只在 up 时才自动配
    # 127.0.0.1/8 与 ::1），任何连 127.0.0.1 的东西都不通 —— 实测 dnsmasq 本地
    # 查询失败，本地 ssh 同理。而且启动日志里没有任何迹象：服务没跑，自然不报错。
    _enable_service loopback boot
    _enable_service syslog
    # 网络（base/init/openrc/network：udhcpc + ip 直接配置；与 gentoo 链对齐注册位置）
    _enable_service network

    # --- base 应用服务（按依赖顺序）---
    # 1. 防火墙（最先加载）
    _enable_service nftables

    # 2. 核心网络服务
    _enable_service dnsmasq

    # 3. 基础应用服务
    _enable_service sshd
    _enable_service ntpd

    # 4. VPN 和隧道服务
    _enable_service tailscale
    _enable_service headscale
    _enable_service cloudflared

    # 5. 监控服务
    _enable_service network-watchdog
    _enable_service keepalived

    echo "[service] === 服务启用完成 ==="
}

# 通用服务启用
# _enable_service <name> [runlevel]
#   runlevel 可选，默认 default
_enable_service() {
    _svc_="$1"
    _rl_="${2:-default}"
    if [ -f "/etc/init.d/${_svc_}" ]; then
        rc-update add "${_svc_}" "${_rl_}" 2>/dev/null || true
        echo "[service]   启用: ${_svc_} (${_rl_})"
    fi
}

