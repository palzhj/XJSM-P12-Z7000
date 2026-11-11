import socket, time, json, urllib.request, struct, sys, os, termios, select

BASE = "http://192.168.1.113"
results = []
def t(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  {'✅' if ok else '❌'} {name}" + (f"  [{detail}]" if detail else ""))

def http(path, timeout=8):
    return urllib.request.urlopen(BASE + path, timeout=timeout).read().decode(errors="replace")

def status():
    return json.loads(http("/cgi-bin/status"))

def xvc(port, cmds=(b'getinfo:',), timeout=3):
    s = socket.create_connection(('192.168.1.113', port), timeout)
    s.settimeout(timeout)
    out = []
    for c in cmds:
        s.sendall(c)
        try: out.append(s.recv(128))
        except Exception: out.append(b'')
    s.close(); return out

# ---------- serial ----------
fd = os.open("/dev/ttyUSB3", os.O_RDWR|os.O_NOCTTY)
a = termios.tcgetattr(fd); a[0]=0; a[1]=0; a[2]=termios.CS8|termios.CREAD|termios.CLOCAL; a[3]=0; a[4]=a[5]=termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
def srd(t=1.0):
    out=b""; end=time.time()+t
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.1)
        if r:
            try: out+=os.read(fd,65536)
            except: pass
    return out
def devmem(addr, val=None):
    cmd = f"devmem {addr} 32" + (f" {val}" if val is not None else "") + "\n"
    os.write(fd, cmd.encode()); time.sleep(0.45)
    out = srd(0.6).decode(errors="replace")
    for ln in out.split("\n"):
        ln=ln.strip()
        if ln.startswith("0x"): return ln
    return "?"
def setmask(v):
    return http(f"/cgi-bin/control?cmd=setbcmask&v=0x{v:03X}")

print("="*60); print(" integrity test"); print("="*60)

# ---------- 1 network/Web ----------
print("\n[1] Network and Web")
import subprocess
p = subprocess.run(["ping","-c","2","-W","2","192.168.1.113"], capture_output=True)
t("ping", p.returncode == 0)
try:
    t("index.html", http("/", 6) != "")
except Exception as e: t("index.html", False, str(e)[:30])
for c in ("status","net","control"):
    try:
        t(f"cgi/{c}", http(f"/cgi-bin/{c}", 5) is not None)
    except Exception as e: t(f"cgi/{c}", False)

# ---------- 2 13 ports ----------
print("\n[2] 13 XVC ports")
ok = 0
for p in range(2542, 2555):
    try:
        r = xvc(p)[0]
        ok += r.startswith(b'xvcServer')
    except Exception: pass
t(f"13 port responses", ok == 13, f"{ok}/13")

# ---------- 3 engine TAGs (12 channels + broadcast) ----------
print("\n[3] engine TAGs (12 channels + broadcast)")
ok = 0
for ch in range(12):
    if devmem(f"0x{0x43C00000+ch*0x10000+0x14:08X}") == "0xA7000000": ok += 1
bc = devmem("0x43CC0014")
t("12 channel engines", ok == 12, f"{ok}/12")
t("broadcast engine", bc == "0xA7000000", bc)

# ---------- 4 register block ----------
print("\n[4] broadcast register block (0x43CD0000)")
t("TAG", devmem("0x43CD000C") == "0xB7000000", devmem("0x43CD000C"))
devmem("0x43CD0004","0xABC"); t("BCMASK write/read", devmem("0x43CD0004") == "0x00000ABC")
devmem("0x43CD0008","7");     t("CHSEL write/read",  devmem("0x43CD0008") == "0x00000007")
devmem("0x43CD0004","0xFFF"); devmem("0x43CD0008","0")
t("CTRL off by default", (devmem("0x43CD0000") or "").endswith("0"))
st = devmem("0x43CD0010")
t("STATUS reflects the mask", st == "0x00000FFF", st)

