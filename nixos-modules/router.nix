# Router VM 消费端声明模块（cloud-hypervisor 直管，不依赖 microvm.nix）
#
# 由旧 microvm.router 模块重写（2026-09-02，方案见 docs/refactor-proposal.md）。
# 镜像生产与消费同仓库：CI 出 release 时用 image/sync-flake-sha.py 自动同步
# 本文件的 tag 与各资产 sha256，宿主侧升级只需 nix flake update。
#
# 用法：
#   imports = [ inputs.router-image.nixosModules.router ];
#   services.router-vm = {
#     enable = true;
#     cpu = 2;                # 隔离给 VM 独占的宿主核（isolcpus + vcpu0 affinity）
#     os = "alpine";          # rootfs 发行版（alpine | gentoo）
#   };
#
# 架构（相对旧 microvm.router 的差异）：
#   - 不依赖 microvm.nix：systemd 单元直接 ExecStart cloud-hypervisor，
#     tap 创建/挂桥、balloon、优雅关机全部自管
#   - 内核唯一：自建 vmlinuz-router（引导链全 builtin，无 initramfs）
#   - guest 完全无状态：rootfs 只读挂载（--disk readonly=on），持久化密钥
#     由宿主 sops-nix 管理（解密到 /run/secrets），router-vm-deploy 在每次
#     VM 启动后 scp 注入 guest 的 /run/router-vm（tmpfs；guest 全部可变
#     状态挂此单根，审计 = ls /run/router-vm），重启即清、重新注入
#   - 状态目录：/var/lib/router-vm/rootfs-<内容哈希>.qcow2 —— rootfs 的只读
#     副本。镜像升级 → 哈希路径变化 → ExecStart 变化 → systemd 自动重启 VM；
#     旧副本保留供 rollback 复用，可手动清理
#   - 串口落盘 /run/router-vm/console.log：网络故障时的恢复通道
#     （router-vm-console 查看），getty 仍在 guest 的 ttyS0 上
{ config, lib, pkgs, ... }:

