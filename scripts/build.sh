#!/usr/bin/env bash
#
# Reproducible build of a FanchmWrt-style OpenWrt image for the
# GL.iNet Flint 3 / GL-BE9300 (IPQ5332), with OpenAppFilter built in.
#
# Run on Ubuntu 22.04/24.04 (or any recent glibc Linux). It does not need
# root. It clones ~2 GB, then builds a full toolchain + image: expect 20-30 GB
# of disk and 1.5-4 hours on 4-8 cores.
#
# Usage:
#   ./scripts/build.sh                     # clone + build with $(nproc) jobs
#   ./scripts/build.sh --jobs 8 --verbose  # more jobs, V=s
#   ./scripts/build.sh --clean             # delete work/ first
#   ./scripts/build.sh --no-download       # reuse dl/
#
# Environment:
#   WORK=/path        build root (default: <repo>/work)
#   JOBS=N            override job count
#   CCACHE_DIR=...    ccache directory (default: ~/.ccache)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
. "$ROOT/versions.env"

WORK="${WORK:-$ROOT/work}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
VERBOSE=0
CLEAN=0
DOWNLOAD=1
REFRESH_FEEDS=0

usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
		--jobs|-j) JOBS="$2"; shift 2 ;;
		--verbose|-v) VERBOSE=1; shift ;;
		--clean) CLEAN=1; shift ;;
		--no-download) DOWNLOAD=0; shift ;;
		--refresh-feeds) REFRESH_FEEDS=1; shift ;;
		--work) WORK="$2"; shift 2 ;;
		--help|-h) usage ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this script must run on Linux (use WSL2, a VM, or GitHub Actions)"
for c in git make gcc python3 tar; do
	command -v "$c" >/dev/null 2>&1 || die "missing build dependency: $c"
done

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
[ -n "$WORK" ] && [ "$WORK" != "/" ] || die "refusing to use '$WORK' as WORK"
TREE="$WORK/openwrt"
OUT="$ROOT/out/$(date +%Y%m%d-%H%M%S)"

