# From RTP packets to frames: the video's NAL units gathered into one
# access unit per picture, the audio's frames as they come.
#
# A picture's packets share an RTP timestamp, and the last has the
# marker bit: either a new timestamp or the marker ends the access unit.
import Base
import ./bytes.bend as B
import ./rtp.bend as R
import ./audio.bend as A
import ./frame.bend as F

# dep: the units being rebuilt. au: the open access unit's NAL units,
# the last first; at: its RTP time. base: the first time seen (based:
# one was). aud: the audio.
type Asm is Data:
  Asm{h265: Bool, dep: R.Dep, au: List<&2, List<&2, U32>>, at: U32, open: Bool,
    base: U32, based: Bool, aud: A.Aud}

# What a packet gave: the frames it completed, and the state after.
type Got is Data:
  Got{frames: List<&2, F.Frame>, st: Asm}

def Asm.new(h265: Bool, aud: A.Aud) -> Asm:
  Asm{h265, R.Dep.new(), Nil{}, 0, False{}, 0, False{}, aud}

# A unit a decoder can start at: an IDR slice (H.264 type 5), or an
# IRAP picture (H.265 types 16 to 21).
def Asm.idr(h265: Bool, +b: U32) -> Bool:
  match h265:
    case True{}:
      (U32.and(U32.shrn(b, 1n), 63) >= 16 && U32.and(U32.shrn(b, 1n), 63) <= 21 : U32)
    case False{}:
      U32.is_eq(U32.and(b, 31), 5)

def Asm.key(+h265: Bool, au: List<&2, List<&2, U32>>) -> Bool:
  match au:
    case Nil{}:
      False{}
    case Con{Con{b, _}, t}:
      Asm.idr(h265, b) || Asm.key(h265, t)
    case Con{Nil{}, t}:
      Asm.key(h265, t)

# The open access unit out, if it is to end.
def Asm.flush.if(yes: Bool, +h265: Bool, dep: R.Dep, +au: List<&2, List<&2, U32>>,
  +at: U32, open: Bool, +base: U32, based: Bool, aud: A.Aud) -> Got:
  match yes:
    case False{}:
      Got{Nil{}, Asm{h265, dep, au, at, open, base, based, aud}}
    case True{}:
      Got{[F.Video{U32.sub(at, base), Asm.key(h265, au),
          R.Nal.annexb(R.Nal.rev(au, Nil{}))}],
        Asm{h265, dep, Nil{}, at, False{}, base, based, aud}}

# End the open access unit when told to, or when the time moved on.
def Asm.flush(m: Asm, rts: U32, force: Bool) -> Got:
  Asm{h265, dep, au, +at, +open, base, based, aud} = m
  Asm.flush.if(open && (force || U32.is_ne(rts, at)), h265, dep, au, at, open, base,
    based, aud)

def Asm.any(nals: List<&2, List<&2, U32>>) -> Bool:
  match nals:
    case Nil{}:
      False{}
    case Con{_, _}:
      True{}

# Units into the open access unit, which is of this time.
def Asm.add(m: Asm, +nals: List<&2, List<&2, U32>>, +rts: U32) -> Asm:
  Asm{h265, dep, au, at, open, base, +based, aud} = m
  +has = Asm.any(nals)
  Asm{h265, dep, R.Nal.rev(nals, au), Bool.pick(U32, has, rts, at), open || has,
    Bool.pick(U32, based, base, rts), based || has, aud}

def Asm.join.end(g: Got, f1: List<&2, F.Frame>) -> Got:
  Got{f2, m} = g
  Got{List.append(&2, F.Frame, f1, f2), m}

def Asm.join(g: Got, nals: List<&2, List<&2, U32>>, marker: Bool, +rts: U32) -> Got:
  Got{f1, m} = g
  Asm.join.end(Asm.flush(Asm.add(m, nals, rts), rts, marker), f1)

def Asm.out(o: R.Out, h265: Bool, au: List<&2, List<&2, U32>>, at: U32, open: Bool,
  base: U32, based: Bool, aud: A.Aud, marker: Bool, +rts: U32) -> Got:
  match o:
    case R.Out{nals, dep}:
      Asm.join(Asm.flush(Asm{h265, dep, au, at, open, base, based, aud}, rts, False{}),
        nals, marker, rts)

def Asm.dep(h265: Bool, dep: R.Dep, payload: List<&2, U32>) -> R.Out:
  match h265:
    case True{}:
      R.H265.push(dep, payload)
    case False{}:
      R.H264.push(dep, payload)

# A video payload into the state.
def Asm.video(m: Asm, marker: Bool, rts: U32, payload: List<&2, U32>) -> Got:
  Asm{+h265, dep, au, at, open, base, based, aud} = m
  Asm.out(Asm.dep(h265, dep, payload), h265, au, at, open, base, based, aud, marker, rts)

def Asm.sound.end(o: A.Sound, h265: Bool, dep: R.Dep, au: List<&2, List<&2, U32>>,
  at: U32, open: Bool, base: U32, based: Bool) -> Got:
  A.Sound{frames, aud} = o
  Got{frames, Asm{h265, dep, au, at, open, base, based, aud}}

# An audio payload into the state.
def Asm.sound(m: Asm, rts: U32, payload: List<&2, U32>) -> Got:
  Asm{h265, dep, au, at, open, base, based, aud} = m
  Asm.sound.end(A.Aud.push(aud, rts, payload), h265, dep, au, at, open, base, based)

def Asm.audio.pt(m: Asm) -> Asm & U32:
  Asm{h265, dep, au, at, open, base, based, +aud} = m
  (Asm{h265, dep, au, at, open, base, based, aud}, A.Aud.pt(aud))

def Asm.mine(video: Bool, audio: Bool, m: Asm, marker: Bool, rts: U32,
  payload: List<&2, U32>) -> Got:
  match video audio:
    case True{} _:
      Asm.video(m, marker, rts, payload)
    case False{} True{}:
      Asm.sound(m, rts, payload)
    case False{} False{}:
      Got{Nil{}, m}

def Asm.typed(ma: Asm & U32, +p: U32, pt: U32, +sound: Bool, marker: Bool, rts: U32,
  payload: List<&2, U32>) -> Got:
  (m, apt) = ma
  Asm.mine(U32.is_eq(p, pt) && Bool.not(sound), U32.is_eq(p, apt) && sound, m, marker,
    rts, payload)

# An RTP packet into the state: the video's, of payload type pt, or
# (sound) one from the audio's channel, of the audio's type; the two
# streams may well use the same number. Another type changes nothing,
# as does something that is no RTP.
def Asm.packet(rtp: R.Rtp, pt: U32, sound: Bool, m: Asm) -> Got:
  match rtp:
    case R.NoRtp{}:
      Got{Nil{}, m}
    case R.Rtp{marker, p, _, ts, _, payload}:
      Asm.typed(Asm.audio.pt(m), p, pt, sound, marker, ts, payload)
