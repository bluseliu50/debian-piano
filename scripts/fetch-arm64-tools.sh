#!/usr/bin/env bash
# fetch-arm64-tools.sh — stage the arm64 userland pieces of the test image.
#
# Usage: scripts/fetch-arm64-tools.sh [--suite SUITE] [--output-dir DIR]
#
# Downloads Debian/Alpine packages and dropbear sources, and stages:
#
#   DIR/busybox/             static busybox from Debian busybox-static
#   DIR/musl-sysroot/        Alpine musl-dev (aarch64) sysroot used to
#                            cross-compile the static piano-pd-locator and
#                            dropbear (crt1.o + libc.a only; toolchain
#                            material, never shipped into any repository)
#   DIR/dropbear-static/     STATIC dropbear + dropbearkey, cross-built from
#                            pinned source against the musl sysroot — the
#                            pair the initramfs actually ships (the Debian
#                            dropbear-bin is dynamically linked and its
#                            glibc closure failed to exec on-device)
#   DIR/bin/musl-aarch64-cc  CC wrapper used for that build (reusable for
#                            further static musl cross-builds)
#   DIR/iw/tree/             iw + its shared-library closure (libnl-3,
#                            libnl-genl-3, libc) — used by the WLAN test
#   DIR/aplay/tree/          aplay + libasound closure — audio test tone
#   DIR/dropbear/tree/       Debian dropbear-bin + glibc closure (legacy
#                            fallback, no longer packed into images)
#
# Default DIR: out/arm64-tools (gitignored).

set -euo pipefail

usage() {
    sed -n '2,26p' "$0"; exit 2
}

die() {
    echo "fetch-arm64-tools: $*" >&2
    exit 1
}

SUITE=trixie
OUTDIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --suite)      SUITE=${2-}; shift 2 ;;
        --output-dir) OUTDIR=${2-}; shift 2 ;;
        -h|--help)    usage ;;
        *) die "unknown option: $1" ;;
    esac
