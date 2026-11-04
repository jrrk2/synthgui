ENTRY(_start)
SECTIONS {
  . = 0x40000000;
  .text : { *(.text.init) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data : { *(.data .data.* .sdata .sdata.*) }
  .bss : { *(.bss .bss.* .sbss .sbss.* COMMON) }
  . = ALIGN(16);
  . = . + 0x100000;
  _stack = .;
  /DISCARD/ : { *(.eh_frame*) *(.riscv.attributes) *(.comment) }
}
