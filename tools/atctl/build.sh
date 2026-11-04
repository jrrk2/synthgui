#!/bin/bash
# build.sh BUILD_DIR OUT [CC]: atctl for this SoC, from the BIOS's own cmd_atspeed.c and LiteX's generated csr.h.
#   BUILD_DIR  LiteX --output-dir (software/include/generated/csr.h)    CC default riscv32 static gcc
# Needs a kernel with CONFIG_DEVMEM=y and CONFIG_STRICT_DEVMEM off (kernel/fpu-nfs.config).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; B=$1; O=$2; CC=${3:-rv32g-gcc}
LX=${LITEX_BIOS:-$HOME/xc7-bitstream-tools/litex-deps/litex/litex/soc/software/bios/cmds}
W=$(mktemp -d -p "$(dirname "$O")"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/cmds" "$W/generated"; cp "$B/software/include/generated/"{csr.h,soc.h,mem.h} "$W/generated/"; cp "$LX/mmcm_drp.h" "$W/cmds/"
awk '/^\/\* sload:/{exit} {print}' "$LX/cmd_atspeed.c" > "$W/cmds/cmd_atspeed.c"
cp "$HERE/shim/command.h" "$HERE/shim/helpers.h" "$W/"
"$CC" -O2 -I"$W" -I"$HERE/shim" -o "$O" -include "$W/generated/csr.h" "$HERE/atctl.c" -I"$W/cmds/.."
