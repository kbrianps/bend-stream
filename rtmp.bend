# RTMP client: a session that gives a stream's audio and video.
#
#   s <- Rtmp.open(E.Opts.new("rtmp://server/app/stream"))
#   (s, tag) <- Rtmp.next(s)      as many times as wanted
#   Rtmp.close(s)
#
# What goes on the wire:
#
#   C: C0 C1                    S: S0 S1 S2          C: C2
#   C: Set Chunk Size, connect(app)                  S: _result
#   C: createStream                                  S: _result, the stream id
#   C: play(stream), Set Buffer Length               S: onStatus Play.Start
#   S: data (the metadata), audio and video messages
#
# A tag is one of those messages, in the form FLV keeps them: written
# one after the other after a header they make an FLV file, and
# flv.bend takes the frames out of them. This file is the IO; the bytes
# and their meaning are in rtmp_core.bend and amf.bend, which are pure.
#
# rtmps:// is RTMP under TLS. A login goes in the URL's query, as the
# servers that use one expect (rtmp://host/app?user=...&pass=...).
import Base
import ./bytes.bend as B
import ./amf.bend as A
import ./rtmp_core.bend as K
import ./rtsp_core.bend as C
import ./conn.bend as N
import ./opts.bend as E

# An open session: the connection and what was read past the last tag,
# the chunk streams' state, how long to wait for the server (ms), the
# bytes received and how many of them were acknowledged.
type Sess is Type:
  Sess{sock: Socket, buf: List<&2, U32>, dec: K.Dec, wait: U32, rx: U32, acked: U32}

# How the steps inside end: a session opened, or a tag read.
type End is Type:
  Opened{s: Sess}
  Next{s: Sess, t: K.Tag}

def Fin() -> Type:
  N.Res(End)

# Reading tags
# ------------

# With nothing whole in the buffer: an acknowledgement when a megabyte
# came since the last (a server may stop sending without them), and
# more bytes.
def Rtmp.more(due: Bool, buf: List<&2, U32>, s: Socket, wait: U32, +rx: U32, acked: U32,
  again: Socket -> List<&2, U32> -> U32 -> U32 -> IO(Fin())) -> IO(Fin()):
  match due:
    case True{}:
      N.Conn.send(End, s, K.Rtmp.ack(rx), s2 => N.Conn.recv.n(End, s2, wait, buf,
        s3 => b3 => n => again(s3, b3, U32.add(rx, n), rx)))
    case False{}:
      N.Conn.recv.n(End, s, wait, buf, s3 => b3 => n => again(s3, b3, U32.add(rx, n), acked))

# Until a tag: a media message given, a ping answered, the rest passed
# over.
def Rtmp.loop(fuel: Nat, e: K.Ev, +st: K.Dec, buf: List<&2, U32>, s: Socket, +wait: U32,
  +rx: U32, +acked: U32) -> IO(Fin()):
  match fuel e:
    case 0n _:
      N.Conn.fail(End, s, E.Garbled{}, 0, "no media in a very long stream of messages")
    case 1n+q K.Media{typ, ts, payload, st2, rest}:
      IO.pure(Fin(), Done{Next{Sess{s, rest, st2, wait, rx, acked}, K.Tag{typ, ts, payload}}})
    case 1n+q K.Ping{data, +st2, +rest}:
      N.Conn.send(End, s, K.Rtmp.pong(data), s2 => Rtmp.loop(q, K.Rtmp.event(st2, rest),
        st2, rest, s2, wait, rx, acked))
    case 1n+q K.Over{_, _}:
      N.Conn.fail(End, s, E.Ended{}, 0, "the publisher stopped")
    case 1n+q K.Refused{msg, _, _}:
      N.Conn.fail(End, s, E.NoStream{}, 0, msg)
    case 1n+q K.Skip{+st2, +rest}:
      Rtmp.loop(q, K.Rtmp.event(st2, rest), st2, rest, s, wait, rx, acked)
    case 1n+q K.Result{_, +st2, +rest}:
      Rtmp.loop(q, K.Rtmp.event(st2, rest), st2, rest, s, wait, rx, acked)
    case 1n+q K.Error{_, +st2, +rest}:
      Rtmp.loop(q, K.Rtmp.event(st2, rest), st2, rest, s, wait, rx, acked)
    case 1n+q K.Wait{}:
      Rtmp.more((U32.sub(rx, acked) >= 1000000 : U32), buf, s, wait, rx, acked,
        s3 => +b3 => +rx3 => +ack3 =>
          Rtmp.loop(q, K.Rtmp.event(st, b3), st, b3, s3, wait, rx3, ack3))

