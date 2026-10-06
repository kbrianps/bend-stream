# RTSP client (RFC 2326): a session that gives a camera's frames.
#
#   s <- Rtsp.open(E.Opts.new("rtsp://user:pass@camera/stream"))
#   (s, frame) <- Rtsp.next(s)      as many times as wanted
#   Rtsp.close(s)
#
# What goes on the wire:
#
#   C: DESCRIBE url            S: 401, WWW-Authenticate   (if it wants a login)
#   C: DESCRIBE url, Authorization   S: 200, the SDP
#   C: SETUP video, Transport: RTP/AVP/TCP;interleaved=0-1   S: 200, Session
#   C: SETUP audio, interleaved=2-3  (when there is AAC and it is wanted)
#   C: PLAY url, Session       S: 200
#   S: $ 0 <len> <RTP packet> ...        (on the same connection)
#   C: GET_PARAMETER url, Session        (at half the session's timeout)
#   C: TEARDOWN url, Session
#
# A frame is a whole picture (its NAL units in Annex B form) or a run of
# AAC frames, with its time; frame.bend says what is in one, rec.bend
# turns them into a file. This file is the IO; what to say and what a
# reply means is in rtsp_core.bend, rtp.bend and depay.bend, pure.
import Base
import ./bytes.bend as B
import ./rtsp_core.bend as C
import ./rtp.bend as R
import ./conn.bend as N
import ./opts.bend as E
import ./depay.bend as D
import ./audio.bend as U
import ./frame.bend as F

# The session
# -----------

# What a request needs: the video's payload type, the session's URL and
# id, the server's challenge and the login that answers it, how often
# to say we are alive (ms), and how long to wait for the server (ms).
type Cfg is Data:
  Cfg{pt: U32, uri: String, session: String, chal: C.Chal, user: String, pass: String,
    cnonce: String, every: Nat, wait: U32}

# An open session: the connection and what was read past the last
# frame, the frames being put together and those ready, when the next
# keep-alive is due and the next request's number.
type Sess is Type:
  Sess{sock: Socket, buf: List<&2, U32>, asm: D.Asm, cfg: Cfg, ka: Nat, cseq: U32,
    queue: List<&2, F.Frame>, info: F.Info}

# How the steps inside end: a session opened, or a frame read.
type End is Type:
  Opened{s: Sess}
  Next{s: Sess, f: F.Frame}

def Fin() -> Type:
  N.Res(End)

def Cfg.every(c: Cfg) -> Nat:
  Cfg{_, _, _, _, _, _, _, x, _} = c
  x

def Cfg.wait(c: Cfg) -> U32:
  Cfg{_, _, _, _, _, _, _, _, x} = c
  x

# A request of this session, signed.
def Cfg.request(c: Cfg, method: String, cseq: U32) -> String:
  Cfg{_, +uri, session, chal, user, pass, cnonce, _, _} = c
  C.Rtsp.signed(chal, user, pass, method, uri, cseq, cnonce, session, Nil{})

# What a channel's packet gives: channel 0 is the video's RTP, channel
# 2 the audio's; 1 and 3 are their RTCP, which is not read.
def Rtsp.put(rtp: Bool, sound: Bool, data: List<&2, U32>, pt: U32, st: D.Asm) -> D.Got:
  match rtp:
    case True{}:
      D.Asm.packet(R.Rtp.of(data), pt, sound, st)
    case False{}:
      D.Got{Nil{}, st}

def Cfg.put(c: Cfg, +chan: U32, data: List<&2, U32>, st: D.Asm) -> D.Got:
  Cfg{pt, _, _, _, _, _, _, _, _} = c
  Rtsp.put(U32.is_zero(chan) || U32.is_eq(chan, 2), U32.is_eq(chan, 2), data, pt, st)

# Replies
# -------

