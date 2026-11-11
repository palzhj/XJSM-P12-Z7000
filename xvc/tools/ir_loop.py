import socket, struct, time
s=socket.create_connection(("192.168.1.113",2543),5); s.settimeout(30)
s.sendall(b"getinfo:"); s.recv(64)
def rd(n):
    b=b""
    while len(b)<n: b+=s.recv(n-len(b))
    return b
def shift(nbits,tms,tdi):
    nb=(nbits+7)//8
    s.sendall(b"shift:"+struct.pack("<I",nbits)+tms+tdi)
    return rd(nb)
def pack(bits):
    v=0
    for i,b in enumerate(bits):
        if b: v|=1<<i
    return v.to_bytes((len(bits)+7)//8,'little')
t0=time.time(); n=0
while time.time()-t0 < 180:
    shift(6,pack([1,1,1,1,1,0]),pack([0]*6))          # TLR
    bits=[]
    for _ in range(2): bits += [(0x09>>i)&1 for i in range(6)]
    tms=[1,1,0,0]+[0]*12+[1,1,0]
    shift(len(tms),pack(tms),pack([0,0,0,0]+bits+[0,0,0]))   # IR=0x09
    nn=3+64+3
    shift(nn,pack([1,0,0]+[0]*64+[1,0,0]),pack([0]*nn))      # DR read
    n+=1
print("ir loops:", n)
s.close()
