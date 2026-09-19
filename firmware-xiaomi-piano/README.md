# firmware-xiaomi-piano

Packaging interface for the piano proprietary firmware set
(adsp/cdsp/venus/GPU zap/WLAN/BT/touch/keyboard/audio).

**No firmware blobs live in this repository.** The helper below reads a
local extraction directory (e.g.
`local/firmware/` in the umbrella workspace) and produces a
`firmware-xiaomi-piano` deb for installation into rootfs images.

## Usage

```sh
# from the umbrella workspace root (or anywhere with FIRMWARE_DIR set)
FIRMWARE_DIR=/path/to/local/firmware \
    ./build-firmware-deb.sh --version 1.0 --output out/

# then, at rootfs build time:
sudo scripts/build-rootfs.sh --suite trixie --output out/rootfs \
    --firmware-dir /path/to/local/firmware
```

The generated deb lists every shipped file with its SHA-256 in
`/usr/share/doc/firmware-xiaomi-piano/manifest.txt`. An empty or missing
input directory is an error — the script never fabricates placeholder
firmware. When no firmware is available at all, build the rootfs with
`--allow-missing-firmware` instead (the image records the gap; see the
main README).
