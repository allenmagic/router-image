# ============================================================
# router.nix 子模块 —— VM 本体（networkd 挂桥 + router-vm.service）
#
# cloud-hypervisor 直管：preStart 准备 rootfs 只读副本（原子落位）与
# 可选持久状态盘（stateDisk），创建 tap；ExecStart 启动 CH；优雅关机
# 走 api-socket。资产派生读自 assets.nix 的 _assets。
# ============================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.router-vm;
  assets = cfg._assets;
in
{
  config = lib.mkIf cfg.enable {
    # ---- CPU 独占：指定核隔离给路由器 VM（宿主调度器不再使用该核） ----
    boot.kernelParams = [ "isolcpus=${toString cfg.cpu}" "rcu_nocbs=${toString cfg.cpu}" ];

    # ---- 网络：tap 由 router-vm.service 的 preStart 创建，networkd 在
    #      tap 出现时自动挂入对应桥（CH 无 qemu 的 bridge 接口类型） ----
    systemd.network.networks = {
      "50-router-wan" = {
        matchConfig.Name = "router-wan";
        networkConfig.Bridge = cfg.wanBridge;
      };
      "50-router-lan" = {
        matchConfig.Name = "router-lan";
        networkConfig.Bridge = cfg.lanBridge;
      };
    };

    # ---- VM 本体 ----
    systemd.services.router-vm = {
      description = "Router VM (cloud-hypervisor)";
      after = [ "network.target" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iproute2 pkgs.coreutils pkgs.e2fsprogs ];

      preStart = ''
        mkdir -p /var/lib/router-vm /run/router-vm

        # rootfs 只读副本（幂等；ExecStart 引用含哈希路径，升级时 systemd
        # 检测 ExecStart 变化自动重启 VM）。原子落位：先写临时文件再 mv——
        # 直写最终路径时拷贝中断（磁盘满/系统崩溃）会留下损坏副本，且
        # [ ! -f ] 从此永远跳过重拷，VM 用坏镜像起不来 + Restart=on-failure
        # 无限循环、无自愈路径
        if [ ! -f "${assets.rootfsCopy}" ]; then
          _tmp="${assets.rootfsCopy}.tmp.$$"
          install -m 0644 "${assets.rootfsImage}" "$_tmp"
          # 完整性：字节数与原镜像一致才算拷完（qcow2 无内嵌校验和；
          # 同主机拷贝，size 校验已能拦下磁盘满/中断等绝大多数场景）
          if [ "$(stat -c %s "$_tmp")" != "$(stat -c %s "${assets.rootfsImage}")" ]; then
            rm -f "$_tmp"
            exit 1
          fi
          mv "$_tmp" "${assets.rootfsCopy}"
        fi
        rm -f "${assets.rootfsCopy}".tmp.*  # 清理历史中断残留（$$ 已变，不会误删在用的）

        # 持久状态盘（可选，stateDisk != null）：guest 的 SSH host key /
        # authorized_keys / 两个 tailscale 实例的节点身份落宿主磁盘，
        # VM 重启后复用（官方 Tailscale 免重复 approve、身份固定）。
        # 首次创建 + mkfs，此后复用；删除 state.raw = 重置全部身份
        ${lib.optionalString (cfg.stateDisk != null) ''
          if [ ! -f /var/lib/router-vm/state.raw ]; then
            truncate -s ${toString cfg.stateDisk.sizeMB}M /var/lib/router-vm/state.raw
            mkfs.ext4 -q -F /var/lib/router-vm/state.raw
          fi
        ''}

        # tap 创建（挂桥由 networkd 负责，见上方 systemd.network）
        for _tap in router-wan router-lan; do
          ip link show "$_tap" >/dev/null 2>&1 || ip tuntap add "$_tap" mode tap
          ip link set "$_tap" up
        done
      '';

      serviceConfig = {
        Type = "simple";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.cloud-hypervisor}/bin/cloud-hypervisor"
          "--kernel ${assets.kernelImage}"
          "--cmdline \"console=ttyS0 root=/dev/vda rootfstype=ext4 ro\""
          # image_type 显式声明：CH v52 起镜像类型自动检测已弃用
          "--disk path=${assets.rootfsCopy},readonly=on,image_type=qcow2"
          # 持久状态盘（stateDisk 启用时）：guest 侧 /dev/vdb，
          # mount-state 服务挂到 /run/router-vm/state
          (lib.optionalString (cfg.stateDisk != null)
            "--disk path=/var/lib/router-vm/state.raw,readonly=off")
          "--cpus boot=${toString cfg.vcpus},affinity=[0@[${toString cfg.cpu}]]"
          "--memory size=${toString cfg.mem}M"
          (lib.optionalString (cfg.initialBalloonMem > 0)
            "--balloon size=${toString cfg.initialBalloonMem}M,deflate_on_oom=true")
          "--net tap=router-wan,mac=02:00:00:01:00:01"
          "--net tap=router-lan,mac=02:00:00:01:00:02"
          "--serial file=/run/router-vm/console.log"
          "--console off"
          "--api-socket /run/router-vm/api.sock"
        ];

        # 关机：经 api-socket shutdown-vmm（实测 CH v52 秒级退出，VMM 级
        # 关闭，guest 侧无关机流程——无状态 guest 无可冲刷数据，无害）。
        # 极端情况下挂起时 TimeoutStopSec 到期由 systemd 兜底 SIGKILL
        ExecStop = "${pkgs.cloud-hypervisor}/bin/ch-remote --api-socket /run/router-vm/api.sock shutdown-vmm";
        TimeoutStopSec = 90;

        # 清理：socket + tap（guest 自身关机/崩溃路径下 ExecStop 不会跑）
        ExecStopPost = ''
          rm -f /run/router-vm/api.sock
          ip link del router-wan 2>/dev/null || true
          ip link del router-lan 2>/dev/null || true
        '';

        Restart = "on-failure";
      };
    };
  };
}
