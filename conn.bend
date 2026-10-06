# What the RTSP and RTMP clients share: the result of a pull, and a
# connection's opening, reads, writes and failures in continuation
# style (the next step is handed the socket back). The sockets are
# net.c's: hosts by name, TLS, and reads that give up after a while.
import Base
import ./bytes.bend as B
import ./net.bend as X

# What a pull did: the packets read (RTP packets, or RTMP messages),
# the units written (NAL units, or FLV tags), the bytes written, and
# the codec or container.
type Pulled is Data:
  Pulled{packets: U32, units: U32, bytes: U32, kind: String}

def Out() -> Type:
  Result<&1, &1, U32 & String, Pulled>

def Recv() -> Type:
  Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>

# How long a read waits for the server, in ms.
def Conn.patience() -> U32:
  10000

def Sent() -> Type:
  Socket & Result<&1, &1, U32 & String, Unit>

def Wrote() -> Type:
  File & Result<&1, &1, U32 & String, Unit>

def Pulled.add(p: Pulled, +units: U32, +bytes: U32) -> Pulled:
  Pulled{packets, n, b, kind} = p
  Pulled{U32.add(packets, 1), U32.add(n, units), U32.add(b, bytes), kind}

def Conn.fail(s: Socket, code: U32, msg: String) -> IO(Out()):
  do IO<Out()>:
    X.Net.close(s)
    IO.pure(Out(), Fail{(code, msg)})

def Conn.got.n(s: Socket, buf: List<&2, U32>, +piece: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Out())) -> IO(Out()):
  more(s, B.Bytes.cat(buf, piece), B.Bytes.len(piece))

def Conn.got(m: Recv(), buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Out())) -> IO(Out()):
  (s, r) = m
  match r:
    case Fail{e}:
      (code, msg) = e
      Conn.fail(s, code, "recv: " ++ msg)
    case Done{None{}}:
      Conn.fail(s, 0, "the server sent nothing for 10 seconds")
    case Done{Some{Nil{}}}:
      Conn.fail(s, 0, "the server closed the connection")
    case Done{Some{Con{h, t}}}:
      Conn.got.n(s, buf, h <> t, more)

# More bytes onto the buffer, and how many came.
def Conn.recv.n(s: Socket, buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Out())) -> IO(Out()):
  do IO<Out()>:
    m : Recv() <- X.Net.poll(s, 65536, Conn.patience())
    Conn.got(m, buf, more)

# More bytes onto the buffer.
def Conn.recv(s: Socket, buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> IO(Out())) -> IO(Out()):
  Conn.recv.n(s, buf, s2 => b2 => _ => more(s2, b2))

def Conn.sent(m: Sent(), k: Socket -> IO(Out())) -> IO(Out()):
  (s, r) = m
  match r:
    case Done{_}:
      k(s)
    case Fail{e}:
      (code, msg) = e
      Conn.fail(s, code, "send: " ++ msg)

def Conn.send(s: Socket, bs: List<&2, U32>, k: Socket -> IO(Out())) -> IO(Out()):
  do IO<Out()>:
    m : Sent() <- X.Net.send(s, bs)
    Conn.sent(m, k)

# Text as bytes (a request's lines are ASCII).
def Conn.say(s: Socket, text: String, k: Socket -> IO(Out())) -> IO(Out()):
  Conn.send(s, B.Bytes.of(text), k)

def Conn.wrote(m: Wrote(), s: Socket, k: Socket -> File -> IO(Out())) -> IO(Out()):
  (f, r) = m
  match r:
    case Done{_}:
      k(s, f)
    case Fail{e}:
      (code, msg) = e
      do IO<Out()>:
        File.close(f)
        Conn.fail(s, code, "write: " ++ msg)

# Bytes to the file (nothing to do for none).
def Conn.save(bs: List<&2, U32>, s: Socket, f: File, k: Socket -> File -> IO(Out())) ->
  IO(Out()):
  match bs:
    case Nil{}:
      k(s, f)
    case Con{h, t}:
      do IO<Out()>:
        m : Wrote() <- File.write_bytes(f, h <> t)
        Conn.wrote(m, s, k)

def Conn.bye.sent(m: Sent(), f: File, r: Out()) -> IO(Out()):
  (s, _) = m
  do IO<Out()>:
    File.close(f)
    X.Net.close(s)
    IO.pure(Out(), r)

# A last word to the server, sent or not, then both ends closed.
def Conn.bye(s: Socket, text: String, f: File, r: Out()) -> IO(Out()):
  do IO<Out()>:
    m : Sent() <- X.Net.send(s, B.Bytes.of(text))
    Conn.bye.sent(m, f, r)

# Both ends closed, and the result.
def Conn.close(s: Socket, f: File, r: Out()) -> IO(Out()):
  do IO<Out()>:
    File.close(f)
    X.Net.close(s)
    IO.pure(Out(), r)

def Conn.due.at(late: Bool, s: Socket, f: File, p: Pulled,
  stop: Socket -> File -> Pulled -> IO(Out()),
  go: Socket -> File -> Pulled -> IO(Out())) -> IO(Out()):
  match late:
    case True{}:
      stop(s, f, p)
    case False{}:
      go(s, f, p)

# stop when the clock (IO.now's, ms) has reached until, else go.
def Conn.due(until: Nat, s: Socket, f: File, p: Pulled,
  stop: Socket -> File -> Pulled -> IO(Out()),
  go: Socket -> File -> Pulled -> IO(Out())) -> IO(Out()):
  do IO<Out()>:
    now : Nat <- IO.now()
    Conn.due.at(Nat.is_le(until, now), s, f, p, stop, go)

def Conn.secured(m: Sent(), k: Socket -> IO(Out())) -> IO(Out()):
  (s, r) = m
  match r:
    case Done{_}:
      k(s)
    case Fail{e}:
      (code, msg) = e
      Conn.fail(s, code, msg)

def Conn.ca(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{path}:
      path
    case Fail{_}:
      ""

def Conn.opened(r: Result<&1, &1, U32 & String, Socket>, tls: Bool, host: String,
  k: Socket -> IO(Out())) -> IO(Out()):
  match r tls:
    case Fail{e} _:
      (code, msg) = e
      IO.pure(Out(), Fail{(code, "connect: " ++ msg)})
    case Done{s} False{}:
      k(s)
    case Done{s} True{}:
      do IO<Out()>:
        ca : Result<&1, &1, U32 & String, String> <- IO.get_env("STREAM_CAFILE")
        m : Sent() <- X.Net.tls(s, host, Conn.ca(ca), "", "")
        Conn.secured(m, k)

# A connection to host:port, under TLS when asked: the certificate is
# checked against the host's name and the system's store, or the PEM
# file the environment's STREAM_CAFILE names (for a server with a
# certificate of its own making).
def Conn.open(+host: String, port: U32, tls: Bool, k: Socket -> IO(Out())) -> IO(Out()):
  do IO<Out()>:
    r : Result<&1, &1, U32 & String, Socket> <- X.Net.connect(host, port)
    Conn.opened(r, tls, host, k)
