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
# 实际布局：
#   p16 = 0:HLOS       p17 = 0:HLOS_1
#   p18 = rootfs       p20 = rootfs_1
# BOOTCONFIG 的 byte 148 决定当前槽位。
# sysupgrade 使用 tar 包，必须由 emmc_do_upgrade() 写入
# 对应 HLOS/rootfs，而不能使用旧的 mmc_do_upgrade()。
# ==========================================================

PLATFORM_SH="target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh"
mkdir -p files/lib/upgrade

cat > files/lib/upgrade/emmc.sh <<'EOF'
# Copyright (C) 2021 OpenWrt.org

. /lib/functions.sh

emmc_upgrade_tar() {
	local tar_file="$1"
	[ "$CI_KERNPART" -a -z "$EMMC_KERN_DEV" ] && export EMMC_KERN_DEV="$(find_mmc_part $CI_KERNPART $CI_ROOTDEV)"
	[ "$CI_ROOTPART" -a -z "$EMMC_ROOT_DEV" ] && export EMMC_ROOT_DEV="$(find_mmc_part $CI_ROOTPART $CI_ROOTDEV)"
	[ "$CI_DATAPART" -a -z "$EMMC_DATA_DEV" ] && export EMMC_DATA_DEV="$(find_mmc_part $CI_DATAPART $CI_ROOTDEV)"
	[ "$CI_DTBPART" -a -z "$EMMC_DTB_DEV" ] && export EMMC_DTB_DEV="$(find_mmc_part $CI_DTBPART $CI_ROOTDEV)"
	local has_kernel has_rootfs has_dtb gz board_dir
	[ "$(identify_magic_long $(get_magic_long "$tar_file" cat))" = "gzip" ] && gz="z"
	board_dir=$(tar t${gz}f "$tar_file" | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	tar t${gz}f "$tar_file" ${board_dir}/kernel >/dev/null 2>/dev/null && has_kernel=1
	tar t${gz}f "$tar_file" ${board_dir}/root >/dev/null 2>/dev/null && has_rootfs=1
	tar t${gz}f "$tar_file" ${board_dir}/dtb >/dev/null 2>/dev/null && has_dtb=1

	[ "$has_rootfs" = 1 -a "$EMMC_ROOT_DEV" ] && {
		[ "$has_kernel" = 1 -a "$EMMC_KERN_DEV" ] && {
			dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 count=8
			sync
		}
		export EMMC_ROOTFS_BLOCKS=$(($(tar x${gz}f "$tar_file" ${board_dir}/root -O | dd of="$EMMC_ROOT_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))
		EMMC_ROOTFS_BLOCKS=$(((EMMC_ROOTFS_BLOCKS + 127) & ~127))
		sync
	}
	[ "$has_dtb" = 1 -a "$EMMC_DTB_DEV" ] && export EMMC_DTB_BLOCKS=$(($(tar x${gz}f "$tar_file" ${board_dir}/dtb -O | dd of="$EMMC_DTB_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))
	[ "$has_kernel" = 1 -a "$EMMC_KERN_DEV" ] && export EMMC_KERNEL_BLOCKS=$(($(tar x${gz}f "$tar_file" ${board_dir}/kernel -O | dd of="$EMMC_KERN_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))

	if [ -z "$UPGRADE_BACKUP" ]; then
		if [ "$EMMC_DATA_DEV" ]; then
			dd if=/dev/zero of="$EMMC_DATA_DEV" bs=512 count=8
		elif [ "$EMMC_ROOTFS_BLOCKS" ]; then
			dd if=/dev/zero of="$EMMC_ROOT_DEV" bs=512 seek=$EMMC_ROOTFS_BLOCKS count=8
		elif [ "$EMMC_KERNEL_BLOCKS" ]; then
			dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS count=8
		fi
	fi
}

emmc_upgrade_fit() {
	local fit_file="$1"
	[ "$CI_KERNPART" -a -z "$EMMC_KERN_DEV" ] && export EMMC_KERN_DEV="$(find_mmc_part $CI_KERNPART $CI_ROOTDEV)"
	if [ "$EMMC_KERN_DEV" ]; then
		export EMMC_KERNEL_BLOCKS=$(($(get_image "$fit_file" | fwtool -i /dev/null -T - | dd of="$EMMC_KERN_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))
		[ -z "$UPGRADE_BACKUP" ] && dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS count=8
	fi
}

emmc_copy_config() {
	if [ "$EMMC_DATA_DEV" ]; then
		dd if="$UPGRADE_BACKUP" of="$EMMC_DATA_DEV" bs=512
	elif [ "$EMMC_ROOTFS_BLOCKS" ]; then
		dd if="$UPGRADE_BACKUP" of="$EMMC_ROOT_DEV" bs=512 seek=$EMMC_ROOTFS_BLOCKS
	elif [ "$EMMC_KERNEL_BLOCKS" ]; then
		dd if="$UPGRADE_BACKUP" of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS
	fi
}

emmc_do_upgrade() {
	local file_type=$(identify_magic_long "$(get_magic_long "$1")")
	case "$file_type" in
		fit) emmc_upgrade_fit "$1" ;;
		*) emmc_upgrade_tar "$1" ;;
	esac
}
EOF
chmod 0755 files/lib/upgrade/emmc.sh

# Replace the complete JDCloud eMMC dispatch block, rather than replacing
# a single occurrence. This avoids leaving duplicate/stale handlers when
# the LiBwrt target source changes.
python3 - "$PLATFORM_SH" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

new_case = '''\tjdcloud,re-ss-01|\\
\tjdcloud,re-cs-02|\\
\tjdcloud,re-cs-07|\\
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

# Match from the first JDCloud entry through the end of the adjacent
# eMMC case, stopping immediately before the next device case.
pattern = re.compile(
    r'(?ms)^\tjdcloud,re-ss-01\|\\\n.*?^\t\t;;\n(?=\t(?:netgear|tplink|yuncore|linksys),)'
)
match = pattern.search(text)
if not match:
    raise SystemExit('ERROR: cannot find JDCloud eMMC dispatch block')
text = text[:match.start()] + new_case + '\n' + text[match.end():]
path.write_text(text)
PY

# Validate only the JDCloud block. The source target may legitimately
# contain mmc_do_upgrade handlers for other boards; those must not fail
# the RE-SS-01 check.
python3 - "$PLATFORM_SH" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
m = re.search(r'(?ms)^\tjdcloud,re-ss-01\|\\\n.*?^\t\t;;\n(?=\t(?:netgear|tplink|yuncore|linksys),)', text)
if not m:
    raise SystemExit('ERROR: JDCloud eMMC block not found')
block = m.group(0)
if 'emmc_do_upgrade "$1"' not in block:
    raise SystemExit('ERROR: JDCloud block is not using emmc_do_upgrade')
if 'mmc_do_upgrade "$1"' in block:
    raise SystemExit('ERROR: stale mmc_do_upgrade handler remains in JDCloud block')
if 'CI_KERNPART="0:HLOS_1"' not in block or 'CI_ROOTPART="rootfs_1"' not in block:
    raise SystemExit('ERROR: inactive-slot mapping missing')
if 'CI_KERNPART="0:HLOS"' not in block or 'CI_ROOTPART="rootfs"' not in block:
    raise SystemExit('ERROR: active-slot mapping missing')
echo = print
echo('RE-SS-01 eMMC upgrade handler: OK')
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
