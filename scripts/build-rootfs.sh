#!/usr/bin/env bash
# build-rootfs.sh — Debian arm64 rootfs for the Xiaomi Pad 8 Pro (piano).
#
# Usage:
#   scripts/build-rootfs.sh --suite SUITE --output DIR \
#       [--firmware-dir DIR] [--userspace-dir DIR] [--allow-missing-firmware]
#
# - Architecture is fixed to arm64.
# - On non-arm64 hosts, qemu-aarch64-static + binfmt registration are
#   required and checked.
# - Fails with a list of missing prerequisites (tools, root, network,
#   packages); never produces a half-finished rootfs silently.
# - Without --firmware-dir the build refuses to run unless
#   --allow-missing-firmware is given (the image then records
#   /usr/share/xiaomi-piano/firmware-missing). Placeholders are never
#   written in place of real firmware.

set -euo pipefail

usage() {
    sed -n '2,14p' "$0"; exit 2
}

die() {
    echo "build-rootfs: error: $*" >&2
    exit 1
}

ARCH=arm64
SUITE=""
OUTDIR=""
FIRMWARE_DIR=""
USERSPACE_DIR=""
ALLOW_MISSING_FIRMWARE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --suite)                 SUITE="${2:?}"; shift 2 ;;
        --output)                OUTDIR="${2:?}"; shift 2 ;;
        --firmware-dir)          FIRMWARE_DIR="${2:?}"; shift 2 ;;
        --userspace-dir)         USERSPACE_DIR="${2:?}"; shift 2 ;;
        --allow-missing-firmware) ALLOW_MISSING_FIRMWARE=1; shift ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

[ -n "$SUITE" ]   || usage
[ -n "$OUTDIR" ]  || usage

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGES_FILE="$REPO_ROOT/rootfs/packages.txt"
MIRROR="http://deb.debian.org/debian"

[ -f "$PACKAGES_FILE" ] || die "missing $PACKAGES_FILE"

missing=()

# --- prerequisites --------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    missing+=("root privileges (run under sudo)")
fi
command -v debootstrap >/dev/null 2>&1 || missing+=(debootstrap)
command -v chroot      >/dev/null 2>&1 || missing+=(chroot)
HOSTARCH=$(uname -m)
QEMU=""
if [ "$HOSTARCH" != "aarch64" ]; then
    QEMU=$(command -v qemu-aarch64-static || true)
    [ -n "$QEMU" ] || missing+=("qemu-aarch64-static (host is $HOSTARCH)")
    if [ -n "$QEMU" ] && ! grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        missing+=("binfmt registration for qemu-aarch64 (systemd-binfmt / binfmt-support)")
    fi
fi
if [ ! -e "/usr/share/debootstrap/scripts/$SUITE" ]; then
    missing+=("debootstrap suite script for '$SUITE' (/usr/share/debootstrap/scripts/$SUITE)")
fi
# network reachability to the mirror
if ! curl -fsI --max-time 15 "$MIRROR/" >/dev/null 2>&1; then
    missing+=("network access to $MIRROR")
fi
if [ -n "$FIRMWARE_DIR" ] && [ ! -d "$FIRMWARE_DIR" ]; then
    missing+=("--firmware-dir $FIRMWARE_DIR (not a directory)")
fi
if [ "${#missing[@]}" -gt 0 ]; then
    echo "build-rootfs: missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
fi

if [ -z "$FIRMWARE_DIR" ] && [ "$ALLOW_MISSING_FIRMWARE" -ne 1 ]; then
    die "no --firmware-dir given; pass --allow-missing-firmware for an explicitly firmware-less rootfs"
fi

# --- package list ---------------------------------------------------------
sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
    -e 's/[[:space:]]//g' "$PACKAGES_FILE" > "$REPO_ROOT/.pkglist.$$"
mapfile -t PKGS < "$REPO_ROOT/.pkglist.$$"
rm -f "$REPO_ROOT/.pkglist.$$"
[ "${#PKGS[@]}" -gt 0 ] || die "empty package list in $PACKAGES_FILE"

OUTDIR=$(realpath -m "$OUTDIR")
if [ -e "$OUTDIR" ]; then
    die "output directory $OUTDIR already exists; remove it first (refusing to overwrite)"
fi
mkdir -p "$OUTDIR"
ROOTFS="$OUTDIR/rootfs"
mkdir -p "$ROOTFS"

echo "build-rootfs: phase 1: debootstrap $SUITE $ARCH minbase (host=$HOSTARCH)"

DEBOOTSTRAP_ARGS=(--arch="$ARCH" --variant=minbase --components=main)
if [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
    DEBOOTSTRAP_ARGS+=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)
