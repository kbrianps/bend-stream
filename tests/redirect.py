#!/usr/bin/env python3
"""An RTSP server that only redirects: every request gets a 302 to the
URL given. Usage: redirect.py PORT URL"""
import socket
import sys
import threading


def serve(conn, to):
    with conn:
        buf = b""
        while b"\r\n\r\n" not in buf:
            more = conn.recv(4096)
            if not more:
                return
            buf += more
        cseq = "0"
        for line in buf.decode("latin-1").split("\r\n"):
            if line.lower().startswith("cseq:"):
                cseq = line.split(":", 1)[1].strip()
        conn.sendall(("RTSP/1.0 302 Moved Temporarily\r\nCSeq: %s\r\nLocation: %s\r\n\r\n"
                      % (cseq, to)).encode())


def main():
    port, to = int(sys.argv[1]), sys.argv[2]
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(16)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=serve, args=(conn, to), daemon=True).start()


main()
