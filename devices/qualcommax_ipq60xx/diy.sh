#!/bin/bash

shopt -s extglob

SHELL_FOLDER=$(dirname $(readlink -f "$0"))

rm -rf package/boot package/firmware/ipq-wifi target/linux/generic target/linux/qualcommax package/firmware/ath11k-firmware package/kernel/mac80211 package/kernel/nat46

git_clone_path main-nss https://github.com/LiBwrt/openwrt-6.x target/linux/generic target/linux/qualcommax package/boot package/firmware/ipq-wifi package/firmware/ath11k-firmware package/kernel/mac80211 package/kernel/nat46

wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/main-nss/include/image-commands.mk -P include/
wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/main-nss/config/Config-ipq.in -P config/
wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/main-nss/Config.in -P ./

rm -rf feeds/kiddin9/shortcut-fe

git clone https://github.com/qosmio/nss-packages.git package/nss-packages
git clone https://github.com/qosmio/sqm-scripts-nss.git package/sqm-scripts-nss

sed -i "/ECM_INTERFACE_RAWIP_ENABLE/d" package/nss-packages/qca-nss-ecm/Makefile
rm -rf package/nss-packages/nss-userspace-oss

sed -i "s/luci uboot-envtools wpad-openssl/luci uboot-envtools wpad-mbedtls/" target/linux/qualcommax/Makefile

# ==========================================================
# JDCloud RE-SS-01 / 亚瑟：纯净配置
# ==========================================================
# 上游 LiBwrt 的 ipq60xx.mk 已经包含正确的
# Device/jdcloud_re-ss-01 + Device/EmmcImage 定义。
# 不在这里二次改 image 定义，避免与上游设备定义冲突。
#
# 2 GiB rootfs/overlay 的大小由本设备 .config 中的
# CONFIG_TARGET_ROOTFS_PARTSIZE=2048 控制；实际 eMMC 分区表
# 仍需与已经验证的 2 GiB GPT 布局匹配。
# ==========================================================

# Kwrt common/diy.sh 会把一批 luci-app-* 写进 DEFAULT_PACKAGES。
# 本配置要求“无插件”，因此在 target 层把这些第三方/可选 LuCI
# 应用从默认包列表中移除；基础 luci/luci-ssl 仍由 .config 保留。
if [ -f include/target.mk ]; then
    sed -i -E 's/ ?luci-app-[^ ]+//g' include/target.mk
fi

# 清掉可能由 feeds 默认配置拉入的常见第三方插件选择；
# 不删除驱动、NSS、LuCI 基础组件或系统必需包。
cat >> .config <<'EOF'

# JDCloud RE-SS-01 clean profile: no optional LuCI applications
CONFIG_PACKAGE_luci-app-advancedplus=n
CONFIG_PACKAGE_luci-app-firewall=n
CONFIG_PACKAGE_luci-app-package-manager=n
CONFIG_PACKAGE_luci-app-upnp=n
CONFIG_PACKAGE_luci-app-syscontrol=n
CONFIG_PACKAGE_luci-app-wizard=n
CONFIG_PACKAGE_luci-app-fan=n
CONFIG_PACKAGE_luci-app-filemanager=n
CONFIG_PACKAGE_luci-app-wifihistory=n
CONFIG_PACKAGE_luci-app-store=n
CONFIG_PACKAGE_luci-app-ttyd=n
CONFIG_PACKAGE_luci-app-homeproxy=n
CONFIG_PACKAGE_luci-app-mosdns=n
CONFIG_PACKAGE_luci-app-adguardhome=n
CONFIG_PACKAGE_luci-app-openclash=n
CONFIG_PACKAGE_luci-app-passwall=n
CONFIG_PACKAGE_luci-app-passwall2=n

# 不要把代理核心作为默认插件带入
CONFIG_PACKAGE_xray-core=n
CONFIG_PACKAGE_sing-box=n
CONFIG_PACKAGE_hysteria=n

# 保证 LAN 默认地址由本设备专用 UCI defaults 固定
EOF

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-jdcloud-re-ss-01-clean <<'EOF'
#!/bin/sh

# 只修改 LAN 地址，保留 target 自己生成的 WAN/LAN 端口布局。
if uci -q get network.lan >/dev/null 2>&1; then
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='192.168.20.1'
    uci set network.lan.netmask='255.255.255.0'
fi

uci set system.@system[0].hostname='JDCloud-AX1800-Pro'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'

uci commit network
uci commit system

exit 0
EOF
chmod +x files/etc/uci-defaults/99-jdcloud-re-ss-01-clean
