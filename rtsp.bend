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
# Annex B form, the parameter sets the description announces first; or,
# to a file named .ts, as MPEG-TS with each picture's time (mux.bend). This
# file is the IO; what to say and what a reply means is in rtsp_core.bend
# and rtp.bend, which are pure.
#
# The sockets are net.c's (see conn.bend): the host may be a name,
# rtsps:// is RTSP under TLS, and a server silent for 10 seconds ends
# the pull.
import Base
import ./bytes.bend as B
import ./rtsp_core.bend as C
import ./rtp.bend as R
import ./conn.bend as N
import ./mux.bend as M
import ./audio.bend as U

# What the loop needs to know: H.265 or H.264, the payload type, when to
# stop (IO.now's clock, ms), and how to sign a request.
type Cfg is Data:
  Cfg{h265: Bool, pt: U32, until: Nat, uri: String, session: String, chal: C.Chal,
    user: String, pass: String, cnonce: String, codec: String, every: Nat}

def Cfg.uri(c: Cfg) -> String:
  Cfg{_, _, _, x, _, _, _, _, _, _, _} = c
  x

def Cfg.until(c: Cfg) -> Nat:
  Cfg{_, _, x, _, _, _, _, _, _, _, _} = c
  x

def Cfg.every(c: Cfg) -> Nat:
  Cfg{_, _, _, _, _, _, _, _, _, _, x} = c
  x

def Cfg.codec(c: Cfg) -> String:
  Cfg{_, _, _, _, _, _, _, _, _, x, _} = c
  x

# A request of this session, signed.
def Cfg.request(c: Cfg, method: String, cseq: U32) -> String:
  Cfg{_, _, _, +uri, session, chal, user, pass, cnonce, _, _} = c
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
  N.Conn.say(s, req, s2 => Rtsp.reply(4096n, C.Rtsp.demux(buf), buf, s2, k))

# The stream
# ----------

# What a channel's packet gives the file: channel 0 is the video's RTP,
# channel 2 the audio's; 1 and 3 are their RTCP, which is not read.
def Rtsp.put(rtp: Bool, sound: Bool, data: List<&2, U32>, pt: U32, st: M.Mux) -> M.Put:
  match rtp:
    case True{}:
      M.Mux.packet(R.Rtp.of(data), pt, sound, st)
    case False{}:
      M.Put{Nil{}, 0, st}

def Cfg.put(c: Cfg, +chan: U32, data: List<&2, U32>, st: M.Mux) -> M.Put:
  Cfg{_, pt, _, _, _, _, _, _, _, _, _} = c
  Rtsp.put(U32.is_zero(chan) || U32.is_eq(chan, 2), U32.is_eq(chan, 2), data, pt, st)

def Cfg.h265(c: Cfg) -> Bool:
  Cfg{x, _, _, _, _, _, _, _, _, _, _} = c
  x

# TEARDOWN (its reply is not waited for), then both ends closed.
def Rtsp.finish(s: Socket, f: File, c: Cfg, cseq: U32, r: N.Out()) -> IO(N.Out()):
  N.Conn.bye(s, Cfg.request(c, "TEARDOWN", cseq), f, r)

def Rtsp.frame(o: M.Put, s: Socket, f: File, p: N.Pulled,
  k: Socket -> File -> M.Mux -> N.Pulled -> IO(N.Out())) -> IO(N.Out()):
  M.Put{+bs, units, st} = o
  N.Conn.save(bs, s, f, s2 => f2 => k(s2, f2, st, N.Pulled.add(p, units, B.Bytes.len(bs))))

# With nothing left in the buffer: stop when the time is up; else, a
# keep-alive when one is due (at half the session's timeout), and more
# bytes.
def Rtsp.wait(up: Bool, due: Bool, s: Socket, f: File, +c: Cfg, +cseq: U32,
  p: N.Pulled, more: Socket -> File -> Bool -> N.Pulled -> IO(N.Out())) -> IO(N.Out()):
  match up due:
    case True{} _:
      Rtsp.finish(s, f, c, cseq, Done{p})
    case False{} True{}:
      N.Conn.say(s, Cfg.request(c, "GET_PARAMETER", cseq), s2 => more(s2, f, True{}, p))
    case False{} False{}:
      more(s, f, False{}, p)

