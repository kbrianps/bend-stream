# RTP (RFC 3550) and the H.264 and H.265 payload formats (RFC 6184, RFC
# 7798): a packet's header and payload, and the NAL units rebuilt from
# single-unit, aggregation and fragmentation packets, written out in
# Annex B form (each unit after a 00 00 00 01 start code), which is what
# a decoder or `ffprobe` reads as a raw .h264 or .h265 file.
#
# Not done: reordering and loss. Over RTSP's interleaved TCP there is
# neither; over UDP a fragment lost in the middle would leave a broken
# unit.
import Base
import ./bytes.bend as B

# A packet: the marker bit, payload type, sequence number, timestamp,
# source, and the payload with any padding and extension taken off.
type Rtp is Data:
  NoRtp{}
  Rtp{marker: Bool, pt: U32, seq: U32, ts: U32, ssrc: U32, payload: List<&2, U32>}

# Header
# ------

def Rtp.ext(yes: Bool, bs: List<&2, U32>) -> List<&2, U32>:
  match yes bs:
    case True{} Con{_, Con{_, Con{a, Con{b, t}}}}:
      B.Bytes.drop(U32.to_nat((U32.or(U32.shln(a, 8n), b) * 4 : U32)), t)
    case True{} _:
      Nil{}
    case False{} rest:
      rest

# The last byte of a reversed list says how many bytes of padding the
# packet ends with, itself included.
def Rtp.unpad.rev(rev: List<&2, U32>) -> List<&2, U32>:
  match rev:
    case Nil{}:
      Nil{}
    case Con{+n, t}:
      B.Bytes.rev(B.Bytes.drop(U32.to_nat(n), n <> t))

def Rtp.unpad(yes: Bool, bs: List<&2, U32>) -> List<&2, U32>:
  match yes:
    case True{}:
      Rtp.unpad.rev(B.Bytes.rev(bs))
    case False{}:
      bs

def Rtp.with(v2: Bool, +b0: U32, +b1: U32, seq: U32, ts: U32, ssrc: U32,
  rest: List<&2, U32>) -> Rtp:
  match v2:
    case False{}:
      NoRtp{}
    case True{}:
      Rtp{(b1 >= 128 : U32), U32.and(b1, 127), seq, ts, ssrc,
        Rtp.unpad(U32.is_eq(U32.and(b0, 32), 32),
          Rtp.ext(U32.is_eq(U32.and(b0, 16), 16),
            B.Bytes.drop(U32.to_nat((U32.and(b0, 15) * 4 : U32)), rest)))}

# A packet from its bytes: version 2, then the CSRC list, the header
# extension and the padding skipped (RFC 3550 5.1). NoRtp when it is
# too short or another version.
def Rtp.of(bs: List<&2, U32>) -> Rtp:
  match bs:
    case Con{+b0, Con{b1, Con{s0, Con{s1, Con{t0, Con{t1, Con{t2, Con{t3,
      Con{c0, Con{c1, Con{c2, Con{c3, rest}}}}}}}}}}}}:
      Rtp.with(U32.is_eq(U32.shrn(b0, 6n), 2), b0, b1, U32.or(U32.shln(s0, 8n), s1),
        B.Bytes.u32([t0, t1, t2, t3]), B.Bytes.u32([c0, c1, c2, c3]), rest)
    case _:
      NoRtp{}

# Rebuilding units
# ----------------

# The fragments of the unit being rebuilt, the last one first, and
# whether one is open.
type Dep is Data:
  Dep{frags: List<&2, List<&2, U32>>, on: Bool}

# The units a packet completed, in order, and the state after it.
type Out is Data:
  Out{nals: List<&2, List<&2, U32>>, st: Dep}

def Dep.new() -> Dep:
  Dep{Nil{}, False{}}

def Dep.join(frags: List<&2, List<&2, U32>>, acc: List<&2, U32>) -> List<&2, U32>:
  match frags:
    case Nil{}:
      acc
    case Con{f, t}:
      Dep.join(t, B.Bytes.cat(f, acc))

def Dep.end(done: Bool, +frags: List<&2, List<&2, U32>>, on: Bool) -> Out:
  match done:
    case True{}:
      Out{[Dep.join(frags, Nil{})], Dep.new()}
    case False{}:
      Out{Nil{}, Dep{frags, on}}

# A fragment into the state: a start opens a unit with its rebuilt
# header, an end closes it and gives it out; a middle or an end with no
# unit open is dropped (its start was lost).
def Dep.frag(st: Dep, +s: Bool, +e: Bool, hdr: List<&2, U32>, +data: List<&2, U32>) ->
  Out:
  Dep{+frags, +on} = st
  Dep.end(e && (s || on),
    Bool.pick(List<&2, List<&2, U32>>, s, [data, hdr],
      Bool.pick(List<&2, List<&2, U32>>, on, data <> frags, frags)), s || on)