done

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Mirror overrides for constrained networks, e.g.
#   PIANO_DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian
#   PIANO_ALPINE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine
MIRROR=${PIANO_DEBIAN_MIRROR:-http://deb.debian.org/debian}
ALPINE=${PIANO_ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
OUTDIR=${OUTDIR:-$REPO_ROOT/out/arm64-tools}

# dropbear-bin runtime closure (trixie arm64 Depends, measured 2026-09-19):
# libc6 additionally depends on libgcc-s1.
PKGS=(busybox-static dropbear-bin libc6 libcrypt1 libtomcrypt1 libtommath1 zlib1g libgcc-s1 iw libnl-3-200 libnl-genl-3-200 alsa-utils libasound2t64)

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v zcat >/dev/null 2>&1 || missing+=(gzip)
command -v ar    >/dev/null 2>&1 || missing+=(ar)
command -v tar   >/dev/null 2>&1 || missing+=(tar)
if [ "${#missing[@]}" -gt 0 ]; then
    printf 'fetch-arm64-tools: missing: %s\n' "${missing[*]}" >&2
    exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/piano-tools.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Debian-package staging is skipped when all previously staged trees are
# still in place (set PIANO_FORCE_FETCH=1 to re-download).
DEBIAN_NEEDED=0
[ "${PIANO_FORCE_FETCH:-0}" = 1 ] && DEBIAN_NEEDED=1
for f in "$OUTDIR/busybox/busybox" "$OUTDIR/dropbear/tree/usr/sbin/dropbear" \
         "$OUTDIR/iw/tree/usr/sbin/iw" "$OUTDIR/aplay/tree/usr/bin/aplay"; do
    [ -x "$f" ] || DEBIAN_NEEDED=1
done

package_field() { # package_field PKGNAME FIELD
    # NOTE: awk must not exit early — an early exit SIGPIPEs zcat under
    # pipefail and kills the script.
    zcat "$WORK/Packages.gz" \
        | awk -v pkg="$1" -v fld="$2" '
            /^Package: / { cur = $2 }
            cur == pkg && !done && index($0, fld ": ") == 1 {
                sub("^[^:]+: ", ""); print; done = 1
            }
        '
}
if [ "$DEBIAN_NEEDED" = 1 ]; then
echo "fetch-arm64-tools: resolving packages for $SUITE/arm64..."
curl -fsSL --retry 3 --retry-delay 2 "$MIRROR/dists/$SUITE/main/binary-arm64/Packages.gz" -o "$WORK/Packages.gz" \
    || die "cannot download Packages.gz for $SUITE"


fetch_and_extract() { # fetch_and_extract PKGNAME — extracts data.tar into WORK/x/PKGNAME
    local pkg=$1 ver fn
    ver=$(package_field "$pkg" Version) || true
    [ -n "$ver" ] || die "package $pkg not found in $SUITE"
    fn=$(package_field "$pkg" Filename)
    [ -n "$fn" ] || die "package $pkg has no Filename"
    echo "fetch-arm64-tools: $pkg $ver" >&2
    curl -fsSL --retry 3 --retry-delay 2 "$MIRROR/$fn" -o "$WORK/$pkg.deb" || die "download failed: $pkg"
    sha256sum "$WORK/$pkg.deb" >&2
    mkdir -p "$WORK/x/$pkg"
    ( cd "$WORK/x/$pkg" && ar x "$WORK/$pkg.deb" ) || die "ar extract failed: $pkg"
    ( cd "$WORK/x/$pkg" && tar -xf data.tar.* ) || die "tar extract failed: $pkg"
}

for p in "${PKGS[@]}"; do
    fetch_and_extract "$p"
done

# --- stage busybox ----------------------------------------------------------
BB=$WORK/x/busybox-static/bin/busybox
if [ ! -s "$BB" ] || ! head -c4 "$BB" | grep -q .ELF; then
    BB=$(find "$WORK/x/busybox-static" -type f -name 'busybox*' \
        -exec sh -c 'head -c4 "$1" | grep -q .ELF && echo "$1"' _ {} \; | head -1)
fi
[ -s "$BB" ] || die "no ELF busybox found in busybox-static package"
file "$BB" | grep -q 'ELF .*ARM aarch64' || die "busybox at $BB is not an arm64 ELF"
mkdir -p "$OUTDIR/busybox"
install -m 0755 "$BB" "$OUTDIR/busybox/busybox"

# --- stage dropbear tree ----------------------------------------------------
# Debian trixie is merged-usr: libraries live under usr/lib/aarch64-linux-gnu
# and the loader symlink at usr/lib/ld-linux-aarch64.so.1; binaries want
TREE="$OUTDIR/dropbear/tree"
rm -rf "$TREE"
mkdir -p "$TREE/usr"
for f in usr/sbin/dropbear usr/bin/dropbearkey; do
    [ -s "$WORK/x/dropbear-bin/$f" ] || die "dropbear-bin does not contain $f"
done
( cd "$WORK/x/dropbear-bin" && tar -cf - usr/sbin usr/bin ) | ( cd "$TREE" && tar -xf - )
for p in libc6 libcrypt1 libtomcrypt1 libtommath1 zlib1g libgcc-s1; do
    if [ -d "$WORK/x/$p/usr/lib" ]; then
        ( cd "$WORK/x/$p" && tar -cf - usr/lib ) | ( cd "$TREE" && tar -xf - )
    fi
done
file "$TREE/usr/sbin/dropbear" | grep -q 'ARM aarch64' \
    || die "staged dropbear is not arm64"
ln -sfn usr/lib "$TREE/lib"
[ -e "$TREE/lib/ld-linux-aarch64.so.1" ] || die "no arm64 loader reachable at tree /lib"
mkdir -p "$OUTDIR/dropbear"
ln -sf tree/usr/sbin/dropbear    "$OUTDIR/dropbear/dropbear"
ln -sf tree/usr/bin/dropbearkey  "$OUTDIR/dropbear/dropbearkey"

# --- stage aplay tree ---------------------------------------------------------
# aplay (ALSA playback for the audio test tone) is dynamically linked against
# libasound + libc; staged like the iw tree.
APLAY_TREE="$OUTDIR/aplay/tree"
rm -rf "$APLAY_TREE"
mkdir -p "$APLAY_TREE/usr"
[ -s "$WORK/x/alsa-utils/usr/bin/aplay" ] || die "the alsa-utils package does not contain usr/bin/aplay"
( cd "$WORK/x/alsa-utils" && tar -cf - usr/bin ) | ( cd "$APLAY_TREE" && tar -xf - )
for p in libasound2t64 libc6 libgcc-s1; do
    ( cd "$WORK/x/$p" && tar -cf - usr/lib ) | ( cd "$APLAY_TREE" && tar -xf - ) 2>/dev/null \
        || ( cd "$WORK/x/$p" && tar -cf - lib ) | ( cd "$APLAY_TREE" && tar -xf - )
done
file "$APLAY_TREE/usr/bin/aplay" | grep -q 'ARM aarch64' \
    || die "staged aplay is not arm64"
ln -sfn usr/lib "$APLAY_TREE/lib"
[ -e "$APLAY_TREE/lib/ld-linux-aarch64.so.1" ] || die "no arm64 loader reachable at aplay tree /lib"
mkdir -p "$OUTDIR/aplay"
ln -sf tree/usr/bin/aplay "$OUTDIR/aplay/aplay"
# --- stage iw tree -----------------------------------------------------------
# iw (WLAN nl80211 client for the scan test) is dynamically linked against
# libnl-3/libnl-genl-3 + libc; the same merged-usr staging rules apply.
IW_TREE="$OUTDIR/iw/tree"
rm -rf "$IW_TREE"
mkdir -p "$IW_TREE/usr"
[ -s "$WORK/x/iw/usr/sbin/iw" ] || die "the iw package does not contain usr/sbin/iw"
( cd "$WORK/x/iw" && tar -cf - usr/sbin ) | ( cd "$IW_TREE" && tar -xf - )
for p in libnl-3-200 libnl-genl-3-200 libc6 libgcc-s1; do
    if [ -d "$WORK/x/$p/usr/lib" ]; then
        ( cd "$WORK/x/$p" && tar -cf - usr/lib ) | ( cd "$IW_TREE" && tar -xf - )
    fi
done
file "$IW_TREE/usr/sbin/iw" | grep -q 'ARM aarch64' \
    || die "staged iw is not arm64"
ln -sfn usr/lib "$IW_TREE/lib"
[ -e "$IW_TREE/lib/ld-linux-aarch64.so.1" ] || die "no arm64 loader reachable at iw tree /lib"
mkdir -p "$OUTDIR/iw"
ln -sf tree/usr/sbin/iw "$OUTDIR/iw/iw"
else
    echo "fetch-arm64-tools: staged Debian trees present — skipping re-download"
fi

# --- stage musl sysroot (for the static pd-locator cross-build) ---------------
# Pinned Alpine musl-dev; downloaded from the official Alpine CDN, extracted
# under the gitignored tools dir. This is compiler material, not shipped code.
MUSL_VER=1.2.6-r3
SYSROOT="$OUTDIR/musl-sysroot"
if [ ! -f "$SYSROOT/usr/lib/libc.a" ] || [ ! -f "$SYSROOT/usr/lib/crt1.o" ]; then
    echo "fetch-arm64-tools: fetching musl-dev $MUSL_VER (aarch64) for the sysroot..."
    curl -fsSL --retry 3 --retry-delay 2 "$ALPINE/edge/main/aarch64/musl-dev-$MUSL_VER.apk" \
        -o "$WORK/musl-dev.apk" || die "cannot download musl-dev"
    rm -rf "$SYSROOT"
    mkdir -p "$SYSROOT"
    tar -xzf "$WORK/musl-dev.apk" -C "$SYSROOT" || die "cannot extract musl-dev (not gzip?)"
    [ -f "$SYSROOT/usr/lib/libc.a" ] || die "musl-dev apk lacks usr/lib/libc.a"
    [ -f "$SYSROOT/usr/lib/crt1.o" ] || die "musl-dev apk lacks usr/lib/crt1.o"
fi

# --- build static dropbear (dropbear + dropbearkey) ---------------------------
# The Debian dropbear-bin above is dynamically linked; its glibc closure died
# on-device (2026-09-22: no exec in the bare initramfs). Build a fully static
# dropbear from source against the Alpine musl sysroot instead — same approach
# as piano-pd-locator, plus a CC wrapper that lets autoconf drive the link
# (crt1.o + libc.a + compiler-rt builtins; musl's vfprintf references the
# fp128 __*_tf3 helpers, so the aarch64 builtins archive is required).
# The builtins come from Alpine's clang19-rtlib package (freestanding, no libc
# dependency). Both downloads are version- and sha256-pinned.
DROPBEAR_VER=2025.88
DROPBEAR_SHA256=783f50ea27b17c16da89578fafdb6decfa44bb8f6590e5698a4e4d3672dc53d4
RTLIB_PATH=v3.22/community/aarch64/clang19-rtlib-0.1.0-r0.apk
RTLIB_SHA256=afce3cc76d1446465306f82439aa6c76447be0dd3fb46379f4173de7ca412b56
DB_STATIC="$OUTDIR/dropbear-static"

if [ ! -x "$DB_STATIC/dropbear" ] || [ ! -x "$DB_STATIC/dropbearkey" ]; then
    echo "fetch-arm64-tools: building static dropbear $DROPBEAR_VER (musl aarch64)..."
    command -v clang >/dev/null 2>&1 || die "clang not found (needed to build dropbear)"
    command -v ld.lld >/dev/null 2>&1 || die "ld.lld not found (needed to build dropbear)"
    DB="$WORK/dropbear"
    mkdir -p "$DB"
    curl -fsSL --retry 3 --retry-delay 2 "https://matt.ucc.asn.au/dropbear/releases/dropbear-$DROPBEAR_VER.tar.bz2" \
        -o "$DB/src.tar.bz2" || die "cannot download dropbear source"
    echo "$DROPBEAR_SHA256  $DB/src.tar.bz2" | sha256sum -c - >/dev/null \
        || die "dropbear source sha256 mismatch"
    curl -fsSL --retry 3 --retry-delay 2 "$ALPINE/$RTLIB_PATH" -o "$DB/rtlib.apk" || die "cannot download clang19-rtlib"
    echo "$RTLIB_SHA256  $DB/rtlib.apk" | sha256sum -c - >/dev/null \
        || die "clang19-rtlib sha256 mismatch"
    BUILTINS="$DB/usr/lib/llvm19/lib/clang/19/lib/linux/libclang_rt.builtins-aarch64.a"
    tar -xzf "$DB/rtlib.apk" -C "$DB" usr \
        || die "cannot extract clang19-rtlib (not gzip?)"
    [ -f "$BUILTINS" ] || die "clang19-rtlib apk lacks the aarch64 builtins archive"
    tar -xjf "$DB/src.tar.bz2" -C "$DB" || die "cannot extract dropbear source"

    mkdir -p "$OUTDIR/bin"
    cat > "$OUTDIR/bin/musl-aarch64-cc" <<'CCWRAP'
#!/bin/sh
# musl-aarch64-cc — clang→musl-aarch64 compiler/linker wrapper for
# configure+make builds inside a sysroot that only carries crt1.o/libc.a
# (no compiler-rt/libgcc from the host toolchain).
#   compile (-c/-E): forwarded to clang (minus GCC-x86 retpoline flags that
#                    dropbear's configure blindly accepts when cross-building)
#   link:            ld.lld -static: crt1.o + objects/archives + libc.a + builtins
set -u
SYSROOT=${MUSL_AARCH64_SYSROOT:?MUSL_AARCH64_SYSROOT is not set}
BUILTINS=${MUSL_AARCH64_BUILTINS:-}
CLANG="clang --target=aarch64-linux-musl --sysroot=$SYSROOT"

case " $* " in
  *" -c "*|*" -E "*)
    set -- $(printf '%s\n' "$@" | grep -vE '^-(mindirect-branch|mfunction-return)')
    exec $CLANG "$@" ;;
esac
case "$1" in
  -v|-V|--version|-qversion|-version|-dumpmachine) exec $CLANG "$@" ;;