# Setting up
# ----------

# The answer to a command: the next _result, with pings answered and
# everything else passed over meanwhile.
def Rtmp.await(fuel: Nat, e: K.Ev, +st: K.Dec, +buf: List<&2, U32>, s: Socket,
  +wait: U32, k: Socket -> K.Dec -> List<&2, U32> -> List<&2, A.Tok> -> IO(Fin())) ->
  IO(Fin()):
  match fuel e:
    case 0n _:
      N.Conn.fail(End, s, E.Garbled{}, 0, "no answer to a command")
    case 1n+p K.Result{ts, st2, rest}:
      k(s, st2, rest, ts)
    case 1n+p K.Error{msg, _, _}:
      N.Conn.fail(End, s, E.Refused{}, 0, msg)
    case 1n+p K.Refused{msg, _, _}:
      N.Conn.fail(End, s, E.Refused{}, 0, msg)
    case 1n+p K.Ping{data, +st2, +rest}:
      N.Conn.send(End, s, K.Rtmp.pong(data), s2 =>
        Rtmp.await(p, K.Rtmp.event(st2, rest), st2, rest, s2, wait, k))
    case 1n+p K.Skip{+st2, +rest}:
      Rtmp.await(p, K.Rtmp.event(st2, rest), st2, rest, s, wait, k)
    case 1n+p K.Over{+st2, +rest}:
      Rtmp.await(p, K.Rtmp.event(st2, rest), st2, rest, s, wait, k)
    case 1n+p K.Media{_, _, _, +st2, +rest}:
      Rtmp.await(p, K.Rtmp.event(st2, rest), st2, rest, s, wait, k)
    case 1n+p K.Wait{}:
      N.Conn.recv(End, s, wait, buf, s2 => +b2 =>
        Rtmp.await(p, K.Rtmp.event(st, b2), st, b2, s2, wait, k))

# The stream is created (its id is the result's fourth value): play,
# and the session is open.
def Rtmp.created(s: Socket, st: K.Dec, buf: List<&2, U32>, ts: List<&2, A.Tok>,
  stream: String, wait: U32) -> IO(Fin()):
  N.Conn.send(End, s, K.Rtmp.play(A.Amf.number(A.Amf.at(ts, 3n)), stream), s2 =>
    IO.pure(Fin(), Done{Opened{Sess{s2, buf, st, wait, 0, 0}}}))

# Connected to the application: create a stream.
def Rtmp.connected(s: Socket, +st: K.Dec, +buf: List<&2, U32>, stream: String,
  +wait: U32) -> IO(Fin()):
  N.Conn.send(End, s, K.Rtmp.create(), s2 => Rtmp.await(1000000n, K.Rtmp.event(st, buf),
    st, buf, s2, wait, s3 => st3 => b3 => ts => Rtmp.created(s3, st3, b3, ts, stream,
      wait)))

# The handshake's answer is here (or more of it is read): C2, our chunk
# size, and connect.
def Rtmp.shaking(fuel: Nat, h: K.Shake, buf: List<&2, U32>, s: Socket, +u: C.Url,
  +w: K.Where, +wait: U32) -> IO(Fin()):
  match fuel h:
    case 0n _:
      N.Conn.fail(End, s, E.Garbled{}, 0, "the handshake did not end")
    case 1n+p K.Early{}:
      N.Conn.recv(End, s, wait, buf, s2 => +b2 =>
        Rtmp.shaking(p, K.Rtmp.shake(b2), b2, s2, u, w, wait))
    case 1n+p K.Shake{c2, +rest}:
      N.Conn.send(End, s, B.Bytes.cat(c2, B.Bytes.cat(K.Rtmp.chunk_size(K.Rtmp.out()),
        K.Rtmp.connect(K.Where.app(w), C.Url.host.of(u), C.Url.port.of(u)))), s2 =>
        Rtmp.await(1000000n, K.Rtmp.event(K.Dec.new(), rest), K.Dec.new(), rest, s2, wait,
          s3 => st3 => b3 => _ => Rtmp.connected(s3, st3, b3, K.Where.stream(w), wait)))

def Rtmp.go(bad: Bool, +u: C.Url, tls: Bool, o: E.Opts) -> IO(Fin()):
  match bad:
    case True{}:
      IO.pure(Fin(), Fail{E.Err{E.BadUrl{}, 0,
        "not an RTMP URL (rtmp://host[:port]/app/stream)"}})
    case False{}:
      E.Opts{_, _, _, +wait, _, ca} = o
      do IO<Fin()>:
        seed : U32 <- IO.try(U32, IO.random_u32())
        N.Conn.open(End, C.Url.host.of(u), C.Url.port.of(u), tls, ca, s =>
          N.Conn.send(End, s, K.Rtmp.hello(seed), s2 => Rtmp.shaking(4096n, K.Early{},
            Nil{}, s2, u, K.Where.of(C.Url.path(u)), wait)))