# The next reply, the interleaved packets before it skipped. Each turn
# takes a message off the buffer or reads more, so the fuel bounds it.
def Rtsp.reply(fuel: Nat, m: C.Msg, buf: List<&2, U32>, s: Socket, +wait: U32,
  k: Socket -> List<&2, U32> -> C.Resp -> IO(Fin())) -> IO(Fin()):
  match fuel m:
    case _ C.Reply{r, rest}:
      k(s, rest, r)
    case 1n+p C.Frame{_, _, +rest}:
      Rtsp.reply(p, C.Rtsp.demux(rest), rest, s, wait, k)
    case 1n+p C.Need{}:
      N.Conn.recv(End, s, wait, buf, s2 => +b2 =>
        Rtsp.reply(p, C.Rtsp.demux(b2), b2, s2, wait, k))
    case _ _:
      N.Conn.fail(End, s, E.Garbled{}, 0, "the server sent something that is not RTSP")

# Send a request and read its reply.
def Rtsp.ask(s: Socket, +buf: List<&2, U32>, req: String, wait: U32,
  k: Socket -> List<&2, U32> -> C.Resp -> IO(Fin())) -> IO(Fin()):
  N.Conn.say(End, s, req, s2 => Rtsp.reply(4096n, C.Rtsp.demux(buf), buf, s2, wait, k))

# Reading frames
# --------------

# The frames a packet completed: the first is given with a session that
# holds the rest; none, and the reading goes on.
def Rtsp.emit(g: D.Got, s: Socket, rest: List<&2, U32>, c: Cfg, ka: Nat, cseq: U32,
  info: F.Info, on: Socket -> List<&2, U32> -> D.Asm -> F.Info -> IO(Fin())) -> IO(Fin()):
  match g:
    case D.Got{Nil{}, asm}:
      on(s, rest, asm, info)
    case D.Got{Con{f, more}, asm}:
      IO.pure(Fin(), Done{Next{Sess{s, rest, asm, c, ka, cseq, more, info}, f}})

# With nothing whole in the buffer: a keep-alive when one is due, and
# more bytes.
def Rtsp.wait(due: Bool, +now: Nat, buf: List<&2, U32>, s: Socket, +c: Cfg, ka: Nat,
  +cseq: U32, again: Socket -> List<&2, U32> -> Nat -> U32 -> IO(Fin())) -> IO(Fin()):
  match due:
    case True{}:
      N.Conn.say(End, s, Cfg.request(c, "GET_PARAMETER", cseq), s2 =>
        N.Conn.recv(End, s2, Cfg.wait(c), buf, s3 => b3 =>
          again(s3, b3, Nat.add(now, Cfg.every(c)), U32.add(cseq, 1))))
    case False{}:
      N.Conn.recv(End, s, Cfg.wait(c), buf, s3 => b3 => again(s3, b3, ka, cseq))

def Rtsp.due(+now: Nat, buf: List<&2, U32>, s: Socket, c: Cfg, +ka: Nat, cseq: U32,
  again: Socket -> List<&2, U32> -> Nat -> U32 -> IO(Fin())) -> IO(Fin()):
  Rtsp.wait(Nat.is_le(ka, now), now, buf, s, c, ka, cseq, again)

