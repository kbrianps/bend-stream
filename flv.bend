# The frames inside RTMP's tags (the FLV forms of H.264 and AAC):
#
#   video  a codec byte (frame type and 7 for AVC), a packet type, a
#          24-bit time offset; then either the configuration (the
#          parameter sets, and how many bytes a size takes), or a
#          picture's NAL units, each after its size;
#   audio  a format byte (10 for AAC), a packet type; then either the
#          configuration (profile, rate, channels), or one frame.
#
# A picture comes out in Annex B form, the parameter sets in front of
# each key picture; an audio frame after its ADTS header. Times are the
# tags' (ms, plus the video's offset), from the first one seen, in 90
# kHz ticks. Other codecs are passed over.
import Base
import ./bytes.bend as B
import ./rtmp_core.bend as K
import ./frame.bend as F
import ./audio.bend as U

# lens: the bytes of a NAL unit's size. sets: the parameter sets. obj,
# freq, chan: the audio's configuration (sound: one came). base: the
# first time seen (based: one was).
type Flv is Data:
  Flv{lens: U32, sets: List<&2, U32>, obj: U32, freq: U32, chan: U32, sound: Bool,
    base: U32, based: Bool}

# What a tag gave: its frames (none, or one), and the state after.
type Out is Data:
  Out{frames: List<&2, F.Frame>, st: Flv}

def Flv.new() -> Flv:
  Flv{4, Nil{}, 0, 0, 0, False{}, 0, False{}}

# What is known of the stream so far (the audio's configuration comes
# before the first picture when there is audio).
def Flv.info(st: Flv) -> F.Info:
  Flv{_, _, _, _, chan, sound, _, _} = st
  F.Info{"H264", Nil{}, sound, 0, chan}

def Flv.sets.cut(c: B.Cut, acc: List<&2, U32>,
  k: List<&2, U32> -> List<&2, U32> -> List<&2, U32>) -> List<&2, U32>:
  match c:
    case B.Short{}:
      acc
    case B.Cut{nal, rest}:
      k(rest, B.Bytes.onto(nal, 1 <> 0 <> 0 <> 0 <> acc))

# count parameter sets, each after a 16-bit size, onto acc in Annex B
# form, the last first; then what follows them.
def Flv.sets(n: Nat, bs: List<&2, U32>, acc: List<&2, U32>,
  k: List<&2, U32> -> List<&2, U32> -> List<&2, U32>) -> List<&2, U32>:
  match n bs:
    case 1n+p Con{a, Con{b, t}}:
      Flv.sets.cut(B.Bytes.cut(U32.or(U32.shln(a, 8n), b), t), acc, rest => acc2 =>
        Flv.sets(p, rest, acc2, k))
    case _ rest:
      k(rest, acc)