def Rtmp.start.url(+u: C.Url, tls: Bool, o: E.Opts) -> IO(Fin()):
  Rtmp.go(String.is_empty(C.Url.host.of(u)), u, tls, o)

def Rtmp.start.tls(+tls: Bool, url: String, o: E.Opts) -> IO(Fin()):
  Rtmp.start.url(C.Url.of(url, Bool.pick(String, tls, "rtmps://", "rtmp://"),
    Bool.pick(U32, tls, 443, 1935)), tls, o)

def Rtmp.start(+o: E.Opts) -> IO(Fin()):
  E.Opts{+url, _, _, _, _, _} = o
  Rtmp.start.tls(String.starts_with(String.to_lower(url), "rtmps://"), url, o)

# The public face
# ---------------

def Opened() -> Type:
  Result<&1, &1, E.Err, Sess>

def Read() -> Type:
  Result<&1, &1, E.Err, Sess & K.Tag>

def Rtmp.open.end(r: Fin()) -> Opened():
  match r:
    case Done{Opened{s}}:
      Done{s}
    case Done{Next{_, _}}:
      Fail{E.Err{E.Garbled{}, 0, "a tag before the session was open"}}
    case Fail{e}:
      Fail{e}

def Rtmp.next.end(r: Fin()) -> Read():
  match r:
    case Done{Next{s, t}}:
      Done{(s, t)}
    case Done{Opened{_}}:
      Fail{E.Err{E.Garbled{}, 0, "the session opened twice"}}
    case Fail{e}:
      Fail{e}

# Open a session: connect, shake hands, connect to the application and
# ask to play the stream. On a failure the connection is already closed.
def Rtmp.open(o: E.Opts) -> IO(Opened()):
  do IO<Opened()>:
    r : Fin() <- Rtmp.start(o)
    IO.pure(Opened(), Rtmp.open.end(r))

def Rtmp.reopen.end(r: Opened(), rest: IO(Opened())) -> IO(Opened()):
  match r:
    case Done{s}:
      IO.pure(Opened(), Done{s})
    case Fail{+e}:
      Bool.pick(IO(Opened()), E.Err.lasting(e), IO.pure(Opened(), Fail{e}), rest)

def Rtmp.reopen.go(late: Bool, o: E.Opts, rest: IO(Opened())) -> IO(Opened()):
  match late:
    case True{}:
      IO.pure(Opened(), Fail{E.Err{E.Silent{}, 0, "the stream did not come back in time"}})
    case False{}:
      do IO<Opened()>:
        r : Opened() <- Rtmp.open(o)
        Rtmp.reopen.end(r, rest)

def Rtmp.reopen.at(tries: Nat, +o: E.Opts, +until: Nat, +delay: U32) -> IO(Opened()):
  match tries:
    case 0n:
      IO.pure(Opened(), Fail{E.Err{E.Silent{}, 0, "the stream did not come back"}})
    case 1n+p:
      rest = Rtmp.reopen.at(p, o, until, U32.min((delay * 2 : U32), 15000))
      do IO<Opened()>:
        u : Unit <- IO.sleep(delay)
        now : Nat <- IO.now()
        Rtmp.reopen.go(Nat.is_le(until, now), o, rest)

# Open again a session that was lost: it waits half a second, tries,
# and doubles the wait (up to 15 s) after each failure, until the
# session opens, an error says it never will (E.Err.lasting), or the
# clock (IO.now's, ms) reaches until.
def Rtmp.reopen(o: E.Opts, until: Nat) -> IO(Opened()):
  Rtmp.reopen.at(100000n, o, until, 500)

# The next tag, and the session to go on with. It waits for the server
# at most the options' wait; on a failure (or at the stream's end, which
# comes as the reason Ended) the connection is already closed.
def Rtmp.next(x: Sess) -> IO(Read()):
  Sess{s, +buf, +dec, wait, rx, acked} = x
  do IO<Read()>:
    r : Fin() <- Rtmp.loop(4000000000n, K.Rtmp.event(dec, buf), dec, buf, s, wait, rx,
      acked)
    IO.pure(Read(), Rtmp.next.end(r))

# End the session: the connection closed.
def Rtmp.close(x: Sess) -> IO(Unit):
  Sess{s, _, _, _, _, _} = x
  N.Conn.shut(s, Nil{}, 0)
