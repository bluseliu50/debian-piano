#!/usr/bin/env bash
# build-firmware-deb.sh — package a local piano firmware extraction as a deb.
#
# Usage:
#   FIRMWARE_DIR=DIR ./build-firmware-deb.sh --version V --output DIR
#
# Reads a local firmware extraction from a stock-ROM unpack and installs it as
# /lib/firmware/** inside a firmware-xiaomi-piano deb. Fails on an empty
# or missing input; never writes placeholder firmware.

set -euo pipefail

usage() {
    sed -n '2,9p' "$0"; exit 2
}

die() {
    echo "build-firmware-deb: error: $*" >&2
    exit 1
}

VERSION=""
OUTDIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?}"; shift 2 ;;
        --output)  OUTDIR="${2:?}"; shift 2 ;;
        -h|--help) usage ;;
        *)         usage ;;
    esac
done

[ -n "$VERSION" ] || usage
[ -n "$OUTDIR" ]  || usage
[ -n "${FIRMWARE_DIR:-}" ] || die "FIRMWARE_DIR is not set (point it at the local firmware extraction)"
[ -d "$FIRMWARE_DIR" ] || die "FIRMWARE_DIR=$FIRMWARE_DIR is not a directory"

missing=()
command -v dpkg-deb >/dev/null 2>&1 || missing+=(dpkg-deb)
command -v sha256sum >/dev/null 2>&1 || missing+=(sha256sum)
if [ "${#missing[@]}" -gt 0 ]; then
    echo "build-firmware-deb: missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
fi

FILECOUNT=$(find "$FIRMWARE_DIR" -type f | wc -l)
[ "$FILECOUNT" -gt 0 ] || die "$FIRMWARE_DIR contains no files — refusing to build an empty firmware deb"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/piano-fw-deb.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PKG="$WORK/firmware-xiaomi-piano"
mkdir -p "$PKG/DEBIAN" "$PKG/lib/firmware" "$PKG/usr/share/doc/firmware-xiaomi-piano"
cp -a "$FIRMWARE_DIR"/. "$PKG/lib/firmware/"

( cd "$PKG/lib/firmware" && find . -type f -print0 | xargs -0 sha256sum ) \
    > "$PKG/usr/share/doc/firmware-xiaomi-piano/manifest.txt"

cat > "$PKG/DEBIAN/control" <<EOF
Package: firmware-xiaomi-piano
Version: $VERSION
Section: non-free/firmware
Priority: optional
Architecture: arm64
Maintainer: piano mainline contributors
Depends: -
Description: Proprietary firmware for Xiaomi Pad 8 Pro (piano)
 Extracted from the stock fastboot ROM OS3.0.308.0.WPYCNXM (see
 manifest.txt for per-file provenance hashes). Redistributable only
 per the applicable licenses; build locally, do not publish.
EOF

mkdir -p "$OUTDIR"
dpkg-deb --root-owner-group --build "$PKG" "$OUTDIR/firmware-xiaomi-piano_${VERSION}_arm64.deb"

echo "build-firmware-deb: packed $FILECOUNT files -> $OUTDIR/firmware-xiaomi-piano_${VERSION}_arm64.deb"