esac

objs=""; srcs=""; out="a.out"; want_out=0
for a in "$@"; do
  if [ "$want_out" = 1 ]; then out="$a"; want_out=0; continue; fi
  case "$a" in
    -o) want_out=1 ;;
    -l*|-Wl,*|-L*|-shared|-static|-rdynamic|-pie|-no-pie|-pthread) : ;;
    -*) : ;;
    *.c) srcs="$srcs $a" ;;
    *.o|*.a) objs="$objs $a" ;;
    *) : ;;
  esac
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/musl-cc.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
for s in $srcs; do
  o="$tmp/$(basename "${s%.c}").o"
  $CLANG -c "$s" -o "$o" || exit 1
  objs="$objs $o"
done
[ -n "${objs# }" ] || exit 1
# shellcheck disable=SC2086
exec ld.lld -o "$out" "$SYSROOT/usr/lib/crt1.o" $objs "$SYSROOT/usr/lib/libc.a" $BUILTINS
CCWRAP
    chmod 0755 "$OUTDIR/bin/musl-aarch64-cc"

    SRC="$DB/dropbear-$DROPBEAR_VER"
    ( cd "$SRC" \
      && MUSL_AARCH64_SYSROOT="$SYSROOT" \
         MUSL_AARCH64_BUILTINS="$BUILTINS" \
         PATH="$OUTDIR/bin:$PATH" \
         CC=musl-aarch64-cc ./configure --host=aarch64-linux-musl \
            --disable-zlib --disable-lastlog --disable-utmp --disable-utmpx \
            --disable-wtmp --disable-wtmpx \
      && make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" STATIC=1 strip \
    ) || die "static dropbear build failed"
    for b in dropbear dropbearkey; do
        file "$SRC/$b" | grep -q 'statically linked' \
            || die "$b did not build as a static binary"
        file "$SRC/$b" | grep -q 'ARM aarch64' \
            || die "$b did not build as an arm64 ELF"
    done
    mkdir -p "$DB_STATIC"
    install -m 0755 "$SRC/dropbear"     "$DB_STATIC/dropbear"
    install -m 0755 "$SRC/dropbearkey"  "$DB_STATIC/dropbearkey"
    echo "fetch-arm64-tools: static dropbear staged in $DB_STATIC"
fi

{
    echo "suite: $SUITE"
    if [ -f "$WORK/Packages.gz" ]; then
        for p in "${PKGS[@]}"; do
            printf '%s: %s\n' "$p" "$(package_field "$p" Version)"
        done
    else
        echo "debian packages: (staged earlier — set PIANO_FORCE_FETCH=1 to refresh)"
    fi
    echo "dropbear (static, built from source): $DROPBEAR_VER (sha256 $DROPBEAR_SHA256)"
    echo "clang19-rtlib (aarch64 builtins): $ALPINE/$RTLIB_PATH (sha256 $RTLIB_SHA256)"
    file "$OUTDIR/busybox/busybox" "$OUTDIR/dropbear/tree/usr/sbin/dropbear" \
        "$DB_STATIC/dropbear" "$DB_STATIC/dropbearkey" "$OUTDIR/iw/tree/usr/sbin/iw"
} | tee "$OUTDIR/TOOLS-PROVENANCE"

echo "fetch-arm64-tools: staged in $OUTDIR"
