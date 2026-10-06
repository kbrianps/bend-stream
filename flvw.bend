# Frames into an FLV file: the one container here that holds pictures,
# their times, and the audio most cameras send (G.711) together.
#
#   video  H.264 as FLV has it: a configuration tag made of the SPS and
#          the PPS, then a tag per picture, its NAL units each after
#          its size. H.265 the same way under enhanced RTMP's header
#          ("hvc1"), the configuration made of the VPS, SPS and PPS.
#   audio  G.711 as it is (format 7 for the A-law, 8 for the mu-law);
#          AAC as a configuration tag and a tag per frame, each frame
#          without the ADTS header it came with.
#
# No picture is written before a key one whose parameter sets are known:
# they come from the stream's description, or with the picture.
import Base
import ./bytes.bend as B
import ./frame.bend as F
import ./rtmp_core.bend as K

# NAL units
# ---------

def Nal.push(cur: List<&2, U32>, acc: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match cur:
    case Nil{}:
      acc
    case Con{h, t}:
      B.Bytes.rev(h <> t) <> acc

def Nal.split.go(bs: List<&2, U32>, cur: List<&2, U32>,
  acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, Nal.push(cur, acc))
    case Con{0, Con{0, Con{0, Con{1, t}}}}:
      Nal.split.go(t, Nil{}, Nal.push(cur, acc))
    case Con{b, t}:
      Nal.split.go(t, b <> cur, acc)

# The units of an Annex B stream: what is between its start codes (00
# 00 00 01, which no unit can hold: a unit escapes two zeros in a row).
def Nal.split(bs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Nal.split.go(bs, Nil{}, Nil{})

# A unit's type: 5 bits of its first byte in H.264, 6 in H.265.
def Nal.type(h265: Bool, +b: U32) -> U32:
  match h265:
    case True{}:
      U32.and(U32.shrn(b, 1n), 63)
    case False{}:
      U32.and(b, 31)

# The first unit of a type, or nothing.
def Nal.find(nals: List<&2, List<&2, U32>>, +h265: Bool, +want: U32) -> List<&2, U32>:
  match nals:
    case Nil{}:
      Nil{}
    case Con{Nil{}, rest}:
      Nal.find(rest, h265, want)
    case Con{Con{+b, t}, rest}:
      Bool.pick(List<&2, U32>, U32.is_eq(Nal.type(h265, b), want), b <> t,
        Nal.find(rest, h265, want))

# Units each after its size in 4 bytes, as a tag holds a picture.
def Nal.sized(nals: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match nals:
    case Nil{}:
      Nil{}
    case Con{+n, rest}:
      B.Bytes.put32(B.Bytes.len(n), B.Bytes.cat(n, Nal.sized(rest)))

# A unit after its size in 2 bytes, as a configuration holds a
# parameter set.
def Nal.set(+n: List<&2, U32>, rest: List<&2, U32>) -> List<&2, U32>:
  B.Bytes.put16(B.Bytes.len(n), B.Bytes.cat(n, rest))

# The first n bytes of a unit with its escapes taken out (a 03 after
# two zeros is not data).
def Nal.plain(n: Nat, bs: List<&2, U32>, +zeros: U32) -> List<&2, U32>:
  match n bs:
    case 1n+p Con{+b, t}:
      +skip = (zeros >= 2 : U32) && U32.is_eq(b, 3)
      +rest = Nal.plain(p, t, Bool.pick(U32, skip, 0,
        Bool.pick(U32, U32.is_zero(b), U32.add(zeros, 1), 0)))
      Bool.pick(List<&2, U32>, skip, rest, b <> rest)
    case _ _:
      Nil{}

# Configurations
# --------------

# H.264's (an AVCDecoderConfigurationRecord): the profile and level out
# of the SPS, sizes of 4 bytes, one SPS, one PPS. Nothing when either
# is missing.
def Conf.avc(+sps: List<&2, U32>, +pps: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_zero(B.Bytes.len(sps)) || U32.is_zero(B.Bytes.len(pps)),
    Nil{},
    23 <> 0 <> 0 <> 0 <> 0 <> 1 <> B.Bytes.cat(B.Bytes.take(3n, B.Bytes.drop(1n, sps)),
      255 <> 225 <> Nal.set(sps, 1 <> Nal.set(pps, Nil{}))))

# H.265's (an HEVCDecoderConfigurationRecord) after enhanced RTMP's
# header: the 12 bytes of profile, tier and level out of the SPS (they
# follow its 2 bytes of header and one of ids), then what a decoder
# reads again in the SPS itself, sizes of 4 bytes, and three arrays of
# one: VPS (32), SPS (33), PPS (34). Nothing when one is missing.
def Conf.hevc(+vps: List<&2, U32>, +sps: List<&2, U32>, +pps: List<&2, U32>) ->
  List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_zero(B.Bytes.len(vps)) || U32.is_zero(B.Bytes.len(sps))
    || U32.is_zero(B.Bytes.len(pps)), Nil{},
    144 <> 104 <> 118 <> 99 <> 49 <> 1
      <> B.Bytes.cat(B.Bytes.take(12n, B.Bytes.drop(3n, Nal.plain(24n, sps, 0))),
        240 <> 0 <> 252 <> 253 <> 248 <> 248 <> 0 <> 0 <> 15 <> 3
          <> 160 <> 0 <> 1 <> Nal.set(vps, 161 <> 0 <> 1 <> Nal.set(sps,
            162 <> 0 <> 1 <> Nal.set(pps, Nil{})))))

def Conf.video(h265: Bool, +nals: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match h265:
    case True{}:
      Conf.hevc(Nal.find(nals, True{}, 32), Nal.find(nals, True{}, 33),
        Nal.find(nals, True{}, 34))
    case False{}:
      Conf.avc(Nal.find(nals, False{}, 7), Nal.find(nals, False{}, 8))

# The writer
# ----------

# first: the file's header is still to write. vconf, aconf: the video's
# and the audio's configurations were written. audio: its codec. step:
# an AAC frame's length in ms. sets: the parameter sets of the stream's
# description.
type Fw is Data:
  Fw{first: Bool, h265: Bool, vconf: Bool, aconf: Bool, audio: String, step: U32,
    sets: List<&2, List<&2, U32>>}

# What a frame gave: bytes to write, and the state after.
type Put is Data:
  Put{bytes: List<&2, U32>, w: Fw}

def Fw.new(+i: F.Info) -> Fw:
  Fw{True{}, F.Info.h265(i), False{}, False{}, F.Info.audio(i),
    U32.div(1024000, U32.max(F.Info.rate(i), 8000)), Nal.split(F.Info.sets(i))}

def Fw.head(first: Bool) -> List<&2, U32>:
  match first:
    case True{}:
      K.Flv.header()
    case False{}:
      Nil{}

# The tag a picture goes in: H.264's header (key or not, a picture, no
# time offset) or H.265's (key or not, a picture with no offset, "hvc1").
def Fw.picture(h265: Bool, key: Bool, body: List<&2, U32>) -> List<&2, U32>:
  match h265:
    case True{}:
      Bool.pick(U32, key, 147, 163) <> 104 <> 118 <> 99 <> 49 <> body
    case False{}:
      Bool.pick(U32, key, 23, 39) <> 1 <> 0 <> 0 <> 0 <> body

def Fw.conf.tag(conf: List<&2, U32>, ms: U32) -> List<&2, U32>:
  match conf:
    case Nil{}:
      Nil{}
    case Con{h, t}:
      K.Flv.tag(9, ms, h <> t)

# A picture. The file's video starts at a key picture, after its
# configuration (made from the description's parameter sets or the
# picture's own): what comes before one a decoder could not use.
def Fw.video(w: Fw, +ms: U32, +key: Bool, data: List<&2, U32>) -> Put:
  Fw{+first, +h265, +vconf, aconf, audio, step, +sets} = w
  +nals = Nal.split(data)
  +conf = Bool.pick(List<&2, U32>, vconf, Nil{},
    Conf.video(h265, List.append(&2, List<&2, U32>, sets, nals)))
  +ready = vconf || (key && Bool.not(U32.is_zero(B.Bytes.len(conf))))
  Put{Bool.pick(List<&2, U32>, ready, B.Bytes.cat(Fw.head(first),
      B.Bytes.cat(Fw.conf.tag(conf, ms),
        K.Flv.tag(9, ms, Fw.picture(h265, key, Nal.sized(nals))))), Nil{}),
    Fw{first && Bool.not(ready), h265, ready, aconf, audio, step, sets}}

# AAC's configuration out of a frame's ADTS header: profile, rate index
# and channels, in 2 bytes, in a tag of its own.
def Fw.asc(done: Bool, data: List<&2, U32>, ms: U32) -> List<&2, U32>:
  match done data:
    case False{} Con{_, Con{_, Con{+b2, Con{b3, _}}}}:
      K.Flv.tag(8, ms, [175, 0,
        U32.or(U32.shln(U32.add(U32.and(U32.shrn(b2, 6n), 3), 1), 3n),
          U32.shrn(U32.and(U32.shrn(b2, 2n), 15), 1n)),
        U32.or(U32.shln(U32.and(U32.shrn(b2, 2n), 1), 7n),
          U32.shln(U32.or(U32.shln(U32.and(b2, 1), 2n), U32.shrn(b3, 6n)), 3n))])
    case _ _:
      Nil{}

def Fw.aac.cut(c: B.Cut, +ms: U32, acc: List<&2, U32>,
  k: List<&2, U32> -> List<&2, U32> -> List<&2, U32>) -> List<&2, U32>:
  match c:
    case B.Short{}:
      acc
    case B.Cut{raw, rest}:
      k(rest, B.Bytes.cat(acc, K.Flv.tag(8, ms, 175 <> 1 <> raw)))

# Each ADTS frame (a 7-byte header that says its size in 13 bits) as a
# tag of the frame alone, step ms after the one before.
def Fw.aac(fuel: Nat, bs: List<&2, U32>, +ms: U32, +step: U32, acc: List<&2, U32>) ->
  List<&2, U32>:
  match fuel bs:
    case 1n+p Con{_, Con{_, Con{_, Con{b3, Con{b4, Con{b5, Con{_, rest}}}}}}}:
      Fw.aac.cut(B.Bytes.cut(U32.sub(U32.max(U32.or(U32.or(
        U32.shln(U32.and(b3, 3), 11n), U32.shln(b4, 3n)), U32.shrn(b5, 5n)), 7), 7),
        rest), ms, acc, r => a => Fw.aac(p, r, U32.add(ms, step), step, a))
    case _ _:
      acc

def Fw.sound(aac: Bool, alaw: Bool, ulaw: Bool, first: Bool, h265: Bool, vconf: Bool,
  +aconf: Bool, audio: String, +step: U32, sets: List<&2, List<&2, U32>>, +ms: U32,
  +data: List<&2, U32>) -> Put:
  match aac alaw ulaw:
    case True{} _ _:
      Put{B.Bytes.cat(Fw.head(first), B.Bytes.cat(Fw.asc(aconf, data, ms),
          Fw.aac(U32.to_nat(B.Bytes.len(data)), data, ms, step, Nil{}))),
        Fw{False{}, h265, vconf, True{}, audio, step, sets}}
    case False{} True{} _:
      Put{B.Bytes.cat(Fw.head(first), K.Flv.tag(8, ms, 114 <> data)),
        Fw{False{}, h265, vconf, aconf, audio, step, sets}}
    case False{} False{} True{}:
      Put{B.Bytes.cat(Fw.head(first), K.Flv.tag(8, ms, 130 <> data)),
        Fw{False{}, h265, vconf, aconf, audio, step, sets}}
    case False{} False{} False{}:
      Put{Nil{}, Fw{first, h265, vconf, aconf, audio, step, sets}}

def Fw.audio(w: Fw, ms: U32, data: List<&2, U32>) -> Put:
  Fw{first, h265, vconf, aconf, +audio, step, sets} = w
  Fw.sound(String.eq(audio, "AAC"), String.eq(audio, "PCMA"), String.eq(audio, "PCMU"),
    first, h265, vconf, aconf, audio, step, sets, ms, data)

# A frame into the file; its time in ms.
def Fw.put(w: Fw, f: F.Frame) -> Put:
  match f:
    case F.Video{pts, key, data}:
      Fw.video(w, U32.div(pts, 90), key, data)
    case F.Audio{pts, data}:
      Fw.audio(w, U32.div(pts, 90), data)
