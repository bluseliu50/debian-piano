#!/usr/bin/env bash
# build-test-bootimg.sh — build the piano RAM-boot test image set.
#
# Usage:
#   scripts/build-test-bootimg.sh --kernel-dir DIR --firmware-dir DIR \
#       --output-dir DIR [--authorized-keys FILE | --generate-access-key]
#       [--root-password PASS] [--cmdline STR] [--busybox DIR] [--dropbear DIR]
#
# --kernel-dir  linux-piano O= output dir (Image, piano dtb, .ko files,
#               include/generated/utsrelease.h)
# --firmware-dir local/firmware (only novatek/*.bin are installed)
#
# Produces, all verified by unpack_bootimg round-trip:
#   piano-test-boot.img         v4 boot image, stock layout (empty ramdisk)
#   piano-test-vendor_boot.img  v4 vendor_boot: PLATFORM initramfs + our DTB
#   piano-test-boot-ramdisk.img v4 boot image carrying the initramfs itself
#                               (fallback for abl variants that ignore the
#                               vendor ramdisk; pair with vendor_boot.img)
#   piano-test-boot-v2.img      header v2 all-in-one fallback
#   piano-test-ssh-ed25519      generated SSH access key (0600) unless
#                               --authorized-keys was given
#   MANIFEST.txt                sha256s + parameters + next steps
#
# Boot-image parameters are taken from boot/stock-boot-params.env and must
# be CONFIRMED there (stock ROM measurements) — same gate as
# build-bootimg.sh. The cmdline is operator policy (console selection).

set -euo pipefail

usage() {
    sed -n '2,24p' "$0"; exit 2
}

die() {
    echo "build-test-bootimg: $*" >&2
    exit 1
}

KERNEL_DIR=""
FIRMWARE_DIR=""
OUTPUT_DIR=""
AUTHORIZED_KEYS=""
GEN_KEY=0
ROOT_PASSWORD=""
ROOT_PASSWORD_SET=0
CMDLINE="console=tty0 console=ttyMSM0,115200n8 loglevel=7"
BUSYBOX_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-dir)          KERNEL_DIR=${2-}; shift 2 ;;
        --firmware-dir)        FIRMWARE_DIR=${2-}; shift 2 ;;
        --output-dir)          OUTPUT_DIR=${2-}; shift 2 ;;
        --authorized-keys)     AUTHORIZED_KEYS=${2-}; shift 2 ;;
        --generate-access-key) GEN_KEY=1; shift ;;
        --root-password)        ROOT_PASSWORD=${2-}; ROOT_PASSWORD_SET=1; shift 2 ;;
        --cmdline)             CMDLINE=${2-}; shift 2 ;;
        --busybox)             BUSYBOX_DIR=${2-}; shift 2 ;;
        -h|--help)             usage ;;
        *) die "unknown option: $1" ;;
    esac
done

for v in KERNEL_DIR FIRMWARE_DIR OUTPUT_DIR; do
    [ -n "${!v}" ] || { echo "build-test-bootimg: missing required argument for $v" >&2; usage; }
done

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARAMS_FILE="$REPO_ROOT/boot/stock-boot-params.env"
MKBOOTIMG="$REPO_ROOT/mkbootimg/mkbootimg.py"
UNPACK="$REPO_ROOT/mkbootimg/unpack_bootimg.py"
INITRAMFS_BUILDER="$REPO_ROOT/scripts/build-initramfs.sh"
FETCH_TOOLS="$REPO_ROOT/scripts/fetch-arm64-tools.sh"

