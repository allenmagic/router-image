#!/bin/sh
#
# distros/alpine/setup.sh —— Alpine chroot 内设置（OpenRC）
#   安装包 + 部署配置 + 系统设置 + 启用服务
#
set -eu

ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HOSTNAME_VAL="${HOSTNAME_VAL:-alpine-router}"
MIRROR="${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
SERIAL_DEV="${SERIAL_DEV:-ttyS0}"   # VM 串口（R3S 是 ttyS2）
SERIAL_BAUD="${SERIAL_BAUD:-115200}"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /download-helpers.sh

# ============================================================
#  1. 安装包 —— 按 package.list 三段安装
# ============================================================
echo "[setup] === 安装系统包（package.list 单段 base）==="

# [dl@] 下载用 curl（_dl_url），但 curl 不进最终镜像（ro guest 无运行期
# 用途，已从 package.list 移除）——构建期临时安装，下载完成后卸载
# （与下方 tzdata 同模式）。alpine 链的 chroot 就是镜像本身，
# 卸载前 curl 必须全程在位。
apk add --no-cache curl >/dev/null

_PKG_LIST_="/package.list"
if [ -f "${_PKG_LIST_}" ]; then
    while read -r _line_; do
        [ -z "${_line_}" ] && continue

        case "${_line_}" in
            '# ========== base'*)
                _section_="base"
                echo "[setup] --- 段: base ---"
                continue
                ;;
            '#'*) continue ;;
        esac

        case "${_line_}" in
            '[pm]'*)
                _pkg_="${_line_#\[pm\] }"
                echo "[setup]   [pm] ${_pkg_}"
                apk add --no-cache "${_pkg_}"
                ;;
            '[dl@'*)
                _line_="${_line_#\[dl@}"
                _url_="${_line_%%\] *}"
                _bin_="${_line_#*\] }"
                echo "[setup]   [dl@${_bin_}]"
                _dl_url "${_url_}" "${_bin_}"
                ;;
        esac
    done < "${_PKG_LIST_}"
else
    echo "[setup] 警告: ${_PKG_LIST_} 不存在" >&2
fi

# 配置时区
cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true
apk del tzdata curl 2>/dev/null || true

# ============================================================
#  2. 部署配置文件
# ============================================================
echo "[setup] === 部署出厂配置 ==="

