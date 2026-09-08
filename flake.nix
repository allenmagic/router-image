# router-image flake
#
# 提供 nixosModules.router：路由 VM 消费端声明模块（cloud-hypervisor 直管：
# 镜像 fetchurl + systemd 单元 + rootfs 只读副本 + tap 挂桥 + deploy 注入）。
# 镜像 release 的 tag 与各资产 sha256 硬编码在模块内（与本仓库 CI 同源），
# 消费端升级只需 nix flake update。
{
  description = "Router VM image production + NixOS consumption module (alpine/gentoo dual-distro)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      # 宿主侧测试配置（在 NixOS VM 内运行 router VM，验收见
      # docs/verify-on-nixos.md）
      testNixosHost = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./nixos-modules/router.nix
          ./test-nixos-host.nix
        ];
      };
    in {
    # 消费端模块：qnap-nixos-nas 等宿主引用
    #   imports = [ inputs.router-image.nixosModules.router ];
    #   services.router-vm.enable = true;
    nixosModules.router = import ./nixos-modules/router.nix;

    # NixOS 宿主测试（可以在非 NixOS 上构建 VM 验证模块）
    nixosConfigurations.test-nixos-host = testNixosHost;
  };
}
