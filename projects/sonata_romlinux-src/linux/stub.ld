/*
 * Linker script for M-mode stub.
 * Linked at address 0 — the code is position-independent.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0;
    .text : { *(.text) *(.got) *(.got.plt) }
    /DISCARD/ : { *(*) }
}
