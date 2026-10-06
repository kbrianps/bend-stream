# Record a camera or a stream into a file.
#
#   bend pull.bend -o pull
#   ./pull rtsp://user:pass@camera.example:554/stream out.ts 10
#   ./pull rtmp://192.168.0.20/live/cam out.flv 10
#
# The file's name picks the form: .ts is MPEG-TS, with the audio and
# each frame's time; .flv (RTMP only) is the stream's tags as they
# come; anything else is the raw video (.h264, .h265). The last
# argument is how many seconds to record (10 when left out).
#
# It is also the example of the library: open a session, take frames
# until the time is up, close it. It runs as a native binary only (the
# sockets are in net.c); rtsps:// and rtmps:// are the same under TLS,
# and STREAM_CAFILE names a PEM file to trust instead of the system's.
import Base
import ./bytes.bend as B
import ./conn.bend as N
import ./opts.bend as E
import ./frame.bend as F
import ./rec.bend as W
import ./rtsp.bend as S
import ./rtsp_core.bend as C
import ./rtmp.bend as M
import ./rtmp_core.bend as K
import ./flv.bend as V

# What was written: frames (or tags) and bytes; the last frame's time
# and what is added to a frame's time (a stream that comes back starts
# its times over); how many times the stream was lost and found; and
# whether the next tag is the first after one of those (RTMP, whose
# times start anywhere).
type Stat is Data:
  Stat{frames: U32, bytes: U32, last: U32, off: U32, lost: U32, fresh: Bool}

def Stat.add(st: Stat, bytes: U32) -> Stat:
  Stat{n, b, last, off, lost, fresh} = st
  Stat{U32.add(n, 1), U32.add(b, bytes), last, off, lost, fresh}

# The frame at its place in the file, and its time noted.
def Stat.place(st: Stat, f: F.Frame) -> Stat & F.Frame:
  Stat{n, b, last, +off, lost, fresh} = st
  +g = F.Frame.later(f, off)
  (Stat{n, b, U32.max(last, F.Frame.pts(g)), off, lost, fresh}, g)

# The tag at its place in the file: the first after the stream came
# back goes a tenth of a second after the last one written, and the
# rest keep their distance from it.
def Stat.tag(st: Stat, t: K.Tag) -> Stat & K.Tag:
  Stat{n, b, +last, off, lost, fresh} = st
  K.Tag{typ, +ts, data} = t
  +d = Bool.pick(U32, fresh, U32.sub(U32.add(last, 100), ts), off)
  (Stat{n, b, U32.max(last, U32.add(ts, d)), d, lost, False{}},
    K.Tag{typ, U32.add(ts, d), data})

# The stream was lost and found: what comes goes a tenth of a second
# after the last frame written.
def Stat.found(st: Stat) -> Stat:
  Stat{n, b, +last, _, lost, _} = st
  Stat{n, b, last, U32.add(last, 9000), U32.add(lost, 1), True{}}

def Stat.show(st: Stat, kind: String) -> String:
  Stat{n, b, _, _, +lost, _} = st
  "ok: " ++ kind ++ ", " ++ U32.show(n) ++ " frames, " ++ U32.show(b) ++ " bytes"
    ++ Bool.pick(String, U32.is_zero(lost), "", ", reconnected " ++ U32.show(lost)
      ++ Bool.pick(String, U32.is_eq(lost, 1), " time", " times"))

def Pull.error(e: E.Err, st: Stat) -> String:
  Stat{+n, _, _, _, _, _} = st
  "error: " ++ E.Err.show(e) ++ Bool.pick(String, U32.is_zero(n), "",
    " (after " ++ U32.show(n) ++ " frames)")

# Writing
# -------

def Wrote() -> Type:
  File & Result<&1, &1, U32 & String, Unit>

def Pull.save.end(m: Wrote()) -> File:
  (f, _) = m
  f

# Bytes to the file (nothing to do for none).
def Pull.save(bs: List<&2, U32>, f: File) -> IO(File):
  match bs:
    case Nil{}:
      IO.pure(File, f)
    case Con{h, t}:
      do IO<File>:
        m : Wrote() <- File.write_bytes(f, h <> t)
        IO.pure(File, Pull.save.end(m))

# The session x of any kind ended and the file closed, with these words.
def Pull.end(-X: Type, x: X, f: File, stop: X -> IO(Unit), words: String) -> IO(String):
  do IO<String>:
    File.close(f)
    stop(x)
    IO.pure(String, words)

