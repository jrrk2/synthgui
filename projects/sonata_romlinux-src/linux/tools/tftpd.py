import socket,sys,os,struct,threading,time
root=sys.argv[1]
def serve(data,addr,blk,s=None):
    """send the data in blk-sized blocks, stop-and-wait. A stale (duplicate) ACK is ignored, not answered with a
    retransmission, and a lost block is resent only after RETRY seconds: the BIOS's tftpflash can be busy erasing
    and programming flash for a few seconds between two blocks."""
    RETRY, GIVE_UP = 5.0, 120.0
    if s is None:
        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('',0))
    n=0
    while True:
        chunk=data[n*blk:(n+1)*blk]; pkt=struct.pack('>HH',3,(n+1)&0xffff)+chunk
        s.sendto(pkt,addr)
        start=time.time(); resend=start+RETRY
        while True:
            s.settimeout(max(0.05,resend-time.time()))
            try:
                r,a=s.recvfrom(600)
            except socket.timeout:
                if time.time()-start>GIVE_UP: print('timeout',addr,flush=True); return
                s.sendto(pkt,addr); resend=time.time()+RETRY
                continue
            if a==addr and len(r)>=4 and r[:2]==b'\0\4' and struct.unpack('>H',r[2:4])[0]==((n+1)&0xffff): break
        n+=1
        if len(chunk)<blk: print('sent',len(data),'to',addr,flush=True); return
UPLOAD=os.path.join(root,'upload')

def receive(fn,addr,opts):
    """WRQ: the board saves a file (tftp -p). Stored in <root>/upload/, never over the served images, so a
    forgotten name cannot overwrite kernel.bin; read back later with tftp -g (RRQ looks in upload/ too)."""
    os.makedirs(UPLOAD,exist_ok=True)
    path=os.path.join(UPLOAD,os.path.basename(fn)); print('WRQ',fn,'->',path,addr,opts,flush=True)
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('',0)); s.settimeout(10)
    blk=512
    if b'blksize' in opts:
        blk=min(int(opts[b'blksize']),1468)
        first=struct.pack('>H',6)+b'blksize\0'+str(blk).encode()+b'\0'      # OACK: the client sends data block 1 next
    else:
        first=struct.pack('>HH',4,0)                                         # ACK 0
    s.sendto(first,addr)
    data=b''; n=1
    while True:
        try:
            r,a=s.recvfrom(blk+8)
        except socket.timeout:
            print('upload timeout',fn,flush=True); return
        if a!=addr or len(r)<4 or r[:2]!=b'\0\3': continue
        bn=struct.unpack('>H',r[2:4])[0]
        if bn==(n&0xffff):
            data+=r[4:]; s.sendto(struct.pack('>HH',4,bn),addr); n+=1
            if len(r)-4<blk:
                open(path,'wb').write(data); print('saved',path,len(data),'bytes',flush=True); return
        elif bn==((n-1)&0xffff):
            s.sendto(struct.pack('>HH',4,bn),addr)                          # duplicate: ack again, store nothing

def handle(pkt,addr,sock):
    op=struct.unpack('>H',pkt[:2])[0]
    if op not in (1,2): return
    parts=pkt[2:].split(b'\0'); fn=parts[0].decode(); opts={parts[i].lower():parts[i+1] for i in range(2,len(parts)-1,2)}
    if op==2:
        receive(fn,addr,opts); return
    path=os.path.join(root,os.path.basename(fn))
    if not os.path.isfile(path): path=os.path.join(UPLOAD,os.path.basename(fn))
    print('RRQ',fn,addr,opts,flush=True)
    if not os.path.isfile(path):
        sock.sendto(struct.pack('>HH',5,1)+b'not found\0',addr); return
    data=open(path,'rb').read(); blk=512
    if b'blksize' in opts:
        blk=min(int(opts[b'blksize']),1468)
        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2); s.bind(('',0))
        oack=struct.pack('>H',6)+b'blksize\0'+str(blk).encode()+b'\0'
        for t in range(5):
            s.sendto(oack,addr)
            try:
                r,a=s.recvfrom(600)
                if a==addr and r[:4]==b'\0\4\0\0': break
            except socket.timeout: pass
        else: return
        serve(data,addr,blk,s); return
    serve(data,addr,blk)
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); sock.bind(('',69)); print('tftpd on 69, root',root,'(uploads go to',UPLOAD+')',flush=True)
while True:
    p,a=sock.recvfrom(600); threading.Thread(target=handle,args=(p,a,sock),daemon=True).start()
