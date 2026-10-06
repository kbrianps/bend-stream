# RTMP (Adobe's specification of 2012): the pure half of the client.
#
#   - the handshake's bytes;
#   - the chunk stream: a message is cut into chunks, each after a
#     header that says which chunk stream it is on and, in one of four
#     sizes, what changed since that stream's last message;
#   - the control messages and the commands (AMF0) a player sends;
#   - what a message from the server means to a player;
#   - FLV, the file the audio, video and data messages are written to
#     as they are: a tag is a message with another header.
import Base
import ./bytes.bend as B
import ./amf.bend as A
import ./rtsp_core.bend as C

# Handshake
# ---------

def Rtmp.noise(n: Nat, +x: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      Rtmp.noise(p, (x * 1664525 + 1013904223 : U32), U32.shrn(x, 24n) <> acc)

# C0 and C1: version 3, then 1536 bytes: a time, four zeros, and 1528
# bytes of anything (here a sequence grown from the seed).
def Rtmp.hello(seed: U32) -> List<&2, U32>:
  3 <> 0 <> 0 <> 0 <> 0 <> 0 <> 0 <> 0 <> 0 <> Rtmp.noise(1528n, seed, Nil{})

type Shake is Data:
  Early{}
  Shake{c2: List<&2, U32>, rest: List<&2, U32>}

def Rtmp.shake.s2(c: B.Cut, s1: List<&2, U32>) -> Shake:
  match c:
    case B.Short{}:
      Early{}
    case B.Cut{_, rest}:
      Shake{s1, rest}

def Rtmp.shake.s1(c: B.Cut) -> Shake:
  match c:
    case B.Short{}:
      Early{}
    case B.Cut{s1, rest}:
      Rtmp.shake.s2(B.Bytes.cut(1536, rest), s1)

# The server's S0, S1 and S2 (1 + 1536 + 1536 bytes): C2 is S1 sent
# back, and what follows them is the chunk stream. Early when they are
# not all here yet.
def Rtmp.shake(buf: List<&2, U32>) -> Shake:
  match buf:
    case Nil{}:
      Early{}
    case Con{_, t}:
      Rtmp.shake.s1(B.Bytes.cut(1536, t))

# Chunks out
# ----------

# The pieces of a payload, the separator between them.
def Rtmp.parts(fuel: Nat, c: B.Cut, +sep: List<&2, U32>, +size: Nat,
  acc: List<&2, U32>) -> List<&2, U32>:
  match fuel c:
    case 1n+p B.Cut{h, Con{x, t}}:
      Rtmp.parts(p, B.Bytes.split(size, x <> t), sep, size,
        B.Bytes.onto(sep, B.Bytes.onto(h, acc)))
    case _ B.Cut{h, Nil{}}:
      B.Bytes.rev(B.Bytes.onto(h, acc))
    case _ _:
      B.Bytes.rev(acc)

def Rtmp.ext(big: Bool, ts: U32) -> List<&2, U32>:
  match big:
    case True{}:
      B.Bytes.put32(ts, Nil{})
    case False{}:
      Nil{}

# A message as chunks of at most size bytes on chunk stream cs (2 to
# 63): the first after a full header (type 0), the others after a
# one-byte one (type 3). A timestamp that does not fit 3 bytes goes as
# FFFFFF there and in 4 bytes after each header.
def Rtmp.message(+cs: U32, typ: U32, sid: U32, +ts: U32, +payload: List<&2, U32>,
  +size: U32) -> List<&2, U32>:
  +big = (ts >= 16777215 : U32)
  +n = B.Bytes.len(payload)
  U32.and(cs, 63) <> B.Bytes.put24(Bool.pick(U32, big, 16777215, ts), B.Bytes.put24(n,
    typ <> B.Bytes.put32le(sid, B.Bytes.cat(Rtmp.ext(big, ts),
      Rtmp.parts(U32.to_nat(U32.add(n, 1)), B.Bytes.split(U32.to_nat(size), payload),
        B.Bytes.rev(U32.or(192, U32.and(cs, 63)) <> Rtmp.ext(big, ts)),
        U32.to_nat(size), Nil{})))))

# The chunk size this client announces and then writes with (the
# protocol starts at 128).
def Rtmp.out() -> U32:
  4096

# Protocol control (on chunk stream 2, message stream 0; they are
# smaller than any chunk size).
def Rtmp.control(typ: U32, data: List<&2, U32>) -> List<&2, U32>:
  Rtmp.message(2, typ, 0, 0, data, 128)

# Set Chunk Size (1).
def Rtmp.chunk_size(n: U32) -> List<&2, U32>:
  Rtmp.control(1, B.Bytes.put32(n, Nil{}))

# Acknowledgement (3): the bytes received so far.
def Rtmp.ack(n: U32) -> List<&2, U32>:
  Rtmp.control(3, B.Bytes.put32(n, Nil{}))

# User control (4): event 3 is Set Buffer Length, 7 the answer to a ping.
def Rtmp.buffer(sid: U32, ms: U32) -> List<&2, U32>:
  Rtmp.control(4, B.Bytes.put16(3, B.Bytes.put32(sid, B.Bytes.put32(ms, Nil{}))))

def Rtmp.pong(data: List<&2, U32>) -> List<&2, U32>:
  Rtmp.control(4, B.Bytes.put16(7, data))

# A command (20) of AMF0 values.
def Rtmp.command(cs: U32, sid: U32, ts: List<&2, A.Tok>) -> List<&2, U32>:
  Rtmp.message(cs, 20, sid, 0, A.Amf.bytes(ts), Rtmp.out())

# Commands
# --------

# Where a URL's path sends us: the application to connect to, and the
# stream to play in it (the last part of the path, with the query).
type Where is Data:
  Where{app: String, stream: String}

def Where.end(has: Bool, app: String, seg: String) -> Where:
  match has:
    case True{}:
      Where{String.reverse(app), String.reverse(seg)}
    case False{}:
      Where{String.reverse(seg), ""}

def Where.slash(has: Bool, app: String, seg: String) -> String:
  match has:
    case True{}:
      seg ++ "/" ++ app
    case False{}:
      seg

# app and seg are kept reversed; a "/" before the query ends a part.
def Where.go(s: String, +has: Bool, +app: String, +seg: String, +query: Bool) -> Where:
  match s:
    case SNil{}:
      Where.end(has, app, seg)
    case SCon{Chr{+c}, t}:
      +cut = U32.is_eq(c, 47) && Bool.not(query)
      Where.go(t, has || cut, Bool.pick(String, cut, Where.slash(has, app, seg), app),
        Bool.pick(String, cut, "", SCon{Chr{c}, seg}), query || U32.is_eq(c, 63))

def Where.of(path: String) -> Where:
  match path:
    case SCon{Chr{47}, t}:
      Where.go(t, False{}, "", "", False{})
    case s:
      Where.go(s, False{}, "", "", False{})

def Where.app(w: Where) -> String:
  Where{a, _} = w
  a

def Where.stream(w: Where) -> String:
  Where{_, s} = w
  s

# connect, transaction 1: the application, and its URL.
def Rtmp.connect(+app: String, host: String, port: U32) -> List<&2, U32>:
  Rtmp.command(3, 0, [A.AStr{"connect"}, A.ANum{1}, A.AObj{},
    A.AKey{"app"}, A.AStr{app},
    A.AKey{"type"}, A.AStr{"nonprivate"},
    A.AKey{"flashVer"}, A.AStr{"LNX 9,0,124,2"},
    A.AKey{"tcUrl"}, A.AStr{"rtmp://" ++ host ++ ":" ++ U32.show(port) ++ "/" ++ app},
    A.AKey{"fpad"}, A.AFlag{False{}},
    A.AKey{"capabilities"}, A.ANum{15},
    A.AKey{"audioCodecs"}, A.ANum{4071},
    A.AKey{"videoCodecs"}, A.ANum{252},
    A.AKey{"videoFunction"}, A.ANum{1},
    A.AEnd{}])

# createStream, transaction 2: its result carries the stream's id.
def Rtmp.create() -> List<&2, U32>:
  Rtmp.command(3, 0, [A.AStr{"createStream"}, A.ANum{2}, A.ANull{}])

# play on the stream, and how much the server may send ahead.
def Rtmp.play(+sid: U32, stream: String) -> List<&2, U32>:
  B.Bytes.cat(Rtmp.command(8, sid, [A.AStr{"play"}, A.ANum{3}, A.ANull{},
    A.AStr{stream}]), Rtmp.buffer(sid, 3000))

# Chunks in
# ---------

# A chunk stream's last header: the timestamp, the 3-byte field it came
# in (a delta but in a type 0 header; FFFFFF says the real value is in
# 4 more bytes), the message's size, type and stream; and the message
# under way: the bytes it has, its pieces last first.
type Lane is Data:
  Lane{id: U32, ts: U32, field: U32, len: U32, typ: U32, sid: U32, got: U32,
    parts: List<&2, List<&2, U32>>}

# The decoder: the size of the server's chunks, and its chunk streams.
type Dec is Data:
  Dec{size: U32, chans: List<&2, Lane>}

# A step of the decoder: nothing whole in the buffer; a chunk taken
# that ends no message; or a message.
type Step is Data:
  More{}
  Part{st: Dec, rest: List<&2, U32>}
  Msg{typ: U32, ts: U32, sid: U32, payload: List<&2, U32>, st: Dec, rest: List<&2, U32>}

def Dec.new() -> Dec:
  Dec{128, Nil{}}

def Lane.find(cs: List<&2, Lane>, +id: U32) -> Lane:
  match cs:
    case Nil{}:
      Lane{id, 0, 0, 0, 0, 0, 0, Nil{}}
    case Con{Lane{+i, ts, field, len, typ, sid, got, parts}, t}:
      Bool.pick(Lane, U32.is_eq(i, id), Lane{i, ts, field, len, typ, sid, got, parts},
        Lane.find(t, id))

def Lane.drop(cs: List<&2, Lane>, +id: U32) -> List<&2, Lane>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{Lane{+i, ts, field, len, typ, sid, got, parts}, t}:
      +rest = Lane.drop(t, id)
      Bool.pick(List<&2, Lane>, U32.is_eq(i, id), rest,
        Lane{i, ts, field, len, typ, sid, got, parts} <> rest)

# The message is whole, or not yet.
def Rtmp.done(full: Bool, id: U32, +ts: U32, field: U32, len: U32, +typ: U32, +sid: U32,
  got: U32, parts: List<&2, List<&2, U32>>, +size: U32, others: List<&2, Lane>,
  rest: List<&2, U32>) -> Step:
  match full:
    case True{}:
      +payload = B.Bytes.join(parts, Nil{})
      Msg{typ, ts, sid, payload, Dec{Bool.pick(U32, U32.is_eq(typ, 1),
        U32.and(B.Bytes.u32(payload), 2147483647), size),
        Lane{id, ts, field, len, typ, sid, 0, Nil{}} <> others}, rest}
    case False{}:
      Part{Dec{size, Lane{id, ts, field, len, typ, sid, got, parts} <> others}, rest}

def Rtmp.data(c: B.Cut, +n: U32, ch: Lane, size: U32, others: List<&2, Lane>) -> Step:
  match c:
    case B.Short{}:
      More{}
    case B.Cut{h, rest}:
      Lane{id, ts, field, +len, typ, sid, +got, parts} = ch
      Rtmp.done((U32.add(got, n) >= len : U32), id, ts, field, len, typ, sid,
        U32.add(got, n), h <> parts, size, others, rest)

# The chunk's data: up to the chunk size of what the message lacks. A
# chunk that starts a message moves the timestamp by v, or to v after
# a type 0 header.
def Rtmp.body(+v: U32, abs: Bool, fresh: Bool, ch: Lane, r: List<&2, U32>,
  +size: U32, others: List<&2, Lane>) -> Step:
  Lane{id, +ts, field, +len, typ, sid, +got, parts} = ch
  +n = U32.min(size, U32.sub(len, U32.min(got, len)))
  Rtmp.data(B.Bytes.cut(n, r), n, Lane{id, Bool.pick(U32, fresh,
    Bool.pick(U32, abs, v, U32.add(ts, v)), ts), field, len, typ, sid, got, parts},
    size, others)

def Rtmp.time(big: Bool, +field: U32, abs: Bool, fresh: Bool, ch: Lane,
  r: List<&2, U32>, size: U32, others: List<&2, Lane>) -> Step:
  match big r:
    case True{} Con{a, Con{b, Con{c, Con{d, t}}}}:
      Rtmp.body(B.Bytes.u32([a, b, c, d]), abs, fresh, ch, t, size, others)
    case True{} _:
      More{}
    case False{} t:
      Rtmp.body(field, abs, fresh, ch, t, size, others)

def Lane.field(ch: Lane) -> U32:
  Lane{_, _, f, _, _, _, _, _} = ch
  f

def Lane.fresh(ch: Lane) -> Bool:
  Lane{_, _, _, _, _, _, got, _} = ch
  U32.is_zero(got)

# The header a chunk brings: all of it (type 0), without the stream
# (1), the time only (2); a new header starts a message over.
def Lane.with(kind: Nat, ch: Lane, +h: List<&2, U32>) -> Lane:
  match kind:
    case 0n:
      Lane{id, ts, _, _, _, _, _, _} = ch
      Lane{id, ts, B.Bytes.u24(h), B.Bytes.u24(B.Bytes.drop(3n, h)),
        B.Bytes.u8(B.Bytes.drop(6n, h)), B.Bytes.u32le(B.Bytes.drop(7n, h)), 0, Nil{}}
    case 1n:
      Lane{id, ts, _, _, _, sid, _, _} = ch
      Lane{id, ts, B.Bytes.u24(h), B.Bytes.u24(B.Bytes.drop(3n, h)),
        B.Bytes.u8(B.Bytes.drop(6n, h)), sid, 0, Nil{}}
    case _:
      Lane{id, ts, _, len, typ, sid, _, _} = ch
      Lane{id, ts, B.Bytes.u24(h), len, typ, sid, 0, Nil{}}

def Rtmp.timed(+ch: Lane, abs: Bool, fresh: Bool, r: List<&2, U32>, size: U32,
  others: List<&2, Lane>) -> Step:
  +f = Lane.field(ch)
  Rtmp.time(U32.is_eq(f, 16777215), f, abs, fresh, ch, r, size, others)

def Rtmp.header(c: B.Cut, +kind: Nat, ch: Lane, size: U32, others: List<&2, Lane>) ->
  Step:
  match c:
    case B.Short{}:
      More{}
    case B.Cut{h, rest}:
      Rtmp.timed(Lane.with(kind, ch, h), Nat.is_eq(kind, 0n), True{}, rest, size,
        others)

def Rtmp.format(fmt: Nat, +ch: Lane, r: List<&2, U32>, size: U32,
  others: List<&2, Lane>) -> Step:
  match fmt:
    case 0n:
      Rtmp.header(B.Bytes.cut(11, r), 0n, ch, size, others)
    case 1n:
      Rtmp.header(B.Bytes.cut(7, r), 1n, ch, size, others)
    case 2n:
      Rtmp.header(B.Bytes.cut(3, r), 2n, ch, size, others)
    case _:
      Rtmp.timed(ch, False{}, Lane.fresh(ch), r, size, others)

def Rtmp.stream(fmt: U32, +id: U32, r: List<&2, U32>, st: Dec) -> Step:
  Dec{size, +chans} = st
  Rtmp.format(U32.to_nat(fmt), Lane.find(chans, id), r, size, Lane.drop(chans, id))

# The chunk stream's number: 6 bits, or in 1 or 2 more bytes when they
# say 0 or 1.
def Rtmp.basic(zero: Bool, one: Bool, cs: U32, fmt: U32, t: List<&2, U32>, st: Dec) ->
  Step:
  match zero one t:
    case True{} _ Con{a, r}:
      Rtmp.stream(fmt, U32.add(a, 64), r, st)
    case False{} True{} Con{a, Con{b, r}}:
      Rtmp.stream(fmt, U32.add(U32.add(a, U32.shln(b, 8n)), 64), r, st)
    case False{} False{} r:
      Rtmp.stream(fmt, cs, r, st)
    case _ _ _:
      More{}

# One chunk off the buffer.
def Rtmp.chunk(st: Dec, buf: List<&2, U32>) -> Step:
  match buf:
    case Nil{}:
      More{}
    case Con{+b, t}:
      +cs = U32.and(b, 63)
      Rtmp.basic(U32.is_zero(cs), U32.is_eq(cs, 1), cs, U32.shrn(b, 6n), t, st)

# What a player makes of it
# -------------------------

# Wait: more bytes are needed. Skip: nothing to act on. Result and
# Error answer a command. Start, Over and Refused are the stream's
# status. Media is audio (8), video (9) or the metadata (18). Ping asks for a
# pong with the same bytes.
type Ev is Data:
  Wait{}
  Skip{st: Dec, rest: List<&2, U32>}
  Result{ts: List<&2, A.Tok>, st: Dec, rest: List<&2, U32>}
  Error{msg: String, st: Dec, rest: List<&2, U32>}
  Over{st: Dec, rest: List<&2, U32>}
  Refused{msg: String, st: Dec, rest: List<&2, U32>}
  Media{typ: U32, ts: U32, payload: List<&2, U32>, st: Dec, rest: List<&2, U32>}
  Ping{data: List<&2, U32>, st: Dec, rest: List<&2, U32>}

def Ev.words(+code: String, +desc: String) -> String:
  Bool.pick(String, String.is_empty(desc), code, code ++ ": " ++ desc)

def Ev.status.of(bad: Bool, end: Bool, code: String, desc: String, st: Dec,
  rest: List<&2, U32>) -> Ev:
  match bad end:
    case True{} _:
      Refused{Ev.words(code, desc), st, rest}
    case False{} True{}:
      Over{st, rest}
    case False{} False{}:
      Skip{st, rest}

# An onStatus: the stream ended, was refused, or goes on.
def Ev.status(+code: String, desc: String, st: Dec, rest: List<&2, U32>) -> Ev:
  Ev.status.of(String.contains(code, "Failed") || String.contains(code, "NotFound")
    || String.contains(code, "Rejected") || String.contains(code, "InvalidArg"),
    String.contains(code, "Play.Stop") || String.contains(code, "UnpublishNotify")
    || String.contains(code, "Play.Complete"), code, desc, st, rest)

def Ev.named(res: Bool, err: Bool, status: Bool, +ts: List<&2, A.Tok>, st: Dec,
  rest: List<&2, U32>) -> Ev:
  match res err status:
    case True{} _ _:
      Result{ts, st, rest}
    case False{} True{} _:
      Error{Ev.words(A.Amf.get(ts, "code"), A.Amf.get(ts, "description")), st, rest}
    case False{} False{} True{}:
      Ev.status(A.Amf.get(ts, "code"), A.Amf.get(ts, "description"), st, rest)
    case False{} False{} False{}:
      Skip{st, rest}

def Ev.command(+ts: List<&2, A.Tok>, st: Dec, rest: List<&2, U32>) -> Ev:
  +name = A.Amf.string(A.Amf.at(ts, 0n))
  Ev.named(String.eq(name, "_result"), String.eq(name, "_error"),
    String.eq(name, "onStatus"), ts, st, rest)

# A user control message: event 6 is a ping; the rest is news.
def Ev.user(p: List<&2, U32>, st: Dec, rest: List<&2, U32>) -> Ev:
  match p:
    case Con{0, Con{6, data}}:
      Ping{data, st, rest}
    case _:
      Skip{st, rest}

# A data message as a file wants it: servers pass on the publisher's
# "@setDataFrame" in front of "onMetaData", and a reader of FLV expects
# the name first.
def Ev.data(yes: Bool, p: List<&2, U32>) -> List<&2, U32>:
  match yes p:
    case True{} Con{2, Con{0, Con{13, Con{64, t}}}}:
      B.Bytes.drop(12n, t)
    case _ p:
      p

# Of the data messages only the metadata goes to the file: servers
# also send their own notes as data (a sample-access flag, a status),
# and a reader of FLV takes each for a stream of its own.
def Ev.script(p: List<&2, U32>, ts: U32, st: Dec, rest: List<&2, U32>) -> Ev:
  match p:
    case Con{2, Con{0, Con{10, Con{111, Con{110, Con{77, t}}}}}}:
      Media{18, ts, 2 <> 0 <> 10 <> 111 <> 110 <> 77 <> t, st, rest}
    case _:
      Skip{st, rest}

def Ev.typed(media: Bool, data: Bool, cmd: Bool, user: Bool, typ: U32, ts: U32,
  p: List<&2, U32>, st: Dec, rest: List<&2, U32>) -> Ev:
  match media data cmd user:
    case True{} _ _ _:
      Media{typ, ts, p, st, rest}
    case False{} True{} _ _:
      Ev.script(Ev.data(True{}, p), ts, st, rest)
    case False{} False{} True{} _:
      Ev.command(A.Amf.of(p), st, rest)
    case False{} False{} False{} True{}:
      Ev.user(p, st, rest)
    case False{} False{} False{} False{}:
      Skip{st, rest}

def Ev.of(s: Step) -> Ev:
  match s:
    case More{}:
      Wait{}
    case Part{st, rest}:
      Skip{st, rest}
    case Msg{+typ, ts, _, p, st, rest}:
      Ev.typed(U32.is_eq(typ, 8) || U32.is_eq(typ, 9), U32.is_eq(typ, 18),
        U32.is_eq(typ, 20), U32.is_eq(typ, 4), typ, ts, p, st, rest)

# The next event of a buffer.
def Rtmp.event(st: Dec, buf: List<&2, U32>) -> Ev:
  Ev.of(Rtmp.chunk(st, buf))

# FLV
# ---

# A media message as a session gives it: audio (8), video (9) or the
# metadata (18), its time in ms, and the data in the form an FLV tag
# holds (flv.bend takes frames out of it).
type Tag is Data:
  Tag{typ: U32, ts: U32, data: List<&2, U32>}

# The file's header (audio and video both announced), and the size of
# the tag before the first, which is none.
def Flv.header() -> List<&2, U32>:
  [70, 76, 86, 1, 0, 0, 0, 0, 9, 0, 0, 0, 0]

# A tag: the type, the data's size, the timestamp (its top byte last),
# stream 0, the data, and the tag's whole size after it.
def Flv.tag(typ: U32, +ts: U32, +data: List<&2, U32>) -> List<&2, U32>:
  +n = B.Bytes.len(data)
  typ <> B.Bytes.put24(n, B.Bytes.put24(U32.and(ts, 16777215), U32.shrn(ts, 24n) <> 0
    <> 0 <> 0 <> B.Bytes.cat(data, B.Bytes.put32(U32.add(n, 11), Nil{}))))

# A tag's bytes in a file.
def Flv.of(t: Tag) -> List<&2, U32>:
  Tag{typ, ts, data} = t
  Flv.tag(typ, ts, data)
