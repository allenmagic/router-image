# Router VM 消费端声明模块（cloud-hypervisor 直管，不依赖 microvm.nix）
#
# 由旧 microvm.router 模块重写（2026-09-02，方案见 docs/refactor-proposal.md）。
# 镜像生产与消费同仓库：CI 出 release 时用 image/sync-flake-sha.py 自动同步
# 资产声明的 tag 与各资产 sha256（锚定 assets.nix），宿主侧升级只需
# nix flake update。
#
# 用法：
#   imports = [ inputs.router-image.nixosModules.router ];
#   services.router-vm = {
#     enable = true;
#     cpu = 2;                # 隔离给 VM 独占的宿主核（isolcpus + vcpu0 affinity）
#     os = "alpine";          # rootfs 发行版（alpine | gentoo）
#     stateDisk = { };        # 可选：持久身份（SSH host key + tailscale 节点）
#   };
#
# 架构（相对旧 microvm.router 的差异）：
#   - 不依赖 microvm.nix：systemd 单元直接 ExecStart cloud-hypervisor，
#     tap 创建/挂桥、balloon、优雅关机全部自管
#   - 内核唯一：自建 vmlinuz-router（引导链全 builtin，无 initramfs）
#   - guest 无状态 + 身份可持久：rootfs 只读挂载（--disk readonly=on），
#     密钥由宿主 sops-nix 管理、deploy 注入 /run（易失，绝不落盘）；
#     身份（host key / tailscale 节点）可选经 stateDisk 持久到宿主磁盘
#   - 状态目录：/var/lib/router-vm/rootfs-<内容哈希>.qcow2 —— rootfs 的只读
#     副本。镜像升级 → 哈希路径变化 → ExecStart 变化 → systemd 自动重启 VM；
#     旧副本保留供 rollback 复用，可手动清理
#   - 串口落盘 /run/router-vm/console.log：网络故障时的恢复通道
#     （router-vm-console 查看），getty 仍在 guest 的 ttyS0 上
#
# 本文件只定义公开 options 与聚合子模块；实现按职责拆分：
#   assets.nix      资产声明与派生（sync-flake-sha.py 锚定目标）
#   vm-service.nix  networkd 挂桥 + router-vm.service（CH 直管）
#   deploy.nix      密钥注入守护 + 手工命令（router-vm-deploy/shell/console）
{ config, lib, pkgs, ... }:

{
  imports = [
    ./assets.nix
    ./vm-service.nix
    ./deploy.nix
  ];

  options.services.router-vm = {
    enable = lib.mkEnableOption "Router VM（cloud-hypervisor 直管，与 libvirt 方案二选一）";

    os = lib.mkOption {
      type = lib.types.enum [ "alpine" "gentoo" ];
      default = "alpine";
      description = ''
        rootfs 发行版（选择对应的 release 资产 <distro>-rootfs.qcow2；
        内核是发行版无关的共享资产 vmlinuz-router）。
      '';
    };

    cpu = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        隔离给路由器 VM 独占的宿主核号（isolcpus + vcpu0 affinity）。
        默认 0（所有机器都有此核，最通用）。
        注意：isolcpus 影响整个宿主，核号必须真实存在。
      '';
    };

    vcpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        vCPU 总数：vcpu0 独占隔离核（affinity pin 到 `cpu`），
        其余 vCPU 由宿主调度器在非隔离核上动态调度。
      '';
    };

    mem = lib.mkOption {
      type = lib.types.ints.positive;
      # 2026-09 实测：全量服务（tailscaled+cloudflared+隧道）工作集 ~170MB
      # 加 page cache。生产决策沿用 256M（余量 ~80M，balloon 默认关闭避免
      # 进一步挤压；曾提默认 512M 后按真实验收回落）。宿主内存吃紧时优先
      # 走宿主侧回收/降 balloon 路径，而非默认涨 guest 上限。
      default = 256;
      description = "guest 内存上限（MB）";
    };

    initialBalloonMem = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        初始 balloon 充气量（MB，CH 要求 128M 对齐）。0 = 不启用 balloon
        （默认）。

        注意语义：size 是「启动即充气」的量，guest 可用内存 = mem - size。
        全量服务（含 tailscaled/cloudflared）约需 130-160MB，256MB 总容量
        下默认充气 128M 会把可用压到 128MB、踩 OOM 线（deflate_on_oom 能
        放气救场但 OOM killer 往往先动手）。宿主侧「OOM 时充气回收」的
        方向本模块未实现——将来实现宿主侧内存回收时再恢复非零默认值。
      '';
    };

    wanBridge = lib.mkOption {
      type = lib.types.str;
      default = "br-wan";
      description = "WAN 侧宿主网桥（tap 创建后 networkd 自动挂入）";
    };

    lanBridge = lib.mkOption {
      type = lib.types.str;
      default = "br-lan";
      description = "LAN 侧宿主网桥（tap 创建后 networkd 自动挂入）";
    };

    vmIp = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.1";
      description = "VM LAN 口 IP（deploy 脚本的 ssh 目标）。与 guest 的 network.env 和宿主网桥配置保持一致。";
    };

    secretsDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets";
      description = ''
        宿主密钥目录（sops-nix 的默认解密落点）。router-vm-deploy 在每次
        VM 启动后从这里读取以下文件注入 guest（缺文件则跳过对应注入）：
          ssh-public-key / tailscale-auth-key / headscale-auth-key / cloudflared-token
      '';
    };

    stateDisk = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options.sizeMB = lib.mkOption {
          type = lib.types.ints.positive;
          default = 64;
          description = ''
            状态盘大小（MB）。内容 = SSH host key + authorized_keys +
            两个 tailscale 实例的 tailscaled.state（各 ~100K），64M 绰绰有余。
          '';
        };
      });
      default = null;
      description = ''
        持久状态盘（可选）。启用后 guest 的 SSH host key、authorized_keys
        与两个 tailscale 实例（官方 tailscale0 + headscale ts0）的节点身份
        落宿主磁盘 /var/lib/router-vm/state.raw（第二块 virtio-blk），VM
        重启后复用——官方 Tailscale 免重复 approve、节点身份/IP 固定。

        null（默认）= 不启用：全部易失（/run tmpfs），每次重启新 host key、
        新节点重新注册（auth key 需 reusable + ephemeral）。

        删除 state.raw = 重置 guest 全部持久身份（下轮 boot 重新生成）。
        注意：持久化的是身份文件，密钥（authkey/cloudflared token）仍只
        经 deploy 注入 /run，绝不落盘。
      '';
    };
  };
}