fi
if [ -n "$QEMU" ]; then
    mkdir -p "$ROOTFS/usr/bin"
    cp "$QEMU" "$ROOTFS/usr/bin/qemu-aarch64-static"
fi

debootstrap "${DEBOOTSTRAP_ARGS[@]}" --foreign "$SUITE" "$ROOTFS" "$MIRROR"
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

# Phase 2: full package list via the real apt solver inside the chroot.
# This resolves virtual-package alternatives (e.g. dbus-system-bus)
# correctly and reports any missing package by name, instead of failing
# deep inside debootstrap's own resolver.
echo "build-rootfs: phase 2: installing ${#PKGS[@]} packages via apt"
mount -t proc proc "$ROOTFS/proc"
mount --rbind /sys "$ROOTFS/sys"
mount --rbind /dev "$ROOTFS/dev"
cleanup_mounts() {
    umount -l "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT
chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "${PKGS[@]}"
cleanup_mounts
trap - EXIT

# --- bring-up configuration ----------------------------------------------
echo "piano" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1       localhost
127.0.1.1       piano
EOF

# Serial console on the SM8750 QUP UART (ttyMSM0)
mkdir -p "$ROOTFS/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
    "$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyMSM0.service"

# Debug access over the gadget network: root/piano, sshd permits it only
# as a bring-up convenience — tighten after first successful boot.
chroot "$ROOTFS" /bin/sh -c 'echo "root:piano" | chpasswd'
mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
cat > "$ROOTFS/etc/ssh/sshd_config.d/50-piano-bringup.conf" <<EOF
# piano bring-up: root login allowed for early debugging over USB NCM.
# REMOVE after install on internal storage.
PermitRootLogin yes
PasswordAuthentication yes
EOF

chroot "$ROOTFS" systemctl enable ssh.service || true
chroot "$ROOTFS" systemctl enable NetworkManager.service || true

# --- firmware -------------------------------------------------------------
mkdir -p "$ROOTFS/usr/share/xiaomi-piano" "$ROOTFS/lib/firmware"
FIRMWARE_MANIFEST="$OUTDIR/firmware-manifest.txt"
: > "$FIRMWARE_MANIFEST"
if [ -n "$FIRMWARE_DIR" ]; then
    echo "build-rootfs: injecting firmware from $FIRMWARE_DIR"
    cp -a "$FIRMWARE_DIR"/. "$ROOTFS/lib/firmware/"
    ( cd "$ROOTFS/lib/firmware" && find . -type f -print0 ) \
        | ( cd "$ROOTFS/lib/firmware" && xargs -0 sha256sum ) \
        >> "$FIRMWARE_MANIFEST" || true
else
    echo "build-rootfs: firmware-less rootfs (--allow-missing-firmware)"
    cat > "$ROOTFS/usr/share/xiaomi-piano/firmware-missing" <<EOF
This rootfs was built WITHOUT device firmware (--allow-missing-firmware).
No placeholder firmware was installed. Inject real firmware from
local/firmware/ via scripts/build-rootfs.sh --firmware-dir DIR.
EOF
    echo "MISSING: all (built with --allow-missing-firmware)" >> "$FIRMWARE_MANIFEST"
fi

# --- userspace packages ---------------------------------------------------
if [ -n "$USERSPACE_DIR" ]; then
    [ -d "$USERSPACE_DIR" ] || die "--userspace-dir $USERSPACE_DIR is not a directory"
    if compgen -G "$USERSPACE_DIR/*.deb" > /dev/null; then
        mkdir -p "$ROOTFS/root/userspace"
        cp "$USERSPACE_DIR"/*.deb "$ROOTFS/root/userspace/"
        chroot "$ROOTFS" /bin/sh -c \
            'dpkg -i /root/userspace/*.deb || apt-get -y install -f --no-install-recommends'
    else
        echo "build-rootfs: note: no .deb files in $USERSPACE_DIR (skipped)"
    fi
fi

# --- build manifest -------------------------------------------------------
{
    echo "suite=$SUITE"
    echo "arch=$ARCH"
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hostarch=$HOSTARCH"
    echo "firmware=$([ -n "$FIRMWARE_DIR" ] && echo "$FIRMWARE_DIR" || echo "missing(-allow-missing-firmware)")"
    # shellcheck disable=SC2016  # ${Package}/${Version} must reach dpkg-query literally
    chroot "$ROOTFS" dpkg-query -W -f='${Package} ${Version}\n' | sort
} > "$OUTDIR/build-manifest.txt"

truncate -s 0 "$ROOTFS/etc/machine-id" 2>/dev/null || true
rm -rf "$ROOTFS/var/lib/apt/lists"/*

echo "build-rootfs: rootfs ready at $ROOTFS"
echo "build-rootfs: manifest at $OUTDIR/build-manifest.txt"
