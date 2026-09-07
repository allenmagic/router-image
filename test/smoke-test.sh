#!/usr/bin/env bash
# ============================================================
# 路由 VM 镜像冒烟测试
#
# 下载 router-image 的 release 资产 → 校验 sha256 → 用
# qemu / cloud-hypervisor 启动并观察串口（ttyS0）。
#
# 资产两件套：vmlinuz-router（自建内核，全 builtin、无 initramfs）+
# <distro>-rootfs.qcow2。guest 无状态（ro rootfs），与生产同参数启动。
#
# 用法:
#   test/smoke-test.sh alpine                   # 只测 alpine
#   test/smoke-test.sh gentoo                   # 只测 gentoo
#   test/smoke-test.sh all                      # 两个都测（顺序启动）
#   test/smoke-test.sh alpine --verify-only     # 只下载+校验，不启动
#   test/smoke-test.sh gentoo --backend cloud-hypervisor
#
# 选项:
#   --tag TAG         release tag（默认自动探测最新 router-vm-* 前缀）
#   --backend NAME    qemu | cloud-hypervisor（默认 qemu）
#   --local-kernel PATH  用本地内核替代 release 的 vmlinuz-router（跳过它的
#                     下载与校验；测 kernel/build.sh 刚构建、尚未发布的产物）
#   --assert          非交互断言：后台启动 + 日志落盘 + 轮询 login: 或超时
#                     + 强制清理（qemu：-nographic 串口重定向落日志；
#                     CH：--serial file 落日志）。断言项：FATAL: Module /
#                     Function not implemented / hwclock:（仅 qemu，CH 无
#                     CMOS RTC 属预期）/ Kernel panic / Read-only file
#                     system / 未到达 login 一律视为失败（内核能启动 ≠
#                     能力完整；openrc 的 modules 服务结构上无法失败，
#                     日志是唯一能拦住静默丢失的地方）
#   --assets-dir DIR  资产缓存目录（默认 <仓库>/build/smoke-assets，已被 .gitignore 忽略）
#   --no-download     跳过下载，只用缓存里已有的文件
#   --force-download  无条件重新下载（默认已会按 sha256 自动刷新过期缓存）
#   --verify-only     只下载 + 校验 sha256，不启动
#   --loglevel N      追加内核参数 loglevel=N（0-7，默认不追加；3 可屏蔽 nft warn 级日志对串口的干扰）
#   --proxy           下载走 proxychains 代理（默认 auto：装了 proxychains 就自动用）
#   --no-proxy        强制直连，不走代理
#   -h|--help         本帮助
#
# 两条启动路径的定位：
#   qemu              交互验证（串口直连 ttyS0，登录 root/root，rc-status /
#                     nft list ruleset）。qemu 无 KVM 要求、-snapshot 不落盘
#   cloud-hypervisor  与生产同参数的启动验证（--kernel + --disk readonly=on
#                     + ro cmdline + 内存 256M）。CH 路径无 tap 网卡（建 tap
#                     需 root，冒烟保持免 sudo）——virtio-net 回归由 qemu 路径
#                     的 user-mode 网卡覆盖。--assert 模式为非交互（重定向下
#                     --serial tty 不可用，改 --serial file 落日志，
#                     不尝试 tee/script 保 TTY）；交互测试归 qemu
#
# 依赖: curl sha256sum python3（探测/解析 JSON）。
#   启动需要 qemu-system-x86_64 或 cloud-hypervisor（--verify-only 不需要；
#   CH 需要 root/KVM 权限）。
# ============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_SLUG="allenmagic/router-image"   # 用 --repo 覆盖（fork 时）
TAG=""                                        # 空 = 自动探测
BACKEND="qemu"
ASSETS_DIR="${REPO_ROOT}/build/smoke-assets"
DO_DOWNLOAD=1
FORCE_DOWNLOAD=0   # --force-download：无条件重新下载（默认按 sha256 自动刷新）
VERIFY_ONLY=0
LOGLEVEL=""      # 空 = 不追加 loglevel；如 --loglevel 3
PROXY_MODE="auto"   # auto | on | off（下载是否走 proxychains）
PROXY=""            # 实际前缀命令（resolve 后，空 = 直连）
DISTRO=""
LOCAL_KERNEL=""     # --local-kernel PATH：本地内核直通（跳过 release 内核的下载校验）
ASSERT=0            # --assert：捕获启动日志并断言（无 FATAL/ENOSYS/panic 等）

