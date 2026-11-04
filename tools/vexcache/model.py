#!/usr/bin/env python3
"""model.py trace.csv [board seconds]: time for each memory system from the trace and the penalties measured by membench.
One fitted parameter: the base time per instruction, from the measured time of the current configuration."""
import sys, csv
rows = list(csv.reader(open(sys.argv[1])))
T = float(sys.argv[2]) if len(sys.argv) > 2 else 951.0
N = int(rows[0][1]); loads = int(rows[0][3]); stores = int(rows[0][5])
it = {int(r[1]): int(r[3]) for r in rows if r[0] == 'itlb' and r[1].isdigit()}
dt = {int(r[1]): int(r[3]) for r in rows if r[0] == 'dtlb'}
ic = {int(r[1]): int(r[3]) for r in rows if r[0] == 'ic'}
dc = {int(r[1]): int(r[3]) for r in rows if r[0] == 'dc'}
l2 = {(int(r[1]), int(r[2]), int(r[3])): list(map(int, r[4:])) for r in rows if r[0] == 'l2'}
# ns, membench at 83.3 MHz
P = dict(i=578.0, d=607.0, l2m=1026.0, st=33.0)
def mem(I, D, L, IT, DT, walk):
    ird, irdm, drd, drdm, wr, wrm = l2[(I, D, L)]
    return dict(icache=ird * P['i'], dcache=drd * P['d'], l2miss=(irdm + drdm + wrm) * P['l2m'], store=wr * P['st'], tlb=(it[IT] + dt[DT]) * walk)
def total(*a, base): return (N * base + sum(mem(*a).values())) * 1e-9
cur = (4, 4, 128, 4, 4)
print(f'{N/1e9:.2f} G instructions, {loads/1e9:.2f} G loads, {stores/1e9:.2f} G stores, measured {T:.0f} s = {T*83.33e6/N:.1f} cycles/instruction')
for walk in (160.0, 317.0):
    base = (T * 1e9 - sum(mem(*cur, walk).values())) / N
    print(f'\nTLB walk {walk:.0f} ns: fitted base {base:.1f} ns/insn = {base*0.08333:.2f} cycles')
    print(' current breakdown (s): base %.0f, ' % (N * base * 1e-9) + ', '.join(f'{k} {v*1e-9:.0f}' for k, v in mem(*cur, walk).items()))
    print(' DTLB sweep at I4 D4 L128 ITLB4 :', ' '.join(f'{k}:{total(4,4,128,4,k,walk,base=base):.0f}' for k in sorted(dt)))
    print(' ITLB sweep at I4 D4 L128 DTLB4 :', ' '.join(f'{k}:{total(4,4,128,k,4,walk,base=base):.0f}' for k in sorted(it)))
    print(' DTLB sweep at I64 D16 L128 ITLB16:', ' '.join(f'{k}:{total(64,16,128,16,k,walk,base=base):.0f}' for k in sorted(dt)))
    print(' Icache at D4 :', ' '.join(f'{k}K:{total(k,4,128,4,4,walk,base=base):.0f}' for k in sorted(ic)))
    print(' Dcache at I4 :', ' '.join(f'{k}K:{total(4,k,128,4,4,walk,base=base):.0f}' for k in sorted(dc)))
    print(' L2 at I64 D16 ITLB16 DTLB32 :', ' '.join(f'{k}K:{total(64,16,k,16,32,walk,base=base):.0f}' for k in sorted({x[2] for x in l2})))
    for c in [(4,4,128,4,4),(4,4,128,8,32),(16,16,128,8,16),(16,16,128,16,32),(32,16,128,16,32),(64,16,128,4,4),(64,16,128,16,32),(64,16,128,32,64),(64,32,128,16,32),(64,32,512,32,64),(64,64,2048,64,256)]:
        t = total(*c, walk, base=base); print(f'  I{c[0]:>2} D{c[1]:>2} L2 {c[2]:>4}K iTLB {c[3]:>2} dTLB {c[4]:>3}: {t:5.0f} s  {T/t:4.2f}x   break-even Fmax {83.33*t/T:5.1f} MHz')