def Rtsp.pinged(yes: Bool, +now: Nat, ka: Nat, every: Nat) -> Nat:
  match yes:
    case True{}:
      Nat.add(now, every)
    case False{}:
      ka

# With the time read: stop, ping, or read more, and around again.
def Rtsp.turn(+now: Nat, buf: List<&2, U32>, s: Socket, f: File, +c: Cfg, +ka: Nat,
  +cseq: U32, p: N.Pulled,
  again: List<&2, U32> -> Socket -> File -> Nat -> U32 -> N.Pulled -> IO(N.Out())) ->
  IO(N.Out()):
  Rtsp.wait(Nat.is_le(Cfg.until(c), now), Nat.is_le(ka, now), s, f, c, cseq, p,
    s2 => f2 => +pinged => p2 => N.Conn.recv(s2, buf, s3 => b3 =>
      again(b3, s3, f2, Rtsp.pinged(pinged, now, ka, Cfg.every(c)),
        U32.add(cseq, Bool.pick(U32, pinged, 1, 0)), p2)))

# The loop: a packet off the buffer into the file, a reply (to a
# keep-alive) dropped, and more bytes when the buffer has no whole
# message. ka: when the next keep-alive is due.
def Rtsp.loop(fuel: Nat, m: C.Msg, buf: List<&2, U32>, s: Socket, f: File,
  st: M.Mux, +c: Cfg, +ka: Nat, +cseq: U32, p: N.Pulled) -> IO(N.Out()):
  match fuel m:
    case 0n _:
      Rtsp.finish(s, f, c, cseq, Done{p})
    case 1n+q C.Frame{chan, data, +rest}:
      Rtsp.frame(Cfg.put(c, chan, data, st), s, f, p, s2 => f2 => st2 => p2 =>
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
  +c: Cfg, +now: Nat, head: U32, mux: M.Mux, next: U32) -> IO(N.Out()):
  match ok:
    case True{}:
      Rtsp.loop(4000000000n, C.Rtsp.demux(buf), buf, s, f, mux, c,
        Nat.add(now, Cfg.every(c)), next, N.Pulled{0, 0, head, Cfg.codec(c)})
    case False{}:
      do IO<N.Out()>:
        File.close(f)
        N.Conn.fail(s, C.Resp.code(r), "PLAY was refused")

# PLAY, once the file is open.
def Rtsp.play(s: Socket, buf: List<&2, U32>, f: File, +c: Cfg, +now: Nat,
  head: U32, mux: M.Mux, +next: U32) -> IO(N.Out()):
  Rtsp.ask(s, buf, Cfg.request(c, "PLAY", next), s2 => b2 => +r =>
    Rtsp.play.got(U32.is_eq(C.Resp.code(r), 200), r, s2, b2, f, c, now, head, mux,
      U32.add(next, 1)))

def Rtsp.opened(r: Result<&1, &1, U32 & String, File>, s: Socket,
  buf: List<&2, U32>, +c: Cfg, +sets: List<&2, U32>, now: Nat, +ts: Bool,
  aud: U.Aud, next: U32) -> IO(N.Out()):
  match r:
    case Fail{e}:
      (code, msg) = e
      N.Conn.fail(s, code, "cannot write the file: " ++ msg)
    case Done{f}:
      # The announced parameter sets open a raw file; in a TS they go
      # in front of the first picture.
      +first = Bool.pick(List<&2, U32>, ts, Nil{}, sets)
      N.Conn.save(first, s, f, s2 => f2 => Rtsp.play(s2, buf, f2, c, now,
        B.Bytes.len(first), M.Mux.new(ts, Cfg.h265(c),
          Bool.pick(List<&2, U32>, ts, sets, Nil{}), aud), next))