usage() {
    sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

log() { printf '[smoke] %s\n' "$*" >&2; }
die() { printf '[smoke] 错误: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --tag)        TAG="${2:?--tag 需要值}"; shift 2 ;;
        --backend)    BACKEND="${2:?--backend 需要值}"; shift 2 ;;
        --assets-dir) ASSETS_DIR="${2:?--assets-dir 需要值}"; shift 2 ;;
        --repo)       REPO_SLUG="${2:?--repo 需要值}"; shift 2 ;;
        --no-download) DO_DOWNLOAD=0; shift ;;
        --force-download) FORCE_DOWNLOAD=1; shift ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --loglevel)    LOGLEVEL="${2:?--loglevel 需要值(0-7)}"; shift 2 ;;
        --local-kernel) LOCAL_KERNEL="${2:?--local-kernel 需要值(路径)}"; shift 2 ;;
        --assert)      ASSERT=1; shift ;;
        --proxy)       PROXY_MODE="on"; shift ;;
        --no-proxy)    PROXY_MODE="off"; shift ;;
        alpine|gentoo|all) DISTRO="$1"; shift ;;
        *) die "未知参数: $1（见 --help）" ;;
    esac
done

[ -n "$DISTRO" ] || die "缺少发行版参数（alpine|gentoo|all），见 --help"

# 后端 → 启动函数名。后端名含连字符，不能直接拼进函数名，故在此显式映射。
case "$BACKEND" in
    qemu)             BOOT_FN="boot_qemu" ;;
    cloud-hypervisor) BOOT_FN="boot_ch" ;;
    *) die "未知后端: $BACKEND（支持 qemu | cloud-hypervisor）" ;;
esac

mkdir -p "$ASSETS_DIR"

# cloud-hypervisor 需要 /dev/kvm：对当前用户可写则免 root，否则预取 sudo
# 凭证（避免后续卡在密码提示）
CH_PREFIX=""
if [ "$BACKEND" = "cloud-hypervisor" ]; then
    if [ -w /dev/kvm ]; then
        log "/dev/kvm 可写，cloud-hypervisor 免 root 运行"
    else
        CH_PREFIX="sudo"
        if ! sudo -n true 2>/dev/null; then
            log "cloud-hypervisor 需要 root 权限，请输入密码："
            sudo -v || die "sudo 认证失败"
        fi
    fi
fi

# 代理解析：默认 auto（装了 proxychains 就用于下载），--proxy 强制、--no-proxy 直连
detect_proxy() {
    command -v proxychains4 >/dev/null 2>&1 && { PROXY="proxychains4"; return 0; }
    command -v proxychains  >/dev/null 2>&1 && { PROXY="proxychains";  return 0; }
    return 1
}
case "$PROXY_MODE" in
    on)   detect_proxy || die "未找到 proxychains（Arch: sudo pacman -S proxychains-ng）" ;;
    off)  PROXY="" ;;
    auto) detect_proxy || PROXY="" ;;
esac
[ -n "$PROXY" ] && log "下载走代理: $PROXY"

# 内核 cmdline：与生产同参数（guest 无状态，rootfs 只读；写点已由镜像内
# 符号链接指到 /run）。--loglevel 可选追加，用于压掉 nft warn 级日志对串口的干扰
KCMD="console=ttyS0 root=/dev/vda rootfstype=ext4 ro"
[ -n "$LOGLEVEL" ] && KCMD="${KCMD} loglevel=${LOGLEVEL}"