# Until a frame: a packet off the buffer into the frames being put
# together, a reply (to a keep-alive) dropped, and more bytes when the
# buffer has no whole message.
def Rtsp.loop(fuel: Nat, m: C.Msg, buf: List<&2, U32>, s: Socket, asm: D.Asm, +c: Cfg,
  +ka: Nat, +cseq: U32, info: F.Info) -> IO(Fin()):
  match fuel m:
    case 0n _:
      N.Conn.fail(End, s, E.Garbled{}, 0, "no frame in a very long stream of packets")
    case 1n+q C.Frame{chan, data, rest}:
      Rtsp.emit(Cfg.put(c, chan, data, asm), s, rest, c, ka, cseq, info,
        s2 => +r2 => asm2 => i2 =>
          Rtsp.loop(q, C.Rtsp.demux(r2), r2, s2, asm2, c, ka, cseq, i2))
    case 1n+q C.Reply{_, +rest}:
      Rtsp.loop(q, C.Rtsp.demux(rest), rest, s, asm, c, ka, cseq, info)
    case 1n+q C.Bad{}:
      N.Conn.fail(End, s, E.Garbled{}, 0, "lost the stream's framing")
    case 1n+q C.Need{}:
      do IO<Fin()>:
        now : Nat <- IO.now()
        Rtsp.due(now, buf, s, c, ka, cseq,
          s3 => +b3 => +ka3 => +n3 =>
            Rtsp.loop(q, C.Rtsp.demux(b3), b3, s3, asm, c, ka3, n3, info))

def Rtsp.pop(queue: List<&2, F.Frame>, s: Socket, +buf: List<&2, U32>, asm: D.Asm,
  c: Cfg, ka: Nat, cseq: U32, info: F.Info) -> IO(Fin()):
  match queue:
    case Con{f, more}:
      IO.pure(Fin(), Done{Next{Sess{s, buf, asm, c, ka, cseq, more, info}, f}})
    case Nil{}:
      Rtsp.loop(4000000000n, C.Rtsp.demux(buf), buf, s, asm, c, ka, cseq, info)

# Setting up
# ----------

def Rtsp.play.got(ok: Bool, r: C.Resp, s: Socket, buf: List<&2, U32>, +c: Cfg,
  now: Nat, next: U32, asm: D.Asm, info: F.Info) -> IO(Fin()):
  match ok:
    case True{}:
      IO.pure(Fin(), Done{Opened{Sess{s, buf, asm, c, Nat.add(now, Cfg.every(c)), next,
        Nil{}, info}}})
    case False{}:
      N.Conn.fail(End, s, E.Refused{}, C.Resp.code(r), "PLAY was refused")

# PLAY, and the session is open.
def Rtsp.play(s: Socket, buf: List<&2, U32>, +c: Cfg, +next: U32, asm: D.Asm,
  info: F.Info) -> IO(Fin()):
  do IO<Fin()>:
    now : Nat <- IO.now()
    Rtsp.ask(s, buf, Cfg.request(c, "PLAY", next), Cfg.wait(c), s2 => b2 => +r =>
      Rtsp.play.got(U32.is_eq(C.Resp.code(r), 200), r, s2, b2, c, now, U32.add(next, 1),
        asm, info))

def Rtsp.info(+m: C.Media, +aud: U.Aud) -> F.Info:
  F.Info{C.Media.codec(m), R.Nal.annexb(C.Sdp.sprops(C.Media.fmtp(m))), U.Aud.codec(aud),
    U.Aud.rate(aud), U.Aud.chans(aud)}

def Rtsp.audio.on(s: Socket, buf: List<&2, U32>, c: Cfg, +m: C.Media, +aud: U.Aud) ->
  IO(Fin()):
  Rtsp.play(s, buf, c, 5, D.Asm.new(String.eq(C.Media.codec(m), "H265"), aud),
    Rtsp.info(m, aud))

def Rtsp.audio.got(ok: Bool, s: Socket, buf: List<&2, U32>, c: Cfg, +m: C.Media,
  aud: U.Aud) -> IO(Fin()):
  match ok:
    case True{}:
      Rtsp.audio.on(s, buf, c, m, aud)
    case False{}:
      Rtsp.play(s, buf, c, 5, D.Asm.new(String.eq(C.Media.codec(m), "H265"), U.Aud.none()),
        Rtsp.info(m, U.Aud.none()))

