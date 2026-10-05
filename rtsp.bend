# RTSP client (RFC 2326): pull a camera's video into a file.
#
#   C: DESCRIBE url            S: 401, WWW-Authenticate   (if it wants a login)
#   C: DESCRIBE url, Authorization   S: 200, the SDP
#   C: SETUP track, Transport: RTP/AVP/TCP;interleaved=0-1   S: 200, Session
#   C: PLAY url, Session       S: 200
#   S: $ 0 <len> <RTP packet> ...        (on the same connection)
#   C: GET_PARAMETER url, Session        (every 25 s, so the session lives)
#   C: TEARDOWN url, Session
#
# The video's NAL units are rebuilt from the RTP packets and written in
# Annex B form, the parameter sets the description announces first. This
# file is the IO; what to say and what a reply means is in rtsp_core.bend
# and rtp.bend, which are pure.
#
# Over Base's TCP only: the host is an IPv4 address (Base resolves no
# names), there is no TLS (no rtsps), and a read has no timeout (a
# server that goes silent is waited on).
import Base
import ./bytes.bend as B
import ./rtsp_core.bend as C
import ./rtp.bend as R
import ./conn.bend as N

# What the loop needs to know: H.265 or H.264, the payload type, when to
# stop (IO.now's clock, ms), and how to sign a request.
type Cfg is Data:
  Cfg{h265: Bool, pt: U32, until: Nat, uri: String, session: String, chal: C.Chal,
    user: String, pass: String, cnonce: String, codec: String}

def Cfg.uri(c: Cfg) -> String:
  Cfg{_, _, _, x, _, _, _, _, _, _} = c
  x

def Cfg.until(c: Cfg) -> Nat:
  Cfg{_, _, x, _, _, _, _, _, _, _} = c
  x

def Cfg.codec(c: Cfg) -> String:
  Cfg{_, _, _, _, _, _, _, _, _, x} = c
  x

# A request of this session, signed.
def Cfg.request(c: Cfg, method: String, cseq: U32) -> String:
  Cfg{_, _, _, +uri, session, chal, user, pass, cnonce, _} = c
  C.Rtsp.signed(chal, user, pass, method, uri, cseq, cnonce, session, Nil{})

# The connection
# --------------

# The next reply, the interleaved packets before it skipped. Each turn
# takes a message off the buffer or reads more, so the fuel bounds it.
def Rtsp.reply(fuel: Nat, m: C.Msg, buf: List<&2, U32>, s: Socket,
  k: Socket -> List<&2, U32> -> C.Resp -> IO(N.Out())) -> IO(N.Out()):
  match fuel m:
    case _ C.Reply{r, rest}:
      k(s, rest, r)
    case 1n+p C.Frame{_, _, +rest}:
      Rtsp.reply(p, C.Rtsp.demux(rest), rest, s, k)
    case 1n+p C.Need{}:
      N.Conn.recv(s, buf, s2 => +b2 => Rtsp.reply(p, C.Rtsp.demux(b2), b2, s2, k))
    case _ _:
      N.Conn.fail(s, 0, "the server sent something that is not RTSP")

# Send a request and read its reply.
def Rtsp.ask(s: Socket, +buf: List<&2, U32>, req: String,
  k: Socket -> List<&2, U32> -> C.Resp -> IO(N.Out())) -> IO(N.Out()):
  do IO<N.Out()>:
    m : N.Sent() <- TCP.send(s, req)
    N.Conn.sent(m, s2 => Rtsp.reply(4096n, C.Rtsp.demux(buf), buf, s2, k))

# The stream
# ----------

def Rtsp.units.pt(mine: Bool, h265: Bool, payload: List<&2, U32>, st: R.Dep) -> R.Out:
  match mine h265:
    case False{} _:
      R.Out{Nil{}, st}
    case True{} True{}:
      R.H265.push(st, payload)
    case True{} False{}:
      R.H264.push(st, payload)