# ------------------------------------------------------------
# 探测最新 release tag（无 --tag 时）
# ------------------------------------------------------------
# 新前缀 router-vm-* 优先；尚无时回退最新 release（旧格式 tag 的镜像仍是
# 三件套/非无状态，CH --assert 可能失败，仅过渡期可用——尽快触发 CI 出
# router-vm-* 前缀的 release）
latest_tag() {
    local url="https://api.github.com/repos/${REPO_SLUG}/releases?per_page=50"
    local tags
    tags="$($PROXY python3 - "$url" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "smoke-test"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        for rel in json.load(r):
            print(rel.get("tag_name", ""))
except Exception:
    sys.exit(1)
PY
)" || die "探测失败，请用 --tag 显式指定"

    local t
    for t in $tags; do
        case "$t" in
            router-vm-*) printf '%s\n' "$t"; return 0 ;;
        esac
    done

    t="$(printf '%s\n' $tags | head -1)"
    [ -n "$t" ] || die "未取到任何 release，请用 --tag 显式指定"
    log "警告: 尚无 router-vm-* 前缀的 release，回退旧格式 tag $t（旧镜像非无状态，断言可能失败）"
    printf '%s\n' "$t"
}

if [ -z "$TAG" ]; then
    log "探测最新 release tag ..."
    TAG="$(latest_tag)"
fi
BASE="https://github.com/${REPO_SLUG}/releases/download/${TAG}"
log "release: ${TAG}（${BASE}）"
[ -n "$LOCAL_KERNEL" ] && log "本地内核: ${LOCAL_KERNEL}（跳过 release 内核下载与校验；MODULES=n 后 rootfs 无 /lib/modules，本地内核直测无版本耦合）"

# ------------------------------------------------------------
# 下载与校验
# ------------------------------------------------------------
fetch() {
    local url="$1" out="$2"
    log "下载 ${url##*/} ..."
    $PROXY curl -sSLf --retry 3 -o "$out" "$url" || die "下载失败: $url"
}

# SHA256SUMS 路径（判断缓存是否最新的依据）
SUMS="${ASSETS_DIR}/SHA256SUMS"

# 校验：判定规则是「命中同名文件下的任意一条」即可（不要求 sha256sum -c
# 的严格一一对应，兼容历史上 SHA256SUMS 出现重复条目的旧 tag）。
# 返回 0 = 缓存文件的 sha256 命中（已是最新），非 0 = 缺失或过期。
_is_current() {
    local f="$1" h
    [ -f "${ASSETS_DIR}/${f}" ] || return 1
    h="$(sha256sum "${ASSETS_DIR}/${f}" | awk '{print $1}')"
    awk -v n="$f" -v h="$h" '$2==n && $1==h {found=1} END{exit !found}' "$SUMS"
}

# 本次真正要用到的 release 资产（两件套：内核 + rootfs）。
# --local-kernel 时内核不下载不校验（本地产物无对应 release 条目）
_asset_list() {
    local distro="$1"
    [ -n "$LOCAL_KERNEL" ] || printf '%s\n' "vmlinuz-router"
    printf '%s-rootfs.qcow2\n' "$distro"
}

verify() {
    local distro="$1"
    # 始终拉最新 SHA256SUMS，确保校验针对最新 release（而非缓存里的旧 sums）
    fetch "$BASE/SHA256SUMS" "$SUMS"

    local f
    while read -r f; do
        [ -f "${ASSETS_DIR}/${f}" ] || die "缺失 ${ASSETS_DIR}/${f}（去掉 --no-download 或先下载）"
        if _is_current "$f"; then
            log "  ✓ ${f}"
        else
            die "  ✗ ${f}: 校验失败（sha256 不在 release SHA256SUMS 中）"
        fi
    done < <(_asset_list "$distro")
    return 0
}

download() {
    local distro="$1"
    # 始终拉最新 SHA256SUMS（很小），作为判断缓存是否最新的唯一依据
    fetch "$BASE/SHA256SUMS" "$SUMS"

    local f
    while read -r f; do
        if [ "$FORCE_DOWNLOAD" = 1 ]; then
            fetch "$BASE/$f" "${ASSETS_DIR}/${f}"
        elif _is_current "$f"; then
            log "已是最新 ${f}，跳过下载"
        else
            [ -f "${ASSETS_DIR}/${f}" ] && log "缓存过期 ${f}，重新下载"
            fetch "$BASE/$f" "${ASSETS_DIR}/${f}"
        fi
    done < <(_asset_list "$distro")
}

# ------------------------------------------------------------
# 启动（前台，串口直连）
# ------------------------------------------------------------
_kernel_path() {
    if [ -n "$LOCAL_KERNEL" ]; then
        printf '%s' "$LOCAL_KERNEL"
    else
        printf '%s' "${ASSETS_DIR}/vmlinuz-router"
    fi
}