# The audio's track too, on channels 2 and 3, when it is wanted and it
# is AAC or G.711; a server that refuses it gives the video alone.
def Rtsp.audio(want: Bool, s: Socket, buf: List<&2, U32>, +c: Cfg, +m: C.Media,
  aud: U.Aud, req: String) -> IO(Fin()):
  match want:
    case False{}:
      Rtsp.play(s, buf, c, 4, D.Asm.new(String.eq(C.Media.codec(m), "H265"), U.Aud.none()),
        Rtsp.info(m, U.Aud.none()))
    case True{}:
      Rtsp.ask(s, buf, req, Cfg.wait(c), s2 => b2 => r => Rtsp.audio.got(
        U32.is_eq(C.Resp.code(r), 200), s2, b2, c, m, aud))

def Rtsp.setup.got(ok: Bool, +r: C.Resp, s: Socket, buf: List<&2, U32>, +m: C.Media,
  uri: String, +chal: C.Chal, +user: String, +pass: String, +cnonce: String,
  a: C.Media, aurl: String, +o: E.Opts) -> IO(Fin()):
  match ok:
    case True{}:
      E.Opts{_, _, _, +wait, audio, _} = o
      +session = C.Rtsp.session(C.Resp.get(r, "session"))
      +aud = U.Aud.of(a)
      Rtsp.audio(audio && U.Aud.on(aud), s, buf,
        Cfg{C.Media.pt(m), uri, session, chal, user, pass, cnonce,
          U32.to_nat((C.Rtsp.timeout(C.Resp.get(r, "session")) * 500 : U32)), wait},
        m, aud,
        C.Rtsp.signed(chal, user, pass, "SETUP", aurl, 4, cnonce, session,
          [C.Hdr{"Transport", "RTP/AVP/TCP;unicast;interleaved=2-3"}]))
    case False{}:
      N.Conn.fail(End, s, E.Refused{}, C.Resp.code(r), "SETUP was refused (the server "
        ++ "may not do RTP over the RTSP connection)")

# SETUP for the video's track, RTP interleaved on channels 0 and 1.
def Rtsp.setup(problem: String, s: Socket, buf: List<&2, U32>, +m: C.Media,
  +base: String, +sdp: C.Sdp, +chal: C.Chal, +user: String, +pass: String,
  +cnonce: String, +a: C.Media, +o: E.Opts) -> IO(Fin()):
  match problem:
    case SCon{h, t}:
      N.Conn.fail(End, s, E.Refused{}, 0, SCon{h, t})
    case SNil{}:
      Rtsp.ask(s, buf, C.Rtsp.signed(chal, user, pass, "SETUP",
        C.Rtsp.control(base, C.Media.control(m)), 3, cnonce, "",
        [C.Hdr{"Transport", "RTP/AVP/TCP;unicast;interleaved=0-1"}]), E.Opts.wait.of(o),
        s2 => b2 => +r => Rtsp.setup.got(U32.is_eq(C.Resp.code(r), 200), r, s2, b2, m,
          C.Rtsp.control(base, C.Sdp.session(sdp)), chal, user, pass, cnonce, a,
          C.Rtsp.control(base, C.Media.control(a)), o))

# The description is here: its video stream, and the URL its control
# attributes are relative to (Content-Base, else the request's).
def Rtsp.described(+r: C.Resp, s: Socket, buf: List<&2, U32>, +uri: String,
  chal: C.Chal, user: String, pass: String, cnonce: String, o: E.Opts) -> IO(Fin()):
  +sdp = C.Sdp.of(B.Bytes.text(C.Resp.body(r)))
  +m = C.Sdp.media(sdp, "video")
  +cb = C.Resp.get(r, "content-base")
  Rtsp.setup(C.Sdp.problem(m), s, buf, m, Bool.pick(String, String.is_empty(cb), uri, cb),
    sdp, chal, user, pass, cnonce, C.Sdp.media(sdp, "audio"), o)

def Rtsp.describe.req(chal: C.Chal, user: String, pass: String, +uri: String, cseq: U32,
  cnonce: String) -> String:
  C.Rtsp.signed(chal, user, pass, "DESCRIBE", uri, cseq, cnonce, "",
    [C.Hdr{"Accept", "application/sdp"}])