# The units a channel's packet completes: only channel 0's RTP packets
# of the video's payload type count.
def Rtsp.units.of(rtp: R.Rtp, +h265: Bool, +pt: U32, st: R.Dep) -> R.Out:
  match rtp:
    case R.NoRtp{}:
      R.Out{Nil{}, st}
    case R.Rtp{_, p, _, _, _, payload}:
      Rtsp.units.pt(U32.is_eq(p, pt), h265, payload, st)

def Rtsp.units(video: Bool, data: List<&2, U32>, h265: Bool, pt: U32, st: R.Dep) ->
  R.Out:
  match video:
    case True{}:
      Rtsp.units.of(R.Rtp.of(data), h265, pt, st)
    case False{}:
      R.Out{Nil{}, st}

def Cfg.units(c: Cfg, chan: U32, data: List<&2, U32>, st: R.Dep) -> R.Out:
  Cfg{h265, pt, _, _, _, _, _, _, _, _} = c
  Rtsp.units(U32.is_zero(chan), data, h265, pt, st)

def Rtsp.closed(m: N.Sent(), f: File, r: N.Out()) -> IO(N.Out()):
  (s, _) = m
  do IO<N.Out()>:
    File.close(f)
    Socket.close(s)
    IO.pure(N.Out(), r)

# TEARDOWN (its reply is not waited for), then both ends closed.
def Rtsp.finish(s: Socket, f: File, c: Cfg, cseq: U32, r: N.Out()) -> IO(N.Out()):
  do IO<N.Out()>:
    m : N.Sent() <- TCP.send(s, Cfg.request(c, "TEARDOWN", cseq))
    Rtsp.closed(m, f, r)

def Rtsp.alive(m: N.Sent(), k: Socket -> IO(N.Out())) -> IO(N.Out()):
  N.Conn.sent(m, k)

def Rtsp.frame(o: R.Out, s: Socket, f: File, p: N.Pulled,
  k: Socket -> File -> R.Dep -> N.Pulled -> IO(N.Out())) -> IO(N.Out()):
  R.Out{+nals, st} = o
  +bs = R.Nal.annexb(nals)
  N.Conn.save(bs, s, f, s2 => f2 => k(s2, f2, st,
    N.Pulled.add(p, U32.from_nat(List.length(&2, List<&2, U32>, nals)), B.Bytes.len(bs))))

# With nothing left in the buffer: stop when the time is up; else, a
# keep-alive when one is due (every 25 s; servers time a session out at
# 60 by default, RFC 2326 12.37), and more bytes.
def Rtsp.wait(up: Bool, due: Bool, s: Socket, f: File, +c: Cfg, +cseq: U32,
  p: N.Pulled, more: Socket -> File -> Bool -> N.Pulled -> IO(N.Out())) -> IO(N.Out()):
  match up due:
    case True{} _:
      Rtsp.finish(s, f, c, cseq, Done{p})
    case False{} True{}:
      do IO<N.Out()>:
        m : N.Sent() <- TCP.send(s, Cfg.request(c, "GET_PARAMETER", cseq))
        Rtsp.alive(m, s2 => more(s2, f, True{}, p))
    case False{} False{}:
      more(s, f, False{}, p)

def Rtsp.pinged(yes: Bool, +now: Nat, ka: Nat) -> Nat:
  match yes:
    case True{}:
      Nat.add(now, 25000n)
    case False{}:
      ka

# With the time read: stop, ping, or read more, and around again.
def Rtsp.turn(+now: Nat, buf: List<&2, U32>, s: Socket, f: File, +c: Cfg, +ka: Nat,
  +cseq: U32, p: N.Pulled,
  again: List<&2, U32> -> Socket -> File -> Nat -> U32 -> N.Pulled -> IO(N.Out())) ->
  IO(N.Out()):
  Rtsp.wait(Nat.is_le(Cfg.until(c), now), Nat.is_le(ka, now), s, f, c, cseq, p,
    s2 => f2 => +pinged => p2 => N.Conn.recv(s2, buf, s3 => b3 =>
      again(b3, s3, f2, Rtsp.pinged(pinged, now, ka),
        U32.add(cseq, Bool.pick(U32, pinged, 1, 0)), p2)))