# ------------------------------------------------------------
# 启动日志断言
# ------------------------------------------------------------
# 为什么需要：内核能编译、能启动、服务全 [ ok ]，仍可能静默丢失能力。
# 实测踩过三次，全部因为 allnoconfig 把带 prompt 的符号一律置 n（即使
# Kconfig 写着 default y），而 verify-config.py 只能校验声明过的项：
#   FILE_LOCKING 丢 → openrc 启动时 flock 全部 "Function not implemented"
#   SECCOMP 丢     → sshd 每次连接的 privsep 子进程被自己的沙箱打死
#   RTC_INTF_DEV 丢 → 驱动已绑定但 /dev/rtc0 不存在，hwclock 失败
# 2026-09 裁剪后 MODULES=n（modules 服务与 modprobe 已随 kmod 移除），
# 模块类静默失败通道不复存在；但「片段静默失效」这类风险仍在，
# 启动日志断言 + verify-guest.sh 双防线不变。
_assert_log() {
    local log_file="$1" distro="$2" fails=0
    # ANSI 转义会打断 grep 的模式匹配
    local plain; plain="$(mktemp)"
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$log_file" > "$plain"

    _expect_absent() {
        local pat="$1" why="$2" n
        n="$(grep -ac "$pat" "$plain" || true)"
        if [ "$n" -gt 0 ]; then
            log "  ✗ 出现 ${n} 次「${pat}」—— ${why}"
            grep -a "$pat" "$plain" | head -3 | sed 's/^/      /' >&2
            fails=$((fails + 1))
        else
            log "  ✓ 无「${pat}」"
        fi
    }

    log "启动日志断言（${distro}）..."
    # MODULES=n（2026-09 裁剪）后 guest 内无 modprobe，正常启动不应出现
    # 模块装载输出；保留该断言仅为捕获意外调用模块装载路径的失败
    _expect_absent 'FATAL: Module'          '有模块名解析失败（非 -q 调用方）'
    _expect_absent 'Function not implemented' '内核缺 syscall（如 CONFIG_FILE_LOCKING 未开）'
    # 2026-09：openrc hwclock 服务已从两链删除（CH 无 RTC、必败），启动
    # 日志不应再出现 "Failed to set the system clock"；RTC 驱动链完整性
    # （/dev/rtc0，qemu 路径）由 verify-guest.sh 检查
    _expect_absent 'Failed to set the system clock' 'openrc hwclock 服务残留（应已删除）'
    _expect_absent 'Kernel panic'            '内核 panic'
    _expect_absent 'Unable to mount root'    '根盘挂载失败（virtio_blk/ext4 未 builtin 且无 initrd）'
    _expect_absent 'Read-only file system'   'ro 写点漏处理（有服务写 rootfs 失败）'

    # 正向断言：必须真的走完启动
    if grep -aq 'login:' "$plain"; then
        log "  ✓ 到达登录提示"
    else
        log "  ✗ 未到达登录提示（启动未完成）"
        fails=$((fails + 1))
    fi

    rm -f "$plain"
    [ "$fails" -eq 0 ] || return 1
}

boot_qemu() {
    local distro="$1"
    command -v qemu-system-x86_64 >/dev/null 2>&1 || \
        die "未找到 qemu-system-x86_64（Arch: sudo pacman -S qemu-base）"
    log "qemu 启动 ${distro}（ro 根盘与生产同参；串口直连 ttyS0；退出按 Ctrl-A 然后 X）"
    # readonly=on 与生产 --disk readonly=on 对齐：否则 openrc root 服务会按
    # fstab 把 / remount 成 rw，ro 验证失真且污染缓存镜像（替代旧 -snapshot）
    qemu-system-x86_64 -m 256 -smp 2 \
        -kernel "$(_kernel_path)" \
        -append "$KCMD" \
        -drive "file=${ASSETS_DIR}/${distro}-rootfs.qcow2,format=qcow2,if=virtio,readonly=on" \
        -netdev user,id=wan -device virtio-net-pci,netdev=wan,mac=02:00:00:01:00:01 \
        -netdev user,id=lan -device virtio-net-pci,netdev=lan,mac=02:00:00:01:00:02 \
        -nographic
}

