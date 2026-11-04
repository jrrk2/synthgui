#!/usr/bin/env python3
"""vcdshow.py gold.vcd gate.vcd from to name[=gatename] ...: side by side values of fpu_0_logic signals, cycle by cycle"""
import re,sys
sys.path.insert(0,'.')
def parse(path):
    scope,vs=[],{}
    f=open(path)
    for line in f:
        t=line.split()
        if not t: continue
        if t[0]=='$scope': scope.append(t[2])
        elif t[0]=='$upscope': scope.pop()
        elif t[0]=='$var':
            sc=re.sub(r'^TOP\.?(VexRiscv\w*)?\.?','','.'.join(scope))
            vs[(sc+'.'+t[4]).lstrip('.')]=(t[3],int(t[2]))
        elif t[0]=='$enddefinitions': break
    return f,vs
def snaps(f,want,a,b):
    st,now={},None
    for line in f:
        c=line[0]
        if c=='#':
            if now is not None and now&1 and a<=now//2<=b: yield now//2,dict(st)
            now=int(line[1:])
        elif c in '01':
            i=line[1:].strip()
            if i in want: st[i]=c
        elif c=='b':
            v,i=line[1:].split()
            if i in want: st[i]=v
fg,vg=parse(sys.argv[1]); fx,vx=parse(sys.argv[2]); a,b=int(sys.argv[3]),int(sys.argv[4])
names=[]
for s in sys.argv[5:]:
    gn,_,xn=s.partition('=')
    xn=xn or gn
    xbits={}
    for n,(i,w) in vx.items():
        m=re.match(r'^(.*?)(?:\[(\d+)\]|__(\d+))?$',n)
        if m.group(1)==xn: xbits[int(m.group(2) or m.group(3) or 0)]=(i,w)
    names.append((gn,xn,vg.get(gn),xbits))
    if gn not in vg: print('no gold',gn)
    if not xbits: print('no gate',xn)
wg={v[2][0] for v in names if v[2]}; wx={i for v in names for i,w in v[3].values()}
G=snaps(fg,wg,a,b);X=snaps(fx,wx,a,b)
for (c,sg),(_,sx) in zip(G,X):
    print(f'--- {c}')
    for gn,xn,g,xb in names:
        gv=int(sg[g[0]],2) if g and g[0] in sg and set(sg[g[0]])<=set('01') else None
        xv=None
        if xb:
            xv=0
            for k,(i,w) in xb.items():
                v=sx.get(i)
                if v is None or not set(v)<=set('01'): xv=None;break
                xv|=int(v,2)<<k
        flag='' if gv==xv else '  <<< DIFF'
        print(f'  {gn.split(".")[-1]:42} gold={gv if gv is None else hex(gv)} gate={xv if xv is None else hex(xv)}{flag}')
