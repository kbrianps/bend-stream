# Record a camera or a stream into a file.
#
#   bend pull.bend -- rtsp://user:pass@192.168.0.10:554/stream out.h264 10
#   bend pull.bend -- rtmp://192.168.0.20/live/cam out.flv 10
#
# RTSP gives the video's raw stream (.h264 or .h265); RTMP gives an FLV
# with what the server sends. The last argument is how many seconds to
# record (10 when left out).
import Base
import ./rtsp.bend as S
import ./rtmp.bend as M
import ./rtsp_core.bend as C
import ./conn.bend as N

def Pull.secs(args: List<&2, String>) -> U32:
  match args:
    case Con{n, _}:
      C.Rtsp.num(U32.read(n))
    case Nil{}:
      10

def Pull.show(r: N.Out()) -> String:
  match r:
    case Done{N.Pulled{packets, units, bytes, kind}}:
      "ok: " ++ kind ++ ", " ++ U32.show(packets) ++ " packets, " ++ U32.show(units)
        ++ " units, " ++ U32.show(bytes) ++ " bytes"
    case Fail{e}:
      (code, msg) = e
      "error " ++ U32.show(code) ++ ": " ++ msg

def Pull.copy(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      x <> Pull.copy(rest)

def Pull.by(rtmp: Bool, url: String, out: String, ms: U32) -> IO(N.Out()):
  match rtmp:
    case True{}:
      M.Rtmp.pull(url, out, ms)
    case False{}:
      S.Rtsp.pull(url, out, ms)

def Pull.run(args: List<&2, String>) -> IO(Unit):
  match args:
    case Con{_, Con{+url, Con{out, rest}}}:
      do IO<Unit>:
        r : N.Out() <- Pull.by(String.starts_with(String.to_lower(url), "rtmp://"), url,
          out, (Pull.secs(rest) * 1000 : U32))
        IO.print(Pull.show(r))
    case _:
      IO.print("usage: bend pull.bend -- rtsp://[user:pass@]IP[:port]/path OUT [SECONDS]\n"
        ++ "       bend pull.bend -- rtmp://IP[:port]/app/stream OUT [SECONDS]")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    Pull.run(Pull.copy(xs))
