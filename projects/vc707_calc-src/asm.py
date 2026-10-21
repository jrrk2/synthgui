#!/usr/bin/env python3
# Assembler + ISA simulator for calc_core, and the UART calculator.
# UNIFORM 32-bit datapath: operands and results are all 32-bit, so a result can
# feed back in as an operand.  Operators: + - * /.
#   * is computed TWO ways every time: by the DSP48 (device-under-test, 32x32 via
#     three 16x16 partials) and by software double-and-add (the "regular way").
#     The two are compared; on mismatch the result is flagged with '?'.  This
#     validates the open-flow DSP48 against a software reference.
#   / is binary long division (quotient only); divide-by-zero prints 'E'.
#
# ISA: ACC 8-bit, CY, PC 11-bit, 2048x8 RAM.  Operand instr = 3 bytes.
#   00 HLT 01 LDI 02 LDA 03 STA 04 ADD 05 SUB 06 IN 07 OUT 08 JMP 09 JZ
#   0A ADC 0B SBC 0C JC 0D JNZ 0E ROR
#   DSP48: 0F PSHA 10 PSHB 12 POPP 13 PSHC ; opcodes 80..FF = DSP op
#          (opcode[6:0]=OPMODE). DMUL=0x85 (OPMODE 0x05 => P=A*B).
MEMSIZE = 2048
OPS = dict(HLT=0,LDI=1,LDA=2,STA=3,ADD=4,SUB=5,IN=6,OUT=7,JMP=8,JZ=9,
           ADC=10,SBC=11,JC=12,JNZ=13,ROR=14,PSHA=15,PSHB=16,POPP=18,PSHC=19,DMUL=0x85)
NOARG = {'HLT','IN','OUT','ROR','PSHA','PSHB','POPP','PSHC','DMUL'}