boot_ch() {
    local distro="$1"
    # AUR 的 cloud-hypervisor-bin 只装 cloud-hypervisor-static（无 cloud-hypervisor 主名）
    local ch; ch="$(command -v cloud-hypervisor 2>/dev/null || command -v cloud-hypervisor-static 2>/dev/null)"
    [ -n "$ch" ] || die "未找到 cloud-hypervisor（Arch AUR: paru -S cloud-hypervisor-bin）"

    # CH 无 qemu 的 -snapshot 等价物，先复制到临时文件再启动，避免污染缓存镜像
    # （与生产 disk-prep 先复制到只读副本同一思路）
    local img="${ASSETS_DIR}/${distro}-rootfs.qcow2"
    local scratch; scratch="$(mktemp --suffix=.qcow2)" || die "创建临时镜像失败"
    log "复制镜像到临时文件（避免污染缓存）..."
    cp "$img" "$scratch"
    # 注：CH 把终端置 raw 模式透传串口输入，Ctrl+C 会作为字节发进 guest
    # 而非 SIGINT 给 CH。guest 内 poweroff/halt 也退不出 VMM（实测：ACPI
    # S5 无仿真 → init 存活重拉 getty；halt → guest 冻结但 CH 不响应
    # KVM 关机退出）。退出方式（另开终端）：
    #   ch-remote --api-socket /tmp/router-vm-smoke.sock shutdown-vmm
    #   （或 pkill -f cloud-hypervisor）。交互验证首选 qemu 路径（Ctrl-A X）。
    local api_sock="/tmp/router-vm-smoke.sock"
    rm -f "$api_sock"
    log "cloud-hypervisor 启动 ${distro}（与生产同参数；串口直连 ttyS0；退出：另开终端 ch-remote --api-socket $api_sock shutdown-vmm）"
    $CH_PREFIX "$ch" \
        --kernel "$(_kernel_path)" \
        --cmdline "$KCMD" \
        --disk "path=$scratch,readonly=on,image_type=qcow2" \
        --cpus boot=2 \
        --memory size=256M \
        --serial tty \
        --console off \
        --api-socket "$api_sock"
    local rc=$?
    rm -f "$scratch"
    return $rc
}

# CH 路径的 --assert：非交互断言。重定向下 --serial tty 不可用（无控制终端），
# 改为与生产同款 --serial file 落盘日志：后台启动 → 轮询日志至 login: 或
# 超时（120s）或 CH 提前退出 → 强制清理（断言只关心能不能到 login，
# 不依赖 guest 优雅关机）→ 日志交给 _assert_log。
boot_ch_assert() {
    local distro="$1" blog="$2"
    local ch; ch="$(command -v cloud-hypervisor 2>/dev/null || command -v cloud-hypervisor-static 2>/dev/null)"
    [ -n "$ch" ] || die "未找到 cloud-hypervisor（Arch AUR: paru -S cloud-hypervisor-bin）"

    local img="${ASSETS_DIR}/${distro}-rootfs.qcow2"
    local scratch; scratch="$(mktemp --suffix=.qcow2)" || die "创建临时镜像失败"
    cp "$img" "$scratch"

    # 先清空日志：轮询以 login: 为终止条件，上次运行残留的旧日志会立即
    # 命中造成假阳性（CH 随后 O_TRUNC 打开，日志被清空且未重新写入）
    rm -f "$blog"

    log "cloud-hypervisor 后台启动 ${distro}（--serial file=${blog#$REPO_ROOT/}）"
    $CH_PREFIX "$ch" \
        --kernel "$(_kernel_path)" \
        --cmdline "$KCMD" \
        --disk "path=$scratch,readonly=on,image_type=qcow2" \
        --cpus boot=2 \
        --memory size=256M \
        --serial "file=$blog" \
        --console off &
    local ch_pid=$!

    # 轮询日志至 login: / 超时 / CH 提前退出
    local deadline=$(( $(date +%s) + 120 ))
    local reached=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$blog" ] && grep -aq 'login:' "$blog" 2>/dev/null; then
            reached=1; break
        fi
        kill -0 "$ch_pid" 2>/dev/null || break
        sleep 2
    done

    # 强制清理：kill CH 本体（sudo 进程被杀会遗留孤儿，用 scratch 路径精确定位）
    $CH_PREFIX pkill -f "$scratch" 2>/dev/null || true
    wait "$ch_pid" 2>/dev/null || true
    rm -f "$scratch"

    if [ "$reached" = 1 ]; then
        log "${distro} 到达 login（${blog#$REPO_ROOT/}）"
        return 0
    fi
    log "${distro} 未到达 login（超时或提前退出，日志见 ${blog#$REPO_ROOT/}）"
    return 1
}

