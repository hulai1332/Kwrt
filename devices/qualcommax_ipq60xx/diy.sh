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
# JDCloud RE-SS-01 / 亚瑟：eMMC sysupgrade 修复
# ==========================================================
# 实际分区：p16=0:HLOS, p17=0:HLOS_1, p18=rootfs,
# p20=rootfs_1。BOOTCONFIG/p2 的 byte 148 为当前槽位：
# 0 = HLOS/rootfs，1 = HLOS_1/rootfs_1。
# sysupgrade 必须写入“非当前槽”，完成后再切换 BOOTCONFIG。
# ==========================================================

PLATFORM_SH="target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh"
mkdir -p files/lib/upgrade

cat > files/lib/upgrade/emmc.sh <<'EOF'
# Copyright (C) 2021 OpenWrt.org

. /lib/functions.sh
. /lib/upgrade/common.sh

emmc_do_upgrade() {
	local image="$1"
	local board_dir
	local kern_dev root_dev
	local cfgpart="/dev/mmcblk0p2"
	local slot

	# RE-SS-01 is an eMMC dual-slot device.  The sysupgrade image is a tar
	# archive containing kernel and root.  Select the inactive slot directly;
	# this avoids relying on missing fw_env/NVMEM support on this device.
	slot="$(dd if="$cfgpart" bs=1 skip=148 count=1 2>/dev/null | hexdump -v -e '1/1 "%u"')"
	case "$slot" in
		1)
			kern_dev="/dev/mmcblk0p16"
			root_dev="/dev/mmcblk0p18"
			new_slot=0
			;;
		*)
			kern_dev="/dev/mmcblk0p17"
			root_dev="/dev/mmcblk0p20"
			new_slot=1
			;;
	esac

	board_dir="$(tar tf "$image" | sed -n 's#^\(sysupgrade-[^/]*/\)$#\1#p' | head -n 1)"
	[ -n "$board_dir" ] || return 1

	# Kernel and rootfs are separate files in the sysupgrade tar.
	tar xOf "$image" "${board_dir}kernel" > /tmp/re-ss-01-kernel || return 1
	tar xOf "$image" "${board_dir}root" > /tmp/re-ss-01-root || return 1

	# The HLOS partitions are 6 MiB.  Rootfs partitions are 2 GiB and
	# 60 MiB respectively; the image root is written at the beginning.
	dd if=/tmp/re-ss-01-kernel of="$kern_dev" bs=4M conv=fsync || return 1
	dd if=/tmp/re-ss-01-root of="$root_dev" bs=4M conv=fsync || return 1
	sync

	# Switch the boot slot only after both images were written successfully.
	printf '\001' | dd of="$cfgpart" bs=1 seek=148 conv=notrunc 2>/dev/null
	if [ "$new_slot" = 0 ]; then
		printf '\000' | dd of="$cfgpart" bs=1 seek=148 conv=notrunc 2>/dev/null
	else
		printf '\001' | dd of="$cfgpart" bs=1 seek=148 conv=notrunc 2>/dev/null
	fi
	sync
	rm -f /tmp/re-ss-01-kernel /tmp/re-ss-01-root
}
EOF
chmod 0755 files/lib/upgrade/emmc.sh

# Replace the entire JDCloud case with one deterministic block.  Do not use
# a text substitution of only the upgrade call: the previous version left
# the old mmc_do_upgrade handler in the generated source.
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

labels = '''\tjdcloud,re-ss-01|\\
\tjdcloud,re-cs-02|\\
\tjdcloud,re-cs-07|\\
\tlink,nn6000-v1|\\
\tlink,nn6000-v2|\\
\tphilips,ly1800|\\
\tredmi,ax5-jdcloud)'''

replacement = labels + '''
\t\temmc_do_upgrade "$1"
\t\t;;'''

text = text[:start.start()] + replacement + text[start.end() + end.end():]
path.write_text(text)
PY

# Verify the generated target source before compilation.
python3 - "$PLATFORM_SH" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
m = re.search(r'(?ms)^\s*jdcloud,re-ss-01\|\\\n.*?^\s*;;\s*$', text)
if not m:
    raise SystemExit('ERROR: JDCloud eMMC block not found')
block = m.group(0)
if 'emmc_do_upgrade "$1"' not in block:
    raise SystemExit('ERROR: JDCloud block is not using emmc_do_upgrade')
if 'mmc_do_upgrade "$1"' in block:
    raise SystemExit('ERROR: stale mmc_do_upgrade handler remains in JDCloud block')
print('RE-SS-01 eMMC upgrade handler: OK')
PY

test -f files/lib/upgrade/emmc.sh
grep -q 'emmc_do_upgrade' files/lib/upgrade/emmc.sh
echo 'emmc.sh: OK'

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