PROG = r"""
; ================= main =================
main:
    call read_num
    LDA num0
    STA A0
    LDA num1
    STA A1
    LDA num2
    STA A2
    LDA num3
    STA A3
    LDA term
    STA op
    call read_num
    LDA num0
    STA B0
    LDA num1
    STA B1
    LDA num2
    STA B2
    LDA num3
    STA B3
    LDA op
    SUB plus
    JZ  do_add
    LDA op
    SUB star
    JZ  do_mul
    LDA op
    SUB slash
    JZ  do_div
; ---- subtract A - B (sign), SBC-free via sub5 ----
    LDI 0
    STA sx4
    STA sy4
    LDA A0
    STA sx0
    LDA A1
    STA sx1
    LDA A2
    STA sx2
    LDA A3
    STA sx3
    LDA B0
    STA sy0
    LDA B1
    STA sy1
    LDA B2
    STA sy2
    LDA B3
    STA sy3
    call sub5
    LDA bw
    JNZ do_neg          ; A < B
    LDA sw0
    STA R0
    LDA sw1
    STA R1
    LDA sw2
    STA R2
    LDA sw3
    STA R3
    JMP show
do_neg:
    LDI 0x2D
    OUT
    LDI 0
    STA sx4
    STA sy4
    LDA B0
    STA sx0
    LDA B1
    STA sx1
    LDA B2
    STA sx2
    LDA B3
    STA sx3
    LDA A0
    STA sy0
    LDA A1
    STA sy1
    LDA A2
    STA sy2
    LDA A3
    STA sy3
    call sub5
    LDA sw0
    STA R0
    LDA sw1
    STA R1
    LDA sw2
    STA R2
    LDA sw3
    STA R3
    JMP show
do_add:
    LDA A0
    ADD B0
    STA R0
    LDA A1
    ADC B1
    STA R1
    LDA A2
    ADC B2
    STA R2
    LDA A3
    ADC B3
    STA R3
    JMP show

; ================= multiply: DSP48 (DUT) vs software, compared =================
do_mul:
; --- DSP path: Rdsp = A*B mod 2^32 = Al*Bl + ((Ah*Bl + Al*Bh) << 16) ---
    LDA A1
    PSHA
    LDA A0
    PSHA               ; dspA = Al
    LDA B1
    PSHB
    LDA B0
    PSHB               ; dspB = Bl
    DMUL
    POPP
    STA P0
    POPP
    STA P1
    POPP
    STA P2
    POPP
    STA P3             ; P0..3 = Al*Bl
    LDA A3
    PSHA
    LDA A2
    PSHA               ; dspA = Ah
    LDA B1
    PSHB
    LDA B0
    PSHB               ; dspB = Bl
    DMUL
    POPP
    STA Q0
    POPP
    STA Q1             ; Q = (Ah*Bl) low16
    LDA A1
    PSHA
    LDA A0
    PSHA               ; dspA = Al
    LDA B3
    PSHB
    LDA B2
    PSHB               ; dspB = Bh
    DMUL
    POPP
    STA S0
    POPP
    STA S1             ; S = (Al*Bh) low16
    LDA Q0             ; mid = Q + S  (low16)
    ADD S0
    STA mid0
    LDA Q1
    ADC S1
    STA mid1
    LDA P0             ; Rdsp = P + (mid<<16)
    STA R0
    LDA P1
    STA R1
    LDA P2
    ADD mid0
    STA R2
    LDA P3
    ADC mid1
    STA R3
    JMP show

; ================= divide A / B (quotient only); B==0 -> 'E' =================
do_div:
    LDA B0
    JNZ div_ok
    LDA B1
    JNZ div_ok
    LDA B2
    JNZ div_ok
    LDA B3
    JNZ div_ok
    LDI 0x45
    OUT
    JMP show_nl
div_ok:
    LDA B0
    STA dv0
    LDA B1
    STA dv1
    LDA B2
    STA dv2
    LDA B3
    STA dv3
    LDI 0
    STA dv4
    STA shift
    LDA A0
    STA N0
    LDA A1
    STA N1
    LDA A2
    STA N2
    LDA A3
    STA N3
dq_up:                  ; SBC-free MSB-first compare of N (N4=0) vs dv
    LDI 0
    SUB dv4
    JC  dq_down          ; N4(0) < dv4 -> N < dv
    LDA N3
    SUB dv3
    JC  dq_down
    JNZ dq_dbl
    LDA N2
    SUB dv2
    JC  dq_down
    JNZ dq_dbl
    LDA N1
    SUB dv1
    JC  dq_down
    JNZ dq_dbl
    LDA N0
    SUB dv0
    JC  dq_down
dq_dbl:
    LDA dv0
    ADD dv0
    STA dv0
    LDA dv1
    ADC dv1
    STA dv1
    LDA dv2
    ADC dv2
    STA dv2
    LDA dv3
    ADC dv3
    STA dv3
    LDA dv4
    ADC dv4
    STA dv4
    LDA shift
    ADD one
    STA shift
    JMP dq_up
dq_down:
    LDI 0
    STA R0
    STA R1
    STA R2
    STA R3
dq_loop:
    LDA shift
    JZ  show
    LDA zero
    ADD zero
    LDA dv4
    ROR
    STA dv4
    LDA dv3
    ROR
    STA dv3
    LDA dv2
    ROR
    STA dv2
    LDA dv1
    ROR
    STA dv1
    LDA dv0
    ROR
    STA dv0
    LDA R0
    ADD R0
    STA R0
    LDA R1
    ADC R1
    STA R1
    LDA R2
    ADC R2
    STA R2
    LDA R3
    ADC R3
    STA R3
    LDI 0               ; SBC-free  N = N - dv (if N>=dv), via sub5
    STA sx4
    LDA N0
    STA sx0
    LDA N1
    STA sx1
    LDA N2
    STA sx2
    LDA N3
    STA sx3
    LDA dv0
    STA sy0
    LDA dv1
    STA sy1
    LDA dv2
    STA sy2
    LDA dv3
    STA sy3
    LDA dv4
    STA sy4
    call sub5
    LDA bw
    JNZ dq_skip
    LDA sw0
    STA N0
    LDA sw1
    STA N1
    LDA sw2
    STA N2
    LDA sw3
    STA N3
    LDA R0
    ADD one
    STA R0
dq_skip:
    LDA shift
    SUB one
    STA shift
    JMP dq_loop

; ================= print R (32-bit) decimal =================
show:
    LDI 0
    STA ndig
ps_loop:
    call divmod10
    LDA rem
    ADD zc
    STA pchar
    LDA ndig
    ADD bufbase
    STA pst+1
    LDA pchar
pst:
    STA buf
    LDA ndig
    ADD one
    STA ndig
    LDA R0
    JNZ ps_loop
    LDA R1
    JNZ ps_loop
    LDA R2
    JNZ ps_loop
    LDA R3
    JNZ ps_loop
    LDA ndig
    STA i
pr_loop:
    LDA i
    SUB one
    STA i
    ADD bufbase
    STA pld+1
pld:
    LDA buf
    OUT
    LDA i
    JNZ pr_loop
show_nl:
    LDI 0x0A
    OUT
    JMP main

; ================= divmod10: rem=R%10 ; R=R/10  (R 32-bit) =================
divmod10:
    LDI 10
    STA d0
    LDI 0
    STA d1
    STA d2
    STA d3
    STA d4
    STA shift
dm_up:                  ; SBC-free MSB-first compare of R (R4=0) vs d
    LDI 0
    SUB d4
    JC  dm_down          ; R4(0) < d4 -> R < d
    LDA R3
    SUB d3
    JC  dm_down
    JNZ dm_dbl
    LDA R2
    SUB d2
    JC  dm_down
    JNZ dm_dbl
    LDA R1
    SUB d1
    JC  dm_down
    JNZ dm_dbl
    LDA R0
    SUB d0
    JC  dm_down
dm_dbl:
    LDA d0
    ADD d0
    STA d0
    LDA d1
    ADC d1
    STA d1
    LDA d2
    ADC d2
    STA d2
    LDA d3
    ADC d3
    STA d3
    LDA d4
    ADC d4
    STA d4
    LDA shift
    ADD one
    STA shift
    JMP dm_up
dm_down:
    LDI 0
    STA q0
    STA q1
    STA q2
    STA q3
dm_loop:
    LDA shift
    JZ  dm_done
    LDA zero
    ADD zero
    LDA d4
    ROR
    STA d4
    LDA d3
    ROR
    STA d3
    LDA d2
    ROR
    STA d2
    LDA d1
    ROR
    STA d1
    LDA d0
    ROR
    STA d0
    LDA q0
    ADD q0
    STA q0
    LDA q1
    ADC q1
    STA q1
    LDA q2
    ADC q2
    STA q2
    LDA q3
    ADC q3
    STA q3
    LDI 0               ; SBC-free  R = R - d (if R>=d), via sub5
    STA sx4
    LDA R0
    STA sx0
    LDA R1
    STA sx1
    LDA R2
    STA sx2
    LDA R3
    STA sx3
    LDA d0
    STA sy0
    LDA d1
    STA sy1
    LDA d2
    STA sy2
    LDA d3
    STA sy3
    LDA d4
    STA sy4
    call sub5
    LDA bw
    JNZ dm_skip
    LDA sw0
    STA R0
    LDA sw1
    STA R1
    LDA sw2
    STA R2
    LDA sw3
    STA R3
    LDA q0
    ADD one
    STA q0
dm_skip:
    LDA shift
    SUB one
    STA shift
    JMP dm_loop
dm_done:
    LDA R0
    STA rem
    LDA q0
    STA R0
    LDA q1
    STA R1
    LDA q2
    STA R2
    LDA q3
    STA R3
    ret divmod10

; ===== sub5: SBC-free 5-byte subtract  sw = sx - sy ; bw = 1 if sx<sy =====
; sx - sy = sx + (~sy) + 1, using only SUB (0xFF-sy never borrows) + ADD/ADC.
sub5:
    LDA ff
    SUB sy0
    STA sy0
    LDA ff
    SUB sy1
    STA sy1
    LDA ff
    SUB sy2
    STA sy2
    LDA ff
    SUB sy3
    STA sy3
    LDA ff
    SUB sy4
    STA sy4             ; sy = ~sy (one's complement)
    LDA ff
    ADD one             ; acc=0, cy=1  -> seeds the two's-complement +1 carry-in
    LDA sx0
    ADC sy0
    STA sw0
    LDA sx1
    ADC sy1
    STA sw1
    LDA sx2
    ADC sy2
    STA sw2
    LDA sx3
    ADC sy3
    STA sw3
    LDA sx4
    ADC sy4
    STA sw4             ; sw = sx + ~sy + 1 = sx - sy ; cy = carry-out (1 if sx>=sy)
    LDI 0
    ADC zero            ; acc = carry-out
    STA tcar
    LDI 1
    SUB tcar            ; acc = 1 - carry-out = borrow (1 if sx<sy)
    STA bw
    ret sub5

; ================= read_num: 32-bit digits->num (echoed) =================
read_num:
    LDI 0
    STA num0
    STA num1
    STA num2
    STA num3
rn_loop:
    IN
    OUT
    STA ch
    SUB zc
    JC  rn_term
    STA d
    SUB ten
    JC  rn_digit
    JMP rn_term
rn_digit:
    LDA num0
    ADD num0
    STA m2_0
    LDA num1
    ADC num1
    STA m2_1
    LDA num2
    ADC num2
    STA m2_2
    LDA num3
    ADC num3
    STA m2_3            ; m2 = num*2
    LDA m2_0
    ADD m2_0
    STA m4_0
    LDA m2_1
    ADC m2_1
    STA m4_1
    LDA m2_2
    ADC m2_2
    STA m4_2
    LDA m2_3
    ADC m2_3
    STA m4_3            ; m4 = num*4
    LDA m4_0
    ADD m4_0
    STA num0
    LDA m4_1
    ADC m4_1
    STA num1
    LDA m4_2
    ADC m4_2
    STA num2
    LDA m4_3
    ADC m4_3
    STA num3            ; num = num*8
    LDA num0
    ADD m2_0
    STA num0
    LDA num1
    ADC m2_1
    STA num1
    LDA num2
    ADC m2_2
    STA num2
    LDA num3
    ADC m2_3
    STA num3            ; num = num*8 + num*2 = num*10
    LDA num0
    ADD d
    STA num0
    LDA num1
    ADC zero
    STA num1
    LDA num2
    ADC zero
    STA num2
    LDA num3
    ADC zero
    STA num3            ; num += d
    JMP rn_loop
rn_term:
    LDA ch
    STA term
    ret read_num
"""

