# Frames into the bytes of a file, in one of two forms:
#
#   raw  the video's access units one after the other, the announced
#        parameter sets first (.h264, .h265): what a decoder reads, with
#        no times and no audio;
#   TS   MPEG-TS: each picture and each run of audio frames in a PES
#        packet with its time (.ts).
import Base
import ./bytes.bend as B
import ./ts.bend as T
import ./frame.bend as F

# sets: the parameter sets still to go in front of the first picture.
# vcc, acc, tcc: the packet counters of the video, the audio and the
# tables. n: pictures written.
type Rec is Data:
  Raw{sets: List<&2, U32>}
  Ts{h265: Bool, audio: Bool, vcc: U32, acc: U32, tcc: U32, n: U32, sets: List<&2, U32>}

# What a frame gave: bytes to write, and the state after.
type Wrote is Data:
  Wrote{bytes: List<&2, U32>, r: Rec}

def Rec.raw(i: F.Info) -> Rec:
  Raw{F.Info.sets(i)}

def Rec.ts(+i: F.Info) -> Rec:
  Ts{F.Info.h265(i), F.Info.audio(i), 0, 0, 0, 0, F.Info.sets(i)}

# The form a file's name asks for: TS for .ts, raw for the rest.
def Rec.for(path: String, +i: F.Info) -> Rec:
  Bool.pick(Rec, String.ends_with(String.to_lower(path), ".ts"), Rec.ts(i), Rec.raw(i))

# The access unit delimiter that opens each access unit in a TS.
def Rec.aud(h265: Bool) -> List<&2, U32>:
  match h265:
    case True{}:
      [0, 0, 0, 1, 70, 1, 80]
    case False{}:
      [0, 0, 0, 1, 9, 240]

def Rec.tables(yes: Bool, +tcc: U32, h265: Bool, audio: Bool) -> List<&2, U32>:
  match yes:
    case True{}:
      B.Bytes.cat(T.Ts.pat(tcc), T.Ts.pmt(tcc, Bool.pick(U32, h265, 36, 27),
        Bool.pick(U32, audio, 15, 0)))
    case False{}:
      Nil{}

# A frame into the file. In a TS: the tables again every 30 pictures,
# and everything 0.7 s after the clock the video carries.
def Rec.put(r: Rec, f: F.Frame) -> Wrote:
  match r f:
    case Raw{sets} F.Video{_, _, data}:
      Wrote{B.Bytes.cat(sets, data), Raw{Nil{}}}
    case Raw{sets} F.Audio{_, _}:
      Wrote{Nil{}, Raw{sets}}
    case Ts{+h265, +audio, +vcc, acc, +tcc, +n, sets} F.Video{+pts, _, data}:
      +pes = T.Pes.of(224, False{}, U32.add(pts, 63000),
        B.Bytes.cat(sets, B.Bytes.cat(Rec.aud(h265), data)))
      +tables = U32.is_zero(U32.mod(n, 30))
      Wrote{B.Bytes.cat(Rec.tables(tables, tcc, h265, audio),
          T.Ts.pes(256, vcc, T.Ts.pcr(pts), pes)),
        Ts{h265, audio, U32.add(vcc, T.Ts.count(B.Bytes.len(pes), True{})), acc,
          U32.add(tcc, Bool.pick(U32, tables, 1, 0)), U32.add(n, 1), Nil{}}}
    case Ts{h265, audio, vcc, +acc, tcc, n, sets} F.Audio{pts, data}:
      +pes = T.Pes.of(192, True{}, U32.add(pts, 63000), data)
      Wrote{T.Ts.pes(257, acc, Nil{}, pes),
        Ts{h265, audio, vcc, U32.add(acc, T.Ts.count(B.Bytes.len(pes), False{})), tcc, n,
          sets}}