# Why a DESCRIBE was refused: a login (401, 403), no such stream (404),
# or something else.
def Rtsp.why(+code: U32) -> E.Why:
  Bool.pick(E.Why, U32.is_eq(code, 401) || U32.is_eq(code, 403), E.NoLogin{},
    Bool.pick(E.Why, U32.is_eq(code, 404), E.NoStream{}, E.Refused{}))

def Rtsp.words(+code: U32) -> String:
  Bool.pick(String, U32.is_eq(code, 401) || U32.is_eq(code, 403),
    "wrong user or password",
    Bool.pick(String, U32.is_eq(code, 404), "the server has no stream at this path",
      "DESCRIBE was refused"))

def Rtsp.refused(s: Socket, +code: U32) -> IO(Fin()):
  N.Conn.fail(End, s, Rtsp.why(code), code, Rtsp.words(code))

# A reply that is neither the description nor a challenge: a redirect
# (a 3xx with a Location) ends as Moved, its words the new address, for
# open to follow; anything else is a refusal.
def Rtsp.other(moved: Bool, s: Socket, code: U32, to: String) -> IO(Fin()):
  match moved:
    case True{}:
      N.Conn.fail(End, s, E.Moved{}, code, to)
    case False{}:
      Rtsp.refused(s, code)

def Rtsp.other.of(s: Socket, +code: U32, +to: String) -> IO(Fin()):
  Rtsp.other((code >= 300 && code < 400 : U32) && Bool.not(String.is_empty(to)), s, code,
    to)

def Rtsp.again.got(ok: Bool, +r: C.Resp, s: Socket, buf: List<&2, U32>, uri: String,
  chal: C.Chal, user: String, pass: String, cnonce: String, o: E.Opts) -> IO(Fin()):
  match ok:
    case True{}:
      Rtsp.described(r, s, buf, uri, chal, user, pass, cnonce, o)
    case False{}:
      Rtsp.refused(s, C.Resp.code(r))

# DESCRIBE again, answering the challenge; a server with none we can
# answer ends it.
def Rtsp.again(none: Bool, s: Socket, buf: List<&2, U32>, +uri: String, +chal: C.Chal,
  +user: String, +pass: String, +cnonce: String, +o: E.Opts) -> IO(Fin()):
  match none:
    case True{}:
      N.Conn.fail(End, s, E.NoLogin{}, 401, "the server wants a login this client "
        ++ "cannot give (Basic, or Digest with MD5)")
    case False{}:
      Rtsp.ask(s, buf, Rtsp.describe.req(chal, user, pass, uri, 2, cnonce),
        E.Opts.wait.of(o), s2 => b2 => +r =>
          Rtsp.again.got(U32.is_eq(C.Resp.code(r), 200), r, s2, b2, uri, chal, user,
            pass, cnonce, o))

def Rtsp.again.with(+chal: C.Chal, s: Socket, buf: List<&2, U32>, uri: String,
  user: String, pass: String, cnonce: String, o: E.Opts) -> IO(Fin()):
  Rtsp.again(String.is_empty(C.Chal.scheme(chal)), s, buf, uri, chal, user, pass, cnonce,
    o)

def Rtsp.first.got(ok: Bool, login: Bool, +r: C.Resp, s: Socket, buf: List<&2, U32>,
  uri: String, user: String, pass: String, cnonce: String, o: E.Opts) -> IO(Fin()):
  match ok login:
    case True{} _:
      Rtsp.described(r, s, buf, uri, C.Chal.none(), user, pass, cnonce, o)
    case False{} True{}:
      Rtsp.again.with(C.Chal.pick(C.Chal.all(C.Hdr.all(C.Resp.headers(r),
        "www-authenticate"))), s, buf, uri, user, pass, cnonce, o)
    case False{} False{}:
      Rtsp.other.of(s, C.Resp.code(r), String.trim(C.Resp.get(r, "location")))

