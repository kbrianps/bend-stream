# What the RTSP and RTMP clients share: the result of a pull, and a
# connection's reads, writes and failures in continuation style (the
# next step is handed the socket back).
import Base
import ./bytes.bend as B

# What a pull did: the packets read (RTP packets, or RTMP messages),
# the units written (NAL units, or FLV tags), the bytes written, and
# the codec or container.
type Pulled is Data:
  Pulled{packets: U32, units: U32, bytes: U32, kind: String}

def Out() -> Type:
  Result<&1, &1, U32 & String, Pulled>

def Recv() -> Type:
  Socket & Result<&1, &1, U32 & String, List<&2, U32>>

def Sent() -> Type:
  Socket & Result<&1, &1, U32 & String, Unit>

def Wrote() -> Type:
  File & Result<&1, &1, U32 & String, Unit>

def Pulled.add(p: Pulled, +units: U32, +bytes: U32) -> Pulled:
  Pulled{packets, n, b, kind} = p
  Pulled{U32.add(packets, 1), U32.add(n, units), U32.add(b, bytes), kind}

def Conn.fail(s: Socket, code: U32, msg: String) -> IO(Out()):
  do IO<Out()>:
    Socket.close(s)
    IO.pure(Out(), Fail{(code, msg)})

def Conn.got(m: Recv(), buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> IO(Out())) -> IO(Out()):
  (s, r) = m
  match r:
    case Fail{e}:
      (code, msg) = e
      Conn.fail(s, code, "recv: " ++ msg)
    case Done{Nil{}}:
      Conn.fail(s, 0, "the server closed the connection")
    case Done{Con{h, t}}:
      more(s, B.Bytes.cat(buf, h <> t))

# More bytes onto the buffer.
def Conn.recv(s: Socket, buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> IO(Out())) -> IO(Out()):
  do IO<Out()>:
    m : Recv() <- TCP.recv_bytes(s, 65536)
    Conn.got(m, buf, more)

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
    m : Sent() <- TCP.send_bytes(s, bs)
    Conn.sent(m, k)

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

# Both ends closed, and the result.
def Conn.close(s: Socket, f: File, r: Out()) -> IO(Out()):
  do IO<Out()>:
    File.close(f)
    Socket.close(s)
    IO.pure(Out(), r)