# The loop: a packet off the buffer into the file, a reply (to a
# keep-alive) dropped, and more bytes when the buffer has no whole
# message. ka: when the next keep-alive is due.
def Rtsp.loop(fuel: Nat, m: C.Msg, buf: List<&2, U32>, s: Socket, f: File,
  st: R.Dep, +c: Cfg, +ka: Nat, +cseq: U32, p: N.Pulled) -> IO(N.Out()):
  match fuel m:
    case 0n _:
      Rtsp.finish(s, f, c, cseq, Done{p})
    case 1n+q C.Frame{chan, data, +rest}:
      Rtsp.frame(Cfg.units(c, chan, data, st), s, f, p, s2 => f2 => st2 => p2 =>
        N.Conn.due(Cfg.until(c), s2, f2, p2,
          s3 => f3 => p3 => Rtsp.finish(s3, f3, c, cseq, Done{p3}),
          s3 => f3 => p3 => Rtsp.loop(q, C.Rtsp.demux(rest), rest, s3, f3, st2, c, ka,
            cseq, p3)))
    case 1n+q C.Reply{_, +rest}:
      Rtsp.loop(q, C.Rtsp.demux(rest), rest, s, f, st, c, ka, cseq, p)
    case 1n+q C.Bad{}:
      Rtsp.finish(s, f, c, cseq, Fail{(0, "lost the stream's framing")})
    case 1n+q C.Need{}:
      do IO<N.Out()>:
        now : Nat <- IO.now()
        Rtsp.turn(now, buf, s, f, c, ka, cseq, p, +b3 => s3 => f3 => +ka3 => +n3 => p3 =>
          Rtsp.loop(q, C.Rtsp.demux(b3), b3, s3, f3, st, c, ka3, n3, p3))

# Setting up
# ----------

def Rtsp.play.got(ok: Bool, r: C.Resp, s: Socket, +buf: List<&2, U32>, f: File,
  +c: Cfg, +now: Nat, head: U32) -> IO(N.Out()):
  match ok:
    case True{}:
      Rtsp.loop(4000000000n, C.Rtsp.demux(buf), buf, s, f, R.Dep.new(), c,
        Nat.add(now, 25000n), 5, N.Pulled{0, 0, head, Cfg.codec(c)})
    case False{}:
      do IO<N.Out()>:
        File.close(f)
        N.Conn.fail(s, C.Resp.code(r), "PLAY was refused")

# PLAY, once the file is open and the announced parameter sets are in it.
def Rtsp.play(s: Socket, buf: List<&2, U32>, f: File, +c: Cfg, +now: Nat,
  head: U32) -> IO(N.Out()):
  Rtsp.ask(s, buf, Cfg.request(c, "PLAY", 4), s2 => b2 => +r =>
    Rtsp.play.got(U32.is_eq(C.Resp.code(r), 200), r, s2, b2, f, c, now, head))

def Rtsp.opened(r: Result<&1, &1, U32 & String, File>, s: Socket,
  buf: List<&2, U32>, +c: Cfg, +sets: List<&2, U32>, now: Nat) -> IO(N.Out()):
  match r:
    case Fail{e}:
      (code, msg) = e
      N.Conn.fail(s, code, "cannot write the file: " ++ msg)
    case Done{f}:
      N.Conn.save(sets, s, f, s2 => f2 => Rtsp.play(s2, buf, f2, c, now, B.Bytes.len(sets)))

def Rtsp.start.at(+now: Nat, f: Result<&1, &1, U32 & String, File>, s: Socket,
  buf: List<&2, U32>, ms: U32, cfg: Nat -> Cfg, sets: List<&2, U32>) -> IO(N.Out()):
  Rtsp.opened(f, s, buf, cfg(Nat.add(now, U32.to_nat(ms))), sets, now)

