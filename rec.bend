# Frames into the bytes of a file, in one of four forms:
#
#   raw  the video's access units one after the other, the announced
#        parameter sets first (.h264, .h265): what a decoder reads, with
#        no times and no audio;
#   TS   MPEG-TS: each picture and each run of AAC frames in a PES
#        packet with its time (.ts). G.711 has no place in a TS and is
#        left out.
#   sound  the audio alone, as it comes: AAC with its ADTS headers is an
#        .aac file, G.711 samples an .alaw or .ulaw one;
#   FLV  pictures, their times and the audio, G.711 included (.flv):
#        flvw.bend.
import Base
import ./bytes.bend as B
import ./ts.bend as T
import ./frame.bend as F
import ./flvw.bend as X

# sets: the parameter sets still to go in front of the first picture.
# vcc, acc, tcc: the packet counters of the video, the audio and the
# tables. n: pictures written.
type Rec is Data:
  Raw{sets: List<&2, U32>}
  Snd{}
  Fl{w: X.Fw}
  Ts{h265: Bool, audio: Bool, vcc: U32, acc: U32, tcc: U32, n: U32, sets: List<&2, U32>}

# What a frame gave: bytes to write, and the state after.
type Wrote is Data:
  Wrote{bytes: List<&2, U32>, r: Rec}

def Rec.raw(i: F.Info) -> Rec:
  Raw{F.Info.sets(i)}

def Rec.ts(+i: F.Info) -> Rec:
  Ts{F.Info.h265(i), String.eq(F.Info.audio(i), "AAC"), 0, 0, 0, 0, F.Info.sets(i)}

def Rec.ends(+path: String, a: String, b: String, c: String) -> Bool:
  String.ends_with(path, a) || String.ends_with(path, b) || String.ends_with(path, c)

def Rec.named(+path: String, +i: F.Info) -> Rec:
  Bool.pick(Rec, String.ends_with(path, ".ts"), Rec.ts(i),
    Bool.pick(Rec, String.ends_with(path, ".flv"), Fl{X.Fw.new(i)},
      Bool.pick(Rec, Rec.ends(path, ".aac", ".alaw", ".ulaw"), Snd{}, Rec.raw(i))))

# The form a file's name asks for: TS for .ts, FLV for .flv, the audio
# alone for .aac, .alaw and .ulaw, the raw video for the rest.
def Rec.for(path: String, i: F.Info) -> Rec:
  Rec.named(String.to_lower(path), i)

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

def Rec.flv(p: X.Put) -> Wrote:
  X.Put{bytes, w} = p
  Wrote{bytes, Fl{w}}

# A frame into the file. In a TS: the tables again every 30 pictures,
# and everything 0.7 s after the clock the video carries.
def Rec.put(r: Rec, f: F.Frame) -> Wrote:
  match r f:
    case Raw{sets} F.Video{_, _, data}:
      Wrote{B.Bytes.cat(sets, data), Raw{Nil{}}}
    case Raw{sets} F.Audio{_, _}:
      Wrote{Nil{}, Raw{sets}}
    case Fl{w} f:
      Rec.flv(X.Fw.put(w, f))
    case Snd{} F.Video{_, _, _}:
      Wrote{Nil{}, Snd{}}
    case Snd{} F.Audio{_, data}:
      Wrote{data, Snd{}}
    case Ts{+h265, +audio, +vcc, acc, +tcc, +n, sets} F.Video{+pts, _, data}:
      +pes = T.Pes.of(224, False{}, U32.add(pts, 63000),
        B.Bytes.cat(sets, B.Bytes.cat(Rec.aud(h265), data)))
      +tables = U32.is_zero(U32.mod(n, 30))
      Wrote{B.Bytes.cat(Rec.tables(tables, tcc, h265, audio),
          T.Ts.pes(256, vcc, T.Ts.pcr(pts), pes)),
        Ts{h265, audio, U32.add(vcc, T.Ts.count(B.Bytes.len(pes), True{})), acc,
          U32.add(tcc, Bool.pick(U32, tables, 1, 0)), U32.add(n, 1), Nil{}}}
    case Ts{h265, +audio, vcc, +acc, tcc, n, sets} F.Audio{pts, data}:
      +pes = T.Pes.of(192, True{}, U32.add(pts, 63000), data)
      Wrote{Bool.pick(List<&2, U32>, audio, T.Ts.pes(257, acc, Nil{}, pes), Nil{}),
        Ts{h265, audio, vcc, U32.add(acc, Bool.pick(U32, audio,
          T.Ts.count(B.Bytes.len(pes), False{}), 0)), tcc, n, sets}}
