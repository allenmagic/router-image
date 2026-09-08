#
# distros/alpine/check.sh —— Alpine (openrc) 构建完整性检查
#   被 setup.sh source 调用，在清理步骤之前执行
#

check_rootfs() {
    echo "[check] === 构建完整性检查 ==="
    _OK=0; _FAIL=0

    # ---------- 1. 关键二进制 ----------
    # 与 gentoo 链同款：优先按给定路径查（inittab/init 脚本引用的确切路径），
    # 无路径参数时回落 command -v（2026-09 对称化前只查 PATH，
    # 引用了确切路径但不在 PATH 的二进制会漏检）
    _check_bin() { _b_="$1"; shift
        for _p_ in "$@"; do
            [ -x "${_p_}" ] && { echo "  ✓ $_b_"; _OK=$((_OK + 1)); return 0; }
        done
        if command -v "$_b_" >/dev/null 2>&1; then
            echo "  ✓ $_b_"; _OK=$((_OK + 1))
        else
            echo "  ✗ $_b_ 缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }

_check_ca_certs() {
    # CA 证书 bundle：tailscaled/cloudflared（Go）TLS 握手的系统信任根。
    # 包清单显式声明 ca-certificates-bundle / app-misc/ca-certificates——
    # 曾靠 curl 依赖顺带拉入，curl 移除后必须独立存在
    if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
        echo "  ✓ ca-certificates.crt（TLS 信任根）"
        _OK=$((_OK + 1))
    else
        echo "  ✗ /etc/ssl/certs/ca-certificates.crt 缺失!" >&2
        _FAIL=$((_FAIL + 1))
    fi
}

    echo "[check] 二进制:"
    _check_bin sshd
    _check_bin ntpd
    _check_bin dnsmasq
    _check_bin nft
    _check_bin tailscaled
    _check_bin cloudflared
    _check_bin network-watchdog
    # getty 与 ntp 用户（gentoo 链 2026-09 首曝的盲区，对称补上）：
    # inittab 依赖 busybox 的 /sbin/getty（镜像无 agetty，2026-09 实测），
    # ntpd 依赖 base/init/openrc/ntpd 的 command_user="ntp"（busybox-openrc
    # 预置——预置行为变化即 ntpd 静默起不来的回归）
    _check_bin getty /sbin/getty
    if grep -q '^ntp:' /etc/passwd 2>/dev/null; then
        echo "  ✓ ntp 用户存在（ntpd 的 command_user）"
        _OK=$((_OK + 1))
    else
        echo "  ✗ /etc/passwd 无 ntp 用户!" >&2
        _FAIL=$((_FAIL + 1))
    fi
    if grep -qE '^ttyS[0-9]' /etc/inittab 2>/dev/null; then
        echo "  ✓ inittab 串口 getty 激活"
        _OK=$((_OK + 1))
    else
        echo "  ✗ inittab 无激活串口 getty 行!" >&2
        _FAIL=$((_FAIL + 1))
    fi
    _check_ca_certs

    # ---------- 2. 配置文件占位符残留 ----------
    _check_no_placeholder() { _f_="$1"
        [ -f "$_f_" ] || { echo "  ✗ $_f_ 不存在!"; _FAIL=$((_FAIL + 1)); return; }
        if grep -q '__[A-Z_]\+__' "$_f_" 2>/dev/null; then
            echo "  ✗ $_f_ 有未替换占位符!"; _FAIL=$((_FAIL + 1))
            grep -n '__[A-Z_]\+__' "$_f_"
        else
            echo "  ✓ $_f_"; _OK=$((_OK + 1))
        fi
    }
    echo "[check] 配置占位符:"
    for _f_ in /etc/dnsmasq.d/*.conf /etc/nftables.d/*.nft /etc/headscale/config.json; do
        [ -f "$_f_" ] && _check_no_placeholder "$_f_"
    done

    # ---------- 3. openrc 服务启用 ----------
    # 与 gentoo 链同款：直接断言 runlevels 下的符号链接（rc-update add 与
    # gentoo 侧手工 ln 生成的都是 /etc/runlevels/<rl>/<name> 链接）。
    # 2026-09 对称化前用 rc-update show | grep 子串匹配：不校验 runlevel
    # 且 network 会命中 network-watchdog 行
    _check_openrc() { _s_="$1" _rl_="${2:-default}"
        if [ -x "/etc/init.d/$_s_" ]; then
            if [ -L "/etc/runlevels/$_rl_/$_s_" ]; then
                echo "  ✓ $_s_ ($_rl_)"; _OK=$((_OK + 1))
            else
                echo "  ✗ $_s_ init 脚本存在但未在 $_rl_ runlevel 注册"; _FAIL=$((_FAIL + 1))
            fi
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] openrc 系统服务:"
    # loopback：Alpine 默认不注册它，漏了 lo 就一直 DOWN，且启动日志里没有任何
    # 迹象（服务没跑，自然不报错），只能在构建期查注册状态
    _check_openrc loopback boot
    _check_openrc bootmisc boot
    _check_openrc syslog
    echo "[check] openrc 应用服务:"
    _check_openrc network
    _check_openrc sshd
    _check_openrc ntpd
    _check_openrc nftables
    _check_openrc dnsmasq
    _check_openrc tailscale
    _check_openrc headscale
    _check_openrc cloudflared
    _check_openrc network-watchdog
    # keepalived（VRRP 浮动网关）：gentoo 侧一直查，alpine 曾漏（2026-09 对称化）
    _check_openrc keepalived

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    [ "$_FAIL" -eq 0 ] || { echo "[check] 构建不完整，中止"; exit 1; }
}
