# The frames inside RTMP's tags (the forms FLV keeps them in):
#
#   video  H.264: a codec byte (frame type and 7 for AVC), a packet
#          type, a 24-bit time offset; then either the configuration
#          (the parameter sets, and how many bytes a size takes), or a
#          picture's NAL units, each after its size.
#          H.265, as enhanced RTMP carries it: a byte with its top bit
#          set (frame type and packet type), the four letters "hvc1",
#          and the same two things: the configuration, or a picture,
#          with the time offset (packet type 1) or without (type 3).
#   audio  a format byte, then: for AAC (10), a packet type and either
#          the configuration (profile, rate, channels) or one frame;
#          for G.711 (7 the A-law, 8 the mu-law), the samples.
#
# A picture comes out in Annex B form, the parameter sets in front of
# each key picture; an AAC frame after its ADTS header; G.711 as it is.
# Times are the tags' (ms, plus the video's offset), from the first one
# seen, in 90 kHz ticks. Other codecs are passed over.
import Base
import ./bytes.bend as B
import ./rtmp_core.bend as K
import ./frame.bend as F
import ./audio.bend as U

# lens: the bytes of a NAL unit's size. sets: the parameter sets. obj,
# freq, chan: the audio's configuration. sound: the audio's codec once
# known ("AAC", "PCMA", "PCMU"). base: the first time seen (based: one
# was). video: the video's codec ("H264" until the stream says "H265").
type Flv is Data:
  Flv{lens: U32, sets: List<&2, U32>, obj: U32, freq: U32, chan: U32, sound: String,
    base: U32, based: Bool, video: String}

# What a tag gave: its frames (none, or one), and the state after.
type Out is Data:
  Out{frames: List<&2, F.Frame>, st: Flv}

def Flv.new() -> Flv:
  Flv{4, Nil{}, 0, 0, 0, "", 0, False{}, "H264"}

# What is known of the stream so far (the audio's configuration comes
# before the first picture when there is audio).
def Flv.info(st: Flv) -> F.Info:
  Flv{_, _, _, _, chan, sound, _, _, video} = st
  F.Info{video, Nil{}, sound, 0, chan}

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

# ms since the base, in 90 kHz ticks; a time before the base (audio and
# video do not come in strict order) is the base.
def Flv.ticks(+ms: U32, +base: U32) -> U32:
  Bool.pick(U32, (ms >= base : U32), (U32.sub(ms, base) * 90 : U32), 0)

# A 24-bit time offset as a U32 to add: a negative one wraps around.
def Flv.cts(a: U32, b: U32, c: U32) -> U32:
  +v = U32.or(U32.or(U32.shln(a, 16n), U32.shln(b, 8n)), c)
  Bool.pick(U32, (v >= 8388608 : U32), U32.or(v, 4278190080), v)

def Flv.picture(+key: Bool, +ts: U32, cts: U32, +body: List<&2, U32>, st: Flv) -> Out:
  Flv{+lens, +sets, obj, freq, chan, sound, base, +based, video} = st
  +b = Bool.pick(U32, based, base, ts)
  Out{[F.Video{Flv.ticks(U32.add(ts, cts), b), key,
      B.Bytes.cat(Bool.pick(List<&2, U32>, key, sets, Nil{}),
        Flv.nals(U32.to_nat(B.Bytes.len(body)), lens, body, Nil{}))}],
    Flv{lens, sets, obj, freq, chan, sound, b, True{}, video}}

# H.264's configuration (an AVCDecoderConfigurationRecord).
def Flv.config(body: List<&2, U32>, st: Flv) -> Out:
  match body:
    case Con{_, Con{_, Con{_, Con{_, Con{l, rest}}}}}:
      Flv{_, _, obj, freq, chan, sound, base, based, _} = st
      Out{Nil{}, Flv{U32.add(U32.and(l, 3), 1), Flv.avcc(rest), obj, freq, chan, sound,
        base, based, "H264"}}
    case _:
      Out{Nil{}, st}

