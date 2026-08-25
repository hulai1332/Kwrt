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
# JDCloud RE-SS-01 / 亚瑟
# ==========================================================
# RE-SS-01 使用 eMMC。这里把官方设备定义切换到 EmmcImage，
# 并加入 F2FS 支持；2G Overlay 本身依赖刷入匹配的 2G GPT。
# 这不会修改你现有设备的 GPT，也不会把其它 eMMC 分区写入 factory 镜像。
# ==========================================================

python3 - <<'PY'
from pathlib import Path

p = Path('target/linux/qualcommax/image/ipq60xx.mk')
s = p.read_text()
old = '''define Device/jdcloud_re-ss-01
\t$(call Device/FitImage)
\tDEVICE_VENDOR := JDCloud
\tDEVICE_MODEL := RE-SS-01
\tSOC := ipq6000
\tBLOCKSIZE := 64k
\tKERNEL_SIZE := 6144k
\tDEVICE_DTS_CONFIG := config@cp03-c2
\tDEVICE_PACKAGES := ipq-wifi-jdcloud_re-ss-01
endef
TARGET_DEVICES += jdcloud_re-ss-01'''
new = '''define Device/jdcloud_re-ss-01
\t$(call Device/FitImage)
\t$(call Device/EmmcImage)
\tDEVICE_VENDOR := JDCloud
\tDEVICE_MODEL := RE-SS-01
\tSOC := ipq6000
\tBLOCKSIZE := 64k
\tKERNEL_SIZE := 6144k
\tDEVICE_DTS_CONFIG := config@cp03-c2
\tDEVICE_PACKAGES := ipq-wifi-jdcloud_re-ss-01 kmod-fs-f2fs f2fs-tools
endef
TARGET_DEVICES += jdcloud_re-ss-01'''

if old not in s:
    raise SystemExit('JDCloud RE-SS-01 image definition not found; aborting instead of guessing.')
p.write_text(s.replace(old, new, 1))
PY

# 固定 LAN 为 192.168.20.1，不覆盖 target 自己生成的网口布局。
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-jdcloud-re-ss-01-clean <<'EOF'
#!/bin/sh

# 只修改 LAN 地址，保留设备 target 原本的 WAN/LAN 端口定义。
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

# 明确不选择任何第三方插件；插件仓库可以存在，但不会进入最终固件。
# 保留 NSS 源码以维持 Kwrt 的 Qualcomm/NSS 基础支持。
