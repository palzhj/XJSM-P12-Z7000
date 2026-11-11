import socket, struct, time
s=socket.create_connection(("192.168.1.113",2543),5); s.settimeout(30)
s.sendall(b"getinfo:"); s.recv(64)
def shift(nbits,tms,tdi):
    nb=(nbits+7)//8
    s.sendall(b"shift:"+struct.pack("<I",nbits)+tms+tdi)
    b=b""
    while len(b)<nb: b+=s.recv(nb-len(b))
    return b
def pack(bits):
    v=0
    for i,b in enumerate(bits):
        if b: v|=1<<i
    return v.to_bytes((len(bits)+7)//8,'little')
# combined sequence: TLR + IR(0x09) + DR(64)
tms = [1,1,1,1,1,0]
tdi = [0]*6
irs=[]
for _ in range(2): irs += [(0x09>>i)&1 for i in range(6)]
tms += [1,1,0,0] + [0]*12 + [1,1,0]
tdi += [0,0,0,0] + irs + [0,0,0]
tms += [1,0,0] + [0]*64 + [1,0,0]
tdi += [0]*70
n=len(tms)
print("combined length:", n)
t0=time.time(); k=0
while time.time()-t0 < 180:
    shift(n, pack(tms), pack(tdi))
    k+=1
print("loops:", k)
s.close()
