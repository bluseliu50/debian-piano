#!/usr/bin/env python3
"""Splice dtbo-piano-subsys.dts from the proven nopd9 base + subsystem fragments.

Reads boot/dtbo-piano-usb-nopd9.dts (device-verified), appends the subsystem
fragment chunk (boot/subsys-fragments.dtsi) before the final closing brace,
and adds the extra dt-bindings includes. Emits boot/dtbo-piano-subsys.dts.

Optional --only 225,227,260 keeps ONLY those top-level fragment@N blocks
(brace-depth parsed; labels referenced from a kept fragment must live in a
kept fragment). Used for minimal-risk device rounds: the nopd9 base plus a
hand-picked subset instead of the whole bring-up set.
"""

from pathlib import Path
import re
import sys

BOOT = Path(__file__).resolve().parent


def filter_fragments(chunk: str, keep: set[int]) -> str:
    """Keep only fragment@N top-level blocks whose N is in `keep`.

    A block starts at a line `\\tfragment@N {` and ends at its balanced
    `\\t};`. Preamble text (comments/includes before the first block) is
    always kept; inter-block comments are dropped with their block.
    """
    out: list[str] = []
    lines = chunk.splitlines(keepends=True)
    i = 0
    first_block = True
    while i < len(lines):
        m = re.match(r"\tfragment@(\d+) \{\s*$", lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        # walk to the balanced close of this block
        depth = 0
        j = i
        while j < len(lines):
            depth += lines[j].count("{") - lines[j].count("}")
            j += 1
            if depth == 0:
                break
        else:
            sys.exit(f"unbalanced fragment block starting at line {i + 1}")
        fid = int(m.group(1))
        if fid in keep:
            if not first_block:
                out.append("\n")  # keep blocks visually separated
            out.extend(lines[i:j])
        first_block = False
        i = j
    return "".join(out)


def main() -> None:
    only: set[int] | None = None
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--only":
        only = {int(x) for x in args[1].split(",")}
    elif args:
        sys.exit(f"usage: {sys.argv[0]} [--only 225,227,260]")

    base = (BOOT / "dtbo-piano-usb-nopd9.dts").read_text()
    chunk = (BOOT / "subsys-fragments.dtsi").read_text()
    if only is not None:
        chunk = filter_fragments(chunk, only)

    # extra includes after the existing rpmh-rsc.h include line
    anchor = "#include <dt-bindings/soc/qcom,rpmh-rsc.h>"
    if anchor not in base:
        sys.exit("anchor include not found in nopd9 base")
    extra_includes = anchor + """
#include <dt-bindings/gpio/gpio.h>
#include <dt-bindings/clock/qcom,rpmh.h>
#include <dt-bindings/sound/qcom,q6dsp-lpass-ports.h>
#include <dt-bindings/soc/qcom,gpr.h>
#include <dt-bindings/interconnect/qcom,sm8750-rpmh.h>
#include <dt-bindings/interconnect/qcom,icc.h>"""
    base = base.replace(anchor, extra_includes, 1)

    # splice the chunk before the final closing brace of the root node
    stripped = base.rstrip()
    if not stripped.endswith("\n};"):
        sys.exit("cannot locate final root closing brace")
    idx = stripped.rfind("\n};")
    merged = stripped[:idx].rstrip("\n") + "\n\n" + chunk.strip("\n") + "\n\n};\n"

    out = BOOT / "dtbo-piano-subsys.dts"
    out.write_text(merged)
    scope = f"fragments {sorted(only)}" if only is not None else "all fragments"
    print(f"spliced {out} ({merged.count(chr(10))} lines, {scope})")


if __name__ == "__main__":
    main()