def Pull.timed(up: Bool, -X: Type, x: X, f: File, st: Stat, kind: String,
  stop: X -> IO(Unit), again: X -> File -> Stat -> IO(String)) -> IO(String):
  match up:
    case True{}:
      Pull.end(X, x, f, stop, Stat.show(st, kind))
    case False{}:
      again(x, f, st)

# Bytes written, then: stop if the time is up, else around again.
def Pull.write(-X: Type, +bs: List<&2, U32>, x: X, f: File, until: Nat, st: Stat,
  kind: String, stop: X -> IO(Unit), again: X -> File -> Stat -> IO(String)) ->
  IO(String):
  do IO<String>:
    f2 : File <- Pull.save(bs, f)
    now : Nat <- IO.now()
    Pull.timed(Nat.is_le(until, now), X, x, f2, Stat.add(st, B.Bytes.len(bs)), kind, stop,
      again)

# RTSP
# ----

def Pull.rtsp.put(w: W.Wrote, s: S.Sess, f: File, until: Nat, st: Stat, kind: String,
  again: S.Sess -> File -> W.Rec -> Stat -> IO(String)) -> IO(String):
  W.Wrote{bytes, rec} = w
  Pull.write(S.Sess, bytes, s, f, until, st, kind, S.Rtsp.close,
    s2 => f2 => st2 => again(s2, f2, rec, st2))

def Pull.rtsp.placed(sf: Stat & F.Frame, rec: W.Rec, s: S.Sess, f: File, until: Nat,
  kind: String, again: S.Sess -> File -> W.Rec -> Stat -> IO(String)) -> IO(String):
  (st, frame) = sf
  Pull.rtsp.put(W.Rec.put(rec, frame), s, f, until, st, kind, again)

# The session is open again, or it will not be: what was recorded is
# kept either way, and the file says so.
def Pull.rtsp.found(r: S.Opened(), f: File, rec: W.Rec, st: Stat, +kind: String, +e: E.Err,
  again: S.Sess -> File -> W.Rec -> Stat -> IO(String)) -> IO(String):
  match r:
    case Done{s}:
      again(s, f, rec, Stat.found(st))
    case Fail{_}:
      do IO<String>:
        File.close(f)
        IO.pure(String, Stat.show(st, kind) ++ "; then lost: " ++ E.Err.show(e))

# The stream was lost. If it had been flowing and the error is not one
# that lasts, open it again and go on in the same file.
def Pull.rtsp.lost(retry: Bool, +e: E.Err, f: File, rec: W.Rec, +until: Nat, st: Stat,
  kind: String, o: E.Opts, again: S.Sess -> File -> W.Rec -> Stat -> IO(String)) ->
  IO(String):
  match retry:
    case False{}:
      do IO<String>:
        File.close(f)
        IO.pure(String, Pull.error(e, st))
    case True{}:
      do IO<String>:
        r : S.Opened() <- S.Rtsp.reopen(o, until)
        Pull.rtsp.found(r, f, rec, st, kind, e, again)

def Stat.any(st: Stat) -> Bool:
  Stat{n, _, _, _, _, _} = st
  U32.is_ne(n, 0)

def Pull.rtsp.got(r: S.Read(), f: File, rec: W.Rec, until: Nat, +st: Stat, kind: String,
  o: E.Opts, again: S.Sess -> File -> W.Rec -> Stat -> IO(String)) -> IO(String):
  match r:
    case Fail{+e}:
      Pull.rtsp.lost(Stat.any(st) && Bool.not(E.Err.lasting(e)), e, f, rec, until, st,
        kind, o, again)
    case Done{sf}:
      (s, frame) = sf
      Pull.rtsp.placed(Stat.place(st, frame), rec, s, f, until, kind, again)

# Frame after frame into the file, until the time is up.
def Pull.rtsp.loop(fuel: Nat, s: S.Sess, f: File, rec: W.Rec, +until: Nat, st: Stat,
  +kind: String, +o: E.Opts) -> IO(String):
  match fuel:
    case 0n:
      Pull.end(S.Sess, s, f, S.Rtsp.close, Stat.show(st, kind))
    case 1n+p:
      do IO<String>:
        r : S.Read() <- S.Rtsp.next(s)
        Pull.rtsp.got(r, f, rec, until, st, kind, o, s2 => f2 => rec2 => st2 =>
          Pull.rtsp.loop(p, s2, f2, rec2, until, st2, kind, o))

