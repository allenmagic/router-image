# ============================================================
# router.nix 子模块 —— 密钥注入链路（deploy 守护 + 手工命令）
#
# injectOnce：等待 VM 上线 → 从 /run/secrets 组装 env → scp 上传 →
# 远程执行 install.sh（单次注入，手工 router-vm-deploy 命令共用）。
# deployScript：常驻循环守护——每次 VM boot 后注入一遍（覆盖 CH 崩溃
# 自动重启的缺口，PartOf 只传播显式 restart）。
# deploy 包（无密钥 tarball）读自 assets.nix 的 _assets。
# ============================================================
{ config, lib, pkgs, ... }:

let
  cfg = config.services.router-vm;
  assets = cfg._assets;

  # 宿主侧 ssh 选项：guest host key 每次启动重新生成（无状态架构），
  # 不能依赖 known_hosts；root/root 密码通道只在 LAN 侧（br-lan）可达。
  # （stateDisk 持久 host key 稳定后，可收紧为 accept-new + known_hosts）
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
  config = lib.mkIf cfg.enable {
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
    environment.etc."router-vm/deploy.tar.gz".source = assets.deployPkg;
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
