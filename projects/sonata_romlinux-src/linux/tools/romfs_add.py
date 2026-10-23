import argparse, struct, sys
ap = argparse.ArgumentParser(description="Build a romfs image: from an existing one (src) or from nothing (src = -), "
                             "plus /sbin/init and whatever the options add")
ap.add_argument("src", help="romfs image to start from, or - for an empty one"); ap.add_argument("dst")
ap.add_argument("--dir", action="append", default=[], metavar="PATH", help="add an empty directory")
ap.add_argument("--dev", action="append", default=[], metavar="PATH=c:MAJOR:MINOR", help="add a character device node")
ap.add_argument("--busybox", help="replace /bin/busybox with this file")
ap.add_argument("--links", help="busybox.links: add a symlink to /bin/busybox for every applet path in it")
ap.add_argument("--udhcpc-script", help="install as /usr/share/udhcpc/default.script")
ap.add_argument("--tree", action="append", default=[], metavar="DIR=DEST",
                help="add every file and symlink under DIR as DEST/... (executables stay executable)")
ap.add_argument("--symlink", action="append", default=[], metavar="PATH=TARGET", help="add a symbolic link")
ap.add_argument("--file", action="append", default=[], metavar="PATH=SRC[:x]",
                help="add the file SRC as PATH in the image (:x marks it executable)")
