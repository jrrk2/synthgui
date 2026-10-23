#!/bin/sh
# Build the M-mode stub for TFTP boot, padded to 4 KB.  Usage: build_stub.sh <out.bin> [-DNO_PMP]
# With -DNO_PMP the PMP set-up is nops, so every other offset is the stock stub's (this SoC's VexRiscv has no PMP).
set -e
D=$(cd "$(dirname "$0")" && pwd)
OUT=$1; shift
CROSS=${CROSS:-riscv64-elf-}
${CROSS}gcc -nostdlib -nostartfiles -march=rv32ima_zicsr_zifencei -mabi=ilp32 -DTFTP_BOOT "$@" -T "$D/stub.ld" -o "${OUT%.bin}.elf" "$D/stub.S"
${CROSS}objcopy -O binary "${OUT%.bin}.elf" "$OUT"
truncate -s 4096 "$OUT"