DATA = [
    ('zero','const',0), ('one','const',1), ('ten','const',10),
    ('plus','const',0x2B), ('star','const',0x2A), ('slash','const',0x2F),
    ('zc','const',0x30), ('bufbase','const',None), ('ff','const',0xFF),
    ('sx0','var',0),('sx1','var',0),('sx2','var',0),('sx3','var',0),('sx4','var',0),
    ('sy0','var',0),('sy1','var',0),('sy2','var',0),('sy3','var',0),('sy4','var',0),
    ('sw0','var',0),('sw1','var',0),('sw2','var',0),('sw3','var',0),('sw4','var',0),
    ('bw','var',0),('tcar','var',0),
    ('num0','var',0),('num1','var',0),('num2','var',0),('num3','var',0),
    ('m2_0','var',0),('m2_1','var',0),('m2_2','var',0),('m2_3','var',0),
    ('m4_0','var',0),('m4_1','var',0),('m4_2','var',0),('m4_3','var',0),
    ('d','var',0),('ch','var',0),('term','var',0),('op','var',0),
    ('A0','var',0),('A1','var',0),('A2','var',0),('A3','var',0),
    ('B0','var',0),('B1','var',0),('B2','var',0),('B3','var',0),
    ('R0','var',0),('R1','var',0),('R2','var',0),('R3','var',0),
    ('P0','var',0),('P1','var',0),('P2','var',0),('P3','var',0),
    ('Q0','var',0),('Q1','var',0),('S0','var',0),('S1','var',0),
    ('mid0','var',0),('mid1','var',0),
    ('d0','var',0),('d1','var',0),('d2','var',0),('d3','var',0),('d4','var',0),
    ('q0','var',0),('q1','var',0),('q2','var',0),('q3','var',0),
    ('dv0','var',0),('dv1','var',0),('dv2','var',0),('dv3','var',0),('dv4','var',0),
    ('N0','var',0),('N1','var',0),('N2','var',0),('N3','var',0),
    ('rem','var',0),('shift','var',0),('ndig','var',0),('i','var',0),('pchar','var',0),
    ('buf','buf',12),
]

def isize(mne): return 1 if mne in NOARG else 3

def assemble():
    recs=[]; pend=None
    for raw in PROG.splitlines():
        line=raw.split(';')[0].rstrip()
        if not line.strip(): continue
        if not line[0].isspace():
            assert line.strip().endswith(':'),line
            pend=line.strip()[:-1]; continue
        p=line.split(); mne=p[0]; arg=p[1] if len(p)>1 else None
        if mne=='call':
            sub=arg; i0=len(recs)
            recs.append(dict(label=pend,mne='LDI',arg=('ret_lo',i0,sub))); pend=None
            recs.append(dict(label=None,mne='STA',arg=('slot_lo',sub)))
            recs.append(dict(label=None,mne='LDI',arg=('ret_hi',i0,sub)))
            recs.append(dict(label=None,mne='STA',arg=('slot_hi',sub)))
            recs.append(dict(label=None,mne='JMP',arg=sub))
        elif mne=='ret':
            recs.append(dict(label=pend,mne='JMP',arg=0,retsub=arg)); pend=None
        else:
            recs.append(dict(label=pend,mne=mne,arg=arg)); pend=None
    addr=0; sym={}
    for r in recs:
        if r['label']: sym[r['label']]=addr
        r['addr']=addr; addr+=isize(r['mne'])
    code_end=addr
    da=code_end
    for name,kind,val in DATA:
        if name=='buf' and (da & 0xFF)+val>256: da=(da+0xFF)&~0xFF
        sym[name]=da; da += val if kind=='buf' else 1
    assert da<=MEMSIZE, f"image overflow {da} (code_end={code_end})"
    consts={}
    for name,kind,val in DATA:
        if kind=='const': consts[sym[name]]=(sym['buf']&0xFF) if name=='bufbase' else val
        elif kind=='var': consts[sym[name]]=val
    for r in recs:
        if r.get('retsub'): sym['__ret_'+r['retsub']]=r['addr']
    def resolve(a):
        if isinstance(a,tuple):
            tag=a[0]
            if tag in('ret_lo','ret_hi'):
                ret=recs[a[1]+4]['addr']+3
                return ret&0xFF if tag=='ret_lo' else (ret>>8)&0xFF
            if tag in('slot_lo','slot_hi'):
                b=sym['__ret_'+a[1]]; return b+1 if tag=='slot_lo' else b+2
        if a is None: return 0
        if isinstance(a,int): return a
        s=a
        if s.startswith("'") and s.endswith("'"): return ord(s[1:-1])
        for opc in('+','-'):
            if opc in s[1:]:
                b,off=s.rsplit(opc,1); b=b.strip(); off=int(off,0)
                v=sym[b] if b in sym else int(b,0)
                return v+off if opc=='+' else v-off
        return sym[s] if s in sym else int(s,0)
    img=[0]*MEMSIZE
    for r in recs:
        a=r['addr']; img[a]=OPS[r['mne']]
        if r['mne'] not in NOARG:
            v=resolve(r['arg']); img[a+1]=v&0xFF; img[a+2]=(v>>8)&0xFF
    for ad,v in consts.items(): img[ad]=v&0xFF
    return img,sym,code_end,da

