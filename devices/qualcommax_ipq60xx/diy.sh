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
# Device/jdcloud_re-ss-01 + Device/FitImage 定义。
# RE-SS-01 是 eMMC 双启动槽位设备，sysupgrade 必须写入
# 当前非活动槽位，并由 0:BOOTCONFIG 的 byte 148 决定目标槽位。
# 这里强制使用 OpenWrt 已验证的 mmc_do_upgrade 路径，避免
# 直接写当前 HLOS 后重启又回到旧系统。
# ==========================================================

PLATFORM_SH="target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh"
python3 - "$PLATFORM_SH" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

new_case = '''\tjdcloud,re-cs-02|\\
\tjdcloud,re-cs-07|\\
\tjdcloud,re-ss-01|\\
\tlink,nn6000-v1|\\
\tlink,nn6000-v2)
\t\tlocal cfgpart=$(find_mmc_part "0:BOOTCONFIG")
\t\t[ -n "$cfgpart" ] || return 1

\t\tpart_num="$(hexdump -e '1/1 "%01x|"' -n 1 -s 148 -C "$cfgpart" | cut -f 1 -d "|" | head -n1)"
\t\tif [ "$part_num" -eq "1" ]; then
\t\t\tCI_KERNPART="0:HLOS_1"
\t\t\tCI_ROOTPART="rootfs_1"
\t\telse
\t\t\tCI_KERNPART="0:HLOS"
\t\t\tCI_ROOTPART="rootfs"
\t\tfi

\t\tEMMC_KERN_DEV="$(find_mmc_part "$CI_KERNPART" "$CI_ROOTDEV")"
\t\tEMMC_ROOT_DEV="$(find_mmc_part "$CI_ROOTPART" "$CI_ROOTDEV")"
\t\temmc_do_upgrade "$1"
\t\t;;'''

pattern = re.compile(
    r'(?m)^\tjdcloud,re-cs-02\|\\\n.*?^\t\temmc_do_upgrade "\$1"\n\t\t;;',
    re.S,
)

m = pattern.search(text)
if not m:
    raise SystemExit("ERROR: RE-SS-01 eMMC upgrade case not found in platform.sh")

text = text[:m.start()] + new_case + text[m.end():]
path.write_text(text)
PY

# Sanity-check the generated upgrade handler during the build.
grep -A25 -B2 'jdcloud,re-cs-02' "$PLATFORM_SH"

# Kwrt common/diy.sh can add optional luci-app-* entries to DEFAULT_PACKAGES.
# This profile is intentionally clean: keep base LuCI, remove optional apps.
if [ -f include/target.mk ]; then
    sed -i -E 's/ ?luci-app-[^ ]+//g' include/target.mk
fi

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