# The session is set up: open the file, note the time, play.
def Rtsp.start(s: Socket, buf: List<&2, U32>, path: String, +ms: U32,
  cfg: Nat -> Cfg, sets: List<&2, U32>) -> IO(N.Out()):
  do IO<N.Out()>:
    now : Nat <- IO.now()
    f : Result<&1, &1, U32 & String, File> <- File.open(path, "w")
    Rtsp.start.at(now, f, s, buf, ms, cfg, sets)

def Rtsp.setup.got(ok: Bool, +r: C.Resp, s: Socket, buf: List<&2, U32>,
  path: String, ms: U32, +m: C.Media, uri: String, chal: C.Chal, +u: C.Url,
  cnonce: String) -> IO(N.Out()):
  match ok:
    case True{}:
      +h265 = String.eq(C.Media.codec(m), "H265")
      +pt = C.Media.pt(m)
      +session = C.Rtsp.session(C.Resp.get(r, "session"))
      +codec = C.Media.codec(m)
      Rtsp.start(s, buf, path, ms, until => Cfg{h265, pt, until, uri, session, chal,
        C.Url.user(u), C.Url.pass(u), cnonce, codec},
        R.Nal.annexb(C.Sdp.sprops(C.Media.fmtp(m))))
    case False{}:
      N.Conn.fail(s, C.Resp.code(r), "SETUP was refused (the server may not do "
        ++ "RTP over the RTSP connection)")

# SETUP for the video's track, RTP interleaved on channels 0 and 1.
def Rtsp.setup(problem: String, s: Socket, buf: List<&2, U32>, path: String,
  ms: U32, +m: C.Media, +base: String, +sdp: C.Sdp, +chal: C.Chal, +u: C.Url,
  +cnonce: String) -> IO(N.Out()):
  match problem:
    case SCon{h, t}:
      N.Conn.fail(s, 0, SCon{h, t})
    case SNil{}:
      Rtsp.ask(s, buf, C.Rtsp.signed(chal, C.Url.user(u), C.Url.pass(u), "SETUP",
        C.Rtsp.control(base, C.Media.control(m)), 3, cnonce, "",
        [C.Hdr{"Transport", "RTP/AVP/TCP;unicast;interleaved=0-1"}]),
        s2 => b2 => +r => Rtsp.setup.got(U32.is_eq(C.Resp.code(r), 200), r, s2, b2,
          path, ms, m, C.Rtsp.control(base, C.Sdp.session(sdp)), chal, u, cnonce))

# The description is here: its video stream, and the URL its control
# attributes are relative to (Content-Base, else the request's).
def Rtsp.described(+r: C.Resp, s: Socket, buf: List<&2, U32>, path: String, ms: U32,
  +uri: String, chal: C.Chal, u: C.Url, cnonce: String) -> IO(N.Out()):
  +sdp = C.Sdp.of(B.Bytes.text(C.Resp.body(r)))
  +m = C.Sdp.media(sdp, "video")
  +cb = C.Resp.get(r, "content-base")
  Rtsp.setup(C.Sdp.problem(m), s, buf, path, ms, m,
    Bool.pick(String, String.is_empty(cb), uri, cb), sdp, chal, u, cnonce)

def Rtsp.describe.req(chal: C.Chal, +u: C.Url, +uri: String, cseq: U32,
  cnonce: String) -> String:
  C.Rtsp.signed(chal, C.Url.user(u), C.Url.pass(u), "DESCRIBE", uri, cseq, cnonce, "",
    [C.Hdr{"Accept", "application/sdp"}])

def Rtsp.again.got(ok: Bool, +r: C.Resp, s: Socket, buf: List<&2, U32>,
  path: String, ms: U32, uri: String, chal: C.Chal, u: C.Url, cnonce: String) ->
  IO(N.Out()):
  match ok:
    case True{}:
      Rtsp.described(r, s, buf, path, ms, uri, chal, u, cnonce)
    case False{}:
      N.Conn.fail(s, C.Resp.code(r), Bool.pick(String, U32.is_eq(C.Resp.code(r), 401),
        "wrong user or password", "DESCRIBE was refused"))

