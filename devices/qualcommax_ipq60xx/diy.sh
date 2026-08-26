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
# JDCloud RE-SS-01 / 亚瑟：使用 OpenWrt 原生 eMMC A/B 升级逻辑
# ==========================================================
# RE-SS-01 的正确分区：
#   p2  = 0:BOOTCONFIG
#   p16 = 0:HLOS
#   p17 = 0:HLOS_1
#   p18 = rootfs
#   p20 = rootfs_1
# OpenWrt 原生 emmc_do_upgrade() 已支持该 sysupgrade tar。
# BOOTCONFIG 偏移 148 用于选择要写入的槽位。
# 不再使用不存在的 mmc_do_upgrade，也不覆盖原生 emmc.sh。
# ==========================================================

PLATFORM_SH="target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh"

# Remove any previous custom overlay and use the OpenWrt base-files
# implementation of emmc_do_upgrade().
rm -f files/lib/upgrade/emmc.sh

# LiBwrt's platform.sh is older than the OpenWrt 25.12 implementation.
# Replace the complete JDCloud block with the upstream eMMC handler.
python3 - "$PLATFORM_SH" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

start = re.search(r'(?m)^\s*jdcloud,re-ss-01\|\\\n', text)
if not start:
    raise SystemExit('ERROR: JDCloud case not found')

end = re.search(r'(?m)^\s*;;\s*$', text[start.end():])
if not end:
    raise SystemExit('ERROR: JDCloud case terminator not found')

replacement = '''\tjdcloud,re-cs-02|\\
\tjdcloud,re-cs-07|\\
\tjdcloud,re-ss-01|\\
\tlink,nn6000-v1|\\
\tlink,nn6000-v2)
\t\tlocal cfgpart=$(find_mmc_part "0:BOOTCONFIG")
\t\tpart_num="$(hexdump -e '1/1 "%01x|"' -n 1 -s 148 -C "$cfgpart" | cut -f 1 -d "|" | head -n1)"
\t\tif [ "$part_num" -eq "1" ]; then
\t\t\tCI_KERNPART="0:HLOS_1"
\t\t\tCI_ROOTPART="rootfs_1"
\t\telse
\t\t\tCI_KERNPART="0:HLOS"
\t\t\tCI_ROOTPART="rootfs"
\t\tfi
\t\temmc_do_upgrade "$1"
\t\t;;'''

text = text[:start.start()] + replacement + text[start.end() + end.end():]
path.write_text(text)
PY

# Verify the exact handler before compilation.
python3 - "$PLATFORM_SH" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
m = re.search(r'(?ms)^\s*jdcloud,re-cs-02\|\\\n.*?^\s*;;\s*$', text)
if not m:
    raise SystemExit('ERROR: JDCloud eMMC block not found')
block = m.group(0)
for needle in (
    'local cfgpart=$(find_mmc_part "0:BOOTCONFIG")',
    'CI_KERNPART="0:HLOS_1"',
    'CI_ROOTPART="rootfs_1"',
    'CI_KERNPART="0:HLOS"',
    'CI_ROOTPART="rootfs"',
    'emmc_do_upgrade "$1"',
):
    if needle not in block:
        raise SystemExit(f'ERROR: missing {needle}')
if re.search(r'(?m)^\s*mmc_do_upgrade "\$1"', block):
    raise SystemExit('ERROR: stale mmc_do_upgrade handler remains in JDCloud block')
print('RE-SS-01 eMMC upgrade handler: OK')
PY

# Clean profile: no optional LuCI apps or proxy cores.
if [ -f include/target.mk ]; then
    sed -i -E 's/ ?luci-app-[^ ]+//g' include/target.mk
fi

cat >> .config <<'EOF'

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
CONFIG_PACKAGE_xray-core=n
CONFIG_PACKAGE_sing-box=n
CONFIG_PACKAGE_hysteria=n
EOF

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-jdcloud-re-ss-01-clean <<'EOF'
#!/bin/sh
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