case "$TREE" in
	"$WORK"/*) ;;
	*) die "refusing to use build tree outside WORK: $TREE" ;;
esac

if [ "$CLEAN" = 1 ]; then
	log "removing old build tree $TREE"
	rm -rf -- "$TREE"
fi

# ---------------------------------------------------------------------------
# 1. base tree
# ---------------------------------------------------------------------------
if [ ! -d "$TREE/.git" ]; then
	log "cloning base tree ($BASE_TAG)"
	mkdir -p "$TREE"
	# A CI cache may have pre-created $TREE/dl, so initialise in place instead
	# of `git clone` (which refuses a non-empty destination).
	git -C "$TREE" init -q
	git -C "$TREE" remote add origin "$BASE_REPO" 2>/dev/null || \
		git -C "$TREE" remote set-url origin "$BASE_REPO"
	GIT_TERMINAL_PROMPT=0 git -C "$TREE" fetch --depth 1 origin "tag" "$BASE_TAG"
	git -C "$TREE" checkout -q FETCH_HEAD
else
	log "updating base tree to $BASE_TAG"
	GIT_TERMINAL_PROMPT=0 git -C "$TREE" fetch --depth 1 origin "tag" "$BASE_TAG" || true
	git -C "$TREE" checkout -q "$BASE_TAG"
fi

head_sha="$(git -C "$TREE" rev-parse HEAD)"
if [ "$head_sha" != "$BASE_COMMIT" ]; then
	die "base commit mismatch: got $head_sha, expected $BASE_COMMIT (tag moved?)"
fi
log "base commit verified: $head_sha"

# ---------------------------------------------------------------------------
# 2. feeds (pinned to the base snapshot date)
# ---------------------------------------------------------------------------
cp -f "$ROOT/feeds.conf" "$TREE/feeds.conf.default"

if [ "$REFRESH_FEEDS" = 1 ] || [ ! -d "$TREE/feeds/luci" ] || [ ! -d "$TREE/feeds/packages" ]; then
	log "updating feeds"
	( cd "$TREE" && ./scripts/feeds update -a )
else
	log "feeds already present (use --refresh-feeds to force an update)"
fi
log "installing feeds"
( cd "$TREE" && ./scripts/feeds install -a )

# ---------------------------------------------------------------------------
# 3. OpenAppFilter + board overlay
# ---------------------------------------------------------------------------
if [ ! -d "$TREE/package/OpenAppFilter/.git" ]; then
	log "cloning OpenAppFilter $OAF_VERSION"
	GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$OAF_REPO" "$TREE/package/OpenAppFilter"
else
	log "updating OpenAppFilter"
	GIT_TERMINAL_PROMPT=0 git -C "$TREE/package/OpenAppFilter" fetch --depth 1 origin "$OAF_COMMIT" || true
fi

if ! git -C "$TREE/package/OpenAppFilter" checkout -q "$OAF_COMMIT" 2>/dev/null; then
	warn "pinned OAF commit not in shallow clone; fetching full history"
	GIT_TERMINAL_PROMPT=0 git -C "$TREE/package/OpenAppFilter" fetch --unshallow origin
	git -C "$TREE/package/OpenAppFilter" checkout -q "$OAF_COMMIT"
fi
log "OAF commit: $(git -C "$TREE/package/OpenAppFilter" rev-parse --short HEAD)"

# GCC 14 promotes implicit function declarations to errors. OAF builds with
# -Werror=implicit-function-declaration, which turns any older-style call into
# a hard failure. Downgrade it to a warning: the symbols still resolve at link
# time, and this keeps the package buildable on current OpenWrt toolchains.
OAF_MAKE="$TREE/package/OpenAppFilter/open-app-filter/Makefile"
if grep -q -- '-Werror=implicit-function-declaration' "$OAF_MAKE"; then
	sed -i 's/-Werror=implicit-function-declaration/-Wno-error=implicit-function-declaration/' "$OAF_MAKE"
fi

# OAF's hand-written Build/Compile passes only TARGET_CFLAGS, which in
# OpenWrt is optimisation flags only. Package headers (uci.h, json-c, ubus,
# sqlite3, curl) live under $(STAGING_DIR)/usr/include, and those paths are in
# TARGET_CPPFLAGS. Without this the compile fails on the first #include.
if ! grep -q 'TARGET_CPPFLAGS' "$OAF_MAKE"; then
	sed -i 's|CFLAGS="$(TARGET_CFLAGS)"|CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)"|' "$OAF_MAKE"
fi

# OAF reads per-flow packet counters through nf_conn_acct_find(). If
# CONFIG_NF_CONNTRACK_ACCT is off that helper returns NULL and the hook exits
# early: the module loads, LuCI looks fine, and nothing is ever classified.
# Linux defaults this symbol to n, and kmod-nf-conntrack does not select it,
# so force it both in the package's KCONFIG and in the subtarget kernel config.
OAF_KMAKE="$TREE/package/OpenAppFilter/oaf/Makefile"
if ! grep -q 'CONFIG_NF_CONNTRACK_ACCT' "$OAF_KMAKE"; then
	sed -i 's/^\([[:space:]]*\)KCONFIG:=/\1KCONFIG:=CONFIG_NF_CONNTRACK_ACCT=y /' "$OAF_KMAKE"
fi
# Some kernel configs set CONFIG_WERROR=y. OAF is old-style C and would then
# fail on cosmetic warnings; keep warnings visible but non-fatal for this
# module only.
if ! grep -q '^KCFLAGS := -Wno-error ' "$OAF_KMAKE"; then
	sed -i 's/^KCFLAGS := /KCFLAGS := -Wno-error /' "$OAF_KMAKE"
fi

KCONFIG_DEFAULT="$TREE/target/linux/qualcommbe/ipq53xx/config-default"
if ! grep -q '^CONFIG_NF_CONNTRACK_ACCT=y' "$KCONFIG_DEFAULT"; then
	printf '\n# OpenAppFilter: per-flow packet accounting (nf_conn_acct_find)\nCONFIG_NF_CONNTRACK_ACCT=y\n' >> "$KCONFIG_DEFAULT"
fi

log "installing board overlay"
rm -rf "$TREE/package/be9300-defaults"
cp -a "$ROOT/package/be9300-defaults" "$TREE/package/"

# ---------------------------------------------------------------------------
# 4. configuration
# ---------------------------------------------------------------------------
log "writing .config and running defconfig"
cp -f "$ROOT/configs/be9300-oaf.config" "$TREE/.config"
( cd "$TREE" && make defconfig )
"$ROOT/scripts/verify-config.sh" "$TREE/.config"

if [ "$DOWNLOAD" = 1 ]; then
	log "downloading sources (retries on flaky mirrors)"
	ok=0
	for attempt in 1 2 3; do
		if ( cd "$TREE" && make -j"$JOBS" download ); then ok=1; break; fi
		warn "download attempt $attempt failed; retrying in 15s"
		sleep 15
	done
	[ "$ok" = 1 ] || die "make download failed after 3 attempts"
fi

# ---------------------------------------------------------------------------
# 5. build
# ---------------------------------------------------------------------------
mkdir -p "$OUT"
make_args=(-j"$JOBS")
[ "$VERBOSE" = 1 ] && make_args+=(V=s)

log "building image (log: $OUT/build.log)"
if ! ( cd "$TREE" && make "${make_args[@]}" 2>&1 | tee "$OUT/build.log" ); then
	tail -n 80 "$OUT/build.log" >&2 || true
	die "build failed; full log: $OUT/build.log (package logs under $TREE/logs/)"
fi

# ---------------------------------------------------------------------------
# 6. collect + verify
# ---------------------------------------------------------------------------
IMG_DIR="$TREE/bin/targets/qualcommbe/ipq53xx"
[ -d "$IMG_DIR" ] || die "image directory not found: $IMG_DIR"

shopt -s nullglob
images=("$IMG_DIR"/*.bin "$IMG_DIR"/*.itb "$IMG_DIR"/*.manifest "$IMG_DIR"/*.buildinfo "$IMG_DIR"/sha256sums)
[ "${#images[@]}" -gt 0 ] || die "no images produced in $IMG_DIR"

cp -f "${images[@]}" "$OUT/"
"$ROOT/scripts/verify-image.sh" "$OUT"

log "done"
printf 'images: %s\n' "$OUT"
ls -lh "$OUT"
