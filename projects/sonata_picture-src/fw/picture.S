# The picture: the 160x128 RGB565 frame (40960 bytes, little-endian pixels, row by row) assembled into the program with .incbin,
# so it is just linked data. frame.rgb565 is made from the chosen picture by the Makefile (mkrom frame ...); a different
# picture is a different frame.rgb565 and so a different ROM image, which is what the ROMs tab of the Block RAMs window writes
# into the routed FASM.
        .section .picture, "a"
        .balign 4
        .globl  picture_rom
picture_rom:
        .incbin "frame.rgb565"
        .globl  picture_end
picture_end:
