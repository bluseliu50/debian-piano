# debian-piano

Debian rootfs, initramfs and boot-image builder for the **Xiaomi Pad 8 Pro**
(codename *piano*, Qualcomm SM8750 / Snapdragon 8 Elite).

Everything here is written from scratch and licensed MIT, except the
AOSP mkbootimg tools vendored under `mkbootimg/` (Apache-2.0, provenance in
`mkbootimg/README.md`). No proprietary firmware blobs are stored in this
repository — the RAM-boot test image picks firmware up from a local directory at build
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

## Build entry points

```sh
# Rootfs (run as root; native arm64, or cross with qemu-user + binfmt)
sudo scripts/build-rootfs.sh --suite trixie --output out/rootfs

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

# RAM-boot first-light test image (display + touch + USB-NCM SSH):
# fetches static arm64 busybox + a dropbear userland tree from Debian,
# then builds and round-trip-verifies five boot-image variants.
scripts/fetch-arm64-tools.sh
scripts/build-test-bootimg.sh \
    --kernel-dir ../linux-piano/out \
    --firmware-dir ../local/firmware \
    --output-dir out/test-image
```

### Test image contents

`build-test-bootimg.sh` assembles a self-contained RAM-boot test image from
the `piano/test-bringup` kernel (display pipeline + NT37801 panel + NT36532E
touch). The initramfs carries:

- USB-NCM gadget network (host 10.42.0.1/24, device 10.42.0.2) with
  dropbear SSH; an ed25519 access key is generated per build (or pass
  `--authorized-keys`), `ssh -i out/test-image/piano-test-ssh-ed25519
  root@10.42.0.2`. Optionally add root password auth with
  `--root-password PASS` (SHA-512 hash in the initramfs /etc/passwd);
  `--root-password ''` sets a BLANK password — SSH has no true
  "no-auth" mode, but with dropbear's `-B` a blank password means
  "press enter to log in". These are only reachable over the USB
  point-to-point link.
- `piano-tests` (menu + boot smoke report), `piano-touch-test`
  (streams/decodes NT36532E THP touch frames), `piano-display-test`
  (DRM state + colour-field/noise painting through /dev/fb0) and
  `piano-collect` (evidence tarball for scp)
- the `spi-geni-qcom` + `nt36532e_ts` modules and the four stock Novatek
  touch firmware blobs (test image only, via `--firmware-dir`)

Every image is verified by an `unpack_bootimg` read-back before the build
succeeds; parameters come from `boot/stock-boot-params.env` (stock-ROM
CONFIRMED values only). Boot order and safety rules: see the umbrella
repo's device bring-up runbook.
```

### Device firmware (open design question)

`build-rootfs.sh` does **not** install device firmware, and the earlier
`firmware-xiaomi-piano` packaging helper has been removed: blobs never
enter this repository, and a local-directory injection scheme cannot work
for CI-built full images. The distribution design (how proprietary blobs
reach reproducible images) will be decided with the maintainer when the
Debian-on-device phase starts. Until then the rootfs is firmware-less by
design, and only the local-built RAM-boot test image carries firmware.

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
  versions
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
actionlint) and `build` (rootfs without firmware, initramfs, synthetic boot
image smoke). Both are required checks on `main`.
