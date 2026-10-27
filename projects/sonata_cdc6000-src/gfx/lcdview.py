#!/usr/bin/env python3
"""lcdview.py LCD.OUT PICTURE.png: draw what the words of a Pascal program's LCD file (cdcemu's -d directory, lcd.out, one octal
word a line) put on the panel (see cdc_lcd.v for the word format), three times enlarged, as a PNG."""
import sys, zlib, struct
words=[int(l,8) for l in open(sys.argv[1]) if l.strip()]
W,H=160,128
fb=[[0]*W for _ in range(H)]
for w in words:
    c=w&0xFFFF
    if (w>>32)&1:
        fb=[[c]*W for _ in range(H)]
    else:
        x=(w>>16)&0xFF; y=(w>>24)&0xFF
        if x<W and y<H: fb[y][x]=c
sc=3
raw=b''
for y in range(H):
    row=b''
    for x in range(W):
        c=fb[y][x]
        r=((c>>11)&31)*255//31; g=((c>>5)&63)*255//63; b=(c&31)*255//31
        row+=bytes((r,g,b))*sc
    raw+=(b'\x00'+row)*sc
def chunk(t,d): 
    c=struct.pack('>I',len(d))+t+d
    return c+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',W*sc,H*sc,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
open(sys.argv[2],'wb').write(png)