def Pull.rtsp.file(r: Result<&1, &1, U32 & String, File>, s: S.Sess, rec: W.Rec,
  until: Nat, kind: String, o: E.Opts) -> IO(String):
  match r:
    case Fail{e}:
      (_, msg) = e
      do IO<String>:
        S.Rtsp.close(s)
        IO.pure(String, "error: cannot write the file: " ++ msg)
    case Done{f}:
      Pull.rtsp.loop(4000000000n, s, f, rec, until, Stat{0, 0, 0, 0, 0, False{}}, kind, o)

def Pull.rtsp.at(sa: S.Sess & F.Info, +out: String, ms: U32, o: E.Opts) -> IO(String):
  (s, +info) = sa
  do IO<String>:
    now : Nat <- IO.now()
    f : Result<&1, &1, U32 & String, File> <- File.open(out, "w")
    Pull.rtsp.file(f, s, W.Rec.for(out, info), Nat.add(now, U32.to_nat(ms)),
      F.Info.codec(info), o)

def Pull.rtsp.opened(r: S.Opened(), out: String, ms: U32, o: E.Opts) -> IO(String):
  match r:
    case Fail{e}:
      IO.pure(String, Pull.error(e, Stat{0, 0, 0, 0, 0, False{}}))
    case Done{s}:
      Pull.rtsp.at(S.Rtsp.about(s), out, ms, o)

def Pull.rtsp(+o: E.Opts, out: String, ms: U32) -> IO(String):
  do IO<String>:
    r : S.Opened() <- S.Rtsp.open(o)
    Pull.rtsp.opened(r, out, ms, o)

# RTMP
# ----

# Where an RTMP session's tags go: into an FLV as they are (first: the
# file's header is still to write), or, their frames taken out, into a
# recorder that is made at the first frame, once the stream is known.
type Sink is Data:
  Tags{first: Bool}
  Frames{v: V.Flv, rec: Maybe<&2, W.Rec>, path: String}

type Sunk is Data:
  Sunk{bytes: List<&2, U32>, k: Sink}

def Sink.for(+path: String) -> Sink:
  Bool.pick(Sink, String.ends_with(String.to_lower(path), ".flv"), Tags{True{}},
    Frames{V.Flv.new(), None{}, path})

def Sink.rec(m: Maybe<&2, W.Rec>, path: String, info: F.Info) -> W.Rec:
  match m:
    case Some{r}:
      r
    case None{}:
      W.Rec.for(path, info)

def Sink.wrote(w: W.Wrote, v: V.Flv, path: String) -> Sunk:
  W.Wrote{bytes, rec} = w
  Sunk{bytes, Frames{v, Some{rec}, path}}

def Sink.frames(o: V.Out, rec: Maybe<&2, W.Rec>, +path: String) -> Sunk:
  match o:
    case V.Out{Nil{}, v}:
      Sunk{Nil{}, Frames{v, rec, path}}
    case V.Out{Con{f, _}, +v}:
      Sink.wrote(W.Rec.put(Sink.rec(rec, path, V.Flv.info(v)), f), v, path)

def Sink.put(k: Sink, t: K.Tag) -> Sunk:
  match k:
    case Tags{first}:
      Sunk{B.Bytes.cat(Bool.pick(List<&2, U32>, first, K.Flv.header(), Nil{}), K.Flv.of(t)),
        Tags{False{}}}
    case Frames{v, rec, path}:
      Sink.frames(V.Flv.frames(v, t), rec, path)

def Pull.rtmp.put(u: Sunk, s: M.Sess, f: File, until: Nat, st: Stat,
  again: M.Sess -> File -> Sink -> Stat -> IO(String)) -> IO(String):
  Sunk{bytes, k} = u
  Pull.write(M.Sess, bytes, s, f, until, st, "RTMP", M.Rtmp.close,
    s2 => f2 => st2 => again(s2, f2, k, st2))

def Pull.rtmp.placed(sf: Stat & K.Tag, k: Sink, s: M.Sess, f: File, until: Nat,
  again: M.Sess -> File -> Sink -> Stat -> IO(String)) -> IO(String):
  (st, tag) = sf
  Pull.rtmp.put(Sink.put(k, tag), s, f, until, st, again)

def Pull.rtmp.found(r: M.Opened(), f: File, k: Sink, st: Stat, +e: E.Err,
  again: M.Sess -> File -> Sink -> Stat -> IO(String)) -> IO(String):
  match r:
    case Done{s}:
      again(s, f, k, Stat.found(st))
    case Fail{_}:
      do IO<String>:
        File.close(f)
        IO.pure(String, Stat.show(st, "RTMP") ++ "; then lost: " ++ E.Err.show(e))

