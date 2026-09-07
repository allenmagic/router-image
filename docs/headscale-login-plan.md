# router-vm Tailscale 登录自建 Headscale —— 方案与实施计划

> 状态：**草案，待决策**。本文件用于记录方案与待确认点，尚未开始实施。

## 1. 背景与动机

router-vm 的 tailscale 客户端目前连**官方 Tailscale**（`login.tailscale.com`，`tailscaled` 默认控制面）。

需求：支持**切换/登录自建 Headscale**（如 `hs.zyx1986.icu`）。对 router-vm 这种「无状态 guest、每次重启都重新登录」的场景，Headscale 有一个实际好处：

- **Headscale 的 preauth key 注册天然免手动 approve**（`tailscale up --login-server=<url> --authkey=hskey-auth-...` 即自动上线）；
- 官方 Tailscale 的 auth key 注册在设备审批制下通常仍需 admin 手动 approve（此前 router-vm 实测即如此）。

配合 `--reusable` + `--ephemeral` 的 preauth key，重启后节点自动重新注册上线，无需人工介入。

## 2. 现状分析与根因（关键）

`config.json`（`base/tailscale/config.json`）**是 `tailscaled` 守护进程的配置**，必须通过 **`tailscaled --config=/etc/tailscale/config.json`** 显式指定路径读取，**不会自动读默认路径**。

当前 `base/init/openrc/tailscale` 启动 tailscaled 时：

```sh
start-stop-daemon --start ... --exec /usr/sbin/tailscaled
```

**没有 `--config` 参数**。因此 config.json 里已配好的字段全部未生效：

- `netfilterMode: "off"` → 实际仍走默认 iptables，在 nftables 环境建 `ts-input` 链失败 → tailscale 系统流量进不了 guest；
- `acceptRoutes: true` / `advertiseRoutes: [...]` / `acceptDNS: false` → 全部回落默认值；
- `authKey: "file:/etc/tailscale/authkey"` → file: 机制未生效，deploy 的裸 `tailscale up` 无 key，登录后呈现 `Logged out` + 交互登录 URL。

### 旁支：`deploy-assets/lib/secrets.sh` 的显式参数是 workaround

此前为解决「系统流量不通」，在 `secrets.sh` 里把裸 `tailscale up` 改成了显式传 `--netfilter-mode=off --accept-routes --advertise-routes=... --accept-dns=false`。这是绕过 config.json 的 workaround，**不是正解**。若走「tailscaled 读 config.json」的正解，`secrets.sh` 应简化为裸 `tailscale up`（authKey 由 config.json 的 file: 机制接管）。

## 3. 改动方案（5 处）

| # | 文件 | 改动 | 生效方式 |
|---|---|---|---|
| 1 | `base/init/openrc/tailscale` | tailscaled 加 `--config=/etc/tailscale/config.json` | 烙进镜像 |
| 2 | `base/tailscale/config.json` | 加 `loginServer` 字段（占位符 `__TS_LOGIN_SERVER__`） | 烙进镜像 |
| 3 | `network.env` | 加 `TS_LOGIN_SERVER=`（空 = 官方 Tailscale，非空 = Headscale） | 构建期替换 |
| 4 | 构建脚本（`network.sh` 或等价） | 替换 config.json 的 `__TS_LOGIN_SERVER__` 占位符 | 构建期 |
| 5 | `deploy-assets/lib/secrets.sh` | 撤销显式参数，回到裸 `tailscale up` | 模块打包，NAS rebuild 生效 |

### 3.1 config.json 目标形态

```json
{
  "version": "alpha0",
  "authKey": "file:/etc/tailscale/authkey",
  "hostname": "__TS_HOSTNAME__",
  "loginServer": "__TS_LOGIN_SERVER__",
  "acceptRoutes": true,
  "acceptDNS": false,
  "netfilterMode": "off",
  "advertiseRoutes": ["__TS_ADVERTISE_ROUTES__"]
}
```