# DESCRIBE with no login first: a 401 names the challenge to answer.
def Rtsp.describe(s: Socket, +uri: String, +user: String, +pass: String,
  +cnonce: String, +o: E.Opts) -> IO(Fin()):
  Rtsp.ask(s, Nil{}, Rtsp.describe.req(C.Chal.none(), user, pass, uri, 1, cnonce),
    E.Opts.wait.of(o), s2 => b2 => +r => Rtsp.first.got(U32.is_eq(C.Resp.code(r), 200),
      U32.is_eq(C.Resp.code(r), 401), r, s2, b2, uri, user, pass, cnonce, o))

# The options' login, or the URL's when they have none.
def Rtsp.pick(mine: String, theirs: String) -> String:
  match mine:
    case SNil{}:
      theirs
    case SCon{h, t}:
      SCon{h, t}

def Rtsp.go(bad: Bool, +u: C.Url, +tls: Bool, +o: E.Opts) -> IO(Fin()):
  match bad:
    case True{}:
      IO.pure(Fin(), Fail{E.Err{E.BadUrl{}, 0,
        "not an RTSP URL (rtsp://[user:pass@]host[:port]/path)"}})
    case False{}:
      E.Opts{_, user, pass, _, _, ca} = o
      do IO<Fin()>:
        a : U32 <- IO.try(U32, IO.random_u32())
        b : U32 <- IO.try(U32, IO.random_u32())
        N.Conn.open(End, C.Url.host.of(u), C.Url.port.of(u), tls, ca, s =>
          Rtsp.describe(s, C.Url.show(u, Bool.pick(String, tls, "rtsps://", "rtsp://")),
            Rtsp.pick(user, C.Url.user(u)), Rtsp.pick(pass, C.Url.pass(u)),
            U32.show(a) ++ U32.show(b), o))

def Rtsp.start.url(+u: C.Url, tls: Bool, o: E.Opts) -> IO(Fin()):
  Rtsp.go(String.is_empty(C.Url.host.of(u)), u, tls, o)

def Rtsp.start.tls(+tls: Bool, +url: String, o: E.Opts) -> IO(Fin()):
  Rtsp.start.url(C.Url.of(url, Bool.pick(String, tls, "rtsps://", "rtsp://"),
    Bool.pick(U32, tls, 322, 554)), tls, o)

def Rtsp.start(+o: E.Opts) -> IO(Fin()):
  E.Opts{+url, _, _, _, _, _} = o
  Rtsp.start.tls(String.starts_with(String.to_lower(url), "rtsps://"), url, o)

# The public face
# ---------------

def Opened() -> Type:
  Result<&1, &1, E.Err, Sess>

def Read() -> Type:
  Result<&1, &1, E.Err, Sess & F.Frame>

def Rtsp.open.end(r: Fin()) -> Opened():
  match r:
    case Done{Opened{s}}:
      Done{s}
    case Done{Next{_, _}}:
      Fail{E.Err{E.Garbled{}, 0, "a frame before the session was open"}}
    case Fail{e}:
      Fail{e}

def Rtsp.next.end(r: Fin()) -> Read():
  match r:
    case Done{Next{s, f}}:
      Done{(s, f)}
    case Done{Opened{_}}:
      Fail{E.Err{E.Garbled{}, 0, "the session opened twice"}}
    case Fail{e}:
      Fail{e}

def Rtsp.open.moved(moved: Bool, +e: E.Err, o: E.Opts, again: E.Opts -> IO(Opened())) ->
  IO(Opened()):
  match moved:
    case True{}:
      E.Err{_, _, to} = e
      again(E.Opts.to(o, to))
    case False{}:
      IO.pure(Opened(), Fail{e})

