#!/bin/bash
# Run the picture program under QEMU and compare what it writes to the LCD with the picture. QEMU's virt machine has RAM where
# the Sonata has its LCD (0x80310000), so the program is linked at 0x80000000 (its stack and picture ROM move with it) and its
# writes to the frame buffer and the mode register land in RAM, where QEMU's monitor dumps them.
#
#   test-qemu.sh picture.elf PICTURE            (picture.elf is only a reminder that the program must be built first)
set -eu
cd "$(dirname "$0")"
ELF=${1:-picture.elf}; PICTURE=${2:-../pictures/sonata-logo.rgb565}
RVCC=${RVCC:-riscv64-elf-gcc}; RVOBJCOPY=${RVOBJCOPY:-riscv64-elf-objcopy}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -e 's/ORIGIN = 0x00000000/ORIGIN = 0x80000000/' -e 's/ORIGIN = 0x10000000/ORIGIN = 0x80100000/' link.ld > "$T/link.ld"
[ -x ./mkrom ] || ${HOSTCC:-cc} -O2 -o mkrom mkrom.c
./mkrom frame "$PICTURE" "$T/frame.rgb565"          # the frame the picture file means
cp "$T/frame.rgb565" "$T/expect.fb"
./mkrom photos - "$T/none.S" 2>/dev/null                 # no flash frames: the built-in picture alone
$RVCC -march=rv32imac_zicsr -mabi=ilp32 -Os -ffreestanding -fno-pic -nostdlib -nostartfiles -DCSR_BASE=0x80200000u -T "$T/link.ld" -Wa,-I,"$T" \
    -Wl,--no-warn-rwx-segments -o "$T/t.elf" start.S picture.c picture.S "$T/none.S"
$RVOBJCOPY -O binary "$T/t.elf" "$T/rom.bin"
( sleep 2
  echo "pmemsave 0x80310000 40960 \"$T/fb.bin\""
  echo "pmemsave 0x80305144 4 \"$T/mode.bin\""
  sleep 1; echo quit ) | qemu-system-riscv32 -machine virt -bios none -nographic -serial null -monitor stdio \
    -device loader,file="$T/rom.bin",addr=0x80000000,cpu-num=0 >/dev/null
cmp "$T/fb.bin" "$T/expect.fb" && echo "frame buffer: 40960 bytes, the picture"
[ "$(od -An -tu4 "$T/mode.bin" | tr -d ' ')" = 1 ] && echo "mode register: 1 (frame buffer shown)"
echo "LED register written, no trap: the program got to the mode register after it"

# the slideshow: the real rootfs romfs where the flash window would be, one round with no interval, and the last frame left on
# the display must be the last photo (the virt machine's own CLINT, at 0x02000000, 10 MHz, is the timer)
ROMFS=${ROMFS:-../../sonata_romlinux-src/linux/images/rootfs.romfs}
if [ -f "$ROMFS" ]; then
    ./mkrom photos "$ROMFS" "$T/photos.S" 2>/dev/null
    N=$(sed -n 's/^ *\.word *\([0-9]*\)$/\1/p' "$T/photos.S" | head -1)
    LAST=$(grep '^ *\.word *0x' "$T/photos.S" | tail -1 | sed 's/.*0x//')
    $RVCC -march=rv32imac_zicsr -mabi=ilp32 -Os -ffreestanding -fno-pic -nostdlib -nostartfiles -DCSR_BASE=0x80200000u \
        -DFLASH_BASE=0x80400000u -DCLINT_BASE=0x02000000u -DTIMEBASE_HZ=10000000 -DINTERVAL_S=0 -DROUNDS=1 \
        -T "$T/link.ld" -Wa,-I,"$T" -Wl,--no-warn-rwx-segments -o "$T/s.elf" start.S picture.c picture.S "$T/photos.S"
    $RVOBJCOPY -O binary "$T/s.elf" "$T/s.bin"
    dd if="$ROMFS" bs=1 skip=$(( 0x$LAST - 0x5C0000 )) count=40960 of="$T/last.fb" 2>/dev/null
    ( sleep 4; echo "pmemsave 0x80310000 40960 \"$T/fb2.bin\""; sleep 1; echo quit ) | qemu-system-riscv32 -machine virt -bios none \
        -nographic -serial null -monitor stdio -device loader,file="$T/s.bin",addr=0x80000000,cpu-num=0 \
        -device loader,file="$ROMFS",addr=$(printf '0x%x' $(( 0x80400000 + 0x5C0000 ))) >/dev/null
    cmp "$T/fb2.bin" "$T/last.fb" && echo "slideshow: $N frames from the flash window, the last one is on the display"
fi
