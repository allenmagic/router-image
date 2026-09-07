# NixOS 宿主配置示例：用 cloud-hypervisor 运行 router-image 的路由 VM
#
# 集成方式（qnap-nixos-nas 等宿主）：
#   flake:   inputs.router-image.url = "github:allenmagic/router-image";
#   模块:    imports = [ inputs.router-image.nixosModules.router ];
#   启用:    services.router-vm.enable = true;
#   （本地 checkout 测试时也可直接 import ./nixos-modules/router.nix）
#
# 本文件同时给出三个必备的宿主侧配置：
#   1. br-wan / br-lan 网桥（tap 由模块 preStart 创建并自动挂入）
#   2. services.router-vm（核隔离 / balloon / 镜像 fetchurl）
#   3. sops-nix 密钥（解密到 /run/secrets，每次 VM 启动后自动注入 guest）
#
# 前置：宿主 CPU 需开启虚拟化（/dev/kvm 可用），物理网口名按实际修改。
{ config, pkgs, ... }:

{
  imports = [
    ./nixos-modules/router.nix
    # 生产环境改用 flake 集成：inputs.router-image.nixosModules.router
  ];

  # ============================================================
  # 网络：br-wan / br-lan 宿主网桥
  # ============================================================
  networking.useNetworkd = true;
  systemd.network = {
    enable = true;

    # WAN 桥：上游连接（DHCP 或按需改静态）
    netdevs."10-br-wan" = {
      netdevConfig = { Name = "br-wan"; Kind = "bridge"; };
    };
    networks."10-br-wan" = {
      matchConfig.Name = "br-wan";
      networkConfig.DHCP = "yes";
      linkConfig.RequiredForOnline = "routable";
    };
    networks."20-wan-uplink" = {
      matchConfig.Name = "enp1s0";   # ← 替换为你的 WAN 物理网口
      networkConfig.Bridge = "br-wan";
      linkConfig.RequiredForOnline = "enslaved";
    };

    # LAN 桥：下游设备 + VM 管理口（宿主管理 IP 与 vmIp 同网段）
    netdevs."10-br-lan" = {
      netdevConfig = { Name = "br-lan"; Kind = "bridge"; };
    };
    networks."10-br-lan" = {
      matchConfig.Name = "br-lan";
      address = [ "192.168.10.254/24" ];
      linkConfig.RequiredForOnline = "no";
    };
    networks."20-lan-downlink" = {
      matchConfig.Name = "enp2s0";   # ← 替换为你的 LAN 物理网口（无则删本段）
      networkConfig.Bridge = "br-lan";
      linkConfig.RequiredForOnline = "enslaved";
    };
  };

  # ============================================================
  # 路由 VM（cloud-hypervisor 直管）
  # ============================================================
  services.router-vm = {
    enable = true;
    os = "alpine";                 # alpine | gentoo

    cpu = 2;                       # 隔离给 VM 独占的宿主核（isolcpus）
    vcpus = 2;                     # vcpu0 绑 `cpu`，其余动态调度
    mem = 256;                     # guest 内存上限（MB，默认 256）
    initialBalloonMem = 0;         # 默认不充气（充气会从 mem 扣可用内存；宿主侧回收未实现）

    wanBridge = "br-wan";
    lanBridge = "br-lan";
    vmIp = "192.168.10.1";         # VM LAN 口 IP（deploy 的 ssh 目标）

    secretsDir = "/run/secrets";   # sops-nix 默认解密落点，一般不用改
  };

  # ============================================================
  # 密钥（sops-nix）：加密进 git，激活时解密到 /run/secrets。
  # router-vm-deploy 在每次 VM 启动后自动 scp 注入 guest（guest 无
  # 状态，重启即清、重新注入，操作者无感知）。
  #
  # secrets.yaml 内容示例：
  #   ssh-public-key: |
  #     ssh-ed25519 AAAA... deploy-key
  #   tailscale-auth-key: tskey-auth-xxxxxxxxxxxxxxxx
  #   cloudflared-token: eyJhIjoi...
  #
  # Tailscale 自动登录：注入后 deploy 内后台 tailscale up（key 须 reusable，
  # 建议 Ephemeral；审批在 admin 侧）。确认：ssh root@192.168.10.1 'tailscale status'
  # ============================================================
  # sops.secrets."ssh-public-key" = { sopsFile = ./secrets.yaml; };
  # sops.secrets."tailscale-auth-key" = { sopsFile = ./secrets.yaml; };
  # sops.secrets."cloudflared-token" = { sopsFile = ./secrets.yaml; };

  # ============================================================
  # 防火墙：LAN 侧放行（deploy 通道经 br-lan 到 VM）
  # ============================================================
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "br-lan" ];
  };

  # 宿主也需要转发时（一般由 guest 承担，此处在 guest 起不来时兜底）
  # boot.kernel.sysctl = {
  #   "net.ipv4.ip_forward" = 1;
  #   "net.ipv6.conf.all.forwarding" = 1;
  # };
}
