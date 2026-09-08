#!/bin/sh
#
# lib/secrets.sh —— 密钥注入（SSH / Tailscale / Cloudflared）
#   被 install.sh source 调用
#   定义 inject_secrets()
#
#   密钥来自环境变量（由 env 文件加载，见 env.example），
#   绝不写入部署包或日志。
#   Tailscale 登录自动触发：authkey 经 config.json 的 file: 机制被
#   tailscaled 启动时读取，本脚本注入后自动启动 tailscaled 并后台执行
#   `tailscale up`，无需再传 key（approve/auto-approve 在 Tailscale admin 侧）。
#
#   注入路径说明（guest 无状态架构）：/root/.ssh、/etc/cloudflared、
#   /etc/tailscale/authkey 均为构建期烙入的符号链接 → /run（tmpfs），
#   写入经链接落盘到 tmpfs，重启即清（重新 deploy 即可恢复）。
#

inject_secrets() {
    echo "[secrets] === 密钥注入 ==="

    # SSH 公钥：写入 /root/.ssh/authorized_keys（deploy 通道本身与日常登录；
    # r3s 出厂 sshd 默认拒绝 root 密码登录，公钥是唯一免密通道）
    # 支持多个 key：SSH_PUBLIC_KEY 每行一个公钥（如部署机 + 个人设备各一行），
    # 覆盖写保持 deploy 幂等（authorized_keys 以 env 文件为准）
    if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        printf '%s\n' "${SSH_PUBLIC_KEY}" > /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "  → SSH 公钥已注入"
    else
        echo "  → 未提供 SSH_PUBLIC_KEY，跳过"
    fi

    # Tailscale: authkey 写入 /etc/tailscale/authkey（config.json 引用），
    # 随后启动 tailscaled 并后台自动登录（tailscale up）。
    # 注意：guest 无状态，每次重启都是「新节点」重新注册，key 必须是可复用
    # （reusable）类型；建议勾选 Ephemeral，让离线旧节点自动移除。tailscale up
    # 在设备审批制下会阻塞等 approve，故放后台（nohup）不卡 deploy；日志落
    # /run/tailscale/up.log（tmpfs，随重启清空）。
    # 裸 tailscale up（无显式参数）：tailscaled 经 init 脚本的
    # --config=/etc/tailscale/config.json 读取全部登录参数（authKey file: /
    # netfilterMode=off / acceptRoutes / advertiseRoutes / acceptDNS=false），
    # 此前「1.102 不读 --config」是误判——真正的 bug 是 init 从未传 --config
    # （见 docs/headscale-login-plan.md §2 根因分析）
    if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
        mkdir -p /etc/tailscale
        printf '%s' "${TAILSCALE_AUTH_KEY}" > /etc/tailscale/authkey
        chmod 600 /etc/tailscale/authkey
        rc-service tailscale start 2>/dev/null || true
        mkdir -p /run/tailscale
        nohup sh -c 'for _i in 1 2 3 4 5 6; do sleep 2; tailscale up && exit 0; done' \
            >/run/tailscale/up.log 2>&1 &
        echo "  → Tailscale authkey 已注入，自动登录（tailscale up 后台执行）"
    else
        echo "  → 未提供 TAILSCALE_AUTH_KEY，跳过"
    fi

    # Headscale（自建控制面，第二 tailscale 实例 ts0，与官方实例同构）：
    # authkey 写入 /etc/headscale/authkey（config.json 引用）后启动
    # tailscaled（--config 驱动全部登录参数：loginServer/authKey file:/
    # hostname/routes/netfilterMode）并后台裸 tailscale up（socket 需
    # 显式指定——默认 socket 属于官方实例）。key 需 reusable + Ephemeral
    # （与官方实例同理：无状态 guest 每次重启都是新节点重新注册）
    if [ -n "${HEADSCALE_AUTH_KEY:-}" ]; then
        mkdir -p /etc/headscale
        printf '%s' "${HEADSCALE_AUTH_KEY}" > /etc/headscale/authkey
        chmod 600 /etc/headscale/authkey
        rc-service headscale start 2>/dev/null || true
        mkdir -p /run/router-vm/headscale
        nohup sh -c 'for _i in 1 2 3 4 5 6; do sleep 2; tailscale --socket=/var/lib/headscale/tailscaled.sock up && exit 0; done' \
            >/run/router-vm/headscale/up.log 2>&1 &
        echo "  → Headscale authkey 已注入，自动登录（tailscale up 后台执行）"
    else
        echo "  → 未提供 HEADSCALE_AUTH_KEY，跳过"
    fi

    # Cloudflared: token 写入 /etc/cloudflared/config.yml 后重启服务——
    # 出厂时服务已在跑（无 token 空转），注入 token 必须重启才生效
    if [ -n "${CLOUDFLARED_TOKEN:-}" ]; then
        mkdir -p /etc/cloudflared
        printf 'token: %s\n' "${CLOUDFLARED_TOKEN}" > /etc/cloudflared/config.yml
        chmod 600 /etc/cloudflared/config.yml
        rc-service cloudflared restart 2>/dev/null || true
        echo "  → Cloudflared token 已注入并重启服务"
    else
        echo "  → 未提供 CLOUDFLARED_TOKEN，跳过"
    fi
}
