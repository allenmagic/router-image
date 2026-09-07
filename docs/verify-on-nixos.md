# 在 NixOS 上验证 router.nix 模块

本指南介绍如何验证 `nixos-modules/router.nix`（`services.router-vm.*`）在
NixOS 宿主上的完整功能。验收标准对应 `docs/refactor-proposal.md` §7。

## 方案对比

| 方案 | 适用场景 | 复杂度 | 验证完整度 |
|---|---|---|---|
| **方案 1：NixOS VM** | 在非 NixOS 上测试模块接线 | 中等 | 中（嵌套虚拟化，isolcpus 不生效） |
| **方案 2：GitHub Actions CI** | 每次提交自动验证配置生成 | 低 | 中（无 KVM，只验证 unit 生成） |
| **方案 3：真实 NixOS** | 生产部署前最终验证 | 低 | 最高 |

> 前置：方案 1/3 的模块 fetchurl 需要 router-vm-* 前缀的 release 已存在
> （`nixos-modules/router.nix` 的 sha256 由 CI 的 sync-flake-sha.py 自动同步）。

## 方案 1：使用 NixOS VM

在非 NixOS 系统（如 Arch Linux）上构建一个 NixOS VM，在其中运行 router VM
（嵌套虚拟化）。验证模块的 systemd 单元接线与网络挂桥。

### 前置条件

- Nix 已安装
- /dev/kvm 可读写（嵌套虚拟化需要）
- 至少 8GB 内存（宿主 VM 4GB + router VM 256MB）

### 构建并启动

```bash
cd /path/to/router-image

# 构建 NixOS VM（首次需要下载 NixOS 依赖，~3-5GB）
nix build .#nixosConfigurations.test-nixos-host.config.system.build.vm

# 启动 VM
./result/bin/run-nixos-test-host-vm
```

### 验证步骤

VM 启动后，在宿主 VM 的终端里：

```bash
# 1. 检查 router-vm 服务状态（systemd 直管，无 microvm@ 单元）
systemctl status router-vm
systemctl status router-vm-deploy   # 每次 VM 启动后的密钥注入

# 2. 检查网络桥接与 tap
ip link show br-wan
ip link show br-lan
ip link show router-wan    # 模块 preStart 创建，networkd 自动挂桥
ip link show router-lan

# 3. 串口日志（故障恢复通道）
router-vm-console

# 4. SSH 进入 router VM（root/root；无密钥时 router-vm-deploy 会失败并
#    在 journal 中可见——本方案下可先手工验证 ssh 通道）
ssh root@192.168.10.1
# 密码：root

# 5. 在 router VM 内验证
uname -a                    # 自建内核版本
ip addr                     # eth0=WAN(DHCP) eth1=192.168.10.1
nft list ruleset            # nftables 规则
rc-status                   # 服务矩阵（cloudflared/tailscale 无密钥时 stopped 属正常）

# 6. 优雅关机
systemctl stop router-vm    # api-socket shutdown-vmm，CH 秒级退出
systemctl start router-vm   # 自动恢复（含 router-vm-deploy 重新注入）
```

### 限制

- **CPU 隔离无效**：`isolcpus` 在 VM 内不生效（需要宿主内核参数），
  affinity pin 本身可验证（`taskset -cp $(pgrep cloud-hypervisor)`）
- **网络拓扑简化**：测试桥接是虚拟的，没有连接真实物理接口

## 方案 2：GitHub Actions CI

已实现（`.github/workflows/test-router-module.yml`，push/PR 自动运行）：

- `nix flake check`
- 模块定义与 `services.router-vm.*` 选项求值
- `router-vm.service` 的 ExecStart/ExecStop/preStart 与
  `router-vm-deploy.service` 依赖关系断言
- tap → 桥的 networkd 配置断言
- test-nixos-host toplevel dry-run

## 方案 3：真实 NixOS 宿主（生产验收）

有 NixOS 机器时做最终验证。完整示例见 `example-host-config.nix`，
这里只列验收流程。

### 配置要点

```nix
{
  imports = [
    (builtins.fetchGit {
      url = "https://github.com/allenmagic/router-image";
      ref = "main";
    } + "/nixos-modules/router.nix")
    # 或经 flake：inputs.router-image.nixosModules.router
  ];

  services.router-vm = {
    enable = true;
    os = "alpine";
    cpu = 2;               # 隔离核：按硬件调整（isolcpus）
    vcpus = 2;
    mem = 256;             # 默认值，可省略
    initialBalloonMem = 0; # 默认值，可省略
    wanBridge = "br-wan";
    lanBridge = "br-lan";
    vmIp = "192.168.10.1";
  };

  # 桥接：见 example-host-config.nix（tap 由模块创建，物理口挂桥在宿主配置）

  # 密钥（sops-nix）：解密到 /run/secrets，router-vm-deploy 每次 VM 启动后
  # 自动注入 guest /run。secrets.yaml 条目名与模块 secretsDir 约定一致：
  sops.secrets."ssh-public-key" = { sopsFile = ./secrets.yaml; };
  sops.secrets."tailscale-auth-key" = { sopsFile = ./secrets.yaml; };
  sops.secrets."cloudflared-token" = { sopsFile = ./secrets.yaml; };
}
```