IMAGE=$KERNEL_DIR/arch/arm64/boot/Image
DTB=$KERNEL_DIR/arch/arm64/boot/dts/qcom/sm8750-xiaomi-piano.dtb
TS_MOD=$KERNEL_DIR/drivers/input/touchscreen/nt36532e/nt36532e_ts.ko
SPI_MOD=$KERNEL_DIR/drivers/spi/spi-geni-qcom.ko
UTSRELEASE_H=$KERNEL_DIR/include/generated/utsrelease.h
WLAN_BT_MODS=(
    "$KERNEL_DIR/net/wireless/cfg80211.ko"
    "$KERNEL_DIR/net/mac80211/mac80211.ko"
    "$KERNEL_DIR/net/qrtr/qrtr.ko"
    "$KERNEL_DIR/net/qrtr/qrtr-mhi.ko"
    "$KERNEL_DIR/drivers/bus/mhi/host/mhi.ko"
    "$KERNEL_DIR/drivers/net/wireless/ath/ath.ko"
    "$KERNEL_DIR/drivers/net/wireless/ath/ath12k/ath12k.ko"
    "$KERNEL_DIR/drivers/net/wireless/ath/ath12k/wifi7/ath12k_wifi7.ko"
    "$KERNEL_DIR/net/bluetooth/bluetooth.ko"
    "$KERNEL_DIR/net/rfkill/rfkill.ko"
    "$KERNEL_DIR/drivers/bluetooth/hci_uart.ko"
    "$KERNEL_DIR/drivers/bluetooth/btqca.ko"
    "$KERNEL_DIR/drivers/power/sequencing/pwrseq-qcom-wcn.ko"
)
WLAN_BT_FW_DIR=$FIRMWARE_DIR/wifi-bt

# ADSP/CDSP remoteproc + pmic-glink battery + audioreach sound stack.
# modprobe pulls dependencies via modules.dep; the explicit list is what
# gets packed into the initramfs.
AUDIO_BATT_MODS=(
    "$KERNEL_DIR/net/qrtr/qrtr.ko"
    "$KERNEL_DIR/drivers/soc/qcom/pmic_glink.ko"
    "$KERNEL_DIR/drivers/soc/qcom/pmic_glink_altmode.ko"
    "$KERNEL_DIR/drivers/soc/qcom/apr.ko"
    "$KERNEL_DIR/drivers/remoteproc/qcom_q6v5.ko"
    "$KERNEL_DIR/drivers/remoteproc/qcom_q6v5_pas.ko"
    "$KERNEL_DIR/drivers/misc/fastrpc.ko"
    "$KERNEL_DIR/drivers/power/supply/qcom_battmgr.ko"
    "$KERNEL_DIR/sound/core/snd.ko"
    "$KERNEL_DIR/sound/core/snd-pcm.ko"
    "$KERNEL_DIR/sound/soc/snd-soc-core.ko"
    "$KERNEL_DIR/sound/soc/codecs/snd-soc-lpass-macro-common.ko"
    "$KERNEL_DIR/sound/soc/codecs/snd-soc-lpass-rx-macro.ko"
    "$KERNEL_DIR/sound/soc/codecs/snd-soc-lpass-tx-macro.ko"
    "$KERNEL_DIR/sound/soc/codecs/snd-soc-lpass-wsa-macro.ko"
    "$KERNEL_DIR/sound/soc/codecs/snd-soc-lpass-va-macro.ko"
    "$KERNEL_DIR/sound/soc/codecs/snd-soc-wcd939x.ko"
    "$KERNEL_DIR/sound/soc/codecs/snd-soc-wcd939x-sdw.ko"
    "$KERNEL_DIR/sound/soc/codecs/snd-soc-wsa884x.ko"
    "$KERNEL_DIR/drivers/usb/typec/mux/wcd939x-usbss.ko"
    "$KERNEL_DIR/sound/soc/qcom/qdsp6/snd-q6dsp-common.ko"
    "$KERNEL_DIR/sound/soc/qcom/qdsp6/snd-q6apm.ko"
    "$KERNEL_DIR/sound/soc/qcom/qdsp6/q6apm-dai.ko"
    "$KERNEL_DIR/sound/soc/qcom/qdsp6/q6apm-lpass-dais.ko"
    "$KERNEL_DIR/sound/soc/qcom/qdsp6/q6prm.ko"
    "$KERNEL_DIR/sound/soc/qcom/qdsp6/q6prm-clocks.ko"
    "$KERNEL_DIR/sound/soc/qcom/snd-soc-qcom-common.ko"
    "$KERNEL_DIR/sound/soc/qcom/snd-soc-qcom-sdw.ko"
    "$KERNEL_DIR/sound/soc/qcom/snd-soc-sc8280xp.ko"
    "$KERNEL_DIR/drivers/soundwire/soundwire-bus.ko"
    "$KERNEL_DIR/drivers/soundwire/soundwire-qcom.ko"
)
AUDIO_BATT_FW_SRC=$FIRMWARE_DIR/non-hlos/image
PD_LOCATOR_SRC=$REPO_ROOT/initramfs/pd-locator/piano-pd-locator.c

