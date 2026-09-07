#!/usr/bin/env bash
# rootfs 装配（须以 root 或 fakeroot 环境执行——tar 内 uid 0 属主必须保留，
# 否则镜像里 /var/empty 归属错误，sshd 的 chroot 目录校验会拒绝启动）
#
# 重构后：不再有 Alpine 三件套（vmlinuz-virt/initrd/modloop）——
# 引导链全部由自建内核 builtin 承担，本脚本只做：
#   rootfs 提取 → getty → ext4
# （2026-09 裁剪后连模块元数据注入也不再需要：MODULES=n，guest 内
# 已无 kmod/openrc modules 服务，/lib/modules 目录不复存在）
set -euo pipefail

ROOTFS_TARBALL="$1"
OUT_EXT4="$2"
DISTRO="${3:-alpine}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

mkdir -p rootfs
tar xf "$ROOTFS_TARBALL" -C rootfs --numeric-owner

# 启用 ttyS0 getty（setup.sh 对默认串口通常已追加；此 sed 是给
# "出厂只有注释行"的场景兜底——仅当无任何激活串口行时才反注释，
# 避免与 setup.sh 的追加行叠加成双 getty，2026-09 修复）
grep -qE '^ttyS[0-9]' rootfs/etc/inittab 2>/dev/null \
    || sed -i 's|^#ttyS0:|ttyS0:|' rootfs/etc/inittab

# ============================================================
# mkfs.ext4（512M 稀疏 → qcow2 compact 后 ≈ 实际内容大小）
# rootfs 只读且内容在构建期定型，容量不会运行期增长——512M 约为
# gentoo（双链中较大者）实际占用的 2 倍，留构建余量即可。
# 未来镜像内容增长时调大此行。
# ============================================================
truncate -s 512M "$OUT_EXT4"
mkfs.ext4 -q -F -L "${DISTRO}-rootfs" -d rootfs "$OUT_EXT4"
echo "[assemble-rootfs] 完成"
