# debian-piano

Debian rootfs, initramfs and boot-image builder for the **Xiaomi Pad 8 Pro**
(codename *piano*, Qualcomm SM8750 / Snapdragon 8 Elite).

Everything here is written from scratch and licensed MIT, except the
AOSP mkbootimg tools vendored under `mkbootimg/` (Apache-2.0, provenance in
`mkbootimg/README.md`). No proprietary firmware blobs are stored in this
repository — firmware is always injected from a local directory at build
time.

## Repository layout

| Path | Purpose |
|---|---|
| `scripts/build-rootfs.sh` | Debian arm64 rootfs via `debootstrap` |
| `scripts/build-initramfs.sh` | Debug initramfs with USB-NCM network + dropbear |
| `scripts/build-bootimg.sh` | Android boot image packer (AOSP mkbootimg wrapper) |
| `initramfs/init` | `/init` installed into the initramfs |
| `rootfs/packages.txt` | Fixed package list for the rootfs |
| `boot/stock-boot-params.env` | Boot-image parameter provenance (CONFIRMED/UNVERIFIED) |
| `mkbootimg/` | Vendored AOSP `mkbootimg.py`, `unpack_bootimg.py`, `repack_bootimg.py` |
| `firmware-xiaomi-piano/` | Firmware packaging helper (reads `local/firmware/`, never stores blobs) |

## Build entry points

```sh
# Rootfs (run as root; native arm64, or cross with qemu-user + binfmt)
sudo scripts/build-rootfs.sh --suite trixie --output out/rootfs \
    [--firmware-dir /path/to/local/firmware] [--allow-missing-firmware]

# Initramfs (needs busybox and dropbear binaries)
scripts/build-initramfs.sh \
    --busybox /usr/bin --dropbear /usr/sbin --output out/initramfs-piano.cpio.gz

# Boot image (every parameter must be CONFIRMED against the stock ROM
# before a deliverable image can be produced)
scripts/build-bootimg.sh \
    --kernel out/Image --ramdisk out/initramfs-piano.cpio.gz \
    --dtb out/sm8750-xiaomi-piano.dtb \
    --header-version 4 --pagesize 4096 --ramdisk-compression lz4 \
    --output out/boot.img
```

### Firmware-less mode

Without `--firmware-dir`, `build-rootfs.sh` refuses to build unless
`--allow-missing-firmware` is passed. In that mode the rootfs ships without
any device firmware, and the fact is recorded inside the image
(`/usr/share/xiaomi-piano/firmware-missing`) and in the build manifest.
Placeholders are never substituted for real firmware.

### Boot-image verification gate

`build-bootimg.sh` reads `boot/stock-boot-params.env`, which marks every
boot-image parameter as `CONFIRMED` (measured from the stock fastboot ROM,
see the umbrella repo `docs/bootimg-notes.md`) or `UNVERIFIED`. If any
parameter is `UNVERIFIED` the script refuses to produce a deliverable image.
Synthetic smoke images for CI are only possible with `--allow-unverified`,
which forces a `synthetic-` prefix on the output file name so they can never
be mistaken for flashable artifacts.

## Outputs

- `out/rootfs/` — rootfs tree; `out/rootfs.build-manifest` — suite, package
  versions, firmware manifest
- `out/initramfs-piano.cpio.gz` — debug initramfs
- `out/boot.img` — boot image (only after stock-ROM-confirmed parameters)

## Local dependencies

Rootfs: `debootstrap`, root privileges, network access to
`deb.debian.org`; on non-arm64 hosts also `qemu-aarch64-static` with
binfmt registration. Initramfs: static busybox, `dropbear` binaries,
`cpio`. Boot image: Python 3.

## Flashing safety

Only ever write `boot_b`, `dtbo_b`, or userdata-derived partitions.
**NEVER** flash `abl`, `xbl`, `xbl_config`, `tz`, `hyp`, `devcfg` or any
other bootloader-chain partition. Prefer `fastboot boot boot.img`
(RAM boot) for iteration. Slot A stock Android must remain bootable at
all times. See the umbrella repo safety rules before touching a device.

## CI

GitHub Actions workflows run natively on arm64 runners
(`ubuntu-24.04-arm`): `lint` (shellcheck / sh -n / py_compile / yamllint /
actionlint) and `build` (firmware-less rootfs, initramfs, synthetic boot
image smoke). Both are required checks on `main`.