`loginServer` 为空字符串时，tailscaled 走默认官方控制面；非空则连 Headscale。具体空值语义需在实施时验证（若空字符串导致解析失败，需在构建期按条件剔除该字段，而非传空串）。

### 3.2 auth key 体系差异

- 官方 Tailscale：`tskey-auth-...`
- Headscale：`hskey-auth-{prefix}-{secret}`

两者**不通用**。切换控制面时，`secrets/secrets.yaml` 里的 `tailscale-auth-key` 需换成对应体系的 key。是否新增独立 secret 名（如 `headscale-auth-key`）以避免混淆，作为实施时的次要决策。

## 4. 测试方案（三层）

### 层 1：构建 + 启动断言（本地）

```sh
sudo -E PACK=1 bash distros/gentoo/build.sh
./image/assemble.sh build/gentoo/gentoo-rootfs-minimal.tar.xz dist gentoo
bash test/smoke-test.sh gentoo --backend cloud-hypervisor --assert
```

验证镜像构建不破、能启动。可在 smoke-test 断言里加一条「tailscaled 进程带 `--config`」。

### 层 2：config.json 生效验证（guest 内）

```sh
ps aux | grep tailscaled              # 应含 --config=/etc/tailscale/config.json
tailscale debug prefs | grep -E 'NetfilterMode|RouteAll|AdvertiseRoutes'
# 期望：NetfilterMode=0(off)、RouteAll=true、AdvertiseRoutes=[192.168.10.0/24]
```

验证 config.json 字段真正生效（此前未走通的一环）。

### 层 3：端到端登录 Headscale

1. Headscale 侧生成 reusable + ephemeral 的 preauth key（`hskey-auth-...`）；
2. `network.env` 设 `TS_LOGIN_SERVER=https://<headscale>`；
3. 构建 + 部署 NAS（`nix flake update` + rebuild，VM 自动重启）；
4. 验证：
   - `tailscale status` 节点上线、hostname 正确；
   - `headscale nodes list` 节点已注册（preauth key 自动批准，无需手动 approve）；
   - 开发机侧 ping/ssh 到 router-vm tailscale IP，系统流量通（`--netfilter-mode=off` 生效）。

## 5. 待确认与决策点

1. **Headscale 地址与协议**：`https://hs.zyx1986.icu` 还是别的？是否有有效证书？（tailscale 连 Headscale 走 https，http 明文一般不可用。）
2. **官方 / Headscale 切换形态**：确认是「`TS_LOGIN_SERVER` 二选一」而非「并存」（tailscale 单实例，一次只能连一个控制面）。
3. **preauth key**：Headscale 侧生成 reusable + ephemeral 的 `hskey-auth-...` 用于层 3 测试。
4. **测试节奏**：层 1/2 本地可做（不碰 NAS）；层 3 需重建镜像 + 部署 NAS，影响在跑的 router-vm。
5. **节点身份是否持久化**（独立维度）：若需要「重启后固定 tailscale IP / 免重新注册」，需额外持久化 `tailscaled.state`（方案 A 无状态+auto-approve / B 持久化 state 到宿主 / C 折中）。本计划暂按「无状态 + reusable preauth key」处理，持久化另立议题。
6. **是否新增 `headscale-auth-key` secret 名**：区分官方/自建两套 key，避免 `tailscale-auth-key` 语义混淆。

## 6. 参考

- [Tailscale daemon configuration file](https://tailscale.com/docs/reference/tailscaled/tailscaled-config-file)
- [Tailscale netfilter modes](https://tailscale.com/docs/reference/netfilter-modes)
- [Headscale Pre-Authentication Keys](https://deepwiki.com/juanfont/headscale/4.2-node-management-commands)
- [Headscale Registration methods](https://raw.githubusercontent.com/juanfont/headscale/main/docs/ref/registration.md)
