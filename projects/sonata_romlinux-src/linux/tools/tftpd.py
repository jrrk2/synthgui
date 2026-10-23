import socket,sys,os,struct,threading,time
root=sys.argv[1]
def serve(data,addr,blk,s=None):
    if s is None:
        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2); s.bind(('',0))
    n=0
    while True:
        chunk=data[n*blk:(n+1)*blk]; pkt=struct.pack('>HH',3,n+1)+chunk
        for t in range(8):
            s.sendto(pkt,addr)
            try:
                r,a=s.recvfrom(600)
                if a==addr and struct.unpack('>HH',r[:4])==(4,(n+1)&0xffff): break
            except socket.timeout: pass
        else: print('timeout',addr); return
        n+=1
        if len(chunk)<blk: print('sent',len(data),'to',addr); return
def handle(pkt,addr,sock):
    op=struct.unpack('>H',pkt[:2])[0]
    if op!=1: return
    parts=pkt[2:].split(b'\0'); fn=parts[0].decode(); opts={parts[i].lower():parts[i+1] for i in range(2,len(parts)-1,2)}
    path=os.path.join(root,os.path.basename(fn)); print('RRQ',fn,addr,opts)
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
sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); sock.bind(('',69)); print('tftpd on 69, root',root,flush=True)
while True:
    p,a=sock.recvfrom(600); threading.Thread(target=handle,args=(p,a,sock),daemon=True).start()
