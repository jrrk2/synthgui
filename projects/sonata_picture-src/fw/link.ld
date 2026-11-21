/* The boot ROM is 64 KB (16384 words) at 0, the SRAM 6 KB at 0x10000000. The code comes first, then the picture
 * (picture.S, .incbin of frame.rgb565), 40960 bytes. */
MEMORY {
    rom  (rx) : ORIGIN = 0x00000000, LENGTH = 0x10000
    sram (rw) : ORIGIN = 0x10000000, LENGTH = 0x1800
}
ENTRY(_start)
SECTIONS {
    .text    : { *(.text.start) *(.text*) *(.rodata*) } > rom
    .picture : ALIGN(4) { *(.picture) } > rom
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame) }
}
_stack_top = ORIGIN(sram) + LENGTH(sram);