def Rtsp.ts(path: String) -> Bool:
  String.ends_with(String.to_lower(path), ".ts")

def Rtsp.start.at(+now: Nat, f: Result<&1, &1, U32 & String, File>, s: Socket,
  buf: List<&2, U32>, ms: U32, cfg: Nat -> Cfg, sets: List<&2, U32>, ts: Bool,
  aud: U.Aud, next: U32) -> IO(N.Out()):
  Rtsp.opened(f, s, buf, cfg(Nat.add(now, U32.to_nat(ms))), sets, now, ts, aud, next)

# The session is set up: open the file (a name in .ts asks for MPEG-TS),
# note the time, play.
def Rtsp.start(s: Socket, buf: List<&2, U32>, +path: String, +ms: U32,
  cfg: Nat -> Cfg, sets: List<&2, U32>, aud: U.Aud, next: U32) -> IO(N.Out()):
  do IO<N.Out()>:
    now : Nat <- IO.now()
    f : Result<&1, &1, U32 & String, File> <- File.open(path, "w")
    Rtsp.start.at(now, f, s, buf, ms, cfg, sets, Rtsp.ts(path), aud, next)

def Rtsp.audio.got(ok: Bool, s: Socket, buf: List<&2, U32>, path: String, ms: U32,
  cfg: Nat -> Cfg, sets: List<&2, U32>, aud: U.Aud) -> IO(N.Out()):
  match ok:
    case True{}:
      Rtsp.start(s, buf, path, ms, cfg, sets, aud, 5)
    case False{}:
      Rtsp.start(s, buf, path, ms, cfg, sets, U.Aud.none(), 5)

# The audio's track too, on channels 2 and 3, when the file is a TS and
# the audio is AAC; a server that refuses it gives the video alone.
def Rtsp.audio(want: Bool, s: Socket, buf: List<&2, U32>, path: String, ms: U32,
  cfg: Nat -> Cfg, sets: List<&2, U32>, aud: U.Aud, req: String) -> IO(N.Out()):
  match want:
    case False{}:
      Rtsp.start(s, buf, path, ms, cfg, sets, U.Aud.none(), 4)
    case True{}:
      Rtsp.ask(s, buf, req, s2 => b2 => r => Rtsp.audio.got(
        U32.is_eq(C.Resp.code(r), 200), s2, b2, path, ms, cfg, sets, aud))

def Rtsp.setup.got(ok: Bool, +r: C.Resp, s: Socket, buf: List<&2, U32>,
  +path: String, ms: U32, +m: C.Media, +uri: String, +chal: C.Chal, +u: C.Url,
  +cnonce: String, a: C.Media, aurl: String) -> IO(N.Out()):
  match ok:
    case True{}:
      +h265 = String.eq(C.Media.codec(m), "H265")
      +pt = C.Media.pt(m)
      +session = C.Rtsp.session(C.Resp.get(r, "session"))
      +codec = C.Media.codec(m)
      +every = U32.to_nat((C.Rtsp.timeout(C.Resp.get(r, "session")) * 500 : U32))
      +aud = U.Aud.of(a)
      Rtsp.audio(Rtsp.ts(path) && U.Aud.on(aud), s, buf, path, ms,
        until => Cfg{h265, pt, until, uri, session, chal, C.Url.user(u), C.Url.pass(u),
          cnonce, codec, every},
        R.Nal.annexb(C.Sdp.sprops(C.Media.fmtp(m))), aud,
        C.Rtsp.signed(chal, C.Url.user(u), C.Url.pass(u), "SETUP", aurl, 4, cnonce,
          session, [C.Hdr{"Transport", "RTP/AVP/TCP;unicast;interleaved=2-3"}]))
    case False{}:
      N.Conn.fail(s, C.Resp.code(r), "SETUP was refused (the server may not do "
        ++ "RTP over the RTSP connection)")

