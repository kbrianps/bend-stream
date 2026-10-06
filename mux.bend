# From RTP packets to the bytes of the file, in one of two forms:
#
#   raw  each NAL unit after a start code, as it comes (.h264, .h265);
#   TS   the units of a picture gathered into an access unit, which goes
#        out as a PES packet with its time, in MPEG-TS packets (.ts).
#
# A picture's packets share an RTP timestamp, and the last has the
# marker bit: either a new timestamp or the marker ends the access unit.
import Base
import ./bytes.bend as B
import ./rtp.bend as R
import ./ts.bend as T
import ./audio.bend as A

# ts: the form. dep: the units being rebuilt. au: the open access
# unit's NAL units, the last first; at: its RTP time. base: the first
# time seen (based: one was). vcc, tcc: the video's and the tables'
# packet counters. frames: access units written. sets: the parameter
# sets still to go in front of the first. aud: the audio.
type Mux is Data:
  Mux{ts: Bool, h265: Bool, dep: R.Dep, au: List<&2, List<&2, U32>>, at: U32,
    open: Bool, base: U32, based: Bool, vcc: U32, tcc: U32, frames: U32,
    sets: List<&2, U32>, aud: A.Aud}

# What a packet gave: the bytes to write, how many units they hold, and
# the state after.
type Put is Data:
  Put{bytes: List<&2, U32>, units: U32, m: Mux}

def Mux.new(ts: Bool, h265: Bool, sets: List<&2, U32>, aud: A.Aud) -> Mux:
  Mux{ts, h265, R.Dep.new(), Nil{}, 0, False{}, 0, False{}, 0, 0, 0, sets, aud}

def Mux.count(nals: List<&2, List<&2, U32>>, +n: U32) -> U32:
  match nals:
    case Nil{}:
      n
    case Con{_, t}:
      Mux.count(t, U32.add(n, 1))

# The access unit delimiter that opens each access unit in a TS.
def Mux.aud(h265: Bool) -> List<&2, U32>:
  match h265:
    case True{}:
      [0, 0, 0, 1, 70, 1, 80]
    case False{}:
      [0, 0, 0, 1, 9, 240]

def Mux.tables(yes: Bool, +tcc: U32, h265: Bool, audio: U32) -> List<&2, U32>:
  match yes:
    case True{}:
      B.Bytes.cat(T.Ts.pat(tcc), T.Ts.pmt(tcc, Bool.pick(U32, h265, 36, 27), audio))
    case False{}:
      Nil{}

# The open access unit out, if it is to end: the tables again every 30
# pictures, then the picture, 0.7 s after the clock it carries.
def Mux.flush.if(yes: Bool, +h265: Bool, dep: R.Dep, +au: List<&2, List<&2, U32>>,
  +at: U32, open: Bool, +base: U32, based: Bool, +vcc: U32, +tcc: U32, +frames: U32,
  sets: List<&2, U32>, +aud: A.Aud) -> Put:
  match yes:
    case False{}:
      Put{Nil{}, 0, Mux{True{}, h265, dep, au, at, open, base, based, vcc, tcc, frames,
        sets, aud}}
    case True{}:
      +t = U32.sub(at, base)
      +pes = T.Pes.of(224, False{}, U32.add(t, 63000), B.Bytes.cat(sets,
        B.Bytes.cat(Mux.aud(h265), R.Nal.annexb(R.Nal.rev(au, Nil{})))))
      +tables = U32.is_zero(U32.mod(frames, 30))
      Put{B.Bytes.cat(Mux.tables(tables, tcc, h265, A.Aud.type(aud)),
          T.Ts.pes(256, vcc, T.Ts.pcr(t), pes)),
        Mux.count(au, 0), Mux{True{}, h265, dep, Nil{}, at, False{}, base, based,
          U32.add(vcc, T.Ts.count(B.Bytes.len(pes), True{})),
          U32.add(tcc, Bool.pick(U32, tables, 1, 0)), U32.add(frames, 1), Nil{}, aud}}

# End the open access unit when told to, or when the time moved on.
def Mux.flush(m: Mux, rts: U32, force: Bool) -> Put:
  Mux{_, h265, dep, au, +at, +open, base, based, vcc, tcc, frames, sets, aud} = m
  Mux.flush.if(open && (force || U32.is_ne(rts, at)), h265, dep, au, at, open, base,
    based, vcc, tcc, frames, sets, aud)

def Mux.any(nals: List<&2, List<&2, U32>>) -> Bool:
  match nals:
    case Nil{}:
      False{}
    case Con{_, _}:
      True{}

