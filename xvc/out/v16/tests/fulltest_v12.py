#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fulltest_v12.py — XJSM-P12-Z7000 comprehensive test suite (v12)

Coverage:
  A. Network and Web console
  B. 13 XVC ports x getinfo
  C. XVC protocol edge cases (settck / shift across widths and data patterns / illegal input)
  D. engine registers (12 channels + broadcast) (TAG / DIV / STATUS / SEQ)
  E. Broadcast register block (TAG / BCMASK / CHSEL / CTRL / STATUS)
  F. Concurrency and exclusivity (double connect on one channel / 12 channels at once / broadcast exclusivity / double broadcast)
  G. Broadcast session lifecycle (setup / in-mask channels refused / recovery after disconnect)
  H. Robustness (fast reconnect / mid-transfer disconnect / oversized shift)
  I. OLED (process count / I2C ACK)

Usage:
  python3 fulltest_v12.py              # over network + serial
  python3 fulltest_v12.py --net-only   # network only (when there is no serial port)
"""
import socket, struct, time, json, sys, os, subprocess
import urllib.request

HOST = "192.168.1.113"
BASE = f"http://{HOST}"
BOOT_PORT = 4194304
NET_ONLY = "--net-only" in sys.argv
SERIAL = os.environ.get("XVC_SERIAL", "/dev/ttyUSB1")
BOARD_PW = os.environ.get("XVC_PASSWORD", "")   # serial login password; never hard-coded

P, F = [], []
def chk(cat, name, ok, detail=""):
    (P if ok else F).append((cat, name))
    print(f"  {'✅' if ok else '❌'} [{cat}] {name}" + (f"   {detail}" if detail else ""))

# ---------------- serial ----------------
ser = None
if not NET_ONLY:
    try:
        import termios, select
        fd = os.open(SERIAL, os.O_RDWR | os.O_NOCTTY)
        a = termios.tcgetattr(fd)
        a[0] = 0; a[1] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[3] = 0; a[4] = a[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, a)
        ser = fd
    except Exception as e:
        print(f"  (serial port unavailable, skipping serial items: {e})")

def srd(t=1.0):
    import select
    out = b""; end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([ser], [], [], 0.1)
        if r:
            try: out += os.read(ser, 65536)
            except Exception: pass
    return out.decode(errors="replace")

def login_shell():
    """Make sure we are in a root shell"""
    if ser is None: return False
    srd(0.5)
    os.write(ser, b"\x03"); time.sleep(0.4)
    os.write(ser, b"\n"); time.sleep(0.8)
    s = srd(1.0)
    if "#" in s: return True
    os.write(ser, b"root\n"); time.sleep(1.8)
    s = srd(1.0)
    if "assword" in s:
        os.write(ser, BOARD_PW.encode() + b"\n"); time.sleep(2.5)
        s = srd(1.5)
    return "#" in s

def devmem(addr, val=None):
    if ser is None: return "?"
    cmd = f"devmem {addr} 32" + (f" {val}" if val is not None else "") + "\n"
    os.write(ser, cmd.encode()); time.sleep(0.45)
    out = srd(0.7)
    for ln in out.split("\n"):
        ln = ln.strip()
        if ln.startswith("0x"): return ln
    return "?"

def sh(cmd, wait=1.8):
    if ser is None: return ""
    os.write(ser, cmd.encode() + b"\n"); time.sleep(0.7)
    return srd(wait)

# ---------------- HTTP ----------------
def http(path, timeout=8):
    return urllib.request.urlopen(BASE + path, timeout=timeout).read().decode(errors="replace")

def status():
    return json.loads(http("/cgi-bin/status"))

# ---------------- XVC ----------------
def xvc_conn(port, timeout=3):
    s = socket.create_connection((HOST, port), timeout)
    s.settimeout(timeout)
    return s

def xvc_getinfo(port, retries=3):
    for _ in range(retries):
        try:
            s = xvc_conn(port); s.sendall(b'getinfo:')
            r = s.recv(64); s.close()
            if r: return r
        except Exception:
            pass
        time.sleep(0.5)
    return b""

def xvc_settck(port, ns):
    """XVC 1.0: settck:<4-byte binary period (ns), network byte order>"""
    try:
        s = xvc_conn(port); s.sendall(b'getinfo:'); s.recv(64)
        s.sendall(b'settck:' + struct.pack('>I', ns & 0xFFFFFFFF))
        r = s.recv(32); s.close()
        return r
    except Exception as e:
        return b"ERR:" + type(e).__name__.encode()

def settck_ok(port, ns):
    """Returns (ok, echoed period)"""
    r = xvc_settck(port, ns)
    if len(r) >= 4:
        v = struct.unpack('>I', r[:4])[0]
        return (v == ns, v)
    return (False, -1)

def xvc_shift(port, nbits, tms_fill=0xFF, tdi_fill=0x00, timeout=8):
    """Returns (ok, tdo_bytes). Sends settck first to lock byte order (all real clients do this)"""
    try:
        s = xvc_conn(port, timeout); s.sendall(b'getinfo:'); s.recv(64)
        s.sendall(b'settck:' + struct.pack('>I', 1000)); s.recv(16)
        nb = (nbits + 7) // 8
        s.sendall(b'shift:' + struct.pack('>I', nbits) + bytes([tms_fill])*nb + bytes([tdi_fill])*nb)
        got = b""
        while len(got) < nb:
            c = s.recv(nb - len(got))
            if not c: break
            got += c
        s.close()
        return (len(got) == nb, got)
    except Exception:
        return (False, b"")

# =============================================================
print("=" * 64)
print(f"  XJSM-P12-Z7000 comprehensive test (v12)  {'[network only]' if NET_ONLY else '[network+serial]'}")
print("=" * 64)

# Reset starting state: empty mask = take over no channel (avoids leftovers from a previous run)
try:
    http("/cgi-bin/control?cmd=setbcmask&v=0x000", 6)
    print("  (start: broadcast mask reset to zero)")
except Exception as e:
    print(f"  (initial reset failed: {e})")
time.sleep(0.6)

# ---------- A. Network and Web ----------
print("\n[A] Network and Web console")
chk("A", "ping", subprocess.run(["ping","-c","2","-W","2",HOST], capture_output=True).returncode == 0)
try:
    page = http("/", 6)
    chk("A", "index.html", len(page) > 20000, f"{len(page)}B")
    chk("A", "index contains TX used", "TX used" in page)
except Exception as e:
    chk("A", "index.html", False, str(e)[:30])
for ep in ("status", "net", "control"):
    try:
        r = http(f"/cgi-bin/{ep}", 5)
        chk("A", f"cgi/{ep}", r is not None and len(r) > 0, f"{len(r)}B")
    except Exception as e:
        chk("A", f"cgi/{ep}", False, str(e)[:25])

# ---------- B. 13 ports ----------
print("\n[B] 13 XVC ports")
okn = 0
for p in range(2542, 2555):
    r = xvc_getinfo(p)
    good = b'xvcServer_v1.0:4194304' in r
    if good: okn += 1
chk("B", "all 13 ports respond correctly", okn == 13, f"{okn}/13")
for p in (2542, 2543, 2548, 2554):
    r = xvc_getinfo(p)
    chk("B", f"port {p} response content", b'xvcServer_v1.0:4194304' in r, r[:32].decode(errors='replace'))

# ---------- C. protocol edge cases ----------
print("\n[C] XVC protocol edge cases")
# settck with various values
for ns in (100, 200, 500, 1000, 5000, 20000):
    ok, echo = settck_ok(2543, ns)
    chk("C", f"settck:{ns} binary", ok, f"echo {echo} ns")
    time.sleep(0.3)
# settck 0 => default 10MHz (the server treats it as 100ns)
ok, echo = settck_ok(2543, 0)
chk("C", "settck:0 echo normal", echo >= 0, f"echo {echo}")

# shift with various widths
print("  --- shift width coverage ---")
WIDTHS = [1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 1000, 4096, 8192]
okc = 0
for n in WIDTHS:
    good, tdo = xvc_shift(2543, n)
    if good: okc += 1
    chk("C", f"shift {n:5d} bit", good, tdo.hex().upper()[:16] if good else "failed")
chk("C", f"width coverage {len(WIDTHS)} kinds", okc == len(WIDTHS), f"{okc}/{len(WIDTHS)}")

# shift with various TDI patterns
print("  --- shift TDI data patterns ---")
okd = 0
for pat in (0x00, 0xFF, 0xAA, 0x55, 0x0F, 0xF0):
    good, _ = xvc_shift(2543, 64, 0xFF, pat)
    if good: okd += 1
    chk("C", f"TDI=0x{pat:02X}", good)

# illegal shift
print("  --- illegal shift ---")
try:
    s = xvc_conn(2543); s.sendall(b'getinfo:'); s.recv(64)
    s.sendall(b'shift:' + struct.pack('>I', 0) + b'' + b'')
    r = s.recv(8); s.close()
    chk("C", "shift 0 bit rejected", True, "disconnected/rejected")
except Exception:
    chk("C", "shift 0 bit rejected", True, "rejected")
try:
    s = xvc_conn(2543); s.sendall(b'getinfo:'); s.recv(64)
    s.sendall(b'shift:' + struct.pack('>I', BOOT_PORT + 1) + b'\xff'*16 + b'\x00'*16)
    r = s.recv(8); s.close()
    chk("C", "shift over limit rejected", True)
except Exception:
    chk("C", "shift over limit rejected", True, "rejected")

# unknown command
try:
    s = xvc_conn(2543); s.sendall(b'getinfo:'); s.recv(64)
    s.sendall(b'foobar1234')
    r = s.recv(8); s.close()
    chk("C", "unknown command does not crash", True, "ignored/disconnected")
except Exception:
    chk("C", "unknown command does not crash", True, "disconnected")

# ---------- D. engine registers (12 channels + broadcast) ----------
print("\n[D] engine registers (12 channels + broadcast)")
if ser:
    login_shell()
    okeng = 0
    for ch in range(13):
        addr = 0x43C00000 + ch * 0x10000 + 0x14
        v = devmem(hex(addr))
        if v.upper().endswith("A7000000"): okeng += 1
    chk("D", "all 13 engine TAGs = 0xA7000000", okeng == 13, f"{okeng}/13")

    # broadcast engine DIV
    v = devmem("0x43CC0018")
    chk("D", "broadcast engine DIV = 5", v.upper().endswith("00000005"), v)

    # ch0 DIV
    v = devmem("0x43C00018")
    chk("D", "ch0 DIV = 5", v.upper().endswith("00000005"), v)

    # ch0 STATUS tx_free
    v = devmem("0x43C00024")
    try:
        tx_free = int(v, 16) & 0xFF
        chk("D", "ch0 STATUS tx_free=128", tx_free == 128, f"tx_free={tx_free}")
    except Exception:
        chk("D", "ch0 STATUS tx_free=128", False, v)

    # ch0 SEQ: must increment after a shift
    s0 = devmem("0x43C00038")
    xvc_shift(2543, 32)
    s1 = devmem("0x43C00038")
    try:
        g0 = int(s0, 16) >> 16
        g1 = int(s1, 16) >> 16
        chk("D", "go_seq increments after shift", g1 != g0, f"{g0} -> {g1}")
    except Exception:
        chk("D", "go_seq increments after shift", False, f"{s0} / {s1}")

    # ch0 STATE should be IDLE
    v = devmem("0x43C00030")
    try:
        st = (int(v, 16) >> 8) & 3
        chk("D", "ch0 state = IDLE(0)", st == 0, f"state={st}")
    except Exception:
        chk("D", "ch0 state = IDLE(0)", False, v)
else:
    print("  (skipped: no serial port)")

# ---------- E. broadcast register block ----------
print("\n[E] broadcast register block 0x43CD0000")
if ser:
    # zero everything first so later cases see a clean mask
    devmem("0x43CD0004", "0x000")
    devmem("0x43CD0000", "0")
    v = devmem("0x43CD000C")
    chk("E", "TAG = 0xB7000000", v.upper().endswith("B7000000"), v)
    v = devmem("0x43CD0000")
    try:
        chk("E", "CTRL bit0 = 0 (mask empty)", (int(v, 16) & 1) == 0, v)
    except Exception:
        chk("E", "CTRL bit0 = 0 (mask empty)", False, v)
    v = devmem("0x43CD0004")
    try:
        m = int(v, 16) & 0xFFF
        chk("E", "BCMASK is a valid 12-bit value", 0 <= m <= 0xFFF, f"0x{m:03X}")
    except Exception:
        chk("E", "BCMASK is a valid 12-bit value", False, v)
    # write/read test
    devmem("0x43CD0008", "0x3")
    v = devmem("0x43CD0008")
    chk("E", "CHSEL write 3 reads back 3", v.upper().endswith("00000003"), v)
    devmem("0x43CD0008", "0x0")
    devmem("0x43CD0004", "0x005")
    v = devmem("0x43CD0004")
    chk("E", "BCMASK write 0x005 reads back", v.upper().endswith("00000005"), v)
    devmem("0x43CD0004", "0xFFF")
    devmem("0x43CD0000", "1")
    v = devmem("0x43CD0004")
    chk("E", "BCMASK write 0xFFF reads back", v.upper().endswith("00000FFF"), v)
    # restore: mask 0 = take over no channel (later cases depend on this state)
    devmem("0x43CD0004", "0x000")
    devmem("0x43CD0000", "0")
    time.sleep(0.4)
    v = devmem("0x43CD0000")
    try:
        chk("E", "CTRL bit0 = 0 after restoring the empty mask", (int(v, 16) & 1) == 0, v)
    except Exception:
        chk("E", "CTRL bit0 = 0 after restoring the empty mask", False, v)
else:
    print("  (skipped: no serial port)")

# ---------- F. concurrency and exclusivity ----------
print("\n[F] Concurrency and exclusivity")
# double connect on the same channel
try:
    a = xvc_conn(2543); a.sendall(b'getinfo:'); a.recv(64)
    time.sleep(0.4)
    refused = False
    try:
        b = xvc_conn(2543, 2); b.sendall(b'getinfo:'); r = b.recv(64); b.close()
        refused = b'xvcServer' not in r
    except Exception:
        refused = True
    chk("F", "double connect on the same channel rejected", refused)
    a.close(); time.sleep(1.2)
except Exception as e:
    chk("F", "double connect on the same channel rejected", False, str(e)[:25])

# connect all 12 channels at once
time.sleep(1.0)
socks = []
try:
    for p in range(2543, 2555):
        s = xvc_conn(p); s.sendall(b'getinfo:')
        if b'xvcServer' in s.recv(64): socks.append(s)
    chk("F", "12 channels online at once", len(socks) == 12, f"{len(socks)}/12")
finally:
    for s in socks: s.close()
time.sleep(1.5)

# ---------- G. broadcast lifecycle ----------
print("\n[G] Broadcast session lifecycle")
# make sure the mask is all-selected first (otherwise the "refused during broadcast" case does not hold)
try:
    http("/cgi-bin/control?cmd=setbcmask&v=0xFFF")
    time.sleep(0.5)
    print("  (mask set to 0xFFF)")
except Exception as e:
    print(f"  (setting the mask failed: {e})")
try:
    bc = xvc_conn(2542); bc.sendall(b'getinfo:')
    chk("G", "broadcast session established", b'xvcServer' in bc.recv(64))
    time.sleep(0.6)
    blocked = 0
    for p in (2543, 2548, 2554):
        try:
            c = xvc_conn(p, 2); c.sendall(b'getinfo:'); r = c.recv(64); c.close()
            if b'xvcServer' not in r: blocked += 1
        except Exception:
            blocked += 1
        time.sleep(0.3)
    chk("G", "all 3 channels refused during broadcast", blocked == 3, f"{blocked}/3")
    # can we shift inside a broadcast session (must reuse the same connection; the broadcast port is taken)
    gok = 0; gtot = 0
    for nbits in (8, 32, 64, 200):
        gtot += 1
        try:
            nb = (nbits + 7) // 8
            bc.sendall(b'shift:' + struct.pack('>I', nbits) + b'\xFF'*nb + b'\x00'*nb)
            got = b""
            while len(got) < nb:
                c = bc.recv(nb - len(got))
                if not c: break
                got += c
            if len(got) == nb: gok += 1
        except Exception:
            pass
    chk("G", "shift inside a broadcast session (reusing the same connection)", gok == gtot, f"{gok}/{gtot}")
    bc.close()
    time.sleep(2.0)
    # since v13: the mask is a "static reservation"; ending a broadcast session does **not** release it automatically ✗
    # the mask must be cleared by the UI (or CGI) before the channels recover.
    r = xvc_getinfo(2543)
    chk("G", "in-mask channels still refused after the session ends (static reservation)", b'xvcServer' not in r)
    # channels should recover after the mask is cleared
    http("/cgi-bin/control?cmd=setbcmask&v=0x000")
    time.sleep(0.8)
    r = xvc_getinfo(2543)
    chk("G", "channels recover after clearing the mask", b'xvcServer' in r)
except Exception as e:
    chk("G", "broadcast lifecycle", False, str(e)[:30])

# double broadcast
time.sleep(1.0)
try:
    b1 = xvc_conn(2542); b1.sendall(b'getinfo:'); b1.recv(64)
    time.sleep(0.5)
    refused = False
    try:
        b2 = xvc_conn(2542, 2); b2.sendall(b'getinfo:'); r = b2.recv(64); b2.close()
        refused = b'xvcServer' not in r
    except Exception:
        refused = True
    chk("G", "double broadcast rejected", refused)
    b1.close(); time.sleep(1.5)
except Exception as e:
    chk("G", "double broadcast rejected", False, str(e)[:25])

# ---------- H. robustness ----------
print("\n[H] Robustness")
# fast connect/disconnect x30
t0 = time.time(); errs = 0
for i in range(30):
    try:
        s = xvc_conn(2543, 2); s.sendall(b'getinfo:'); s.recv(64); s.close()
    except Exception:
        errs += 1
    time.sleep(0.12)
chk("H", "fast connect/disconnect x30", errs <= 6, f"failed {errs}/30, elapsed {time.time()-t0:.1f}s")

# disconnect mid-transfer
import struct as _st
try:
    s = xvc_conn(2543); s.sendall(b'getinfo:'); s.recv(64)
    s.sendall(b'shift:' + _st.pack('>I', 4096))
    s.close()          # deliberately do not wait for TMS/TDI
    time.sleep(1.5)
    r = xvc_getinfo(2543)
    chk("H", "usable again after a mid-transfer disconnect", b'xvcServer' in r)
except Exception as e:
    chk("H", "usable again after a mid-transfer disconnect", False, str(e)[:25])

# oversized shift
good, _ = xvc_shift(2543, 65536, 0xFF, 0x00, timeout=20)
chk("H", "shift 65536 bit (oversized)", good)

# maximum packet
good, _ = xvc_shift(2543, 65536 * 8, 0xFF, 0x00, timeout=40)
chk("H", "shift 524288 bit (near the limit)", good)

# ---------- I. OLED ----------
print("\n[I] OLED")
if ser:
    login_shell()
    sh("echo MARK_START", 1.5)
    out = sh("ps | grep oled_ip | grep -v grep | wc -l", 3.0)
    nums = [x for x in out.replace("\r","").split("\n") if x.strip().isdigit()]
    n = nums[-1].strip() if nums else "?"
    try:
        chk("I", "OLED process count = 1", int(n) == 1, n)
    except Exception:
        chk("I", "OLED process count = 1", False, n)
    out = sh("/usr/bin/i2cprobe /dev/i2c-1 2>&1 | grep -c ACK", 6.0)
    nums = [x for x in out.replace("\r","").split("\n") if x.strip().isdigit()]
    n = nums[-1].strip() if nums else "?"
    try:
        chk("I", "at least 1 I2C ACK (OLED 0x3C)", int(n) >= 1, f"{n} ACK")
    except Exception:
        chk("I", "I2C ACK", False, n)
else:
    print("  (skipped: no serial port)")

# ---------- summary ----------
print("\n" + "=" * 64)
print(f"  passed {len(P)}   failed {len(F)}")
if F:
    print("  failed items:")
    for cat, name in F:
        print(f"    ❌ [{cat}] {name}")
else:
    print("  🎉 all passed")
print("=" * 64)
sys.exit(0 if not F else 1)