missing=()
command -v python3 >/dev/null 2>&1 || missing+=(python3)
command -v lz4     >/dev/null 2>&1 || missing+=(lz4)
command -v gzip    >/dev/null 2>&1 || missing+=(gzip)
for f in "$MKBOOTIMG" "$UNPACK" "$PARAMS_FILE" "$INITRAMFS_BUILDER" \
         "$IMAGE" "$DTB" "$TS_MOD" "$SPI_MOD" "$UTSRELEASE_H"; do
    [ -s "$f" ] || missing+=("$f (missing or empty)")
done
ls "$FIRMWARE_DIR"/odm/firmware/novatek_nt36532_*.bin >/dev/null 2>&1 \
    || missing+=("$FIRMWARE_DIR/odm/firmware/novatek_*.bin (touch firmware blobs)")
for m in "${WLAN_BT_MODS[@]}"; do
    [ -s "$m" ] || missing+=("$m (missing or empty)")
done
[ -d "$WLAN_BT_FW_DIR/ath12k" ] || missing+=("$WLAN_BT_FW_DIR/ath12k (ath12k firmware tree)")
[ -d "$WLAN_BT_FW_DIR/qca" ]   || missing+=("$WLAN_BT_FW_DIR/qca (QCA BT firmware)")
for m in "${AUDIO_BATT_MODS[@]}"; do
    [ -s "$m" ] || missing+=("$m (missing or empty)")
done
[ -f "$AUDIO_BATT_FW_SRC/adsp.mdt" ] || missing+=("$AUDIO_BATT_FW_SRC/adsp.mdt (ADSP firmware)")
[ -f "$AUDIO_BATT_FW_SRC/cdsp.mdt" ] || missing+=("$AUDIO_BATT_FW_SRC/cdsp.mdt (CDSP firmware)")
[ -s "$PD_LOCATOR_SRC" ] || missing+=("$PD_LOCATOR_SRC (pd-locator source)")
if [ "${#missing[@]}" -gt 0 ]; then
    printf 'build-test-bootimg: missing: %s\n' "${missing[*]}" >&2
    exit 1
fi

KVER=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' "$UTSRELEASE_H")
[ -n "$KVER" ] || die "cannot parse kernel release from $UTSRELEASE_H"

# --- provenance-gated parameters -------------------------------------------
param_value() { # param_value NAME — echoes CONFIRMED value or dies
    local val
    val=$(sed -n "s/^CONFIRMED:$1=//p" "$PARAMS_FILE" | head -1)
    [ -n "$val" ] || die "parameter $1 is not CONFIRMED in $PARAMS_FILE"
    printf '%s' "$val"
}

HEADER_VERSION=$(param_value header_version)
PAGESIZE=$(param_value pagesize)
BOOT_RAMDISK_COMPRESSION=$(param_value ramdisk_compression)
VB_BASE=$(param_value vb_base)
VB_KERNEL_OFFSET=$(param_value vb_kernel_offset)
VB_RAMDISK_OFFSET=$(param_value vb_ramdisk_offset)
VB_TAGS_OFFSET=$(param_value vb_tags_offset)
VB_DTB_OFFSET=$(param_value vb_dtb_offset)
# vb_ramdisk_type=platform is structural in mkbootimg's single-ramdisk path;
# verify_vendor_boot() checks the readback type instead.

