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

# ts: the form. dep: the units being rebuilt. au: the open access
# unit's NAL units, the last first; at: its RTP time. base: the first
# time seen (based: one was). vcc, tcc: the video's and the tables'
# packet counters. frames: access units written. sets: the parameter
# sets still to go in front of the first.
type Mux is Data:
  Mux{ts: Bool, h265: Bool, dep: R.Dep, au: List<&2, List<&2, U32>>, at: U32,
    open: Bool, base: U32, based: Bool, vcc: U32, tcc: U32, frames: U32,
    sets: List<&2, U32>}

# What a packet gave: the bytes to write, how many units they hold, and
# the state after.
type Put is Data:
  Put{bytes: List<&2, U32>, units: U32, m: Mux}

def Mux.new(ts: Bool, h265: Bool, sets: List<&2, U32>) -> Mux:
  Mux{ts, h265, R.Dep.new(), Nil{}, 0, False{}, 0, False{}, 0, 0, 0, sets}

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

def Mux.tables(yes: Bool, +tcc: U32, h265: Bool) -> List<&2, U32>:
  match yes:
    case True{}:
      B.Bytes.cat(T.Ts.pat(tcc), T.Ts.pmt(tcc, Bool.pick(U32, h265, 36, 27), 0))
    case False{}:
      Nil{}

# The open access unit out, if it is to end: the tables again every 30
# pictures, then the picture, 0.7 s after the clock it carries.
def Mux.flush.if(yes: Bool, +h265: Bool, dep: R.Dep, +au: List<&2, List<&2, U32>>,
  +at: U32, open: Bool, +base: U32, based: Bool, +vcc: U32, +tcc: U32, +frames: U32,
  sets: List<&2, U32>) -> Put:
  match yes:
    case False{}:
      Put{Nil{}, 0, Mux{True{}, h265, dep, au, at, open, base, based, vcc, tcc, frames,
        sets}}
    case True{}:
      +t = U32.sub(at, base)
      +pes = T.Pes.of(224, False{}, U32.add(t, 63000), B.Bytes.cat(sets,
        B.Bytes.cat(Mux.aud(h265), R.Nal.annexb(R.Nal.rev(au, Nil{})))))
      +tables = U32.is_zero(U32.mod(frames, 30))
      Put{B.Bytes.cat(Mux.tables(tables, tcc, h265), T.Ts.pes(256, vcc, T.Ts.pcr(t), pes)),
        Mux.count(au, 0), Mux{True{}, h265, dep, Nil{}, at, False{}, base, based,
          U32.add(vcc, T.Ts.count(B.Bytes.len(pes), True{})),
          U32.add(tcc, Bool.pick(U32, tables, 1, 0)), U32.add(frames, 1), Nil{}}}

# End the open access unit when told to, or when the time moved on.
def Mux.flush(m: Mux, rts: U32, force: Bool) -> Put:
  Mux{_, h265, dep, au, +at, +open, base, based, vcc, tcc, frames, sets} = m
  Mux.flush.if(open && (force || U32.is_ne(rts, at)), h265, dep, au, at, open, base,
    based, vcc, tcc, frames, sets)

def Mux.any(nals: List<&2, List<&2, U32>>) -> Bool:
  match nals:
    case Nil{}:
      False{}
    case Con{_, _}:
      True{}

# Units into the open access unit, which is of this time.
def Mux.add(m: Mux, +nals: List<&2, List<&2, U32>>, +rts: U32) -> Mux:
  Mux{ts, h265, dep, au, at, open, base, +based, vcc, tcc, frames, sets} = m
  +has = Mux.any(nals)
  Mux{ts, h265, dep, R.Nal.rev(nals, au), Bool.pick(U32, has, rts, at), open || has,
    Bool.pick(U32, based, base, rts), based || has, vcc, tcc, frames, sets}

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
  sets: List<&2, U32>, marker: Bool, rts: U32) -> Put:
  match o:
    case R.Out{nals, dep}:
      Mux.run(ts, Mux{ts, h265, dep, au, at, open, base, based, vcc, tcc, frames, sets},
        nals, marker, rts)

def Mux.dep(h265: Bool, dep: R.Dep, payload: List<&2, U32>) -> R.Out:
  match h265:
    case True{}:
      R.H265.push(dep, payload)
    case False{}:
      R.H264.push(dep, payload)

# A video payload into the state.
def Mux.video(m: Mux, marker: Bool, rts: U32, payload: List<&2, U32>) -> Put:
  Mux{ts, +h265, dep, au, at, open, base, based, vcc, tcc, frames, sets} = m
  Mux.out(Mux.dep(h265, dep, payload), ts, h265, au, at, open, base, based, vcc, tcc,
    frames, sets, marker, rts)

def Mux.mine(yes: Bool, m: Mux, marker: Bool, rts: U32, payload: List<&2, U32>) -> Put:
  match yes:
    case True{}:
      Mux.video(m, marker, rts, payload)
    case False{}:
      Put{Nil{}, 0, m}

# An RTP packet of the video's payload type into the state; another
# type, or something that is no RTP, changes nothing.
def Mux.packet(rtp: R.Rtp, pt: U32, m: Mux) -> Put:
  match rtp:
    case R.NoRtp{}:
      Put{Nil{}, 0, m}
    case R.Rtp{marker, p, _, ts, _, payload}:
      Mux.mine(U32.is_eq(p, pt), m, marker, ts, payload)