# DESCRIBE again, answering the challenge; a server with none we can
# answer ends it.
def Rtsp.again(none: Bool, s: Socket, buf: List<&2, U32>, path: String, ms: U32,
  +uri: String, +chal: C.Chal, +u: C.Url, +cnonce: String) -> IO(N.Out()):
  match none:
    case True{}:
      N.Conn.fail(s, 401, "the server wants a login this client cannot give "
        ++ "(Basic, or Digest with MD5)")
    case False{}:
      Rtsp.ask(s, buf, Rtsp.describe.req(chal, u, uri, 2, cnonce), s2 => b2 => +r =>
        Rtsp.again.got(U32.is_eq(C.Resp.code(r), 200), r, s2, b2, path, ms, uri,
          chal, u, cnonce))

def Rtsp.again.with(+chal: C.Chal, s: Socket, buf: List<&2, U32>, path: String,
  ms: U32, uri: String, u: C.Url, cnonce: String) -> IO(N.Out()):
  Rtsp.again(String.is_empty(C.Chal.scheme(chal)), s, buf, path, ms, uri, chal, u,
    cnonce)

def Rtsp.first.got(ok: Bool, login: Bool, +r: C.Resp, s: Socket, buf: List<&2, U32>,
  path: String, ms: U32, uri: String, u: C.Url, cnonce: String) -> IO(N.Out()):
  match ok login:
    case True{} _:
      Rtsp.described(r, s, buf, path, ms, uri, C.Chal.none(), u, cnonce)
    case False{} True{}:
      Rtsp.again.with(C.Chal.pick(C.Chal.all(C.Hdr.all(C.Resp.headers(r),
        "www-authenticate"))), s, buf, path, ms, uri, u, cnonce)
    case False{} False{}:
      N.Conn.fail(s, C.Resp.code(r), "DESCRIBE was refused")

# DESCRIBE with no login first: a 401 names the challenge to answer.
def Rtsp.describe(s: Socket, path: String, ms: U32, +u: C.Url, +cnonce: String) ->
  IO(N.Out()):
  +uri = C.Url.show(u, "rtsp://")
  Rtsp.ask(s, Nil{}, Rtsp.describe.req(C.Chal.none(), u, uri, 1, cnonce),
    s2 => b2 => +r => Rtsp.first.got(U32.is_eq(C.Resp.code(r), 200),
      U32.is_eq(C.Resp.code(r), 401), r, s2, b2, path, ms, uri, u, cnonce))

def Rtsp.connected(r: Result<&1, &1, U32 & String, Socket>, path: String, ms: U32,
  u: C.Url, cnonce: String) -> IO(N.Out()):
  match r:
    case Fail{e}:
      (code, msg) = e
      IO.pure(N.Out(), Fail{(code, "connect: " ++ msg)})
    case Done{s}:
      Rtsp.describe(s, path, ms, u, cnonce)

def Rtsp.go(bad: Bool, +u: C.Url, path: String, ms: U32) -> IO(N.Out()):
  match bad:
    case True{}:
      IO.pure(N.Out(), Fail{(0, "not an RTSP URL (rtsp://[user:pass@]host[:port]/path)")})
    case False{}:
      do IO<N.Out()>:
        a : U32 <- IO.try(U32, IO.random_u32())
        b : U32 <- IO.try(U32, IO.random_u32())
        r : Result<&1, &1, U32 & String, Socket> <- TCP.connect(C.Url.host.of(u),
          C.Url.port.of(u))
        Rtsp.connected(r, path, ms, u, U32.show(a) ++ U32.show(b))

def Rtsp.pull.url(+u: C.Url, path: String, ms: U32) -> IO(N.Out()):
  Rtsp.go(String.is_empty(C.Url.host.of(u)), u, path, ms)

# Pull the video of an RTSP URL into a file for ms milliseconds.
def Rtsp.pull(url: String, path: String, ms: U32) -> IO(N.Out()):
  Rtsp.pull.url(C.Url.of(url, "rtsp://", 554), path, ms)

