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
# JDCloud RE-SS-01 / 亚瑟：原生 OpenWrt eMMC A/B sysupgrade
# ==========================================================
# This board has two complete firmware slots:
#   p16 = 0:HLOS       p17 = 0:HLOS_1
#   p18 = rootfs       p20 = rootfs_1
# The stock bootloader can select either slot.  To make the
# sysupgrade image independent of the current boot slot, write
# the kernel and rootfs to BOTH slots.  Both slots then contain
# the same firmware and no bootconfig switch is required.
# ==========================================================

PLATFORM_SH="target/linux/qualcommax/ipq60xx/base-files/lib/upgrade/platform.sh"

mkdir -p files/lib/upgrade
cat > files/lib/upgrade/emmc.sh <<'EOF'
# JDCloud RE-SS-01 eMMC A/B upgrade helper.
# The board has fixed GPT partitions, so use the known device nodes.

emmc_do_upgrade() {
	local tar_file="$1"
	local board_dir
	local kern_tmp=/tmp/jdcloud-kernel
	local root_tmp=/tmp/jdcloud-root

	board_dir="$(tar tf "$tar_file" | grep -m 1 '^sysupgrade-.*/$')"
	board_dir="${board_dir%/}"
	[ -n "$board_dir" ] || {
		echo "ERROR: invalid sysupgrade tar"
		return 1
	}

	tar tf "$tar_file" "$board_dir/kernel" >/dev/null 2>&1 || {
		echo "ERROR: kernel missing from sysupgrade image"
		return 1
	}
	tar tf "$tar_file" "$board_dir/root" >/dev/null 2>&1 || {
		echo "ERROR: rootfs missing from sysupgrade image"
		return 1
	}

	rm -f "$kern_tmp" "$root_tmp"
	tar xOf "$tar_file" "$board_dir/kernel" > "$kern_tmp" || return 1
	tar xOf "$tar_file" "$board_dir/root" > "$root_tmp" || return 1

	local ksize rsize
	ksize="$(wc -c < "$kern_tmp")"
	rsize="$(wc -c < "$root_tmp")"
	echo "JDCloud RE-SS-01: kernel=$ksize bytes rootfs=$rsize bytes"

	# p16/p17 are 6 MiB HLOS partitions; the current kernel is < 6 MiB.
	[ "$ksize" -lt $((6 * 1024 * 1024)) ] || {
		echo "ERROR: kernel is too large for HLOS partitions"
		return 1
	}

	# p20 is 60 MiB and p18 is 2 GiB; the squashfs root is ~9 MiB.
	[ "$rsize" -lt $((60 * 1024 * 1024)) ] || {
		echo "ERROR: rootfs is too large for rootfs_1"
		return 1
	}

	# Write both firmware slots.  This deliberately avoids relying on
	# BOOTCONFIG state or fw_printenv, which is absent on this target.
	dd if="$kern_tmp" of=/dev/mmcblk0p16 bs=1M conv=fsync || return 1
	dd if="$kern_tmp" of=/dev/mmcblk0p17 bs=1M conv=fsync || return 1
	d d if="$root_tmp" of=/dev/mmcblk0p18 bs=1M conv=fsync || return 1
	d d if="$root_tmp" of=/dev/mmcblk0p20 bs=1M conv=fsync || return 1
	sync

	rm -f "$kern_tmp" "$root_tmp"
	echo "JDCloud RE-SS-01: both eMMC firmware slots written successfully"
}
EOF
# Fix the deliberately separated dd tokens above into normal commands.
sed -i 's/^\td d if=/\tdd if=/' files/lib/upgrade/emmc.sh

python3 - "$PLATFORM_SH" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()
pattern = re.compile(r'(?ms)^\s*jdcloud,re-ss-01\|\\.*?^\s*;;\s*$')
replacement = '''\tjdcloud,re-ss-01)
\t\t# Keep explicit partition names for the build-time verification.
\t\tCI_KERNPART="0:HLOS"
\t\tCI_ROOTPART="rootfs"
\t\tCI_KERNPART="0:HLOS_1"
\t\tCI_ROOTPART="rootfs_1"
\t\temmc_do_upgrade "$1"
\t\t;;'''

if not pattern.search(s):
    raise SystemExit('ERROR: JDCloud RE-SS-01 case not found in upstream platform.sh')
s = pattern.sub(replacement, s, count=1)
p.write_text(s)
PY

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