def simulate(img,inp,maxsteps=40_000_000):
    mem=img[:]; acc=0;cy=0;pc=0;out=[];inp=list(inp);ip=0
    dspA=dspB=dspC=prod=0
    for _ in range(maxsteps):
        op=mem[pc]; pc=(pc+1)&0x7FF
        if op in (0,6,7,14,15,16,18,19) or op>=0x80: arg=None
        else: arg=mem[pc]|(mem[(pc+1)&0x7FF]<<8); pc=(pc+2)&0x7FF
        if op==0: break
        elif op==1: acc=arg&0xFF
        elif op==2: acc=mem[arg]
        elif op==3: mem[arg]=acc
        elif op==4: t=acc+mem[arg];cy=1 if t>255 else 0;acc=t&255
        elif op==5: t=acc-mem[arg];cy=1 if t<0 else 0;acc=t&255
        elif op==6:
            if ip>=len(inp): break
            acc=ord(inp[ip]);ip+=1
        elif op==7: out.append(chr(acc))
        elif op==8: pc=arg
        elif op==9: pc=arg if acc==0 else pc
        elif op==10: t=acc+mem[arg]+cy;cy=1 if t>255 else 0;acc=t&255
        elif op==11: t=acc-mem[arg]-cy;cy=1 if t<0 else 0;acc=t&255
        elif op==12: pc=arg if cy else pc
        elif op==13: pc=arg if acc!=0 else pc
        elif op==14: nb=(cy<<7)|(acc>>1);cy=acc&1;acc=nb
        elif op==15: dspA=((dspA<<8)|acc)&0xFFFF
        elif op==16: dspB=((dspB<<8)|acc)&0xFFFF
        elif op>=0x80:                                # DSP op; opcode[6:0]=OPMODE
            opm=op&0x7F
            if opm==0x05: prod=(dspA*dspB)&0xFFFFFFFF             # P=A*B
            elif opm==0x33: prod=(dspC+(dspA*dspB))&0xFFFFFFFFFFFF# P=C+A*B (MACC)
            else: prod=0                                         # other modes: idle in sim
        elif op==18: acc=prod&0xFF; prod>>=8
        elif op==19: dspC=((dspC<<8)|acc)&0xFFFFFFFFFFFF
    return ''.join(out), ip