# SETUP for the video's track, RTP interleaved on channels 0 and 1.
def Rtsp.setup(problem: String, s: Socket, buf: List<&2, U32>, path: String,
  ms: U32, +m: C.Media, +base: String, +sdp: C.Sdp, +chal: C.Chal, +u: C.Url,
  +cnonce: String, +a: C.Media) -> IO(N.Out()):
  match problem:
    case SCon{h, t}:
      N.Conn.fail(s, 0, SCon{h, t})
    case SNil{}:
      Rtsp.ask(s, buf, C.Rtsp.signed(chal, C.Url.user(u), C.Url.pass(u), "SETUP",
        C.Rtsp.control(base, C.Media.control(m)), 3, cnonce, "",
        [C.Hdr{"Transport", "RTP/AVP/TCP;unicast;interleaved=0-1"}]),
        s2 => b2 => +r => Rtsp.setup.got(U32.is_eq(C.Resp.code(r), 200), r, s2, b2,
          path, ms, m, C.Rtsp.control(base, C.Sdp.session(sdp)), chal, u, cnonce, a,
          C.Rtsp.control(base, C.Media.control(a))))

# The description is here: its video stream, and the URL its control
# attributes are relative to (Content-Base, else the request's).
def Rtsp.described(+r: C.Resp, s: Socket, buf: List<&2, U32>, path: String, ms: U32,
  +uri: String, chal: C.Chal, u: C.Url, cnonce: String) -> IO(N.Out()):
  +sdp = C.Sdp.of(B.Bytes.text(C.Resp.body(r)))
  +m = C.Sdp.media(sdp, "video")
  +cb = C.Resp.get(r, "content-base")
  Rtsp.setup(C.Sdp.problem(m), s, buf, path, ms, m,
    Bool.pick(String, String.is_empty(cb), uri, cb), sdp, chal, u, cnonce,
    C.Sdp.media(sdp, "audio"))

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
def Rtsp.describe(s: Socket, path: String, ms: U32, +u: C.Url, +cnonce: String,
  tls: Bool) -> IO(N.Out()):
  +uri = C.Url.show(u, Bool.pick(String, tls, "rtsps://", "rtsp://"))
  Rtsp.ask(s, Nil{}, Rtsp.describe.req(C.Chal.none(), u, uri, 1, cnonce),
    s2 => b2 => +r => Rtsp.first.got(U32.is_eq(C.Resp.code(r), 200),
      U32.is_eq(C.Resp.code(r), 401), r, s2, b2, path, ms, uri, u, cnonce))

def Rtsp.go(bad: Bool, +u: C.Url, path: String, ms: U32, +tls: Bool) -> IO(N.Out()):
  match bad:
    case True{}:
      IO.pure(N.Out(), Fail{(0, "not an RTSP URL (rtsp://[user:pass@]host[:port]/path)")})
    case False{}:
      do IO<N.Out()>:
        a : U32 <- IO.try(U32, IO.random_u32())
        b : U32 <- IO.try(U32, IO.random_u32())
        N.Conn.open(C.Url.host.of(u), C.Url.port.of(u), tls, s =>
          Rtsp.describe(s, path, ms, u, U32.show(a) ++ U32.show(b), tls))

def Rtsp.pull.url(+u: C.Url, path: String, ms: U32, tls: Bool) -> IO(N.Out()):
  Rtsp.go(String.is_empty(C.Url.host.of(u)), u, path, ms, tls)

def Rtsp.pull.tls(+tls: Bool, url: String, path: String, ms: U32) -> IO(N.Out()):
  Rtsp.pull.url(C.Url.of(url, Bool.pick(String, tls, "rtsps://", "rtsp://"),
    Bool.pick(U32, tls, 322, 554)), path, ms, tls)

# Pull the video of an RTSP URL (rtsp://, or rtsps:// for TLS) into a
# file for ms milliseconds.
def Rtsp.pull(+url: String, path: String, ms: U32) -> IO(N.Out()):
  Rtsp.pull.tls(String.starts_with(String.to_lower(url), "rtsps://"), url, path, ms)