### 验收清单（对应方案 §7）

```bash
# 1. VM 启动、SSH 可达（经 br-lan）
systemctl status router-vm
ssh root@192.168.10.1 'uptime'

# 2. ro rootfs 无写失败报错
ssh root@192.168.10.1 'dmesg | grep -i "read-only\|ro fs" || echo 无写失败'
# 亦可查串口日志：grep "Read-only" /run/router-vm/console.log

# 3. deploy 注入（sops 密钥经符号链接落 /run）
ssh root@192.168.10.1 'cat /root/.ssh/authorized_keys; cat /etc/tailscale/authkey'
# tailscale 自动登录（注入后 deploy 内后台 tailscale up；key 须 reusable，
# 建议 Ephemeral——审批/auto-approve 在 Tailscale admin 侧）
ssh root@192.168.10.1 'tailscale status'

# 4. 镜像升级后状态保留（新架构：状态=密钥，重启即重新注入，无需重新 deploy）
#    nix flake update → nixos-rebuild switch → 自动重启 VM + 重新 deploy
ssh root@192.168.10.1 'cat /root/.ssh/authorized_keys'   # 应仍存在

# 5. 宿主 reboot 后 VM 自动恢复 + deploy 自动补注入
sudo reboot
# 恢复后：
systemctl status router-vm router-vm-deploy

# 6. 优雅关机（api-socket 生效，CH 进程退出）
systemctl stop router-vm
pgrep cloud-hypervisor || echo "CH 已退出"

# 7. 核隔离：只绑定隔离核
taskset -cp $(pgrep cloud-hypervisor)   # 应只显示 cpu 选项指定的核

# 8. balloon：默认关闭（initialBalloonMem=0，启动不传 --balloon）
ssh root@192.168.10.1 'free -h'         # 默认配置下可用内存 ≈ mem（256M）
# 若宿主显式开启 balloon：初始可用 = mem - balloon。deflate_on_oom 在
# guest 内存压力时放气（宿主侧「OOM 时充气回收」方向未实现）

# 9. smoke-test：两条路径（见 docs/quick-start-arch-linux.md）
bash test/smoke-test.sh alpine --verify-only
bash test/smoke-test.sh alpine --backend cloud-hypervisor --assert
```

## 常见问题

### Q1: NixOS VM 构建失败
```bash
nix doctor
nix-collect-garbage -d
nix build .#nixosConfigurations.test-nixos-host.config.system.build.vm
```

### Q2: 嵌套虚拟化不工作
检查 CPU 是否支持嵌套虚拟化：
```bash
cat /sys/module/kvm_intel/parameters/nested  # Intel：Y
cat /sys/module/kvm_amd/parameters/nested    # AMD：1
# 不满足时启用（重启生效）：
echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
```

### Q3: router-vm 服务启动失败
```bash
journalctl -u router-vm -n 50
# 常见原因：
# - 桥接未创建：检查 systemd.network 配置
# - KVM 权限：检查 /dev/kvm 可读写
# - release 未出（fetchurl hash mismatch）：先触发 CI 出 router-vm-* release
```

### Q4: router-vm-deploy 失败
```bash
journalctl -u router-vm-deploy -n 50
# 常见原因：
# - VM 未上线（4 分钟 ping 超时）：查 router-vm-console 串口日志
# - 密钥文件缺失：/run/secrets/ 下应有三项（缺项按跳过处理，不报错）
# - 密码通道被拒：确认镜像含 base/ssh/sshd_config.d/root-login.conf
#   （root/root 密码 + StrictHostKeyChecking=no 是设计通道）
```

### Q5: 想绕过 sops 手工部署
```bash
# ROUTER_VM_ENV_FILE 指向传统 env 文件（格式见 /etc/router-vm/env.example）
sudo cp /etc/router-vm/env.example /tmp/router-vm.env
sudo vim /tmp/router-vm.env   # 填入密钥
sudo ROUTER_VM_ENV_FILE=/tmp/router-vm.env router-vm-deploy
```

## 下一步

- 生产部署：`example-host-config.nix`（网桥 + 模块 + sops 完整示例）
- 迁移自旧 microvm.router：`docs/migration-from-microvm.md`
- 自定义镜像构建：`image/` 与 `distros/` 构建链
- 自建内核配置：`kernel/README.md`
