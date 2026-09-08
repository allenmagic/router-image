#!/bin/sh
# guest 内自检：验证内核能力与镜像装配的正确性
#
# 为什么需要它而不是只看启动日志：启动日志能证明「没崩」，证明不了「能力完整」。
# 历史教训是 openrc modules 服务用 `modprobe -q` 静默吞掉所有模块加载失败；
# 2026-09 裁剪审计后内核 MODULES=n（全 builtin、无 /lib/modules、无 modprobe），
# 那个静默失败通道不复存在，但「片段静默失效 = 能编译不能干活的残缺内核」
# 的风险仍在——builtin 能力只能在这里逐项验证。
#
# 判定方法：builtin 代码同样在 /sys/module/<名> 注册目录（SYSFS=y），
# 比 modprobe 返回码更直接——不依赖任何用户态工具（kmod 包已删）。
#
# 用法（smoke-test 启动后登录 root/root，粘贴到串口）：
#   sh /root/verify-guest.sh
# 或从宿主：
#   test/smoke-test.sh alpine
#   # 登录后手工执行本脚本内容
#
# 退出码 0 = 全通过；非 0 = 失败项数
set -u

FAILS=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

head_ "内核 builtin 能力（MODULES=n，/sys/module 判定）"
KREL="$(uname -r)"
ok "内核版本: $KREL"
if [ -e /proc/modules ]; then
    NMOD="$(wc -l < /proc/modules)"
    [ "$NMOD" -eq 0 ] && ok "零可装载模块（/proc/modules 空，符合 MODULES=n）" \
                      || bad "/proc/modules 有 ${NMOD} 行——MODULES=n 预期为 0"
else
    bad "缺 /proc/modules（MODULES=n 时也应存在空文件）"
fi
# 引导链与路由器能力的关键 builtin——任一项缺失都意味着 config 片段
# 静默失效（allnoconfig 把带 prompt 的符号置 n 的同类事故，见 config.fragment 注释）
for _m in virtio_blk virtio_net virtio_balloon ext4 tun \
          nf_tables nf_conntrack nf_nat; do
    [ -d "/sys/module/$_m" ] && ok "builtin: $_m" || bad "缺 builtin $_m"
done

head_ "功能判据（直接查能力是否真的在，不依赖模块工具）"
nft list tables >/dev/null 2>&1 && ok "nftables 可用" || bad "nftables 不可用"
[ -c /dev/net/tun ] && ok "/dev/net/tun 存在（tailscale 依赖）" || bad "缺 /dev/net/tun"
[ -c /dev/rtc0 ] && ok "/dev/rtc0 存在（缺 RTC_INTF_DEV 会没有）" || bad "缺 /dev/rtc0"
CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
[ "$CC" = bbr ] && ok "拥塞控制 = bbr" || bad "拥塞控制 = ${CC:-未知}（期望 bbr）"
FW="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
[ "$FW" = 1 ] && ok "ip_forward = 1" || bad "ip_forward = ${FW:-未知}（期望 1）"
# flock：CONFIG_FILE_LOCKING 丢失时报 Function not implemented
if flock -n /tmp/.vg.lock true 2>/dev/null; then
    ok "flock 可用（CONFIG_FILE_LOCKING）"
else
    bad "flock 不可用 —— openrc 依赖它缓存服务依赖"
fi
rm -f /tmp/.vg.lock

head_ "回环接口（dnsmasq 本地查询、本地 ssh 等一切连 127.0.0.1 的东西都要它）"
# 注意别把「设备存在」当成「已启用」：lo 这个 netdev 内核无条件创建，ip a 永远
# 列得出来，DOWN 时的样子是 <LOOPBACK> + qdisc noop 且一条地址都没有
if ip link show lo 2>/dev/null | grep -q '[<,]UP[,>]'; then
    ok "lo 已 up"
    ip addr show lo 2>/dev/null | grep -q 'inet 127\.0\.0\.1' \
        && ok "lo 有 127.0.0.1" || bad "lo 已 up 但没有 127.0.0.1"
    ping -c1 -W1 127.0.0.1 >/dev/null 2>&1 \
        && ok "127.0.0.1 可达" || bad "lo 已 up 但 127.0.0.1 不可达"
else
    bad "lo 处于 DOWN —— loopback 服务未注册进 boot runlevel"
fi

head_ "deploy 就绪（密钥注入前置）"
# sshd 是 deploy 的 scp/ssh 通道（root/root 密码 + 注入公钥后的免密登录）；
# 三符号链接把标准路径指向 /run（tmpfs），deploy 写标准路径即落 tmpfs。
if pgrep sshd >/dev/null 2>&1; then
    ok "sshd 进程运行中"
else
    bad "sshd 未运行（deploy 的 scp/ssh 通道会失败）"
fi
if [ -f /run/router-vm/state/ssh/ssh_host_ed25519_key ]; then
    ok "host key 已生成（/run/router-vm/state/ssh，sshd-keys 服务）"
else
    bad "缺 /run/router-vm/state/ssh host key（sshd-keys 未跑，sshd 无法接受连接）"
fi
_symlink_ok() {
    if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then
        ok "$3：$1 -> $2"
    else
        bad "$3：$1 未指向 $2（deploy 写不进 /run）"
    fi
}
_symlink_ok /root/.ssh             /run/router-vm/state/ssh     "SSH authorized_keys"
_symlink_ok /etc/cloudflared       /run/router-vm/cloudflared "Cloudflared config"
_symlink_ok /etc/tailscale/authkey /run/router-vm/tailscale/authkey "Tailscale authkey"
# /tmp 必须可写：router-vm-deploy 把 deploy.tar.gz scp 到 guest 的 /tmp，
# ro rootfs 上 /tmp 若未链到 tmpfs（alpine 链 2026-09 曾漏链）则 scp 报
# "dest open ...: Failure" 密钥注入全挂。这里直接实测而非只看链接。
if [ -w /tmp ] && touch /tmp/.vg-test 2>/dev/null; then
    ok "/tmp 可写（deploy scp 目标就绪）"
    rm -f /tmp/.vg-test
else
    bad "/tmp 不可写 —— deploy scp 到 /tmp 会失败（需链到 /run/router-vm/tmp）"
fi
for _d in state/tailscale state/headscale state/ssh secrets tmp; do
    [ -d "/run/router-vm/$_d" ] && ok "/run/router-vm/$_d 目录存在（run-state）" || bad "缺 /run/router-vm/$_d（run-state 未建）"
done

head_ "服务状态"
CRASHED="$(rc-status --crashed 2>/dev/null)"
[ -z "$CRASHED" ] && ok "无崩溃服务" || bad "崩溃服务: $CRASHED"
echo "  /proc/modules 行数: $(wc -l < /proc/modules 2>/dev/null)（MODULES=n 时为 0）"

head_ "结果"
if [ "$FAILS" -eq 0 ]; then
    printf '\033[32m全部通过\033[0m\n'
else
    printf '\033[31m%d 项失败\033[0m\n' "$FAILS"
fi
exit "$FAILS"
