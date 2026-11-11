import socket, struct, time
s=socket.create_connection(("192.168.1.113",2543),5); s.settimeout(30)
s.sendall(b"getinfo:"); s.recv(64)
def shift(nbits,tms,tdi):
    nb=(nbits+7)//8
    s.sendall(b"shift:"+struct.pack("<I",nbits)+tms+tdi)
    b=b""
    while len(b)<nb: b+=s.recv(nb-len(b))
    return b
t0=time.time(); n=0
while time.time()-t0 < 180:
    shift(5000, b"\x00"*625, b"\x00"*625)   # 5000 bits back to back, TCK never stops
    n+=1
print("shifts:", n)
s.close()