# The arrays of an HEVCDecoderConfigurationRecord: each a type byte, a
# 16-bit count, and that many parameter sets (VPS, SPS, PPS).
def Flv.arrays(n: Nat, bs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match n bs:
    case 1n+p Con{_, Con{a, Con{b, t}}}:
      Flv.sets(U32.to_nat(U32.or(U32.shln(a, 8n), b)), t, acc, rest => acc2 =>
        Flv.arrays(p, rest, acc2))
    case _ _:
      acc

def Flv.hvcc.at(bs: List<&2, U32>, st: Flv) -> Out:
  match bs:
    case Con{l, Con{n, rest}}:
      Flv{_, _, obj, freq, chan, sound, base, based, _} = st
      Out{Nil{}, Flv{U32.add(U32.and(l, 3), 1),
        B.Bytes.rev(Flv.arrays(U32.to_nat(n), rest, Nil{})), obj, freq, chan, sound, base,
        based, "H265"}}
    case _:
      Out{Nil{}, st}

# H.265's configuration: after 21 bytes of profile and level, how many
# bytes a size takes, the number of arrays, and the arrays.
def Flv.hvcc(body: List<&2, U32>, st: Flv) -> Out:
  Flv.hvcc.at(B.Bytes.drop(21n, body), st)

def Flv.timed(body: List<&2, U32>, key: Bool, ts: U32, st: Flv) -> Out:
  match body:
    case Con{c0, Con{c1, Con{c2, rest}}}:
      Flv.picture(key, ts, Flv.cts(c0, c1, c2), rest, st)
    case _:
      Out{Nil{}, st}

def Flv.video.kind(avc: Bool, kind: Nat, key: Bool, ts: U32, body: List<&2, U32>,
  st: Flv) -> Out:
  match avc kind:
    case True{} 0n:
      Flv.config(B.Bytes.drop(3n, body), st)
    case True{} 1n:
      Flv.timed(body, key, ts, st)
    case _ _:
      Out{Nil{}, st}

# An enhanced tag of H.265: packet type 0 is the configuration, 1 a
# picture after its time offset, 3 a picture with none.
def Flv.hevc(hvc1: Bool, kind: Nat, key: Bool, ts: U32, body: List<&2, U32>,
  st: Flv) -> Out:
  match hvc1 kind:
    case True{} 0n:
      Flv.hvcc(body, st)
    case True{} 1n:
      Flv.timed(body, key, ts, st)
    case True{} 3n:
      Flv.picture(key, ts, 0, body, st)
    case _ _:
      Out{Nil{}, st}

def Flv.video.by(ex: Bool, +b0: U32, rest: List<&2, U32>, ts: U32, st: Flv) -> Out:
  match ex rest:
    case True{} Con{a, Con{b, Con{c, Con{d, body}}}}:
      Flv.hevc(U32.is_eq(a, 104) && U32.is_eq(b, 118) && U32.is_eq(c, 99)
        && U32.is_eq(d, 49), U32.to_nat(U32.and(b0, 15)),
        U32.is_eq(U32.and(U32.shrn(b0, 4n), 7), 1), ts, body, st)
    case False{} Con{kind, body}:
      Flv.video.kind(U32.is_eq(U32.and(b0, 15), 7), U32.to_nat(kind),
        U32.is_eq(U32.shrn(b0, 4n), 1), ts, body, st)
    case _ _:
      Out{Nil{}, st}

# A video tag: the first byte's top bit says it is an enhanced one.
def Flv.video(data: List<&2, U32>, ts: U32, st: Flv) -> Out:
  match data:
    case Con{+b0, rest}:
      Flv.video.by((b0 >= 128 : U32), b0, rest, ts, st)
    case Nil{}:
      Out{Nil{}, st}

def Flv.sound(+ts: U32, +body: List<&2, U32>, st: Flv) -> Out:
  Flv{lens, sets, +obj, +freq, +chan, +sound, base, +based, video} = st
  +b = Bool.pick(U32, based, base, ts)
  Out{Bool.pick(List<&2, F.Frame>, String.eq(sound, "AAC"), [F.Audio{Flv.ticks(ts, b),
      B.Bytes.cat(U.Aud.adts(B.Bytes.len(body), obj, freq, chan), body)}], Nil{}),
    Flv{lens, sets, obj, freq, chan, sound, b, True{}, video}}

# The audio's configuration: 5 bits of object type, 4 of rate index, 4
# of channels.
def Flv.asc(body: List<&2, U32>, st: Flv) -> Out:
  match body:
    case Con{+a, Con{+b, _}}:
      Flv{lens, sets, _, _, _, _, base, based, video} = st
      Out{Nil{}, Flv{lens, sets, U32.shrn(a, 3n),
        U32.or(U32.shln(U32.and(a, 7), 1n), U32.shrn(b, 7n)), U32.and(U32.shrn(b, 3n), 15),
        "AAC", base, based, video}}
    case _:
      Out{Nil{}, st}

def Flv.aac(data: List<&2, U32>, ts: U32, st: Flv) -> Out:
  match data:
    case Con{0, body}:
      Flv.asc(body, st)
    case Con{1, body}:
      Flv.sound(ts, body, st)
    case _:
      Out{Nil{}, st}

# G.711: the samples as they are, one channel.
def Flv.g711(name: String, +ts: U32, samples: List<&2, U32>, st: Flv) -> Out:
  Flv{lens, sets, obj, freq, _, _, base, +based, video} = st
  +b = Bool.pick(U32, based, base, ts)
  Out{[F.Audio{Flv.ticks(ts, b), samples}],
    Flv{lens, sets, obj, freq, 1, name, b, True{}, video}}

def Flv.audio.by(format: Nat, rest: List<&2, U32>, ts: U32, st: Flv) -> Out:
  match format:
    case 10n:
      Flv.aac(rest, ts, st)
    case 7n:
      Flv.g711("PCMA", ts, rest, st)
    case 8n:
      Flv.g711("PCMU", ts, rest, st)
    case _:
      Out{Nil{}, st}

# An audio tag: the format is the first byte's top 4 bits.
def Flv.audio(data: List<&2, U32>, ts: U32, st: Flv) -> Out:
  match data:
    case Con{b0, rest}:
      Flv.audio.by(U32.to_nat(U32.shrn(b0, 4n)), rest, ts, st)
    case Nil{}:
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