# --- staging directories ----------------------------------------------------
mkdir -p "$OUTPUT_DIR"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/piano-testimg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- arm64 userland ---------------------------------------------------------
TOOLS="$REPO_ROOT/out/arm64-tools"
DROPBEAR_TREE="$TOOLS/dropbear/tree"
IW_TREE="$TOOLS/iw/tree"
APLAY_TREE="$TOOLS/aplay/tree"
if [ -z "$BUSYBOX_DIR" ]; then
    if [ ! -x "$TOOLS/busybox/busybox" ] || [ ! -x "$DROPBEAR_TREE/usr/sbin/dropbear" ] \
       || [ ! -x "$IW_TREE/usr/sbin/iw" ]; then
        "$FETCH_TOOLS" || die "fetch-arm64-tools failed"
    fi
    BUSYBOX_DIR="$TOOLS/busybox"
fi
[ -x "$DROPBEAR_TREE/usr/sbin/dropbear" ] || die "no dropbear tree (run $FETCH_TOOLS)"
[ -x "$IW_TREE/usr/sbin/iw" ] || die "no iw tree (run $FETCH_TOOLS)"
[ -x "$APLAY_TREE/usr/bin/aplay" ] || die "no aplay tree (run $FETCH_TOOLS)"
command -v python3 >/dev/null 2>&1 || die "python3 needed (test tone generation)"


# --- normalize firmware layout ---------------------------------------------
# The stock-ROM extraction stores touch blobs as
# <firmware-dir>/odm/firmware/novatek_nt36532_*.bin; the initramfs
# builder wants DIR/novatek/*.bin. WLAN/BT blobs (the ath12k tree and
# the qca BT firmware under <firmware-dir>/wifi-bt/) are copied verbatim.
mkdir -p "$WORK/firmware/novatek"
cp "$FIRMWARE_DIR"/odm/firmware/novatek_nt36532_*.bin "$WORK/firmware/novatek/"
cp -a "$WLAN_BT_FW_DIR/qca" "$WLAN_BT_FW_DIR/ath12k" "$WORK/firmware/"

# remoteproc firmware: stock NON-HLOS image names adsp/cdsp segments as
# <name>.mdt + <name>.bNN; the DTS asks for qcom/sm8750/<name>.mbn, and the
# kernel MDT loader resolves <name>.mbn + <name>.bNN automatically.
mkdir -p "$WORK/firmware/qcom/sm8750"
for f in "$AUDIO_BATT_FW_SRC"/adsp* "$AUDIO_BATT_FW_SRC"/cdsp*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
        *.mdt) install -m 0644 "$f" "$WORK/firmware/qcom/sm8750/${base%.mdt}.mbn" ;;
        *)     install -m 0644 "$f" "$WORK/firmware/qcom/sm8750/$base" ;;
    esac
done

# --- initramfs --------------------------------------------------------------
KEY_OUT=""
if [ -n "$AUTHORIZED_KEYS" ]; then
    echo "build-test-bootimg: using operator authorized_keys: $AUTHORIZED_KEYS"
else
    GEN_KEY=1
fi

ACCESS_ARGS=()
if [ "$ROOT_PASSWORD_SET" = 1 ]; then
    ACCESS_ARGS+=(--root-password "$ROOT_PASSWORD")
fi
KEY_ARGS=()
if [ "$GEN_KEY" = 1 ]; then
    KEY_OUT="$OUTPUT_DIR/piano-test-ssh-ed25519"
    rm -f "$KEY_OUT" "$KEY_OUT.pub"
    KEY_ARGS=(--generate-access-key "$KEY_OUT")
else
    KEY_ARGS=(--authorized-keys "$AUTHORIZED_KEYS")
fi