def Dep.agg.cut(c: B.Cut, more: List<&2, U32> -> List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match c:
    case B.Short{}:
      Nil{}
    case B.Cut{nal, rest}:
      nal <> more(rest)

# The units of an aggregation packet: each after its 16-bit size. Every
# unit takes at least its 2 size bytes, so fuel = the byte count lasts.
def Dep.agg(fuel: Nat, bs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match fuel bs:
    case 1n+p Con{a, Con{b, rest}}:
      Dep.agg.cut(B.Bytes.cut(U32.or(U32.shln(a, 8n), b), rest), r => Dep.agg(p, r))
    case _ _:
      Nil{}

def Dep.units(+bs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Dep.agg(U32.to_nat(B.Bytes.len(bs)), bs)

# H.264 (RFC 6184)
# -----

def H264.fu(st: Dep, +h: U32, rest: List<&2, U32>) -> Out:
  match rest:
    case Nil{}:
      Out{Nil{}, st}
    case Con{+fh, data}:
      Dep.frag(st, U32.is_eq(U32.and(fh, 128), 128), U32.is_eq(U32.and(fh, 64), 64),
        [U32.or(U32.and(h, 224), U32.and(fh, 31))], data)

def H264.kind(single: Bool, stap: Bool, fu: Bool, st: Dep, +h: U32,
  rest: List<&2, U32>) -> Out:
  match single stap fu:
    case True{} _ _:
      Out{[h <> rest], st}
    case False{} True{} _:
      Out{Dep.units(rest), st}
    case False{} False{} True{}:
      H264.fu(st, h, rest)
    case False{} False{} False{}:
      Out{Nil{}, st}

# A payload into the state: types 1 to 23 are a unit as it is, 24
# (STAP-A) several units, 28 (FU-A) a fragment of one; the others are
# not used by cameras and are skipped.
def H264.push(st: Dep, payload: List<&2, U32>) -> Out:
  match payload:
    case Nil{}:
      Out{Nil{}, st}
    case Con{+h, rest}:
      +t = U32.and(h, 31)
      H264.kind((t >= 1 && t <= 23 : U32), U32.is_eq(t, 24), U32.is_eq(t, 28), st, h,
        rest)

# H.265 (RFC 7798)
# -----

def H265.fu(st: Dep, +h0: U32, h1: U32, rest: List<&2, U32>) -> Out:
  match rest:
    case Nil{}:
      Out{Nil{}, st}
    case Con{+fh, data}:
      Dep.frag(st, U32.is_eq(U32.and(fh, 128), 128), U32.is_eq(U32.and(fh, 64), 64),
        [U32.or(U32.and(h0, 129), U32.shln(U32.and(fh, 63), 1n)), h1], data)

def H265.kind(single: Bool, ap: Bool, fu: Bool, st: Dep, +h0: U32, +h1: U32,
  rest: List<&2, U32>) -> Out:
  match single ap fu:
    case True{} _ _:
      Out{[h0 <> h1 <> rest], st}
    case False{} True{} _:
      Out{Dep.units(rest), st}
    case False{} False{} True{}:
      H265.fu(st, h0, h1, rest)
    case False{} False{} False{}:
      Out{Nil{}, st}

# A payload into the state: the type is 6 bits of the 2-byte header;
# below 48 a unit as it is, 48 an aggregation packet, 49 a fragment.
def H265.push(st: Dep, payload: List<&2, U32>) -> Out:
  match payload:
    case Con{+h0, Con{h1, rest}}:
      +t = U32.and(U32.shrn(h0, 1n), 63)
      H265.kind((t < 48 : U32), U32.is_eq(t, 48), U32.is_eq(t, 49), st, h0, h1, rest)
    case _:
      Out{Nil{}, st}

# Annex B
# -------

def Nal.rev(nals: List<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match nals:
    case Nil{}:
      acc
    case Con{n, t}:
      Nal.rev(t, n <> acc)

def Nal.put(rev: List<&2, List<&2, U32>>, acc: List<&2, U32>) -> List<&2, U32>:
  match rev:
    case Nil{}:
      acc
    case Con{n, t}:
      Nal.put(t, 0 <> 0 <> 0 <> 1 <> B.Bytes.cat(n, acc))

# The units as a byte stream: each after the start code 00 00 00 01.
def Nal.annexb(nals: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Nal.put(Nal.rev(nals, Nil{}), Nil{})
