"""A fake RTL-TCP server for tests: sends silence and logs every command it's given.
Usage: python3 -I tools/mock_rtl_tcp.py <port> <logfile>"""
import socket, struct, sys, threading, time

port = int(sys.argv[1])
log = open(sys.argv[2], "a", buffering=1)
names = {1: "freq", 2: "rate", 3: "tuner_gain_mode", 4: "tuner_gain", 5: "ppm", 8: "rtl_agc", 14: "bias"}

def client(c):
    log.write("CONNECT\n")
    c.settimeout(0.01)
    c.sendall(b"RTL0" + struct.pack(">II", 5, 29))
    buf = b""
    silence = bytes([127, 128]) * 8192
    while True:
        try:
            d = c.recv(64)
            if not d:
                break
            buf += d
            while len(buf) >= 5:
                cmd, val = struct.unpack(">BI", buf[:5])
                buf = buf[5:]
                log.write(f"{names.get(cmd, cmd)}={val}\n")
        except socket.timeout:
            pass
        except OSError:
            break
        try:
            c.sendall(silence)
        except OSError:
            break
        time.sleep(0.005)
    log.write("CLOSE\n")

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(8)
while True:
    c, _ = s.accept()
    threading.Thread(target=client, args=(c,), daemon=True).start()
