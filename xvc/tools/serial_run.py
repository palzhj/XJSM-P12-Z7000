#!/usr/bin/env python3
"""Run a command on an already-logged-in board serial port and print the output. Usage: serial_run.py "cmd" [wait]"""
import os, termios, time, select, sys
cmd = sys.argv[1]
wait = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
fd = os.open("/dev/ttyUSB3", os.O_RDWR | os.O_NOCTTY)
a = termios.tcgetattr(fd); a[0]=0; a[1]=0; a[2]=termios.CS8|termios.CREAD|termios.CLOCAL; a[3]=0; a[4]=a[5]=termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
def rd(t):
    out=b""; end=time.time()+t
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.15)
        if r:
            try: out+=os.read(fd,65536)
            except BlockingIOError: pass
    return out
os.write(fd, b"\r"); time.sleep(0.4); rd(0.3)
os.write(fd, (cmd + "\r").encode()); time.sleep(wait)
print(rd(1.0).decode(errors="replace"))
os.close(fd)