# qemu 路径的 --assert：后台运行（-nographic 串口走 stdio，重定向落日志），
# 轮询 login: 或超时（90s）/提前退出后强制清理。交互验证归无 --assert 的
# 串口直连模式。
boot_qemu_assert() {
    local distro="$1" blog="$2"
    command -v qemu-system-x86_64 >/dev/null 2>&1 || \
        die "未找到 qemu-system-x86_64（Arch: sudo pacman -S qemu-base）"
    log "qemu 后台启动 ${distro}（-nographic 串口落日志）"
    qemu-system-x86_64 -m 256 -smp 2 \
        -kernel "$(_kernel_path)" \
        -append "$KCMD" \
        -drive "file=${ASSETS_DIR}/${distro}-rootfs.qcow2,format=qcow2,if=virtio,readonly=on" \
        -netdev user,id=wan -device virtio-net-pci,netdev=wan,mac=02:00:00:01:00:01 \
        -netdev user,id=lan -device virtio-net-pci,netdev=lan,mac=02:00:00:01:00:02 \
        -nographic > "$blog" 2>&1 &
    local qpid=$!

    local deadline=$(( $(date +%s) + 90 ))
    local reached=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if grep -aq 'login:' "$blog" 2>/dev/null; then reached=1; break; fi
        kill -0 "$qpid" 2>/dev/null || break
        sleep 2
    done

    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    if [ "$reached" = 1 ]; then
        log "${distro} 到达 login（${blog#$REPO_ROOT/}）"
        return 0
    fi
    log "${distro} 未到达 login（超时或提前退出，日志见 ${blog#$REPO_ROOT/}）"
    return 1
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
main() {
    local distros
    if [ "$DISTRO" = "all" ]; then distros="alpine gentoo"; else distros="$DISTRO"; fi

    # 阶段一：下载 + 校验（两件套共用，只下一次）
    for d in $distros; do
        [ "$DO_DOWNLOAD" = 1 ] && download "$d"
        log "校验 ${d} 资产 ..."
        verify "$d"
    done

    [ "$VERIFY_ONLY" = 1 ] && { log "校验全部通过，跳过启动。"; exit 0; }

    # 阶段二：逐个启动
    local assert_fails=0
    for d in $distros; do
        log "========== 启动 ${d}（登录 root/root；验证 rc-status、nft list ruleset）=========="
        local blog="${ASSETS_DIR}/boot-${d}.log"
        set +e
        if [ "$ASSERT" = 1 ]; then
            if [ "$BACKEND" = "cloud-hypervisor" ]; then
                # CH 断言：非交互（--serial file 落日志），到达 login 即停
                boot_ch_assert "$d" "$blog"
                local rc=$?
            else
                # qemu 断言：后台 + 重定向落日志，到达 login 即停
                boot_qemu_assert "$d" "$blog"
                local rc=$?
            fi
        else
            # 交互模式：函数直接调用（不能经外部命令包装，timeout 会失去函数可见性）
            "$BOOT_FN" "$d"
            local rc=$?
        fi
        set -e
        log "${d} 退出（rc=$rc）"
        [ "$rc" -eq 0 ] || log "提示: rc=$rc 可能是 qemu Ctrl-A X / CH 侧 pkill 的正常退出，非镜像问题。"

        if [ "$ASSERT" = 1 ]; then
            set +e
            _assert_log "$blog" "$d"
            local arc=$?
            set -e
            [ "$arc" -eq 0 ] || assert_fails=$((assert_fails + 1))
            log "启动日志: ${blog#$REPO_ROOT/}"
        fi
    done

    if [ "$assert_fails" -gt 0 ]; then
        die "${assert_fails} 个发行版的启动日志断言未通过"
    fi
}

main "$@"
