#!/usr/bin/env python3
"""vcdcmp.py gold.vcd gate.vcd [regex]: match the gate's bit nets to gold's vectors by name; per cycle (after the rising
edge) list which named bits differ.  Prints the first difference of each signal, oldest first, plus a value timeline for
signals matching the regex."""
import re, sys, collections

def parse(path):
    scope, vars_ = [], {}
    f = open(path)
    for line in f:
        t = line.split()
        if not t: continue
        if t[0] == '$scope': scope.append(t[2])
        elif t[0] == '$upscope': scope.pop()
        elif t[0] == '$var':
            vars_.setdefault(t[3], []).append(('.'.join(scope[1:]), t[4], int(t[2]), ' '.join(t[5:-1])))
        elif t[0] == '$enddefinitions': break
    return f, vars_

def changes(f, want):
    """yield (time, {id: value}) with the state at each odd time"""
    state, now = {}, None
    for line in f:
        c = line[0] if line else ''
        if c == '#':
            if now is not None and now & 1: yield now, state
            now = int(line[1:])
        elif c in '01xz':
            i = line[1:].strip()
            if i in want: state[i] = c
        elif c == 'b':
            v, i = line[1:].split()
            if i in want: state[i] = v
    if now is not None and now & 1: yield now, state

fg, vg = parse(sys.argv[1])
fx, vx = parse(sys.argv[2])
rx = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
T = re.compile(r'^(VexRiscv\w*)\.?')
# gold: hierarchical name -> (id, width)
gold = {}
for i, l in vg.items():
    for sc, n, w, _ in l:
        sc = T.sub('', sc)
        gold[(sc + '.' + n).lstrip('.')] = (i, w)
# gate: scope.flat name, bit in [k] or __k
pairs = []
seen = set()
for i, l in vx.items():
    for sc, n, w, rng in l:
        sc = T.sub('', sc)
        if w != 1: continue
        full = (sc + '.' + n).lstrip('.')
        m = re.match(r'^(.*?)(?:\[(\d+)\]|__(\d+))$', full)
        if rng.startswith('['):
            m2 = re.match(r'\[(\d+)\]', rng)
            if m2: m = re.match(r'^(.*)$', full); base, k = full, int(m2.group(1))
            else: base, k = full, 0
        elif m: base, k = m.group(1), int(m.group(2) or m.group(3))
        else: base, k = full, 0
        if base in gold and gold[base][1] > k and (base, k) not in seen:
            seen.add((base, k)); pairs.append((base, k, gold[base][0], i))
print(f'gold vars {len(gold)}, gate vars {len(vx)}, matched bits {len(pairs)}, over {len({p[0] for p in pairs})} signals')
wg = {p[2] for p in pairs}; wx = {p[3] for p in pairs}
if rx:
    for n, (i, w) in gold.items():
        if rx.search(n): wg.add(i)
first = {}
tl = []
timeline = []
def bit(v, k):
    if v is None: return None
    return v[-1 - k] if k < len(v) else '0'
for (t, sg), (_, sx) in zip(changes(fg, wg), changes(fx, wx)):
    d = collections.defaultdict(list)
    for base, k, ig, ix in pairs:
        a, b = bit(sg.get(ig), k), sx.get(ix)
        if a in '01' and b in ('0', '1') and a != b:
            d[base].append(k)
            first.setdefault(base, t)
    tl.append((t, len(d), sorted(d)[:6]))
    if rx:
        timeline.append((t, {n: sg.get(i) for n, (i, w) in gold.items() if rx.search(n)}, dict(d)))
print('first differences (cycle = t//2):')
for n, t in sorted(first.items(), key=lambda x: x[1])[:60]:
    print(f'  {t//2}  {n}')
print('per-cycle count of differing signals (last 120):')
for t, c, s in tl[-120:]:
    print(f'  {t//2} {c} {" ".join(s)[:150]}')
if rx:
    print('timeline:')
    last = None
    for t, vals, d in timeline:
        cur = {k: v for k, v in vals.items()}
        ch = {k: v for k, v in cur.items() if last is None or last.get(k) != v}
        if ch: print(f'  {t//2}', ' '.join(f'{k.split(".")[-1]}={int(v,2):x}' if v and set(v) <= {"0","1"} else f'{k.split(".")[-1]}={v}' for k, v in sorted(ch.items()))[:400])
        last = cur
