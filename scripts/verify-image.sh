#!/usr/bin/env bash
#
# Post-build sanity checks: the artifacts exist, the package manifest really
# contains OAF, and the checksums verify.
set -euo pipefail

dir="${1:?usage: verify-image.sh <output-dir>}"
[ -d "$dir" ] || { echo "no such directory: $dir" >&2; exit 1; }

shopt -s nullglob
bins=("$dir"/*.bin)
itbs=("$dir"/*.itb)
manifests=("$dir"/*.manifest)
sums=("$dir"/sha256sums)

fail=0
note() { echo "  $*" >&2; fail=1; }

[ "${#bins[@]}" -gt 0 ] || note "no .bin image"
[ "${#manifests[@]}" -gt 0 ] || note "no .manifest"

factory=""
sysupgrade=""
for f in "${bins[@]}"; do
	case "$f" in
		*factory*.bin) factory="$f" ;;
		*sysupgrade*.bin) sysupgrade="$f" ;;
	esac
done
[ -n "$factory" ] || note "no *factory*.bin (cannot flash from stock)"
[ -n "$sysupgrade" ] || note "no *sysupgrade*.bin (cannot upgrade from OpenWrt)"

if [ "${#manifests[@]}" -gt 0 ]; then
	m="${manifests[0]}"
	for pkg in luci-app-oaf kmod-oaf appfilter luci-compat be9300-defaults; do
		if ! grep -qE "^${pkg}([[:space:]]|$)" "$m"; then
			note "package missing from manifest: $pkg"
		fi
	done
	if ! grep -qE '^kernel[[:space:]]' "$m"; then
		note "no kernel entry in manifest"
	fi
else
	m=""
fi

if [ "${#sums[@]}" -gt 0 ]; then
	( cd "$dir" && sha256sum -c sha256sums --ignore-missing ) || note "sha256sums verification failed"
fi

if [ "$fail" -ne 0 ]; then
	echo "image verification FAILED" >&2
	exit 1
fi

echo "image verification OK"
[ -n "$m" ] && echo "manifest: $m"
printf 'factory:   %s\n' "$factory"
printf 'sysupgrade: %s\n' "$sysupgrade"
printf 'initramfs: %s\n' "${itbs[*]:-<none>}"
