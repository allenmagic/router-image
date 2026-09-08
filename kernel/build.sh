#!/usr/bin/env bash
# ============================================================
# 路由 VM 专用内核构建（x86_64 / cloud-hypervisor guest）
#
# 本内核是路由 VM 的唯一内核（重构后不再有 Alpine 官方 virt 变体）：
#   - 引导链全 builtin（ext4/virtio_blk/virtio_net…）→ 无需 initramfs，
#     cloud-hypervisor 直接 --kernel 引导（kernel + rootfs 两件套）
#   - MODULES=n：0 个 .ko、无 /lib/modules 元数据，rootfs 侧已同步移除
#     kmod 包与 openrc modules 服务（2026-09 裁剪审计）
#   - 同时产出 bzImage 与 vmlinux（ELF）：CH 按文件头识别 bzImage；
#     vmlinux 是将来切 PVH 的零成本后路（它本就是 bzImage 的前置产物），
#     故构建但不发布
#
# 版本策略：只跟最新 LTS（路由器要的是不断网，而非新特性；LTS 只收 backport
# 修复，回归面窄）。bump 时同步改 KVER 与 SRC_SHA256，CI 会重建配套 rootfs。
#
# 用法:
#   kernel/build.sh                       # 完整构建到 kernel/out/
#   kernel/build.sh --config-only         # 只生成并校验 .config（CI 快速门禁）
#   KVER=6.18.48 kernel/build.sh          # 覆盖版本
#   JOBS=8 kernel/build.sh                # 覆盖并行度
#
# 依赖: gcc make bc bison flex libelf openssl(dev) perl xz curl
# ============================================================
set -euo pipefail

KVER="${KVER:-6.18.50}"
JOBS="${JOBS:-$(nproc)}"
CONFIG_ONLY=0
[ "${1:-}" = "--config-only" ] && CONFIG_ONLY=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="$SCRIPT_DIR/config.fragment"
OUT_DIR="$SCRIPT_DIR/out"
CACHE_DIR="${KERNEL_CACHE_DIR:-$SCRIPT_DIR/.cache}"

# 源码校验和：升级 KVER 时同步更新（值取自 kernel.org 的 sha256sums.asc）
declare -A SRC_SHA256=(
    [6.18.48]="5ebdadb10a4b5708fc6b1c457764a110bc49f8150cc3502c59b921ead8c6fc8c"
    [6.18.50]="d2fc041dab4e11d9645e3ba53be058faa52b8ce28a8a97c889bb2cacee170461"
)

log() { printf '[kernel] %s\n' "$*" >&2; }
die() { printf '[kernel] 错误: %s\n' "$*" >&2; exit 1; }

MAJOR="v${KVER%%.*}.x"
TARBALL="linux-${KVER}.tar.xz"
SRC_DIR="$CACHE_DIR/linux-${KVER}"

# ---------- 1. 取源码 ----------
mkdir -p "$CACHE_DIR"
if [ ! -d "$SRC_DIR" ]; then
    if [ ! -f "$CACHE_DIR/$TARBALL" ]; then
        log "下载 $TARBALL ..."
        # 镜像优先（国内可用），失败回落 kernel.org
        for base in \
            "https://mirrors.ustc.edu.cn/kernel.org/linux/kernel/$MAJOR" \
            "https://mirrors.tuna.tsinghua.edu.cn/kernel/$MAJOR" \
            "https://cdn.kernel.org/pub/linux/kernel/$MAJOR"
        do
            if curl -fsSL --max-time 900 -o "$CACHE_DIR/$TARBALL.part" "$base/$TARBALL"; then
                mv "$CACHE_DIR/$TARBALL.part" "$CACHE_DIR/$TARBALL"
                log "下载完成（源: $base）"
                break
            fi
            log "镜像失败，尝试下一个: $base"
        done
        [ -f "$CACHE_DIR/$TARBALL" ] || die "所有镜像均下载失败"
    fi

    # 校验（未登记版本时打印实际值供登记，不静默通过）
    want="${SRC_SHA256[$KVER]:-}"
    got="$(sha256sum "$CACHE_DIR/$TARBALL" | cut -d' ' -f1)"
    if [ -z "$want" ]; then
        die "KVER=$KVER 未登记 sha256。实际值: $got（登记到 build.sh 的 SRC_SHA256 后重试）"
    fi
    [ "$want" = "$got" ] || die "源码 sha256 不符：期望 $want，实际 $got"
    log "源码校验通过"

    log "解压 ..."
    mkdir -p "$SRC_DIR"
    tar xf "$CACHE_DIR/$TARBALL" -C "$SRC_DIR" --strip-components=1
fi

# ---------- 2. 生成 .config 并逐条校验片段生效 ----------
BUILD_DIR="$CACHE_DIR/build-${KVER}"
mkdir -p "$BUILD_DIR"

log "生成 .config（allnoconfig + 片段）..."
# allnoconfig：片段外一律 n；再 olddefconfig 补齐 select 出来的新符号默认值
KCONFIG_ALLCONFIG="$FRAGMENT" make -C "$SRC_DIR" O="$BUILD_DIR" allnoconfig >/dev/null
make -C "$SRC_DIR" O="$BUILD_DIR" olddefconfig >/dev/null

# 片段静默失效 = 能编译但不可引导（曾漏掉 BLK_DEV → 无 virtio_blk → 无根盘）
log "校验片段生效 ..."
python3 "$SCRIPT_DIR/verify-config.py" "$FRAGMENT" "$BUILD_DIR/.config" \
    || die "config 片段校验失败（见上方清单）"

if [ "$CONFIG_ONLY" -eq 1 ]; then
    log "--config-only：已生成并校验 $BUILD_DIR/.config"
    exit 0
fi

# ---------- 3. 编译 ----------
log "编译（-j$JOBS）..."
make -C "$SRC_DIR" O="$BUILD_DIR" -j"$JOBS" bzImage vmlinux

# ---------- 4. 产物 ----------
# 产物名不带版本。内核只有一个变体（跟最新 LTS），而 release tag
# （router-vm-YYYYMMDD）已经承担了版本区分——把内核版本写进资产名
# 会让每次 point release bump 都要手改 router.nix 的 url，
# sync-flake-sha.py 的锚定正则也会失配。版本可从 config-router 内容与
# guest 的 uname -r 查得。
KREL="$(make -C "$SRC_DIR" O="$BUILD_DIR" -s kernelrelease)"
log "内核版本串: $KREL"

mkdir -p "$OUT_DIR"
# MODULES=n 后已不产模块元数据；清掉旧构建残留（裁剪审计前的 out/modules）
rm -rf "$OUT_DIR/modules"
cp "$BUILD_DIR/arch/x86/boot/bzImage" "$OUT_DIR/vmlinuz-router"
cp "$BUILD_DIR/vmlinux" "$OUT_DIR/vmlinux-router"
cp "$BUILD_DIR/.config" "$OUT_DIR/config-router"

# ---------- 5. 校验和 ----------
# vmlinux 不入 SHA256SUMS：当前 CH 走 bzImage 路径不消费它，它只是将来切 PVH
# 的后路与宿主侧 gdb/crash 的符号来源，无需作为 release 资产发布
(cd "$OUT_DIR" && sha256sum vmlinuz-router config-router > SHA256SUMS)

log "完成："
ls -la "$OUT_DIR"
log "bzImage: $(du -h "$OUT_DIR/vmlinuz-router" | cut -f1)"