_deploy_cfg_() {
    _CFG_="/$1"
    [ ! -d "${_CFG_}" ] && return
    echo "[setup]   部署 /${1}/ ..."
    for _f_ in "${_CFG_}"/*; do
        [ ! -e "${_f_}" ] && continue
        _base_="$(basename "${_f_}")"
        [ "${_base_}" = "init" ] && continue
        cp -r "${_f_}" /etc/
    done
    if [ -d "${_CFG_}/init/openrc" ]; then
        cp -f "${_CFG_}/init/openrc/"* /etc/init.d/ 2>/dev/null || true
        chmod +x /etc/init.d/* 2>/dev/null || true
    fi
}

# 部署 base/（唯一配置层）
_deploy_cfg_ base

find /etc \( -name '*.md' -o -name '*.example' \) -exec rm -f {} + 2>/dev/null || true

chmod +x /etc/local.d/*.start 2>/dev/null || true

# 安装运行时脚本到 /usr/local/bin/
echo "[setup] === 安装运行时脚本 ==="
if [ -f /scripts/network-watchdog.sh ]; then
    install -m 0755 /scripts/network-watchdog.sh /usr/local/bin/network-watchdog
    echo "[setup]   已安装: network-watchdog"
fi

# ============================================================
#  2.5. 网络配置（config 文件拷贝完成后替换占位符 + 生成接口配置）
# ============================================================
. /network.sh
configure_network

# ============================================================
#  2.6. ro rootfs 写点处理（持久写归状态盘，rootfs 只读）
# ============================================================
echo "[setup] === ro rootfs 写点处理 ==="

# /etc/mtab：busybox mount 检测到符号链接即跳过写入（ro 根上无报错）
ln -sf /proc/mounts /etc/mtab

# /etc/resolv.conf：WAN DHCP 的运行期产物，落 tmpfs。默认脚本用 mv
# 落盘会替换符号链接本体（ro 根上失败），故让 udhcpc 直接写 /run
ln -sf /run/router-vm/resolv.conf /etc/resolv.conf
if [ -f /etc/udhcpc/udhcpc.conf ]; then
    grep -q '^RESOLV_CONF=' /etc/udhcpc/udhcpc.conf 2>/dev/null \
        || echo 'RESOLV_CONF=/run/router-vm/resolv.conf' >> /etc/udhcpc/udhcpc.conf
fi

# ============================================================
#  3. 系统设置
# ============================================================
echo "[setup] === 系统设置 ==="

echo "[setup] 设置 root 密码 ..."
echo "root:${ROOT_PASSWORD}" | chpasswd

# root shell 保持默认 ash（busybox）——bash 已从包清单移除（guest 只读、
# 配置烙入镜像，交互调试 ash 足够；见 package.list 审计结论）

echo "[setup] 设置主机名：${HOSTNAME_VAL}"
echo "${HOSTNAME_VAL}" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*${HOSTNAME_VAL}" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "${HOSTNAME_VAL}" >> /etc/hosts
fi

# 串口 getty：默认 ttyS0 由 image/assemble-rootfs.sh 的共享 sed 反注释
# baselayout 出厂注释行激活；此处兜底非默认串口（如 R3S 的 ttyS2）。
# 守卫只看激活行（^SERIAL_DEV:）——出厂注释行 #ttyS0: 不再误命中导致
# 不追加（2026-09 修复，曾因此默认场景没人激活）。二进制用 /sbin/getty：
# 镜像无 agetty（2026-09 实测 busybox 链接名是 getty，旧行的 agetty
# 即使执行也 cannot execute）
if ! grep -qE "^${SERIAL_DEV}:" /etc/inittab 2>/dev/null; then
    echo "${SERIAL_DEV}::respawn:/sbin/getty -L ${SERIAL_BAUD} ${SERIAL_DEV} vt100" >> /etc/inittab
fi
# 注释掉 tty1-tty6（Alpine busybox init 用设备名作 id）
sed -i 's/^tty[1-6]:/#&/' /etc/inittab 2>/dev/null || true

echo "[setup] 启用基础服务 ..."

# ============================================================
#  4. 启用路由器服务
# ============================================================
echo "[setup] === 启用服务 ==="
. /service.sh
enable_router_services

# MODULES=n（2026-09 裁剪）：无 .ko 可装载。openrc 包自带的 modules 服务
# 与 kmod 包一并移除——builtin 能力不需要运行期 modprobe
rc-update del modules 2>/dev/null || true
rm -f /etc/init.d/modules /etc/modules 2>/dev/null || true
rm -f /etc/modules-load.d/*.conf 2>/dev/null || true

# hwclock 服务删除（2026-09，与 gentoo 链对齐）：CH 不模拟 CMOS RTC，
# 服务无用且必败。alpine 的 openrc 当前未把它注册进 runlevel（故无启动
# 报错），rc-update del 是幂等保险——防止未来 openrc 包升级改变注册。
# 时间链 = kvm-clock + ntpd 常驻校准；qemu 路径由 ntpd start_pre 的
# hwclock --hctosys 直接恢复
rc-update del hwclock 2>/dev/null || true
rm -f /etc/init.d/hwclock /etc/init.d/swclock /etc/init.d/osclock 2>/dev/null || true

# 密钥注入
[ -x /inject-secrets.sh ] && /bin/sh /inject-secrets.sh

# ============================================================
#  4.5. 运行时目录链接（构建期烙入，必须在所有安装之后）
# ============================================================
# ro rootfs 运行期无法创建符号链接，可写目录必须在镜像构建期替换为
# 指向 /run/router-vm（tmpfs）的链接。guest 完全无状态：持久化密钥
# 由宿主 sops-nix 管理、deploy 时注入（见 docs/refactor-proposal.md
# §3.3）。状态统一挂 /run/router-vm/ 单根，审计 = ls /run/router-vm。
# 清单与 base/init/openrc/run-state 的 RUN_DIRS 一一对应。
echo "[setup] === 运行时目录链接 ==="
_link_state_dir() {
    _sys="$1"; _rel="$2"
    rm -rf "$_sys"
    ln -s "/run/router-vm/$_rel" "$_sys"
    echo "[setup]   $_sys -> /run/router-vm/$_rel"
}
# /var/lib 整体链接到 state/lib：动态状态（tailscale/headscale 身份、
# dnsmasq 租约、未来一切 /var/lib 写点）统一覆盖——宿主启用 stateDisk
# 时 mount-state 把盘挂到 state/（lib 随盘持久），否则就是 /run 下
# 普通目录 = 易失，与旧行为一致
_link_state_dir /var/lib            state/lib
# 持久身份候选（ssh 独立于 /var/lib）
_link_state_dir /root/.ssh         state/ssh
# 易失秘密（deploy 每次注入，绝不持久化）
_link_state_dir /etc/cloudflared    secrets/cloudflared
_link_state_dir /var/log            log
_link_state_dir /var/tmp            tmp
# /tmp 一并链到 /run/router-vm/tmp（与 gentoo 链对齐）。否则 ro rootfs 上
# /tmp 只读，router-vm-deploy scp 到 /tmp/router-vm-deploy.tar.gz 会失败
# （2026-09 实测：alpine 链 deploy 因 /tmp 只读而 Failure）
_link_state_dir /tmp                tmp
# /etc/tailscale 整体不能链接（config.json 是构建期配置，留在镜像内），
# 只链接运行期注入的 authkey 文件
rm -f /etc/tailscale/authkey
ln -s /run/router-vm/secrets/tailscale-authkey /etc/tailscale/authkey
# headscale 第二实例（ts0）同构：config.json 留在镜像内，authkey 链接到 /run
rm -f /etc/headscale/authkey
ln -s /run/router-vm/secrets/headscale-authkey /etc/headscale/authkey
# host key 不靠符号链接（ssh-keygen 的临时文件写同目录，ro 上会失败），
# 而是 base/ssh/sshd_config.d/state-hostkeys.conf 把 HostKey 指到
# /run/router-vm/state/ssh/（sshd-keys 服务生成；stateDisk 持久时身份稳定）


# ============================================================
#  4.6. 构建完整性检查
# ============================================================
. /check.sh
check_rootfs

# ============================================================
#  5. 清理
# ============================================================
rm -rf /var/cache/apk/* 2>/dev/null || true
echo "[setup] 完成。"