# --- piano-pd-locator cross-build -------------------------------------------
# Static aarch64 build against the staged musl sysroot (fetched on demand by
# the tools script). crt1.o + libc.a direct link: pure C, no compiler-rt
# builtins needed, so no libgcc is required.
SYSROOT="$TOOLS/musl-sysroot"
if [ ! -f "$SYSROOT/usr/lib/libc.a" ]; then
    echo "build-test-bootimg: musl sysroot missing, fetching tools..."
    "$FETCH_TOOLS" >/dev/null || die "fetch-arm64-tools failed"
fi
command -v clang >/dev/null 2>&1 || missing+=(clang)
command -v ld.lld >/dev/null 2>&1 || missing+=(ld.lld)
PD_LOCATOR_BIN="$WORK/piano-pd-locator"
clang --target=aarch64-linux-musl --sysroot="$SYSROOT" -Os -Wall -Wextra \
    -fno-stack-protector -fno-asynchronous-unwind-tables \
    -c "$PD_LOCATOR_SRC" -o "$WORK/pd-locator.o" \
    || die "pd-locator compile failed"
ld.lld -o "$PD_LOCATOR_BIN" --sysroot="$SYSROOT" -static \
    "$SYSROOT/usr/lib/crt1.o" "$WORK/pd-locator.o" "$SYSROOT/usr/lib/libc.a" \
    || die "pd-locator link failed"
file "$PD_LOCATOR_BIN" | grep -q 'ARM aarch64' \
    || die "pd-locator did not build as an arm64 ELF"
echo "build-test-bootimg: built piano-pd-locator ($(stat -c%s "$PD_LOCATOR_BIN") bytes)"

echo "build-test-bootimg: building initramfs (kernel $KVER)"
WLAN_BT_MOD_ARGS=()
for m in "${WLAN_BT_MODS[@]}" "${AUDIO_BATT_MODS[@]}"; do
    WLAN_BT_MOD_ARGS+=(--module "$m")
done
"$INITRAMFS_BUILDER" \
    --busybox "$BUSYBOX_DIR" --dropbear-tree "$DROPBEAR_TREE" --iw-tree "$IW_TREE" \
    --pd-locator "$PD_LOCATOR_BIN" \
    --aplay-tree "$APLAY_TREE" \
    --output "$WORK/initramfs.cpio" --compress none \
    --module "$TS_MOD" --module "$SPI_MOD" --kernel-version "$KVER" \
    "${WLAN_BT_MOD_ARGS[@]}" \
    --firmware-dir "$WORK/firmware" \
    "${ACCESS_ARGS[@]}" "${KEY_ARGS[@]}"

if [ "$GEN_KEY" = 1 ]; then
    # The plain-cpio build generated the key; reuse it for the gzip variant.
    KEY_ARGS=(--authorized-keys "$KEY_OUT.pub")
fi

"$INITRAMFS_BUILDER" \
    --busybox "$BUSYBOX_DIR" --dropbear-tree "$DROPBEAR_TREE" --iw-tree "$IW_TREE" \
    --pd-locator "$PD_LOCATOR_BIN" \
    --aplay-tree "$APLAY_TREE" \
    --output "$WORK/initramfs.cpio.gz" --compress gzip \
    --module "$TS_MOD" --module "$SPI_MOD" --kernel-version "$KVER" \
    "${WLAN_BT_MOD_ARGS[@]}" \
    --firmware-dir "$WORK/firmware" \
    "${ACCESS_ARGS[@]}" "${KEY_ARGS[@]}"


[ "$BOOT_RAMDISK_COMPRESSION" = lz4 ] \
    || die "this script currently assumes CONFIRMED ramdisk_compression=lz4"

lz4 -l -q -9 "$WORK/initramfs.cpio" "$WORK/initramfs.cpio.lz4" \
    || die "lz4 compression failed"

: > "$WORK/empty"

# Minimal marker cpio for the ramdisk-in-boot variant's vendor_boot.
MARKER=$(mktemp -d "${TMPDIR:-/tmp}/piano-marker.XXXXXX")
echo "piano vendor_boot dtb-only marker" > "$MARKER/marker.txt"
( cd "$MARKER" && find . -print0 | cpio --null -o --format=newc ) > "$WORK/marker.cpio" 2>/dev/null
: > "$WORK/bootconfig.empty"