# ---------- 5 single-channel shift ----------
print("\n[5] single-channel shift (ch0)")
devmem("0x43C00000","8")
t("LEN write/read", devmem("0x43C00000") == "0x00000008")
before = devmem("0x43C00038")
devmem("0x43C00010","1"); time.sleep(0.4)
after = devmem("0x43C00038")
t("SEQ increments (done)", before != after and after != "?", f"{before}->{after}")
t("STATE is not S_BC", ((int(devmem("0x43C00030"),16)>>2)&3) != 3)

# ---------- 6 single port, single session ----------
print("\n[6] single port, single session")
s1 = socket.create_connection(('192.168.1.113', 2546), 3); s1.settimeout(4)
s1.sendall(b'getinfo:'); r1 = s1.recv(48)
t("1st connection", r1.startswith(b'xvcServer'))
try:
    s2 = socket.create_connection(('192.168.1.113', 2546), 3); s2.settimeout(3)
    s2.sendall(b'getinfo:')
    try: r2 = s2.recv(48)
    except Exception: r2 = b''
    t("2nd connection rejected", r2 == b'')
    s2.close()
except Exception: t("2nd connection rejected", True)
s1.close(); time.sleep(1.2)
try:
    r3 = xvc(2546)[0]; t("reconnect works after close", r3.startswith(b'xvcServer'))
except Exception: t("reconnect works after close", False)

# ---------- 7 broadcast session exclusivity ----------
print("\n[7] broadcast session exclusivity")
setmask(0xFFF); time.sleep(0.5)
bc_sock = socket.create_connection(('192.168.1.113', 2542), 3); bc_sock.settimeout(5)
bc_sock.sendall(b'getinfo:'); t("broadcast session established", bc_sock.recv(48).startswith(b'xvcServer'))
time.sleep(1.0)
refused = 0
for ch in range(12):
    try:
        r = xvc(2543+ch, timeout=2)[0]
        if not r: refused += 1
    except Exception: refused += 1
t("12 channels refused", refused == 12, f"{refused}/12")
bc_sock.close(); time.sleep(1.5)
ok = 0
for ch in range(12):
    try:
        if xvc(2543+ch, timeout=2)[0].startswith(b'xvcServer'): ok += 1
    except Exception: pass
t("channels recover after broadcast closes", ok == 12, f"{ok}/12")

# ---------- 8 masking triggers a disconnect ----------
print("\n[8] adding a mask bit -> existing connection dropped")
setmask(0x002); time.sleep(0.8)
sc = socket.create_connection(('192.168.1.113', 2543), 3); sc.settimeout(6)
sc.sendall(b'getinfo:'); connected = sc.recv(48).startswith(b'xvcServer')
t("connect works outside the mask", connected)
setmask(0x003); time.sleep(2)
try:
    sc.settimeout(3); d = sc.recv(16)
    t("disconnected after being masked", d == b'')
except Exception: t("disconnected after being masked", False)
sc.close(); setmask(0xFFF)

# ---------- 9 self-heal ----------
print("\n[9] broadcast self-heal")
devmem("0x43CD0000","1")     # set the bit by hand (no session)
time.sleep(0.5)
try: xvc(2547, timeout=2)     # trigger one accept
except Exception: pass
time.sleep(0.5)
t("leftover bcast_en is cleared", (devmem("0x43CD0000") or "").endswith("0"), devmem("0x43CD0000"))

# ---------- 10 status reporting ----------
print("\n[10] status reporting")
d = status()
t("server_pid", d.get("server_pid", 0) > 0, str(d.get("server_pid")))
t("nch = 12", d.get("nch") == 12)
t("bcast_ch present", "bcast_ch" in d and d["bcast_ch"].get("tag") == "0xA7000000")
t("ch0 tag", d["channels"][0]["tag"] == "0xA7000000")

os.close(fd)

# ---------- summary ----------
print("\n" + "="*60)
passed = sum(1 for _, ok, _ in results if ok)
total = len(results)
print(f" result: {passed}/{total} passed")
if passed < total:
    print(" failed items:")
    for n, ok, det in results:
        if not ok: print(f"   ❌ {n} {det}")
print("="*60)
sys.exit(0 if passed == total else 1)
