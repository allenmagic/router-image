# ============================================================
# router.nix 子模块 —— release 资产声明与派生
#
# image/sync-flake-sha.py 的锚定目标：CI 出 release 后自动同步本文件的
# imageRelease 与各资产 sha256（新增发行版时在 osAssets 加一行即可）。
# fetchurl 派生（kernelImage/rootfsImage/imgId/rootfsCopy/deployPkg）
# 经 internal option（_assets）供 vm-service.nix / deploy.nix 共享——
# 跨模块共享的单一来源。
# ============================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.router-vm;
in
{
  options.services.router-vm._assets = lib.mkOption {
    type = lib.types.attrs;
    internal = true;
    readOnly = true;
    default = { };
    description = ''
      内部：release 资产声明与派生（fetchurl 结果、内容哈希路径、deploy 包）。
      由本文件定义，vm-service.nix 与 deploy.nix 读取。
    '';
  };

  config = lib.mkIf cfg.enable {
    services.router-vm._assets =
      let
        # 本仓库 CI release（sync-flake-sha.py 在每次 release 后自动同步 tag
        # 与 sha256；首次新前缀 release 前 sha256 为占位 0，fetchurl 会失败
        # 并显示真实值，release 触发后 CI 自动回填）
        imageRelease = "router-vm-20260908";
        releaseBase = "https://github.com/allenmagic/router-image/releases/download/${imageRelease}";

        # rootfs 资产表（按发行版；vmlinuz-router 是发行版无关的共享内核资产）。
        # 新发行版构建链就绪后在此加一行即可（SHA256SUMS 会多出对应条目）。
        osAssets = {
          alpine = {
            url = "${releaseBase}/alpine-rootfs.qcow2";
            sha256 = "9dfad6ad84010411089289b8fc06f4ac3a08dd9b13fb7648c317df2a15cf3337";
          };
          gentoo = {
            url = "${releaseBase}/gentoo-rootfs.qcow2";
            sha256 = "7db91809eff91e767bef1660dbb9a266cba366e15c25b71740c85a855148e85d";
          };
        };

        # 内核资产：自建 vmlinuz-router（全 builtin、无 initramfs，CH 按文件头
        # 识别 bzImage 直接引导）。资产名不带版本：LTS bump 只改 sha256
        # （sync-flake-sha.py 自动完成），release tag 承担版本区分。
        kernel = {
          url = "${releaseBase}/vmlinuz-router";
          sha256 = "5c2a3b934b0d8141ef22b0b3632b38ad775e4dae955e9605399d7fd38dbf1ce2";
        };

        kernelImage = pkgs.fetchurl kernel;
        rootfsImage = pkgs.fetchurl (osAssets.${cfg.os});

        # rootfs 只读副本路径含内容哈希：镜像更新 → 路径变 → ExecStart 变 →
        # VM 必然重启；旧镜像文件保留，rollback 时旧 generation 直接指向旧镜像
        imgId = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toString rootfsImage));
        rootfsCopy = "/var/lib/router-vm/rootfs-${imgId}.qcow2";

        # deploy 注入器资产（install.sh + lib/secrets.sh 打包；密钥绝不在此内）
        deployPkg = pkgs.runCommand "router-vm-deploy.tar.gz" { } ''
          tar czf $out -C ${../deploy-assets} .
        '';
      in
      {
        inherit kernelImage rootfsImage imgId rootfsCopy deployPkg;
      };
  };
}