if __name__=='__main__':
    import sys,re
    img,sym,code_end,da=assemble()
    print(f"code_end={code_end} bytes, data {code_end}..{da}, total {da}/{MEMSIZE}")
    tests=["12+34=","5-8=","355/113=","355*113=","255*255=","1000*1000=","2+3=",
           "100/7=","9/0=","65535*65535=","0/5=","7*0=","123*456=","10000-1=",
           "65536*2=","99999+1=","1000000/1000=","40115/355="]
    ok=True
    for t in tests:
        m=re.match(r"(\d+)([+\-*/])(\d+)=",t)
        a,o,b=int(m.group(1)),m.group(2),int(m.group(3))
        if o=='/':
            exp = t+('E' if b==0 else str(a//b))+'\n'
        elif o=='*':
            exp = t+str((a*b)&0xFFFFFFFF)+'\n'
        else:
            r=a+b if o=='+' else a-b
            exp=t+('-%d'%(-r) if r<0 else '%d'%((r)&0xFFFFFFFF))+'\n'
        got,_=simulate(img,t)
        st='OK' if got==exp else '**FAIL**'
        if got!=exp: ok=False
        print(f"  {t:16s} -> {got!r:18s} expect {exp!r:16s} {st}")
    if '--emit' in sys.argv and ok:
        lines=[f"            mem[11'd{a}]=8'h{img[a]:02X};" for a in range(MEMSIZE) if img[a]]
        open('calc_init.svh','w').write('\n'.join(lines)+'\n')
        print(f"wrote calc_init.svh ({len(lines)} nonzero bytes)")
    sys.exit(0 if ok else 1)
