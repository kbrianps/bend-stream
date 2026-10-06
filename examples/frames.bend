# Print the first 50 frames of a camera: what each is, its time, its size.
#
#   bend examples/frames.bend -o frames
#   ./frames rtsp://user:pass@camera/stream
import Base
import ../bytes.bend as B
import ../conn.bend as N
import ../opts.bend as E
import ../frame.bend as F
import ../rtsp.bend as S

def Show.ms(pts: U32) -> String:
  U32.show(U32.div(pts, 90)) ++ " ms"

def Show.frame(f: F.Frame) -> String:
  match f:
    case F.Video{pts, key, data}:
      Bool.pick(String, key, "video (key)  ", "video        ") ++ Show.ms(pts) ++ ", "
        ++ U32.show(B.Bytes.len(data)) ++ " bytes"
    case F.Audio{pts, data}:
      "audio        " ++ Show.ms(pts) ++ ", " ++ U32.show(B.Bytes.len(data)) ++ " bytes"

def Show.got(r: S.Read(), again: S.Sess -> IO(Unit)) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.print(E.Err.show(e))
    case Done{sf}:
      (s, f) = sf
      do IO<Unit>:
        IO.print(Show.frame(f))
        again(s)

def Show.loop(n: Nat, s: S.Sess) -> IO(Unit):
  match n:
    case 0n:
      S.Rtsp.close(s)
    case 1n+p:
      do IO<Unit>:
        r : S.Read() <- S.Rtsp.next(s)
        Show.got(r, s2 => Show.loop(p, s2))

def Show.opened(r: S.Opened()) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.print(E.Err.show(e))
    case Done{s}:
      Show.loop(50n, s)

def Show.run(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{url, _}}:
      do IO<Unit>:
        r : S.Opened() <- S.Rtsp.open(E.Opts.new(url))
        Show.opened(r)
    case _:
      IO.print("usage: frames rtsp://[user:pass@]host[:port]/path")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    Show.run(xs)