def Rtsp.open.got(r: Opened(), o: E.Opts, again: E.Opts -> IO(Opened())) -> IO(Opened()):
  match r:
    case Done{s}:
      IO.pure(Opened(), Done{s})
    case Fail{+e}:
      Rtsp.open.moved(E.Err.moved(e), e, o, again)

# A server may send the client elsewhere (301, 302): up to hops times.
def Rtsp.open.at(hops: Nat, +o: E.Opts) -> IO(Opened()):
  match hops:
    case 0n:
      IO.pure(Opened(), Fail{E.Err{E.Moved{}, 0, "too many redirects"}})
    case 1n+p:
      do IO<Opened()>:
        r : Fin() <- Rtsp.start(o)
        Rtsp.open.got(Rtsp.open.end(r), o, o2 => Rtsp.open.at(p, o2))

# Open a session: connect, log in, set the streams up and play,
# following a redirect if the server answers with one. On a failure the
# connection is already closed.
def Rtsp.open(o: E.Opts) -> IO(Opened()):
  Rtsp.open.at(5n, o)

def Rtsp.reopen.end(r: Opened(), rest: IO(Opened())) -> IO(Opened()):
  match r:
    case Done{s}:
      IO.pure(Opened(), Done{s})
    case Fail{+e}:
      Bool.pick(IO(Opened()), E.Err.lasting(e), IO.pure(Opened(), Fail{e}), rest)

def Rtsp.reopen.go(late: Bool, o: E.Opts, rest: IO(Opened())) -> IO(Opened()):
  match late:
    case True{}:
      IO.pure(Opened(), Fail{E.Err{E.Silent{}, 0, "the stream did not come back in time"}})
    case False{}:
      do IO<Opened()>:
        r : Opened() <- Rtsp.open(o)
        Rtsp.reopen.end(r, rest)

def Rtsp.reopen.at(tries: Nat, +o: E.Opts, +until: Nat, +delay: U32) -> IO(Opened()):
  match tries:
    case 0n:
      IO.pure(Opened(), Fail{E.Err{E.Silent{}, 0, "the stream did not come back"}})
    case 1n+p:
      rest = Rtsp.reopen.at(p, o, until, U32.min((delay * 2 : U32), 15000))
      do IO<Opened()>:
        u : Unit <- IO.sleep(delay)
        now : Nat <- IO.now()
        Rtsp.reopen.go(Nat.is_le(until, now), o, rest)

# Open again a session that was lost: it waits half a second, tries,
# and doubles the wait (up to 15 s) after each failure, until the
# session opens, an error says it never will (E.Err.lasting), or the
# clock (IO.now's, ms) reaches until.
def Rtsp.reopen(o: E.Opts, until: Nat) -> IO(Opened()):
  Rtsp.reopen.at(100000n, o, until, 500)

# The next frame, and the session to go on with. It waits for the
# server at most the options' wait; on a failure the connection is
# already closed and the session is over.
def Rtsp.next(x: Sess) -> IO(Read()):
  Sess{s, buf, asm, c, ka, cseq, queue, info} = x
  do IO<Read()>:
    r : Fin() <- Rtsp.pop(queue, s, buf, asm, c, ka, cseq, info)
    IO.pure(Read(), Rtsp.next.end(r))

# What the session's stream is, and the session back.
def Rtsp.about(x: Sess) -> Sess & F.Info:
  Sess{s, buf, asm, c, ka, cseq, queue, +info} = x
  (Sess{s, buf, asm, c, ka, cseq, queue, info}, info)

# End the session: TEARDOWN, and the connection closed once the server
# has answered or gone quiet for a fifth of a second.
def Rtsp.close(x: Sess) -> IO(Unit):
  Sess{s, _, _, c, _, cseq, _, _} = x
  N.Conn.shut(s, B.Bytes.of(Cfg.request(c, "TEARDOWN", cseq)), 200)
