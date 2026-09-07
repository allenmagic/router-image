# router-image

路由 VM 镜像的**唯一仓库**：镜像生产（CI）+ 消费端声明（flake 模块）。
rootfs 构建链移植自
[nanopi-r3s-rootfs](https://github.com/allenmagic/nanopi-r3s-rootfs)，
并按 VM 场景收敛为 **x86_64 专用**（无跨架构/binfmt/qemu 机制），
双发行版链（Alpine / Gentoo，均为 musl + OpenRC）；
自建单一内核（引导链全 builtin、无 initramfs），产出两件套 release 资产。

## 架构

```
NixOS 宿主
├── services.router-vm（本仓库 nixosModules.router，cloud-hypervisor 直管）
│   ├── router-vm.service        系统单元直接 ExecStart cloud-hypervisor
│   │   ├── preStart             rootfs 只读副本（内容哈希路径）+ tap 创建
│   │   ├── --disk readonly=on   guest rootfs 只读挂载
│   │   ├── --balloon            可选（默认关）；deflate_on_oom 在 guest 内存压力时放气
│   │   ├── --api-socket         优雅关机（ExecStop=ch-remote shutdown-vmm）
│   │   └── --serial file        串口落盘 /run/router-vm/console.log
│   ├── router-vm-deploy.service 每次 VM 启动后：sops 密钥 scp 注入 guest /run
│   └── systemd.network          tap → br-wan/br-lan 自动挂桥
└── guest（ro rootfs，完全无状态）
    ├── 构建期烙入的符号链接（/var/lib/tailscale、/etc/cloudflared、
    │   /var/log、/root/.ssh … → /run/router-vm tmpfs）
    └── 重启即清空 → 宿主重新 deploy（幂等，操作者无感知）
```

- **不依赖 microvm.nix**：systemd 单元自管 tap/挂桥/balloon/关机，
  flake 输入只剩 nixpkgs
- **内核唯一**：`kernel/build.sh` 自建（跟最新 LTS，全 builtin），
  无 initramfs、无 modloop；CVE 响应 = LTS bump（CI 按 KVER 自动重编）
- **guest 无状态**：持久化数据（ssh key / tailscale authkey / cloudflared
  token 等纯文本）由宿主 sops-nix 管理，deploy 时注入 /run；
  镜像升级不丢状态（状态根本不在镜像里）
- 设计决策与风险分析见 `docs/refactor-proposal.md`，实施计划见
  `docs/refactor-plan.md`

## 仓库分工

| 环节 | 位置 |
|---|---|
| 内核构建（vmlinuz-router，全 builtin） | `kernel/build.sh`（CI 独立作业） |
| rootfs 构建 + 装配（两件套 release） | `distros/{alpine,gentoo}/` + `image/assemble.sh` |
| 消费端声明（fetchurl/CH systemd 单元/tap 挂桥/deploy） | 本仓库 `nixosModules.router` |
| 密钥注入 | 本仓库 `deploy-assets/`（模块内打包；密钥经宿主 sops-nix `/run/secrets` 注入，不进 git/store） |

## 消费端使用（flake 模块）

```nix
# 宿主 flake
inputs.router-image.url = "github:allenmagic/router-image";

# 宿主模块
imports = [ inputs.router-image.nixosModules.router ];
services.router-vm = {
  enable = true;

  os = "alpine";           # 客户机发行版：alpine（默认）/ gentoo（均为 musl+OpenRC）
  cpu = 0;                 # isolcpus 独占核（默认 0；vcpu0 pin 到此核）
  vcpus = 2;               # vCPU 总数（默认 2：vcpu0 独占 + 其余动态调度）
  mem = 256;               # guest 内存上限 MB（默认 256）
  initialBalloonMem = 0;   # 初始 balloon 充气 MB（默认 0=不启用；注意会从 mem 里扣）

  wanBridge = "br-wan";    # WAN 侧宿主桥（默认 br-wan）
  lanBridge = "br-lan";    # LAN 侧宿主桥（默认 br-lan）
  vmIp = "192.168.10.1";   # VM LAN 口 IP（deploy 的 ssh 目标）

  secretsDir = "/run/secrets"; # sops-nix 解密落点（默认；三个密钥文件名见模块 option）
};
```

完整宿主示例（网桥 + sops 密钥 + 防火墙）：`example-host-config.nix`。
镜像 release 的 tag 与资产 sha256 硬编码在模块内（`nixos-modules/router.nix`），
**CI 出 release 后自动同步**（`image/sync-flake-sha.py`，幂等）——宿主升级只需
`nix flake update`。镜像更新 → rootfs 副本路径（含内容哈希）变化 →
ExecStart 变化 → VM 自动重启；旧副本保留，宿主 rollback 直接复用。

## 构建流程（本地）

```bash
# 1. 构建内核（全 builtin，无 initramfs；产物 kernel/out/vmlinuz-router +
#    config-router + modules 元数据树）
./kernel/build.sh

# 2. 构建 rootfs（双链二选一；产物 build/<distro>/<distro>-rootfs-minimal.tar.xz）
sudo -E PACK=1 bash distros/alpine/build.sh
sudo -E PACK=1 bash distros/gentoo/build.sh

# 3. 装配 VM 镜像（注入自建内核模块元数据 → mkfs.ext4 → qcow2）
./image/assemble.sh build/alpine/alpine-rootfs-minimal.tar.xz dist alpine
# 产物：dist/{alpine-rootfs.qcow2, SHA256SUMS}（内核资产在 kernel/out/）
```

CI 手动触发（`.github/workflows/build-image.yml`）后：kernel → build →
release 上传（tag `router-vm-YYYYMMDD`，资产 vmlinuz-router +
`<distro>-rootfs.qcow2` + config-router + SHA256SUMS）→ 自动同步 flake
模块 tag+sha256 并推送。

## 测试

```bash
# 冒烟测试：两条路径（详见 test/smoke-test.sh 头部说明）
bash test/smoke-test.sh alpine                                   # qemu 交互（串口直连；退出 Ctrl-A X）
bash test/smoke-test.sh alpine --backend cloud-hypervisor --assert  # CH 非交互断言
bash test/smoke-test.sh alpine --verify-only                     # 只下载+校验
# 本地刚构建的内核直通（跳过 release 内核下载校验；见 kernel/README.md）
bash test/smoke-test.sh alpine --local-kernel kernel/out/vmlinuz-router --assert
# CH 交互模式的退出（另开终端；guest 内 poweroff/halt 在 CH 下退不出 VMM）：
#   ch-remote --api-socket /tmp/router-vm-smoke.sock shutdown-vmm
```

冒烟断言覆盖启动到 login 的日志断言（cmdline/ro 根盘/内存与生产一致；
CH 路径无 tap 网卡——建 tap 需 root，virtio-net 回归由 qemu 路径的
user-mode 网卡覆盖）。真实网络环境（tap + 桥 + 上游）验收走
`docs/verify-on-nixos.md` 的 NixOS 宿主流程。

## 关键设计

- **x86_64 专用**：ARCH 固定在构建脚本内；跨架构映射、binfmt 预检、qemu 注入
  已整体移除。
- **双发行版 musl-openrc**：alpine 与 gentoo 链共用 `base/` 配置体系
  （init.d/conf.d/runlevels），消费端 `os` 选项切换。
- **串口控制台（ttyS0/115200）**：getty 常驻 ttyS0，宿主侧落盘
  `/run/router-vm/console.log`——网络故障时的最后恢复通道。
- **ro rootfs + 构建期符号链接**：运行期无法在 ro 根上创建挂载点/链接，
  全部可写路径（状态目录、/etc/mtab、/etc/resolv.conf、sshd host key）在
  镜像构建期烙入指向 `/run`（tmpfs）；写点失控时的回退路线见
  `docs/refactor-proposal.md` §5。
- **无密钥进镜像/store**：不使用 CI secrets；密钥由宿主 sops-nix 解密到
  `/run/secrets`，router-vm-deploy 每次 VM 启动后 scp 注入 guest /run
  （guest 内 env 文件用后即删）。release 产物公开可下载，密钥绝不进入。
- **配置权威源**：全部路由配置（nftables/dnsmasq/sysctl/服务脚本/网络参数）
  在本仓库 `base/` 与 `network.env`，CI 烙进镜像——出厂即正确；
  deploy 只做密钥注入。
- **无 rootfs 占位符残留**：`network.sh` 构建时按 `network.env` 替换全部
  `__XXX__` 占位符（dnsmasq 主配置/模块配置/nftables vars/tailscale config）。
