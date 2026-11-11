#!/usr/bin/env bash
#
# Fail early if `make defconfig` dropped something essential. An image without
# kmod-oaf looks fine until you open LuCI and the daemon cannot load its
# module, so check the resolved .config, not the seed file.
set -euo pipefail

cfg="${1:?usage: verify-config.sh <openwrt/.config>}"
[ -f "$cfg" ] || { echo "no such config: $cfg" >&2; exit 1; }

fail=0
need() {
	if ! grep -qx "$1=y" "$cfg"; then
		echo "  missing: $1=y" >&2
		fail=1
	fi
}
need_any() {
	if ! grep -qE "^($1)=y$" "$cfg"; then
		echo "  missing: one of $1=y" >&2
		fail=1
	fi
}

need CONFIG_TARGET_qualcommbe
need CONFIG_TARGET_qualcommbe_ipq53xx
need CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_glinet_gl-be9300
need CONFIG_TARGET_ROOTFS_SQUASHFS

# router base, otherwise OAF has no netfilter path to hook into
need CONFIG_PACKAGE_firewall4
need CONFIG_PACKAGE_kmod-nft-offload
need CONFIG_PACKAGE_kmod-nf-conntrack
need_any 'CONFIG_PACKAGE_dnsmasq|CONFIG_PACKAGE_dnsmasq-full'

# LuCI + OAF
need CONFIG_PACKAGE_luci-ssl-openssl
need CONFIG_PACKAGE_luci-compat
need CONFIG_PACKAGE_luci-lib-jsonc
need CONFIG_PACKAGE_luci-app-oaf
need CONFIG_PACKAGE_appfilter
need CONFIG_PACKAGE_kmod-oaf
need CONFIG_PACKAGE_be9300-defaults

if [ "$fail" -ne 0 ]; then
	cat >&2 <<'EOF'

The resolved configuration is not usable. Usual causes:
  * a package name changed in the pinned feed snapshot;
  * a dependency was not selected because its feed was missing;
  * defconfig resolved kmod-oaf as =m (module) instead of =y.

Inspect with:
  grep -E 'OAF|oaf|appfilter|firewall4|dnsmasq' .config
EOF
	exit 1
fi

echo "config OK: target + router base + LuCI + OAF + board defaults are all =y"