let
  cfg = config.services.router-vm;

  # 本仓库 CI release（sync-flake-sha.py 在每次 release 后自动同步 tag 与
  # sha256；首次新前缀 release 前 sha256 为占位 0，fetchurl 会失败并显示
  # 真实值，release 触发后 CI 自动回填）
  imageRelease = "router-vm-20260908";
  releaseBase = "https://github.com/allenmagic/router-image/releases/download/${imageRelease}";

  # rootfs 资产表（按发行版；vmlinuz-router 是发行版无关的共享内核资产）。
  # 新发行版构建链就绪后在此加一行即可（SHA256SUMS 会多出对应条目）。
  osAssets = {
    alpine = {
      url = "${releaseBase}/alpine-rootfs.qcow2";
      sha256 = "c8be4016a598f871a08c781dec5f5120f371797c2a96d0b5436a083023b40ec4";
    };
    gentoo = {
      url = "${releaseBase}/gentoo-rootfs.qcow2";
      sha256 = "48469418ceb73f8db97047150252b0f255bfb5c9def275282ab7f5e0d8505cb8";
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

  # 宿主侧 ssh 选项：guest host key 每次启动重新生成（无状态架构），
  # 不能依赖 known_hosts；root/root 密码通道只在 LAN 侧（br-lan）可达
  sshOpts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR";

  # 单次注入（部署守护与手工 router-vm-deploy 命令共用的函数体）：
  #   等待 VM 上线 → 从 /run/secrets 组装 env → scp 上传 → 远程执行 install.sh
  # 手工部署可用 ROUTER_VM_ENV_FILE 指向传统 env 文件（见 env.example），
  # 覆盖 sops 密钥源（调试/迁移场景）。
  # 失败以 return 1 结束（消费方各自包成函数调用；不能用 exit——守护循环
  # 的消费方会把整个循环脚本炸掉）
  injectOnce = ''
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.openssh pkgs.sshpass pkgs.iputils ]}:$PATH
    export PATH

    VM_IP="${cfg.vmIp}"
    DEPLOY_PKG="/etc/router-vm/deploy.tar.gz"
    SECRETS_DIR="${cfg.secretsDir}"
    SSH_OPTS="${sshOpts}"

    # 组装 env 文件（密钥只在宿主 /run/secrets 与 guest 的 /tmp 瞬间存在）
    ENV_FILE="$(mktemp /tmp/router-vm-env.XXXXXX)"
    chmod 600 "$ENV_FILE"
    if [ -n "''${ROUTER_VM_ENV_FILE:-}" ]; then
        cp "$ROUTER_VM_ENV_FILE" "$ENV_FILE"
    else
        [ -f "$SECRETS_DIR/ssh-public-key" ] \
            && printf 'SSH_PUBLIC_KEY="%s"\n' "$(cat "$SECRETS_DIR/ssh-public-key")" >> "$ENV_FILE"
        [ -f "$SECRETS_DIR/tailscale-auth-key" ] \
            && printf 'TAILSCALE_AUTH_KEY="%s"\n' "$(cat "$SECRETS_DIR/tailscale-auth-key")" >> "$ENV_FILE"
        [ -f "$SECRETS_DIR/headscale-auth-key" ] \
            && printf 'HEADSCALE_AUTH_KEY="%s"\n' "$(cat "$SECRETS_DIR/headscale-auth-key")" >> "$ENV_FILE"
        [ -f "$SECRETS_DIR/cloudflared-token" ] \
            && printf 'CLOUDFLARED_TOKEN="%s"\n' "$(cat "$SECRETS_DIR/cloudflared-token")" >> "$ENV_FILE"
    fi
    [ -s "$ENV_FILE" ] || echo "提示: 未找到任何密钥（$SECRETS_DIR 无 sops 密钥文件），将只跑空注入"

    # 等待 VM 上线（ping 轮询，最长 4 分钟）
    _online=0
    for _i in $(seq 1 120); do
        if ping -c 1 -W 1 "$VM_IP" >/dev/null 2>&1; then _online=1; break; fi
        sleep 2
    done
    if [ "$_online" != 1 ]; then
        echo "错误: VM 未上线（$VM_IP），部署中止" >&2
        rm -f "$ENV_FILE"
        return 1
    fi

    # 上传 + 远程注入。网络可达 ≠ sshd 就绪，重试 5 次（每次间隔 5 秒）
    _rc=1
    for _i in 1 2 3 4 5; do
        if sshpass -p root scp $SSH_OPTS "$DEPLOY_PKG" "root@$VM_IP:/tmp/router-vm-deploy.tar.gz" \
           && sshpass -p root scp $SSH_OPTS "$ENV_FILE" "root@$VM_IP:/tmp/router-vm.env" \
           && sshpass -p root ssh $SSH_OPTS "root@$VM_IP" \
                'rm -rf /tmp/router-vm-deploy && mkdir -p /tmp/router-vm-deploy && cd /tmp/router-vm-deploy && tar xzf /tmp/router-vm-deploy.tar.gz && mv /tmp/router-vm.env ./env && sh install.sh; _rc=$?; rm -f /tmp/router-vm-deploy.tar.gz /tmp/router-vm.env; exit $_rc'
        then _rc=0; break; fi
        sleep 5
    done
    rm -f "$ENV_FILE"
    if [ "$_rc" != 0 ]; then
        echo "错误: 密钥注入失败" >&2
        return 1
    fi
    echo "部署完成。Tailscale 已自动触发登录（approve/auto-approve 在 admin 侧处理）"
    return 0
  '';

  # 部署守护（systemd 单元执行）：每次 VM boot 后注入一遍。
  # 为什么是常驻循环而不是 oneshot + PartOf：PartOf 只传播显式
  # stop/restart——CH 崩溃后 router-vm 的 Restart=on-failure 是 systemd
  # 内部重启，不会重新拉起已完成的 oneshot。届时 guest tmpfs 已清空
  # （host key/authorized_keys/tailscale 全没了），无人重新注入且无任何
  # 报错——服务全"正常"，只是状态是空的。循环语义：注入 → 等 ssh 掉线
  # （VM 关机/崩溃）→ 等新 boot 上线 → 再注入。注入幂等，误判的代价
  # 只是多跑一轮。
  deployScript = ''
    set -eu

    _inject_once() { ${injectOnce} }

    while true; do
        if _inject_once; then
            echo "注入完成；等待 VM 下一次 boot（ssh 掉线即触发下一轮）..."
            while sshpass -p root ssh ${sshOpts} "root@${cfg.vmIp}" true 2>/dev/null; do
                sleep 5
            done
        else
            echo "注入失败（VM 未上线或注入出错），5 秒后重试 ..." >&2
        fi
        sleep 5
    done
  '';
