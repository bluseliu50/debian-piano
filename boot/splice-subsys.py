#!/usr/bin/env python3
"""Splice dtbo-piano-subsys.dts from the proven nopd9 base + subsystem fragments.

Reads boot/dtbo-piano-usb-nopd9.dts (device-verified), appends the subsystem
fragment chunk (boot/subsys-fragments.dtsi) before the final closing brace,
and adds the extra dt-bindings includes. Emits boot/dtbo-piano-subsys.dts.
"""

from pathlib import Path
import sys

BOOT = Path(__file__).resolve().parent
base = (BOOT / "dtbo-piano-usb-nopd9.dts").read_text()
chunk = (BOOT / "subsys-fragments.dtsi").read_text()

# extra includes after the existing rpmh-rsc.h include line
anchor = "#include <dt-bindings/soc/qcom,rpmh-rsc.h>"
if anchor not in base:
    sys.exit("anchor include not found in nopd9 base")
extra_includes = anchor + """
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/clock/qcom,rpmh.h>
#include <dt-bindings/sound/qcom,q6dsp-lpass-ports.h>
#include <dt-bindings/soc/qcom,gpr.h>"""
base = base.replace(anchor, extra_includes, 1)

# splice the chunk before the final closing brace of the root node
stripped = base.rstrip()
if not stripped.endswith("\n};"):
    sys.exit("cannot locate final root closing brace")
idx = stripped.rfind("\n};")
merged = stripped[:idx].rstrip("\n") + "\n\n" + chunk.strip("\n") + "\n\n};\n"

out = BOOT / "dtbo-piano-subsys.dts"
out.write_text(merged)
print(f"spliced {out} ({merged.count(chr(10))} lines)")