def Flv.pps(bs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match bs:
    case Con{n, t}:
      Flv.sets(U32.to_nat(n), t, acc, _ => acc2 => acc2)
    case Nil{}:
      acc

# The parameter sets of an AVCDecoderConfigurationRecord, after its
# first five bytes: the SPS count in 5 bits, the SPSs, the PPS count,
# the PPSs.
def Flv.avcc(bs: List<&2, U32>) -> List<&2, U32>:
  match bs:
    case Con{n, t}:
      B.Bytes.rev(Flv.sets(U32.to_nat(U32.and(n, 31)), t, Nil{}, rest => acc =>
        Flv.pps(rest, acc)))
    case Nil{}:
      Nil{}

def Flv.nals.cut(c: B.Cut, acc: List<&2, U32>,
  k: List<&2, U32> -> List<&2, U32> -> List<&2, U32>) -> List<&2, U32>:
  match c:
    case B.Short{}:
      B.Bytes.rev(acc)
    case B.Cut{nal, rest}:
      k(rest, B.Bytes.onto(nal, 1 <> 0 <> 0 <> 0 <> acc))

def Flv.nals.at(+bs: List<&2, U32>, +lens: U32, acc: List<&2, U32>,
  k: List<&2, U32> -> List<&2, U32> -> List<&2, U32>) -> List<&2, U32>:
  Flv.nals.cut(B.Bytes.cut(B.Bytes.be(U32.to_nat(lens), bs, 0),
    B.Bytes.drop(U32.to_nat(lens), bs)), acc, k)

# A picture's NAL units, each after its size in lens bytes, onto acc in
# Annex B form, the last first. Every unit takes at least a byte.
def Flv.nals(fuel: Nat, +lens: U32, bs: List<&2, U32>, acc: List<&2, U32>) ->
  List<&2, U32>:
  match fuel bs:
    case 1n+p Con{h, t}:
      Flv.nals.at(h <> t, lens, acc, rest => acc2 => Flv.nals(p, lens, rest, acc2))
    case _ _:
      B.Bytes.rev(acc)

# ms since the base, in 90 kHz ticks.
def Flv.ticks(ms: U32, base: U32) -> U32:
  (U32.sub(ms, base) * 90 : U32)

# A 24-bit time offset as a U32 to add: a negative one wraps around.
def Flv.cts(a: U32, b: U32, c: U32) -> U32:
  +v = U32.or(U32.or(U32.shln(a, 16n), U32.shln(b, 8n)), c)
  Bool.pick(U32, (v >= 8388608 : U32), U32.or(v, 4278190080), v)

def Flv.picture(+key: Bool, +ts: U32, cts: U32, +body: List<&2, U32>, st: Flv) -> Out:
  Flv{+lens, +sets, obj, freq, chan, sound, base, +based} = st
  +b = Bool.pick(U32, based, base, ts)
  Out{[F.Video{Flv.ticks(U32.add(ts, cts), b), key,
      B.Bytes.cat(Bool.pick(List<&2, U32>, key, sets, Nil{}),
        Flv.nals(U32.to_nat(B.Bytes.len(body)), lens, body, Nil{}))}],
    Flv{lens, sets, obj, freq, chan, sound, b, True{}}}

def Flv.config(body: List<&2, U32>, st: Flv) -> Out:
  match body:
    case Con{_, Con{_, Con{_, Con{_, Con{l, rest}}}}}:
      Flv{_, _, obj, freq, chan, sound, base, based} = st
      Out{Nil{}, Flv{U32.add(U32.and(l, 3), 1), Flv.avcc(rest), obj, freq, chan, sound,
        base, based}}
    case _:
      Out{Nil{}, st}

def Flv.video.kind(avc: Bool, kind: Nat, key: Bool, ts: U32, cts: U32,
  body: List<&2, U32>, st: Flv) -> Out:
  match avc kind:
    case True{} 0n:
      Flv.config(body, st)
    case True{} 1n:
      Flv.picture(key, ts, cts, body, st)
    case _ _:
      Out{Nil{}, st}

def Flv.video(data: List<&2, U32>, ts: U32, st: Flv) -> Out:
  match data:
    case Con{+b0, Con{kind, Con{c0, Con{c1, Con{c2, body}}}}}:
      Flv.video.kind(U32.is_eq(U32.and(b0, 15), 7), U32.to_nat(kind),
        U32.is_eq(U32.shrn(b0, 4n), 1), ts, Flv.cts(c0, c1, c2), body, st)
    case _:
      Out{Nil{}, st}

def Flv.sound(+ts: U32, +body: List<&2, U32>, st: Flv) -> Out:
  Flv{lens, sets, +obj, +freq, +chan, +sound, base, +based} = st
  +b = Bool.pick(U32, based, base, ts)
  Out{Bool.pick(List<&2, F.Frame>, sound, [F.Audio{Flv.ticks(ts, b),
      B.Bytes.cat(U.Aud.adts(B.Bytes.len(body), obj, freq, chan), body)}], Nil{}),
    Flv{lens, sets, obj, freq, chan, sound, b, True{}}}

# The audio's configuration: 5 bits of object type, 4 of rate index, 4
# of channels.
def Flv.asc(body: List<&2, U32>, st: Flv) -> Out:
  match body:
    case Con{+a, Con{+b, _}}:
      Flv{lens, sets, _, _, _, _, base, based} = st
      Out{Nil{}, Flv{lens, sets, U32.shrn(a, 3n),
        U32.or(U32.shln(U32.and(a, 7), 1n), U32.shrn(b, 7n)), U32.and(U32.shrn(b, 3n), 15),
        True{}, base, based}}
    case _:
      Out{Nil{}, st}

def Flv.audio.kind(aac: Bool, kind: Nat, ts: U32, body: List<&2, U32>, st: Flv) -> Out:
  match aac kind:
    case True{} 0n:
      Flv.asc(body, st)
    case True{} 1n:
      Flv.sound(ts, body, st)
    case _ _:
      Out{Nil{}, st}

def Flv.audio(data: List<&2, U32>, ts: U32, st: Flv) -> Out:
  match data:
    case Con{b0, Con{kind, body}}:
      Flv.audio.kind(U32.is_eq(U32.shrn(b0, 4n), 10), U32.to_nat(kind), ts, body, st)
    case _:
      Out{Nil{}, st}

def Flv.typed(video: Bool, audio: Bool, data: List<&2, U32>, ts: U32, st: Flv) -> Out:
  match video audio:
    case True{} _:
      Flv.video(data, ts, st)
    case False{} True{}:
      Flv.audio(data, ts, st)
    case False{} False{}:
      Out{Nil{}, st}

# A tag into the state: the frame it holds, if it holds one.
def Flv.frames(st: Flv, t: K.Tag) -> Out:
  K.Tag{+typ, ts, data} = t
  Flv.typed(U32.is_eq(typ, 9), U32.is_eq(typ, 8), data, ts, st)