in

{
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
        方向本模块未实现（microvm 时代有监听器，重构后未移植）——将来
        实现宿主侧内存回收时再恢复非零默认值。
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
          ssh-public-key / tailscale-auth-key / cloudflared-token
      '';
    };
  };

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
      path = [ pkgs.iproute2 pkgs.coreutils ];

      preStart = ''
        mkdir -p /var/lib/router-vm /run/router-vm

        # rootfs 只读副本（幂等；ExecStart 引用含哈希路径，升级时 systemd
        # 检测 ExecStart 变化自动重启 VM）。原子落位：先写临时文件再 mv——
        # 直写最终路径时拷贝中断（磁盘满/系统崩溃）会留下损坏副本，且
        # [ ! -f ] 从此永远跳过重拷，VM 用坏镜像起不来 + Restart=on-failure
        # 无限循环、无自愈路径
        if [ ! -f "${rootfsCopy}" ]; then
          _tmp="${rootfsCopy}.tmp.$$"
          install -m 0644 "${rootfsImage}" "$_tmp"
          # 完整性：字节数与原镜像一致才算拷完（qcow2 无内嵌校验和；
          # 同主机拷贝，size 校验已能拦下磁盘满/中断等绝大多数场景）
          if [ "$(stat -c %s "$_tmp")" != "$(stat -c %s "${rootfsImage}")" ]; then
            rm -f "$_tmp"
            exit 1
          fi
          mv "$_tmp" "${rootfsCopy}"
        fi
        rm -f "${rootfsCopy}".tmp.*  # 清理历史中断残留（$$ 已变，不会误删在用的）

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
          "--kernel ${kernelImage}"
          "--cmdline \"console=ttyS0 root=/dev/vda rootfstype=ext4 ro\""
          # image_type 显式声明：CH v52 起镜像类型自动检测已弃用
          "--disk path=${rootfsCopy},readonly=on,image_type=qcow2"
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

    # ---- 密钥注入：常驻守护，每次 VM boot 后注入（guest tmpfs 状态随重启
    #      清空，必须重新注入）。Type=simple 循环脚本覆盖所有 boot 来源
    #      （首次启动/显式重启/CH 崩溃后的自动重启），PartOf 保证生命周期
    #      随 VM。Restart=always 是脚本自身意外退出的兜底
    #      （systemd 默认 StartLimitBurst 防止秒退风暴）----
    systemd.services.router-vm-deploy = {
      description = "Router VM secret injection (re-inject on every VM boot)";
      after = [ "router-vm.service" ];
      partOf = [ "router-vm.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
      };
      script = deployScript;
    };

    # ---- deploy 资产与命令 ----
    # 注入器 tarball（无密钥）与手工部署用的 env 模板（sops 流程下
    # 一般不需要；ROUTER_VM_ENV_FILE 调试/迁移场景用）
    environment.etc."router-vm/deploy.tar.gz".source = deployPkg;
    environment.etc."router-vm/env.example".text =
      builtins.readFile ../deploy-assets/env.example;

    environment.systemPackages = [
      # 手工部署命令 = 单次注入（与 systemd 守护共用 injectOnce 函数体；
      # 手工执行时不需要常驻循环）
      (pkgs.writeShellScriptBin "router-vm-deploy" ''
        _inject_once() { ${injectOnce} }
        _inject_once
      '')

      (pkgs.writeShellScriptBin "router-vm-shell" ''
        PATH=${lib.makeBinPath [ pkgs.openssh pkgs.sshpass ]}:$PATH
        export PATH
        exec sshpass -p root ssh ${sshOpts} root@${cfg.vmIp} "$@"
      '')

      (pkgs.writeShellScriptBin "router-vm-console" ''
        PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
        export PATH
        exec tail -f /run/router-vm/console.log
      '')
    ];
  };
}
