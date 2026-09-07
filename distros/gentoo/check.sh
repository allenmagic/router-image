#
# distros/gentoo/check.sh —— Gentoo (openrc) 构建完整性检查
#   被 setup.sh source 调用，运行在 stage3 环境内
#   检查目标为 TARGET_ROOTFS（/gentoo-rootfs），不是当前根文件系统
#

check_rootfs() {
    echo "[check] === 构建完整性检查 ==="
    _OK=0; _FAIL=0

    # ---------- 1. 关键二进制（在 TARGET_ROOTFS 内查找）----------
    _check_bin() { _b_="$1"; shift
        for _p_ in "$@"; do
            if [ -x "${TARGET_ROOTFS}${_p_}" ]; then
                echo "  ✓ $_b_"; _OK=$((_OK + 1)); return 0
            fi
        done
        echo "  ✗ $_b_ 缺失!"; _FAIL=$((_FAIL + 1))
    }

    _check_ca_certs() {
        # CA 证书 bundle：tailscaled/cloudflared（Go）TLS 握手的系统信任根。
        # 包清单显式声明 app-misc/ca-certificates——曾靠 curl 依赖顺带拉入，
        # curl 移除后必须独立存在。gentoo 链目标在 TARGET_ROOTFS 下
        # （stage3 自身的 bundle 不代表目标镜像）
        if [ -f "${TARGET_ROOTFS}/etc/ssl/certs/ca-certificates.crt" ]; then
            echo "  ✓ ca-certificates.crt（TLS 信任根）"
            _OK=$((_OK + 1))
        else
            echo "  ✗ ${TARGET_ROOTFS}/etc/ssl/certs/ca-certificates.crt 缺失!" >&2
            _FAIL=$((_FAIL + 1))
        fi
    }

    echo "[check] 二进制:"
    _check_bin init     /sbin/init
    _check_bin busybox  /bin/busybox
    _check_bin sshd     /usr/sbin/sshd
    _check_bin dnsmasq  /usr/sbin/dnsmasq /usr/bin/dnsmasq
    _check_bin nft      /usr/sbin/nft /sbin/nft
    # tailscale 是 [pm] net-vpn/tailscale（emerge），musl 版装在 /usr/sbin
    # （与 alpine 链、base/init/openrc/tailscale 一致）；曾误写 /usr/local/bin
    # （那是 [dl@] cloudflared 的位置），本地构建 check 必失败。
    _check_bin tailscaled /usr/sbin/tailscaled
    _check_bin cloudflared /usr/local/bin/cloudflared
    _check_bin network-watchdog /usr/local/bin/network-watchdog
    _check_ca_certs
    # 动态链接器（2026-09 回归的盲区）：-x 查不出 PT_INTERP 断链——
    # baselayout 移除后 ld-musl 落在 /usr/lib，镜像里所有动态二进制
    # exec 报 ENOENT → "No working init found" panic，构建检查照样全绿
    if [ -e "${TARGET_ROOTFS}/lib/ld-musl-x86_64.so.1" ]; then
        echo "  ✓ ld-musl-x86_64.so.1（动态链接器在位）"
        _OK=$((_OK + 1))
    else
        echo "  ✗ ${TARGET_ROOTFS}/lib/ld-musl-x86_64.so.1 缺失!" >&2
        _FAIL=$((_FAIL + 1))
    fi
    # getty 与 ntp 用户（同为 2026-09 包审计后首次产出镜像才暴露的盲区）：
    # inittab 依赖 busybox 的 /sbin/getty（util-linux 已删），ntpd 依赖
    # acct-user/ntp。启动日志断言查不出「到不了 login」这类失败
    _check_bin getty /sbin/getty
    if grep -qE '^S[0-9]+::respawn:/sbin/getty' "${TARGET_ROOTFS}/etc/inittab" 2>/dev/null; then
        echo "  ✓ inittab 串口 getty 激活"
        _OK=$((_OK + 1))
    else
        echo "  ✗ inittab 无激活串口 getty 行!" >&2
        _FAIL=$((_FAIL + 1))
    fi
    # /var/lock 烙链接（bootmisc 运行期 ln 在 ro 上必报 EROFS，构建检查
    # 全绿也拦不住——只能烙期保证）
    if [ -L "${TARGET_ROOTFS}/var/lock" ] && \
       [ "$(readlink "${TARGET_ROOTFS}/var/lock")" = "/run/lock" ]; then
        echo "  ✓ /var/lock -> /run/lock（bootmisc 会跳过 ln）"
        _OK=$((_OK + 1))
    else
        echo "  ✗ /var/lock 未烙链接!" >&2
        _FAIL=$((_FAIL + 1))
    fi
    if grep -q '^ntp:' "${TARGET_ROOTFS}/etc/passwd" 2>/dev/null; then
        echo "  ✓ ntp 用户存在（ntpd 的 command_user）"
        _OK=$((_OK + 1))
    else
        echo "  ✗ ${TARGET_ROOTFS}/etc/passwd 无 ntp 用户!" >&2
        _FAIL=$((_FAIL + 1))
    fi

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
    for _f_ in "${TARGET_ROOTFS}"/etc/dnsmasq.d/*.conf "${TARGET_ROOTFS}"/etc/nftables.d/*.nft; do
        [ -f "$_f_" ] && _check_no_placeholder "$_f_"
    done

    # ---------- 3. openrc 服务启用 ----------
    _check_openrc() { _s_="$1" _rl_="${2:-default}"
        if [ -x "${TARGET_ROOTFS}/etc/init.d/$_s_" ]; then
            if [ -L "${TARGET_ROOTFS}/etc/runlevels/$_rl_/$_s_" ]; then
                echo "  ✓ $_s_ ($_rl_)"; _OK=$((_OK + 1))
            else
                echo "  ✗ $_s_ init 脚本存在但未在 $_rl_ runlevel 注册"; _FAIL=$((_FAIL + 1))
            fi
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    }
    echo "[check] openrc 系统服务:"
    _check_openrc bootmisc boot
    _check_openrc syslog default
    _check_openrc loopback boot

    echo "[check] openrc 应用服务:"
    _check_openrc sshd default
    _check_openrc ntpd
    _check_openrc nftables default
    _check_openrc dnsmasq default
    _check_openrc tailscale default
    _check_openrc cloudflared default
    _check_openrc network-watchdog
    _check_openrc network
    _check_openrc keepalived

    # ---------- 4. 额外检查：自定义 init 脚本完整性 ----------
    echo "[check] Gentoo 自定义 init 脚本:"
    for _s_ in ntpd syslog; do
        if [ -x "${TARGET_ROOTFS}/etc/init.d/$_s_" ]; then
            echo "  ✓ $_s_"; _OK=$((_OK + 1))
        else
            echo "  ✗ $_s_ init 脚本缺失!"; _FAIL=$((_FAIL + 1))
        fi
    done

    # ---------- 结果 ----------
    _TOTAL=$((_OK + _FAIL))
    echo "[check] === $_OK/$_TOTAL 通过 ==="
    # 与 alpine 链对齐：失败即中止构建（2026-09 前这里只打警告恒返回 0，
    # init/ld-musl/getty 等盲区检查形同虚设——check 全绿拦不住回归）
    [ "$_FAIL" -eq 0 ] || { echo "[check] 构建不完整，中止"; exit 1; }
}
