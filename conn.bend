# What the RTSP and RTMP clients share: a connection's opening, reads, writes and failures in continuation
# style (the next step is handed the socket back). A step that fails
# closes the socket and ends in Fail, whatever the result T was to be.
# The sockets are net.c's: hosts by name, TLS, reads with a deadline.
import Base
import ./bytes.bend as B
import ./net.bend as X
import ./opts.bend as E

def Res(T: Type) -> Type:
  Result<&1, &1, E.Err, T>

def Recv() -> Type:
  Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>

def Sent() -> Type:
  Socket & Result<&1, &1, U32 & String, Unit>

# The socket closed and the error given.
def Conn.fail(-T: Type, s: Socket, why: E.Why, code: U32, msg: String) -> IO(Res(T)):
  do IO<Res(T)>:
    X.Net.close(s)
    IO.pure(Res(T), Fail{E.Err{why, code, msg}})

def Conn.got.n(-T: Type, s: Socket, buf: List<&2, U32>, +piece: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Res(T))) -> IO(Res(T)):
  more(s, B.Bytes.cat(buf, piece), B.Bytes.len(piece))

def Conn.got(-T: Type, m: Recv(), buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Res(T))) -> IO(Res(T)):
  (s, r) = m
  match r:
    case Fail{e}:
      (code, msg) = e
      Conn.fail(T, s, E.Hangup{}, code, "recv: " ++ msg)
    case Done{None{}}:
      Conn.fail(T, s, E.Silent{}, 0, "the server sent nothing for too long")
    case Done{Some{Nil{}}}:
      Conn.fail(T, s, E.Hangup{}, 0, "the server closed the connection")
    case Done{Some{Con{h, t}}}:
      Conn.got.n(T, s, buf, h <> t, more)

# More bytes onto the buffer, waiting at most ms, and how many came.
def Conn.recv.n(-T: Type, s: Socket, ms: U32, buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Res(T))) -> IO(Res(T)):
  do IO<Res(T)>:
    m : Recv() <- X.Net.poll(s, 65536, ms)
    Conn.got(T, m, buf, more)

# More bytes onto the buffer, waiting at most ms.
def Conn.recv(-T: Type, s: Socket, ms: U32, buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> IO(Res(T))) -> IO(Res(T)):
  Conn.recv.n(T, s, ms, buf, s2 => b2 => _ => more(s2, b2))

def Conn.sent(-T: Type, m: Sent(), k: Socket -> IO(Res(T))) -> IO(Res(T)):
  (s, r) = m
  match r:
    case Done{_}:
      k(s)
    case Fail{e}:
      (code, msg) = e
      Conn.fail(T, s, E.Hangup{}, code, "send: " ++ msg)

def Conn.send(-T: Type, s: Socket, bs: List<&2, U32>, k: Socket -> IO(Res(T))) ->
  IO(Res(T)):
  do IO<Res(T)>:
    m : Sent() <- X.Net.send(s, bs)
    Conn.sent(T, m, k)

# Text as bytes (a request's lines are ASCII).
def Conn.say(-T: Type, s: Socket, text: String, k: Socket -> IO(Res(T))) -> IO(Res(T)):
  Conn.send(T, s, B.Bytes.of(text), k)

def Conn.shut.end(m: Recv(), go: Socket -> IO(Unit)) -> IO(Unit):
  (s, r) = m
  match r:
    case Done{Some{Con{_, _}}}:
      go(s)
    case _:
      X.Net.close(s)

# What the server still sends is read and dropped, for at most turns
# reads, until it is quiet for ms or it closes; then the socket is
# closed. A server gets to answer the last word and to free the session
# before the connection goes: some refuse a new session while the old
# one is still theirs.
def Conn.shut.drain(turns: Nat, s: Socket, +ms: U32) -> IO(Unit):
  match turns:
    case 0n:
      X.Net.close(s)
    case 1n+p:
      do IO<Unit>:
        m : Recv() <- X.Net.poll(s, 65536, ms)
        Conn.shut.end(m, s2 => Conn.shut.drain(p, s2, ms))

def Conn.shut.sent(m: Sent(), ms: U32) -> IO(Unit):
  (s, r) = m
  match r:
    case Done{_}:
      Conn.shut.drain(64n, s, ms)
    case Fail{_}:
      X.Net.close(s)

# A last word to the server, then the socket closed once the server
# has been quiet for ms (or at once, with no last word).
def Conn.shut(s: Socket, last: List<&2, U32>, ms: U32) -> IO(Unit):
  match last:
    case Nil{}:
      X.Net.close(s)
    case Con{h, t}:
      do IO<Unit>:
        m : Sent() <- X.Net.send(s, h <> t)
        Conn.shut.sent(m, ms)

def Conn.secured(-T: Type, m: Sent(), k: Socket -> IO(Res(T))) -> IO(Res(T)):
  (s, r) = m
  match r:
    case Done{_}:
      k(s)
    case Fail{e}:
      (code, msg) = e
      Conn.fail(T, s, E.Unsafe{}, code, msg)

def Conn.opened(-T: Type, r: Result<&1, &1, U32 & String, Socket>, tls: Bool,
  host: String, ca: String, k: Socket -> IO(Res(T))) -> IO(Res(T)):
  match r tls:
    case Fail{e} _:
      (code, msg) = e
      IO.pure(Res(T), Fail{E.Err{E.NoRoute{}, code, msg}})
    case Done{s} False{}:
      k(s)
    case Done{s} True{}:
      do IO<Res(T)>:
        m : Sent() <- X.Net.tls(s, host, ca, "", "")
        Conn.secured(T, m, k)

# A connection to host:port, under TLS when asked: the certificate is
# checked against the host's name and the system's store, or the PEM
# file ca names (for a server with a certificate of its own making).
def Conn.open(-T: Type, +host: String, port: U32, tls: Bool, ca: String,
  k: Socket -> IO(Res(T))) -> IO(Res(T)):
  do IO<Res(T)>:
    r : Result<&1, &1, U32 & String, Socket> <- X.Net.connect(host, port)
    Conn.opened(T, r, tls, host, ca, k)
