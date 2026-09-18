#!/usr/bin/env bash
# build-initramfs.sh — assemble the piano debug initramfs.
#
# Usage:
#   scripts/build-initramfs.sh --busybox DIR --dropbear DIR --output FILE
#
# DIR arguments point at directories that contain the binaries:
#   --busybox  DIR with a static `busybox`
#   --dropbear DIR with `dropbear` and `dropbearkey` (dropbearmulti works
#              if `dropbearkey` is symlinked next to it)
#
# Fails (non-zero) when tools are missing, the NCM gadget function cannot
# be represented in the generated image (init sanity), or the cpio output
# is empty.

set -euo pipefail

usage() {
    sed -n '2,12p' "$0"; exit 2
}

die() {
    echo "build-initramfs: error: $*" >&2
    exit 1
}

BUSYBOX_DIR=""
DROPBEAR_DIR=""
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --busybox)  BUSYBOX_DIR="${2:?}";  shift 2 ;;
        --dropbear) DROPBEAR_DIR="${2:?}"; shift 2 ;;
        --output)   OUTPUT="${2:?}";       shift 2 ;;
        -h|--help)  usage ;;
        *)          usage ;;
    esac
done

[ -n "$BUSYBOX_DIR" ]  || usage
[ -n "$DROPBEAR_DIR" ] || usage
[ -n "$OUTPUT" ]       || usage

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INIT_SRC="$REPO_ROOT/initramfs/init"

missing=()
command -v cpio   >/dev/null 2>&1 || missing+=(cpio)
command -v gzip   >/dev/null 2>&1 || missing+=(gzip)
command -v sha256sum >/dev/null 2>&1 || missing+=(sha256sum)
[ -x "$BUSYBOX_DIR/busybox" ] || missing+=("$BUSYBOX_DIR/busybox (static busybox)")
[ -x "$DROPBEAR_DIR/dropbear" ] || missing+=("$DROPBEAR_DIR/dropbear")
[ -x "$DROPBEAR_DIR/dropbearkey" ] || missing+=("$DROPBEAR_DIR/dropbearkey")
[ -f "$INIT_SRC" ] || missing+=("$INIT_SRC (initramfs/init)")

if [ "${#missing[@]}" -gt 0 ]; then
    echo "build-initramfs: missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
fi

# busybox must be static (no interpreter deps inside initramfs)
if ldd "$BUSYBOX_DIR/busybox" >/dev/null 2>&1; then
    echo "build-initramfs: error: $BUSYBOX_DIR/busybox is dynamically linked; a static build is required" >&2
    exit 1
fi

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/piano-initramfs.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

mkdir -p \
    "$STAGING/bin" "$STAGING/sbin" "$STAGING/usr/bin" "$STAGING/usr/sbin" \
    "$STAGING/etc/dropbear" "$STAGING/root/.ssh" \
    "$STAGING/dev" "$STAGING/proc" "$STAGING/sys" "$STAGING/run" \
    "$STAGING/var/lib/misc" \
    "$STAGING/sys/kernel/config"

install -m 0755 "$INIT_SRC" "$STAGING/init"
install -m 0755 "$BUSYBOX_DIR/busybox" "$STAGING/bin/busybox"
install -m 0755 "$DROPBEAR_DIR/dropbear"     "$STAGING/usr/sbin/dropbear"
install -m 0755 "$DROPBEAR_DIR/dropbearkey"  "$STAGING/usr/bin/dropbearkey"

# Minimal command symlinks; /init does `busybox --install -s` at runtime,
# but the earliest init lines need these before that install runs.
for cmd in sh mount mkdir ln echo cat ls; do
    ln -sf /bin/busybox "$STAGING/bin/$cmd"
done

# Sanity: the init script must carry the NCM gadget path. A missing or
# renamed function here means the debug network cannot come up — refuse
# to ship such an image instead of failing silently on the device.
grep -q 'functions/ncm\.usb0' "$STAGING/init" \
    || die "init does not create the NCM function (functions/ncm.usb0 missing)"
grep -q 'usb_gadget/piano' "$STAGING/init" \
    || die "init does not create the usb_gadget/piano gadget"

( cd "$STAGING" && find . -print0 | cpio --null -o --format=newc ) \
    | gzip -9 > "$OUTPUT"

[ -s "$OUTPUT" ] || die "cpio output is empty: $OUTPUT"

echo "build-initramfs: wrote $OUTPUT ($(wc -c < "$OUTPUT") bytes)"
sha256sum "$OUTPUT"
