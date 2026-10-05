# RTMP client: play a stream into an FLV file.
#
#   C: C0 C1                    S: S0 S1 S2          C: C2
#   C: Set Chunk Size, connect(app)                  S: _result
#   C: createStream                                  S: _result, the stream id
#   C: play(stream), Set Buffer Length               S: onStatus Play.Start
#   S: data (the metadata), audio and video messages
#
# Each of those messages is written as an FLV tag, as it came: the
# codecs are whatever the server sends (H.264 and AAC as a rule), and
# ffmpeg or a player reads the file. This file is the IO; the bytes and
# their meaning are in rtmp_core.bend and amf.bend, which are pure.
#
# Over Base's TCP only: the host is an IPv4 address, and there is no
# TLS (no rtmps). A login goes in the URL's query, as servers that use
# one expect (rtmp://host/app?user=...&pass=...).
import Base
import ./bytes.bend as B
import ./amf.bend as A
import ./rtmp_core.bend as K
import ./rtsp_core.bend as C
import ./conn.bend as N

def Rtmp.got.n(s: Socket, buf: List<&2, U32>, +piece: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(N.Out())) -> IO(N.Out()):
  more(s, B.Bytes.cat(buf, piece), B.Bytes.len(piece))

def Rtmp.got(m: N.Recv(), buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(N.Out())) -> IO(N.Out()):
  (s, r) = m
  match r:
    case Fail{e}:
      (code, msg) = e
      N.Conn.fail(s, code, "recv: " ++ msg)
    case Done{Nil{}}:
      N.Conn.fail(s, 0, "the server closed the connection")
    case Done{Con{h, t}}:
      Rtmp.got.n(s, buf, h <> t, more)

# More bytes onto the buffer, and how many came.
def Rtmp.recv(s: Socket, buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(N.Out())) -> IO(N.Out()):
  do IO<N.Out()>:
    m : N.Recv() <- TCP.recv_bytes(s, 65536)
    Rtmp.got(m, buf, more)

# The stream
# ----------

# With nothing whole in the buffer: stop when the time is up; else an
# acknowledgement when a megabyte came since the last (a server may
# stop sending without them), and more bytes.
def Rtmp.turn(up: Bool, due: Bool, buf: List<&2, U32>, s: Socket, f: File, +rx: U32,
  acked: U32, p: N.Pulled,
  again: List<&2, U32> -> Socket -> File -> U32 -> U32 -> N.Pulled -> IO(N.Out())) ->
  IO(N.Out()):
  match up due:
    case True{} _:
      N.Conn.close(s, f, Done{p})
    case False{} True{}:
      N.Conn.send(s, K.Rtmp.ack(rx), s2 => Rtmp.recv(s2, buf, s3 => b3 => n =>
        again(b3, s3, f, U32.add(rx, n), rx, p)))
    case False{} False{}:
      Rtmp.recv(s, buf, s3 => b3 => n => again(b3, s3, f, U32.add(rx, n), acked, p))