# --- image assembly ---------------------------------------------------------
GEOM=(--base "$VB_BASE" --kernel_offset "$VB_KERNEL_OFFSET"
      --ramdisk_offset "$VB_RAMDISK_OFFSET" --tags_offset "$VB_TAGS_OFFSET")

echo "build-test-bootimg: packing images (header v$HEADER_VERSION, pagesize $PAGESIZE)"

# A1: stock-layout v4 boot image (empty ramdisk)
python3 "$MKBOOTIMG" \
    --kernel "$IMAGE" --ramdisk "$WORK/empty" \
    --header_version "$HEADER_VERSION" --pagesize "$PAGESIZE" \
    "${GEOM[@]}" -o "$OUTPUT_DIR/piano-test-boot.img"

# A2: v4 vendor_boot with PLATFORM initramfs + our DTB + the cmdline.
# The ramdisk is the gzipped cpio: the vendor_ramdisk entry just carries
# bytes, and the kernel's initramfs unpacker handles gzip (RD_GZIP=y).
python3 "$MKBOOTIMG" \
    --vendor_boot "$OUTPUT_DIR/piano-test-vendor_boot.img" \
    --vendor_ramdisk "$WORK/initramfs.cpio.gz" \
    --vendor_bootconfig "$WORK/bootconfig.empty" \
    --dtb "$DTB" \
    --header_version "$HEADER_VERSION" --pagesize "$PAGESIZE" \
    --vendor_cmdline "$CMDLINE" \
    "${GEOM[@]}" --dtb_offset "$VB_DTB_OFFSET"

# C: v4 boot image that itself carries the initramfs (lz4, stock-style),
python3 "$MKBOOTIMG" \
    --kernel "$IMAGE" --ramdisk "$WORK/initramfs.cpio.lz4" \
    --header_version "$HEADER_VERSION" --pagesize "$PAGESIZE" \
    "${GEOM[@]}" -o "$OUTPUT_DIR/piano-test-boot-ramdisk.img"

python3 "$MKBOOTIMG" \
    --vendor_boot "$OUTPUT_DIR/piano-test-vendor_boot-dtb.img" \
    --vendor_ramdisk "$WORK/marker.cpio" \
    --vendor_bootconfig "$WORK/bootconfig.empty" \
    --dtb "$DTB" \
    --header_version "$HEADER_VERSION" --pagesize "$PAGESIZE" \
    --vendor_cmdline "$CMDLINE" \
    "${GEOM[@]}" --dtb_offset "$VB_DTB_OFFSET"

# B: header v2 all-in-one fallback
python3 "$MKBOOTIMG" \
    --kernel "$IMAGE" --ramdisk "$WORK/initramfs.cpio.gz" \
    --dtb "$DTB" \
    --header_version 2 --pagesize "$PAGESIZE" \
    --cmdline "$CMDLINE" \
    "${GEOM[@]}" --dtb_offset "$VB_DTB_OFFSET" \
    -o "$OUTPUT_DIR/piano-test-boot-v2.img"
# --- verification -----------------------------------------------------------
verify_boot() { # verify_boot FILE
    local f=$1 log hdr
    log=$WORK/verify-$(basename "$f").log
    python3 "$UNPACK" --boot_img "$f" --out "$WORK/unpack-$(basename "$f")" > "$log" 2>&1 \
        || { cat "$log" >&2; die "unpack_bootimg failed to read back $f"; }
    hdr=$(awk -F': *' '/^boot image header version/{print $2}' "$log" | tr -d '[:space:]')
    grep -q "^kernel_size: $(wc -c < "$IMAGE")\$" "$log" \
        || { cat "$log" >&2; die "kernel size mismatch in $f"; }
    cmp -s "$IMAGE" "$WORK/unpack-$(basename "$f")/kernel" \
        || die "kernel payload mismatch in $f"
    echo "build-test-bootimg: verified $f (header v$hdr)"
}

