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
import ./frame.bend as F
import ./rec.bend as W
import ./rtsp.bend as S
import ./rtsp_core.bend as C
import ./rtmp.bend as M
import ./rtmp_core.bend as K
import ./flv.bend as V

# What was written: frames (or tags) and bytes.
type Stat is Data:
  Stat{frames: U32, bytes: U32}

def Stat.add(st: Stat, bytes: U32) -> Stat:
  Stat{n, b} = st
  Stat{U32.add(n, 1), U32.add(b, bytes)}

def Stat.show(st: Stat, kind: String) -> String:
  Stat{n, b} = st
  "ok: " ++ kind ++ ", " ++ U32.show(n) ++ " frames, " ++ U32.show(b) ++ " bytes"

def Pull.error(e: N.Err, st: Stat) -> String:
  Stat{+n, _} = st
  "error: " ++ N.Err.show(e) ++ Bool.pick(String, U32.is_zero(n), "",
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

def Pull.rtsp.got(r: S.Read(), f: File, rec: W.Rec, until: Nat, st: Stat, kind: String,
  again: S.Sess -> File -> W.Rec -> Stat -> IO(String)) -> IO(String):
  match r:
    case Fail{e}:
      do IO<String>:
        File.close(f)
        IO.pure(String, Pull.error(e, st))
    case Done{sf}:
      (s, frame) = sf
      Pull.rtsp.put(W.Rec.put(rec, frame), s, f, until, st, kind, again)

# Frame after frame into the file, until the time is up.
def Pull.rtsp.loop(fuel: Nat, s: S.Sess, f: File, rec: W.Rec, +until: Nat, st: Stat,
  +kind: String) -> IO(String):
  match fuel:
    case 0n:
      Pull.end(S.Sess, s, f, S.Rtsp.close, Stat.show(st, kind))
    case 1n+p:
      do IO<String>:
        r : S.Read() <- S.Rtsp.next(s)
        Pull.rtsp.got(r, f, rec, until, st, kind, s2 => f2 => rec2 => st2 =>
          Pull.rtsp.loop(p, s2, f2, rec2, until, st2, kind))

def Pull.rtsp.file(r: Result<&1, &1, U32 & String, File>, s: S.Sess, rec: W.Rec,
  until: Nat, kind: String) -> IO(String):
  match r:
    case Fail{e}:
      (_, msg) = e
      do IO<String>:
        S.Rtsp.close(s)
        IO.pure(String, "error: cannot write the file: " ++ msg)
    case Done{f}:
      Pull.rtsp.loop(4000000000n, s, f, rec, until, Stat{0, 0}, kind)

def Pull.rtsp.at(sa: S.Sess & F.Info, +out: String, ms: U32) -> IO(String):
  (s, +info) = sa
  do IO<String>:
    now : Nat <- IO.now()
    f : Result<&1, &1, U32 & String, File> <- File.open(out, "w")
    Pull.rtsp.file(f, s, W.Rec.for(out, info), Nat.add(now, U32.to_nat(ms)),
      F.Info.codec(info))

def Pull.rtsp.opened(r: S.Opened(), out: String, ms: U32) -> IO(String):
  match r:
    case Fail{e}:
      IO.pure(String, Pull.error(e, Stat{0, 0}))
    case Done{s}:
      Pull.rtsp.at(S.Rtsp.about(s), out, ms)

def Pull.rtsp(o: N.Opts, out: String, ms: U32) -> IO(String):
  do IO<String>:
    r : S.Opened() <- S.Rtsp.open(o)
    Pull.rtsp.opened(r, out, ms)

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

# The stream's end is no error when something was recorded.
def Pull.rtmp.over(ended: Bool, e: N.Err, st: Stat) -> String:
  match ended:
    case True{}:
      Stat.show(st, "RTMP")
    case False{}:
      Pull.error(e, st)

def Pull.rtmp.failed(+e: N.Err, f: File, st: Stat) -> IO(String):
  N.Err{why, _, _} = e
  do IO<String>:
    File.close(f)
    IO.pure(String, Pull.rtmp.over(N.Why.ended(why), e, st))

def Pull.rtmp.got(r: M.Read(), f: File, k: Sink, until: Nat, st: Stat,
  again: M.Sess -> File -> Sink -> Stat -> IO(String)) -> IO(String):
  match r:
    case Fail{e}:
      Pull.rtmp.failed(e, f, st)
    case Done{sf}:
      (s, tag) = sf
      Pull.rtmp.put(Sink.put(k, tag), s, f, until, st, again)

# Tag after tag into the file, until the time is up.
def Pull.rtmp.loop(fuel: Nat, s: M.Sess, f: File, k: Sink, +until: Nat, st: Stat) ->
  IO(String):
  match fuel:
    case 0n:
      Pull.end(M.Sess, s, f, M.Rtmp.close, Stat.show(st, "RTMP"))
    case 1n+p:
      do IO<String>:
        r : M.Read() <- M.Rtmp.next(s)
        Pull.rtmp.got(r, f, k, until, st, s2 => f2 => k2 => st2 =>
          Pull.rtmp.loop(p, s2, f2, k2, until, st2))

def Pull.rtmp.file(r: Result<&1, &1, U32 & String, File>, s: M.Sess, k: Sink,
  until: Nat) -> IO(String):
  match r:
    case Fail{e}:
      (_, msg) = e
      do IO<String>:
        M.Rtmp.close(s)
        IO.pure(String, "error: cannot write the file: " ++ msg)
    case Done{f}:
      Pull.rtmp.loop(4000000000n, s, f, k, until, Stat{0, 0})

def Pull.rtmp.opened(r: M.Opened(), +out: String, ms: U32) -> IO(String):
  match r:
    case Fail{e}:
      IO.pure(String, Pull.error(e, Stat{0, 0}))
    case Done{s}:
      do IO<String>:
        now : Nat <- IO.now()
        f : Result<&1, &1, U32 & String, File> <- File.open(out, "w")
        Pull.rtmp.file(f, s, Sink.for(out), Nat.add(now, U32.to_nat(ms)))

def Pull.rtmp(o: N.Opts, out: String, ms: U32) -> IO(String):
  do IO<String>:
    r : M.Opened() <- M.Rtmp.open(o)
    Pull.rtmp.opened(r, out, ms)

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

def Pull.by(rtmp: Bool, o: N.Opts, out: String, ms: U32) -> IO(String):
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
          N.Opts.ca(N.Opts.new(url), Pull.ca(ca)), out, (Pull.secs(rest) * 1000 : U32))
        IO.print(words)
    case _:
      IO.print("usage: pull rtsp[s]://[user:pass@]host[:port]/path OUT [SECONDS]\n"
        ++ "       pull rtmp[s]://host[:port]/app/stream OUT [SECONDS]")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    Pull.run(Pull.copy(xs))