# The loop: a media message into the file as a tag, a ping answered,
# the rest passed over. rx: the bytes received; acked: at the last
# acknowledgement.
def Rtmp.loop(fuel: Nat, e: K.Ev, +st: K.Dec, +buf: List<&2, U32>, s: Socket, f: File,
  +until: Nat, +rx: U32, +acked: U32, p: N.Pulled) -> IO(N.Out()):
  match fuel e:
    case 0n _:
      N.Conn.close(s, f, Done{p})
    case 1n+q K.Media{typ, ts, payload, +st2, +rest}:
      +tag = K.Flv.tag(typ, ts, payload)
      N.Conn.save(tag, s, f, s2 => f2 => Rtmp.loop(q, K.Rtmp.event(st2, rest), st2, rest,
        s2, f2, until, rx, acked, N.Pulled.add(p, 1, B.Bytes.len(tag))))
    case 1n+q K.Ping{data, +st2, +rest}:
      N.Conn.send(s, K.Rtmp.pong(data), s2 => Rtmp.loop(q, K.Rtmp.event(st2, rest), st2,
        rest, s2, f, until, rx, acked, p))
    case 1n+q K.Over{_, _}:
      N.Conn.close(s, f, Done{p})
    case 1n+q K.Refused{msg, _, _}:
      N.Conn.close(s, f, Fail{(0, "play was refused: " ++ msg)})
    case 1n+q K.Skip{+st2, +rest}:
      Rtmp.loop(q, K.Rtmp.event(st2, rest), st2, rest, s, f, until, rx, acked, p)
    case 1n+q K.Result{_, +st2, +rest}:
      Rtmp.loop(q, K.Rtmp.event(st2, rest), st2, rest, s, f, until, rx, acked, p)
    case 1n+q K.Error{_, +st2, +rest}:
      Rtmp.loop(q, K.Rtmp.event(st2, rest), st2, rest, s, f, until, rx, acked, p)
    case 1n+q K.Wait{}:
      do IO<N.Out()>:
        now : Nat <- IO.now()
        Rtmp.turn(Nat.is_le(until, now), (U32.sub(rx, acked) >= 1000000 : U32), buf, s, f,
          rx, acked, p, +b3 => s3 => f3 => +rx3 => +ack3 => p3 =>
            Rtmp.loop(q, K.Rtmp.event(st, b3), st, b3, s3, f3, until, rx3, ack3, p3))

# Setting up
# ----------

# The answer to a command: the next _result, with pings answered and
# everything else passed over meanwhile.
def Rtmp.await(fuel: Nat, e: K.Ev, +st: K.Dec, +buf: List<&2, U32>, s: Socket,
  k: Socket -> K.Dec -> List<&2, U32> -> List<&2, A.Tok> -> IO(N.Out())) -> IO(N.Out()):
  match fuel e:
    case 0n _:
      N.Conn.fail(s, 0, "no answer to a command")
    case 1n+p K.Result{ts, st2, rest}:
      k(s, st2, rest, ts)
    case 1n+p K.Error{msg, _, _}:
      N.Conn.fail(s, 0, "refused: " ++ msg)
    case 1n+p K.Refused{msg, _, _}:
      N.Conn.fail(s, 0, "refused: " ++ msg)
    case 1n+p K.Ping{data, +st2, +rest}:
      N.Conn.send(s, K.Rtmp.pong(data), s2 =>
        Rtmp.await(p, K.Rtmp.event(st2, rest), st2, rest, s2, k))
    case 1n+p K.Skip{+st2, +rest}:
      Rtmp.await(p, K.Rtmp.event(st2, rest), st2, rest, s, k)
    case 1n+p K.Over{+st2, +rest}:
      Rtmp.await(p, K.Rtmp.event(st2, rest), st2, rest, s, k)
    case 1n+p K.Media{_, _, _, +st2, +rest}:
      Rtmp.await(p, K.Rtmp.event(st2, rest), st2, rest, s, k)
    case 1n+p K.Wait{}:
      N.Conn.recv(s, buf, s2 => +b2 => Rtmp.await(p, K.Rtmp.event(st, b2), st, b2, s2, k))

def Rtmp.opened(r: Result<&1, &1, U32 & String, File>, s: Socket, +st: K.Dec,
  +buf: List<&2, U32>, +now: Nat, ms: U32) -> IO(N.Out()):
  match r:
    case Fail{e}:
      (code, msg) = e
      N.Conn.fail(s, code, "cannot write the file: " ++ msg)
    case Done{f}:
      N.Conn.save(K.Flv.header(), s, f, s2 => f2 => Rtmp.loop(4000000000n,
        K.Rtmp.event(st, buf), st, buf, s2, f2, Nat.add(now, U32.to_nat(ms)), 0, 0,
        N.Pulled{0, 0, 13, "FLV"}))

