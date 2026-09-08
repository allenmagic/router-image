#
# distros/gentoo/network.sh —— Gentoo (OpenRC/netifrc) 网络配置
#   被 setup.sh source 调用，运行在 stage3 环境内
#   操作目标为 TARGET_ROOTFS（/gentoo-rootfs），不是当前根文件系统
#

configure_network() {
    echo "[network] === 配置网络 (OpenRC network 服务 + udhcpc) ==="
    . /network.env

    _replace_placeholders

    echo "[network] === 网络配置完成 ==="
}

# 通用占位符替换（所有 distro 共用逻辑）
_replace_placeholders() {
    # dnsmasq 主配置 + 模块化 DHCP 配置（含浮动网关 __LAN_GATEWAY__）
    for _f_ in "${TARGET_ROOTFS}"/etc/dnsmasq.conf "${TARGET_ROOTFS}"/etc/dnsmasq.d/*.conf; do
        [ -f "${_f_}" ] || continue
        sed -i \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__LAN_IP__|${LAN_IP}|g" \
            -e "s|__LAN_GATEWAY__|${LAN_GATEWAY}|g" \
            -e "s|__DHCP_RANGE_START__|${DHCP_RANGE_START}|g" \
            -e "s|__DHCP_RANGE_END__|${DHCP_RANGE_END}|g" \
            -e "s|__DHCP_LEASE_TIME__|${DHCP_LEASE_TIME}|g" \
            -e "s|__LAN_NETMASK__|${LAN_NETMASK}|g" \
            -e "s|__LAN_NETWORK__|${LAN_NETWORK}|g" \
            "${_f_}"
    done

    # keepalived（浮动网关接口名）
    _KA="${TARGET_ROOTFS}/etc/keepalived/keepalived.conf"
    if [ -f "${_KA}" ]; then
        sed -i "s|__LAN_IFACE__|${LAN_IFACE}|g" "${_KA}"
    fi

    # nftables vars
    _NFT="${TARGET_ROOTFS}/etc/nftables.d/00-inet-vars.nft"
    if [ -f "${_NFT}" ]; then
        sed -i \
            -e "s|__WAN_IFACE__|${WAN_IFACE}|g" \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__ROUTER_LAN_IP__|${LAN_IP}|g" \
            -e "s|__LAN_NET__|${LAN_NETWORK}|g" \
            "${_NFT}"
    fi

    # tailscale（hostname 与通告路由）
    _TS="${TARGET_ROOTFS}/etc/tailscale/config.json"
    if [ -f "${_TS}" ]; then
        sed -i \
            -e "s|__TS_HOSTNAME__|${TS_HOSTNAME}|g" \
            -e "s|__TS_ADVERTISE_ROUTES__|\"${TS_ADVERTISE_ROUTES}\"|g" \
            "${_TS}"
    fi

    # headscale 第二实例（ts0）的登录参数（config.json，与官方实例同构）
    _HS="${TARGET_ROOTFS}/etc/headscale/config.json"
    if [ -f "${_HS}" ]; then
        sed -i \
            -e "s|__HEADSCALE_CTL_URL__|\"${HEADSCALE_CTL_URL}\"|g" \
            -e "s|__HEADSCALE_HOSTNAME__|${HEADSCALE_HOSTNAME}|g" \
            -e "s|__HEADSCALE_ADVERTISE_ROUTES__|\"${HEADSCALE_ADVERTISE_ROUTES}\"|g" \
            "${_HS}"
    fi

    # network 服务（WAN/LAN 接口与 IP）
    _NET="${TARGET_ROOTFS}/etc/init.d/network"
    if [ -f "${_NET}" ]; then
        sed -i \
            -e "s|__WAN_IFACE__|${WAN_IFACE}|g" \
            -e "s|__LAN_IFACE__|${LAN_IFACE}|g" \
            -e "s|__LAN_IP__|${LAN_IP}|g" \
            -e "s|__LAN_CIDR__|${LAN_CIDR}|g" \
            "${_NET}"
    fi
}
