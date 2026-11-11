import socket, struct, time, sys
s=socket.create_connection(("192.168.1.113",2543),5); s.settimeout(30)
s.sendall(b"getinfo:"); s.recv(64)
def shift(nbits,tms,tdi):
    nb=(nbits+7)//8
    s.sendall(b"shift:"+struct.pack("<I",nbits)+tms+tdi)
    b=b""
    while len(b)<nb: b+=s.recv(nb-len(b))
    return b
t0=time.time()
n=0
while time.time()-t0 < 8:
    for t in (1,1,1,1,1,0):
        shift(1, bytes([t]), b"\x00")
    n+=1
print("TLR loops:", n, "in %.1fs" % (time.time()-t0))
s.close()