# play is sent: open the file, note the time, and take what comes.
def Rtmp.start(s: Socket, st: K.Dec, buf: List<&2, U32>, path: String, ms: U32) ->
  IO(N.Out()):
  do IO<N.Out()>:
    now : Nat <- IO.now()
    f : Result<&1, &1, U32 & String, File> <- File.open(path, "w")
    Rtmp.opened(f, s, st, buf, now, ms)

# The stream is created: its id is the result's fourth value.
def Rtmp.created(s: Socket, st: K.Dec, buf: List<&2, U32>, ts: List<&2, A.Tok>,
  stream: String, path: String, ms: U32) -> IO(N.Out()):
  N.Conn.send(s, K.Rtmp.play(A.Amf.number(A.Amf.at(ts, 3n)), stream), s2 =>
    Rtmp.start(s2, st, buf, path, ms))

# Connected to the application: create a stream.
def Rtmp.connected(s: Socket, +st: K.Dec, +buf: List<&2, U32>, stream: String,
  path: String, ms: U32) -> IO(N.Out()):
  N.Conn.send(s, K.Rtmp.create(), s2 => Rtmp.await(1000000n, K.Rtmp.event(st, buf), st,
    buf, s2, s3 => st3 => b3 => ts => Rtmp.created(s3, st3, b3, ts, stream, path, ms)))

# The handshake's answer is here (or more of it is read): C2, our chunk
# size, and connect.
def Rtmp.shaking(fuel: Nat, h: K.Shake, buf: List<&2, U32>, s: Socket, +u: C.Url,
  +w: K.Where, path: String, ms: U32) -> IO(N.Out()):
  match fuel h:
    case 0n _:
      N.Conn.fail(s, 0, "the handshake did not end")
    case 1n+p K.Early{}:
      N.Conn.recv(s, buf, s2 => +b2 => Rtmp.shaking(p, K.Rtmp.shake(b2), b2, s2, u, w,
        path, ms))
    case 1n+p K.Shake{c2, +rest}:
      N.Conn.send(s, B.Bytes.cat(c2, B.Bytes.cat(K.Rtmp.chunk_size(K.Rtmp.out()),
        K.Rtmp.connect(K.Where.app(w), C.Url.host.of(u), C.Url.port.of(u)))), s2 =>
        Rtmp.await(1000000n, K.Rtmp.event(K.Dec.new(), rest), K.Dec.new(), rest, s2,
          s3 => st3 => b3 => _ => Rtmp.connected(s3, st3, b3, K.Where.stream(w), path,
            ms)))

def Rtmp.hello(r: Result<&1, &1, U32 & String, Socket>, seed: U32, +u: C.Url,
  path: String, ms: U32) -> IO(N.Out()):
  match r:
    case Fail{e}:
      (code, msg) = e
      IO.pure(N.Out(), Fail{(code, "connect: " ++ msg)})
    case Done{s}:
      N.Conn.send(s, K.Rtmp.hello(seed), s2 => Rtmp.shaking(4096n, K.Early{}, Nil{}, s2,
        u, K.Where.of(C.Url.path(u)), path, ms))

def Rtmp.go(bad: Bool, +u: C.Url, path: String, ms: U32) -> IO(N.Out()):
  match bad:
    case True{}:
      IO.pure(N.Out(), Fail{(0, "not an RTMP URL (rtmp://host[:port]/app/stream)")})
    case False{}:
      do IO<N.Out()>:
        seed : U32 <- IO.try(U32, IO.random_u32())
        r : Result<&1, &1, U32 & String, Socket> <- TCP.connect(C.Url.host.of(u),
          C.Url.port.of(u))
        Rtmp.hello(r, seed, u, path, ms)

def Rtmp.pull.url(+u: C.Url, path: String, ms: U32) -> IO(N.Out()):
  Rtmp.go(String.is_empty(C.Url.host.of(u)), u, path, ms)

# Play the stream of an RTMP URL into an FLV file for ms milliseconds.
def Rtmp.pull(url: String, path: String, ms: U32) -> IO(N.Out()):
  Rtmp.pull.url(C.Url.of(url, "rtmp://", 1935), path, ms)