# The stream was lost (or its publisher stopped). If it had been flowing
# and the error is not one that lasts, open it again and go on in the
# same file.
def Pull.rtmp.lost(retry: Bool, +e: E.Err, f: File, k: Sink, +until: Nat, st: Stat,
  o: E.Opts, again: M.Sess -> File -> Sink -> Stat -> IO(String)) -> IO(String):
  match retry:
    case False{}:
      do IO<String>:
        File.close(f)
        IO.pure(String, Pull.error(e, st))
    case True{}:
      do IO<String>:
        r : M.Opened() <- M.Rtmp.reopen(o, until)
        Pull.rtmp.found(r, f, k, st, e, again)

def Pull.rtmp.got(r: M.Read(), f: File, k: Sink, until: Nat, +st: Stat, o: E.Opts,
  again: M.Sess -> File -> Sink -> Stat -> IO(String)) -> IO(String):
  match r:
    case Fail{+e}:
      Pull.rtmp.lost(Stat.any(st) && Bool.not(E.Err.lasting(e)), e, f, k, until, st, o,
        again)
    case Done{sf}:
      (s, tag) = sf
      Pull.rtmp.placed(Stat.tag(st, tag), k, s, f, until, again)

# Tag after tag into the file, until the time is up.
def Pull.rtmp.loop(fuel: Nat, s: M.Sess, f: File, k: Sink, +until: Nat, st: Stat,
  +o: E.Opts) -> IO(String):
  match fuel:
    case 0n:
      Pull.end(M.Sess, s, f, M.Rtmp.close, Stat.show(st, "RTMP"))
    case 1n+p:
      do IO<String>:
        r : M.Read() <- M.Rtmp.next(s)
        Pull.rtmp.got(r, f, k, until, st, o, s2 => f2 => k2 => st2 =>
          Pull.rtmp.loop(p, s2, f2, k2, until, st2, o))

def Pull.rtmp.file(r: Result<&1, &1, U32 & String, File>, s: M.Sess, k: Sink,
  until: Nat, o: E.Opts) -> IO(String):
  match r:
    case Fail{e}:
      (_, msg) = e
      do IO<String>:
        M.Rtmp.close(s)
        IO.pure(String, "error: cannot write the file: " ++ msg)
    case Done{f}:
      Pull.rtmp.loop(4000000000n, s, f, k, until, Stat{0, 0, 0, 0, 0, False{}}, o)

def Pull.rtmp.opened(r: M.Opened(), +out: String, ms: U32, o: E.Opts) -> IO(String):
  match r:
    case Fail{e}:
      IO.pure(String, Pull.error(e, Stat{0, 0, 0, 0, 0, False{}}))
    case Done{s}:
      do IO<String>:
        now : Nat <- IO.now()
        f : Result<&1, &1, U32 & String, File> <- File.open(out, "w")
        Pull.rtmp.file(f, s, Sink.for(out), Nat.add(now, U32.to_nat(ms)), o)

def Pull.rtmp(+o: E.Opts, out: String, ms: U32) -> IO(String):
  do IO<String>:
    r : M.Opened() <- M.Rtmp.open(o)
    Pull.rtmp.opened(r, out, ms, o)

# The command line
# ----------------

def Pull.secs(args: List<&2, String>) -> U32:
  match args:
    case Con{n, _}:
      C.Rtsp.num(U32.read(n))
    case Nil{}:
      10

def Pull.copy(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      x <> Pull.copy(rest)

def Pull.ca(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{path}:
      path
    case Fail{_}:
      ""

def Pull.by(rtmp: Bool, o: E.Opts, out: String, ms: U32) -> IO(String):
  match rtmp:
    case True{}:
      Pull.rtmp(o, out, ms)
    case False{}:
      Pull.rtsp(o, out, ms)

def Pull.run(args: List<&2, String>) -> IO(Unit):
  match args:
    case Con{_, Con{+url, Con{out, rest}}}:
      do IO<Unit>:
        ca : Result<&1, &1, U32 & String, String> <- IO.get_env("STREAM_CAFILE")
        words : String <- Pull.by(String.starts_with(String.to_lower(url), "rtmp"),
          E.Opts.ca(E.Opts.new(url), Pull.ca(ca)), out, (Pull.secs(rest) * 1000 : U32))
        IO.print(words)
    case _:
      IO.print("usage: pull rtsp[s]://[user:pass@]host[:port]/path OUT [SECONDS]\n"
        ++ "       pull rtmp[s]://host[:port]/app/stream OUT [SECONDS]")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    Pull.run(Pull.copy(xs))