verify_vendor_boot() { # verify_vendor_boot FILE
    local f=$1 log
    log=$WORK/verify-$(basename "$f").log
    python3 "$UNPACK" --boot_img "$f" --out "$WORK/unpack-$(basename "$f")" > "$log" 2>&1 \
        || { cat "$log" >&2; die "unpack_bootimg failed to read back $f"; }
    grep -q "^dtb size: $(wc -c < "$DTB")\$" "$log" \
        || { cat "$log" >&2; die "dtb size mismatch in $f"; }
    grep -q "type: 0x1$" "$log" \
        || { cat "$log" >&2; die "vendor ramdisk is not PLATFORM type in $f"; }
    cmp -s "$DTB" "$WORK/unpack-$(basename "$f")/dtb" \
        || die "dtb payload mismatch in $f"
    echo "build-test-bootimg: verified $f"
}

verify_boot "$OUTPUT_DIR/piano-test-boot.img"
verify_vendor_boot "$OUTPUT_DIR/piano-test-vendor_boot.img"
verify_boot "$OUTPUT_DIR/piano-test-boot-ramdisk.img"
verify_vendor_boot "$OUTPUT_DIR/piano-test-vendor_boot-dtb.img"
verify_boot "$OUTPUT_DIR/piano-test-boot-v2.img"

# --- manifest ---------------------------------------------------------------
{
    echo "piano RAM-boot test image set"
    echo "kernel: $KVER"
    echo "cmdline: $CMDLINE"
    echo "boot params: header v$HEADER_VERSION, pagesize $PAGESIZE," \
         "base $VB_BASE koff $VB_KERNEL_OFFSET roff $VB_RAMDISK_OFFSET" \
         "tags $VB_TAGS_OFFSET dtb $VB_DTB_OFFSET (stock-confirmed)"
    echo
    sha256sum "$OUTPUT_DIR"/piano-test-*.img
    [ -f "$KEY_OUT" ] && { echo; echo "SSH access key: $KEY_OUT"; }
    [ "$ROOT_PASSWORD_SET" = 1 ] \
        && echo "SSH root password auth: enabled$([ -n "$ROOT_PASSWORD" ] || echo ' (BLANK — press enter)')"
    echo
    echo "Boot order (all RAM-boot, NOTHING is flashed):"
    echo "  1) fastboot getvar current-slot        # record slot"
    echo "  2) fastboot boot piano-test-boot-v2.img"
    echo "     PRIMARY path — single image. The host fastboot (Debian android-tools"
    echo "     37.0.0) accepts exactly ONE image per 'boot' (AOSP FB_CMD_BOOT:"
    echo "     'boot KERNEL [RAMDISK [SECOND]]'); a second argument that is itself a"
    echo "     boot.img dies with 'cannot boot a boot.img *and* ramdisk'."
    echo "  3) optional abl-acceptance probe: fastboot boot piano-test-boot.img"
    echo "     (v4 boot with EMPTY ramdisk and no dtb — only tells whether abl"
    echo "     accepts a RAM boot at all; the kernel starting and then stopping"
    echo "     is EXPECTED, there is no initramfs/dtb in this image)"
    echo "  4) the v4 dual-image combos (boot+vendor_boot /"
    echo "     boot-ramdisk+vendor_boot-dtb) have NO RAM path on this host:"
    echo "     they need a fastboot that accepts multiple images per 'boot'"
    echo "     (watch its usage text); not available with android-tools 37.0.0."
    echo
    echo "After boot: USB-NCM host 10.42.0.1/24, device 10.42.0.2;"
    echo "  ssh -i $([ -n "$KEY_OUT" ] && echo "$KEY_OUT" || echo '<your-key>') root@10.42.0.2"
    echo "  then run: piano-tests"
} | tee "$OUTPUT_DIR/MANIFEST.txt"

echo
echo "build-test-bootimg: complete — see $OUTPUT_DIR/MANIFEST.txt"