# Units into the open access unit, which is of this time.
def Mux.add(m: Mux, +nals: List<&2, List<&2, U32>>, +rts: U32) -> Mux:
  Mux{ts, h265, dep, au, at, open, base, +based, vcc, tcc, frames, sets, aud} = m
  +has = Mux.any(nals)
  Mux{ts, h265, dep, R.Nal.rev(nals, au), Bool.pick(U32, has, rts, at), open || has,
    Bool.pick(U32, based, base, rts), based || has, vcc, tcc, frames, sets, aud}

def Mux.join.end(p: Put, b1: List<&2, U32>, u1: U32) -> Put:
  Put{b2, u2, m} = p
  Put{B.Bytes.cat(b1, b2), U32.add(u1, u2), m}

def Mux.join(p: Put, nals: List<&2, List<&2, U32>>, marker: Bool, +rts: U32) -> Put:
  Put{b1, u1, m} = p
  Mux.join.end(Mux.flush(Mux.add(m, nals, rts), rts, marker), b1, u1)

def Mux.run(ts: Bool, m: Mux, +nals: List<&2, List<&2, U32>>, marker: Bool,
  +rts: U32) -> Put:
  match ts:
    case False{}:
      Put{R.Nal.annexb(nals), Mux.count(nals, 0), m}
    case True{}:
      Mux.join(Mux.flush(m, rts, False{}), nals, marker, rts)

def Mux.out(o: R.Out, +ts: Bool, h265: Bool, au: List<&2, List<&2, U32>>, at: U32,
  open: Bool, base: U32, based: Bool, vcc: U32, tcc: U32, frames: U32,
  sets: List<&2, U32>, aud: A.Aud, marker: Bool, rts: U32) -> Put:
  match o:
    case R.Out{nals, dep}:
      Mux.run(ts, Mux{ts, h265, dep, au, at, open, base, based, vcc, tcc, frames, sets,
        aud}, nals, marker, rts)

def Mux.dep(h265: Bool, dep: R.Dep, payload: List<&2, U32>) -> R.Out:
  match h265:
    case True{}:
      R.H265.push(dep, payload)
    case False{}:
      R.H264.push(dep, payload)

# A video payload into the state.
def Mux.video(m: Mux, marker: Bool, rts: U32, payload: List<&2, U32>) -> Put:
  Mux{ts, +h265, dep, au, at, open, base, based, vcc, tcc, frames, sets, aud} = m
  Mux.out(Mux.dep(h265, dep, payload), ts, h265, au, at, open, base, based, vcc, tcc,
    frames, sets, aud, marker, rts)

def Mux.sound.end(o: A.Sound, ts: Bool, h265: Bool, dep: R.Dep,
  au: List<&2, List<&2, U32>>, at: U32, open: Bool, base: U32, based: Bool, vcc: U32,
  tcc: U32, frames: U32, sets: List<&2, U32>) -> Put:
  A.Sound{bytes, n, aud} = o
  Put{bytes, n, Mux{ts, h265, dep, au, at, open, base, based, vcc, tcc, frames, sets,
    aud}}

# An audio payload into the state.
def Mux.sound(m: Mux, rts: U32, payload: List<&2, U32>) -> Put:
  Mux{ts, h265, dep, au, at, open, base, based, vcc, tcc, frames, sets, aud} = m
  Mux.sound.end(A.Aud.push(aud, rts, payload), ts, h265, dep, au, at, open, base, based,
    vcc, tcc, frames, sets)

def Mux.audio.pt(m: Mux) -> Mux & U32:
  Mux{ts, h265, dep, au, at, open, base, based, vcc, tcc, frames, sets, +aud} = m
  (Mux{ts, h265, dep, au, at, open, base, based, vcc, tcc, frames, sets, aud},
    A.Aud.pt(aud))

def Mux.mine(video: Bool, audio: Bool, m: Mux, marker: Bool, rts: U32,
  payload: List<&2, U32>) -> Put:
  match video audio:
    case True{} _:
      Mux.video(m, marker, rts, payload)
    case False{} True{}:
      Mux.sound(m, rts, payload)
    case False{} False{}:
      Put{Nil{}, 0, m}

def Mux.typed(ma: Mux & U32, +p: U32, pt: U32, +sound: Bool, marker: Bool, rts: U32,
  payload: List<&2, U32>) -> Put:
  (m, apt) = ma
  Mux.mine(U32.is_eq(p, pt) && Bool.not(sound), U32.is_eq(p, apt) && sound, m, marker,
    rts, payload)

# An RTP packet into the state: the video's, of payload type pt, or
# (sound) one from the audio's channel, of the audio's type; the two
# streams may well use the same number. Another type changes nothing,
# as does something that is no RTP.
def Mux.packet(rtp: R.Rtp, pt: U32, sound: Bool, m: Mux) -> Put:
  match rtp:
    case R.NoRtp{}:
      Put{Nil{}, 0, m}
    case R.Rtp{marker, p, _, ts, _, payload}:
      Mux.typed(Mux.audio.pt(m), p, pt, sound, marker, ts, payload)