args = ap.parse_args()
src, dst = args.src, args.dst
d = b'' if src == '-' else open(src,'rb').read()
def cstr(o): return d[o:o+64].split(b'\0')[0]
def hdrlen(nm): return 16+((len(nm)+1+15)//16)*16
def parse(o):
    out=[]
    while True:
        nxt,spec,size,ck=struct.unpack('>IIII',d[o:o+16]); typ=nxt&7; exe=nxt&8; nxt&=~15
        nm=cstr(o+16); h=hdrlen(nm)
        e=dict(name=nm,typ=typ,exe=exe,spec=spec,data=b'')
        if typ==1 and nm not in(b'.',b'..'): e['kids']=parse(spec&~15)
        if typ in(2,3): e['data']=d[o+h:o+h+size]
        out.append(e)
        if nxt==0: break
        o=nxt
    return out
if src == '-':
    vname = b'rootfs'; vh = hdrlen(vname)
    root = [dict(name=b'.', typ=0, exe=0, spec=0, data=b''), dict(name=b'..', typ=0, exe=0, spec=0, data=b'')]
else:
    vname=cstr(16); vh=hdrlen(vname)
    root=parse(vh)
def find_dir(entries, name):
    for e in entries:
        if e['name'] == name and e['typ'] == 1:
            return e
    return None

def ensure_dir(path):
    kids = root
    for part in [p for p in path.split("/") if p]:
        n = find_dir(kids, part.encode())
        if n is None:
            n = dict(name=part.encode(), typ=1, exe=0, spec=0, data=b'',
                     kids=[dict(name=b'.', typ=0, exe=0, spec=0, data=b''), dict(name=b'..', typ=0, exe=0, spec=0, data=b'')])
            kids.append(n)
        kids = n['kids']
    return kids

def put(path, typ, data, exe=0, spec=0):
    """create or replace the file/symlink at path (creating directories)"""
    d, _, name = path.rpartition("/")
    kids = ensure_dir(d)
    node = dict(name=name.encode(), typ=typ, exe=exe, spec=spec, data=data)
    for i, e in enumerate(kids):
        if e['name'] == node['name']:
            kids[i] = node
            return
    kids.append(node)

for path in args.dir:
    ensure_dir(path)
for spec in args.dev:
    path, _, kind = spec.partition("=")
    c, major, minor = kind.split(":")
    assert c == "c"
    put(path, 5, b'', 0, (int(major) << 16) | int(minor))
if args.busybox:
    put("/bin/busybox", 2, open(args.busybox, 'rb').read(), 8)
if args.links:
    for line in open(args.links).read().split():
        p = line if line.startswith("/") else "/" + line
        if p not in ("/bin/busybox", "/sbin/init"):
            put(p, 3, b'/bin/busybox')
import os
for spec in args.tree:
    d, _, dest = spec.partition("=")
    for dirpath, dirnames, filenames in os.walk(d):
        dirnames.sort()
        for fn in sorted(filenames):
            f = os.path.join(dirpath, fn)
            target = "/" + os.path.join(dest.strip("/"), os.path.relpath(f, d)).strip("/")
            if os.path.islink(f):
                put(target, 3, os.readlink(f).encode())
            else:
                put(target, 2, open(f, "rb").read(), 8 if os.access(f, os.X_OK) else 0)
for spec in args.symlink:
    path, _, target = spec.partition("=")
    put(path, 3, target.encode())
for spec in args.file:
    path, _, srcfile = spec.partition("=")
    exe = 8 if srcfile.endswith(":x") else 0
    put(path, 2, open(srcfile.removesuffix(":x"), 'rb').read(), exe)
if args.udhcpc_script:
    put("/usr/share/udhcpc/default.script", 2, open(args.udhcpc_script, 'rb').read(), 8)

ensure_dir('/sbin')
sb=[e for e in root if e['name']==b'sbin'][0]
assert not any(k['name']==b'init' for k in sb['kids'])
sb['kids'].append(dict(name=b'init',typ=2,exe=8,spec=0,data=b'''#!/bin/sh
PATH=/bin:/sbin
# devtmpfs is already mounted by the kernel
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs -o size=2m tmpfs /tmp
echo "========================================"
echo "  Sonata Linux - LiteX VexRiscv RV32IMAC"
echo "  MMU, single hart, 8 MB HyperRAM"
echo "========================================"
uname -a
echo
exec /bin/sh
'''))
def pad(b): return b+b'\0'*(-len(b)%16)
def size_of(entries):
    t=0
    for e in entries:
        t+=hdrlen(e['name'])+len(pad(e['data']))
        if 'kids' in e: t+=size_of(e['kids'])
    return t
def layout(entries,base,self_hdr,parent_hdr):
    """Lay out one directory's entries at offset base.  Following genromfs: a subdirectory's own header is its entry
    in the parent's list (type 1, executable = searchable, spec = the first entry of its list); in its list "." is a
    hard link to that header and ".." a hard link to the parent's header.  The root has no such header: its first
    entry "." is a directory entry pointing at itself (the kernel starts there), and ".." points at it too.
    self_hdr is None for the root list."""
    root_list = self_hdr is None
    my_hdr = base if root_list else self_hdr
    out=b'';offs=[];o=base
    for e in entries:
        offs.append(o); o+=hdrlen(e['name'])+len(pad(e['data']))
    sub=o
    subs=b''
    for i,e in enumerate(entries):
        nxt=offs[i+1] if i+1<len(entries) else 0
        typ,exe,spec=e['typ'],e['exe'],e['spec']
        if e['name']==b'.':
            typ,exe,spec=(1,8,base) if root_list else (0,0,my_hdr)
        elif e['name']==b'..':
            typ,exe,spec=0,0,parent_hdr
        elif 'kids' in e:
            kb=sub+len(subs); spec=kb; typ=1; exe=8
            subs+=layout(e['kids'],kb,offs[i],my_hdr)
        nm=pad(e['name']+b'\0')
        h=struct.pack('>IIII',nxt|typ|exe,spec,len(e['data']) if typ in(2,3) else 0,0)+nm
        s=sum(struct.unpack('>%dI'%(len(h)//4),h))&0xffffffff
        h=h[:12]+struct.pack('>I',(-s)&0xffffffff)+h[16:]
        out+=h+pad(e['data'])
    return out+subs
body=layout(root,vh,None,vh)
total=vh+len(body)
total_pad=total+(-total%1024)
head=b'-rom1fs-'+struct.pack('>II',total,0)+pad(vname+b'\0')
n=min(total,512)
words=struct.unpack('>%dI'%(len(pad(head))//4),pad(head))
img=head+body
w=struct.unpack('>%dI'%(min(len(img),512)//4),img[:min(len(img),512)//4*4])
s=sum(w)&0xffffffff
img=img[:12]+struct.pack('>I',(-s)&0xffffffff)+img[16:]
img+=b'\0'*(-len(img)%1024)
open(dst,'wb').write(img)
print(len(d),len(img))
