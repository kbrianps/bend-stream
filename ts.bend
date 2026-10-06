# MPEG-TS (ISO 13818-1), the writing side: a file of 188-byte packets
# that carries the video's access units and the audio's frames with
# their times, which a raw .h264 has no place for.
#
#   PID 0     the PAT: program 1 is described on PID 4096
#   PID 4096  the PMT: the video on PID 256, the audio (if any) on 257
#   PID 256   the video, one PES packet per access unit; it carries the
#             clock (PCR)
#   PID 257   the audio, one PES packet per frame (AAC, as ADTS)
#
# Times are 90 kHz ticks in a U32: enough for 13 hours.
import Base
import ./bytes.bend as B

# CRC
# ---

def Crc.bit(n: Nat, +c: U32) -> U32:
  match n:
    case 0n:
      c
    case 1n+p:
      Crc.bit(p, Bool.pick(U32, (c >= 2147483648 : U32),
        U32.xor(U32.shln(c, 1n), 79764919), U32.shln(c, 1n)))

# CRC-32/MPEG-2: polynomial 04C11DB7, from FFFFFFFF, nothing reflected.
def Crc.of(bs: List<&2, U32>, c: U32) -> U32:
  match bs:
    case Nil{}:
      c
    case Con{b, t}:
      Crc.of(t, Crc.bit(8n, U32.xor(c, U32.shln(b, 24n))))

# Packets
# -------

def Ts.fill(n: Nat, rest: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      rest
    case 1n+p:
      Ts.fill(p, 255 <> rest)

# The 4-byte header: the sync byte, whether a unit starts here, the
# PID, whether an adaptation field comes before the payload, and the
# PID's counter.
def Ts.head(+pid: U32, start: Bool, adapt: Bool, cc: U32, rest: List<&2, U32>) ->
  List<&2, U32>:
  71 <> U32.or(Bool.pick(U32, start, 64, 0), U32.shrn(pid, 8n)) <> U32.and(pid, 255)
    <> U32.or(Bool.pick(U32, adapt, 48, 16), U32.and(cc, 15)) <> rest

# A table: a section in one packet, after a pointer byte, its CRC after
# it, the rest of the packet filled.
def Ts.table(pid: U32, cc: U32, +section: List<&2, U32>) -> List<&2, U32>:
  +n = B.Bytes.len(section)
  Ts.head(pid, True{}, False{}, cc, 0 <> B.Bytes.cat(section,
    B.Bytes.put32(Crc.of(section, 4294967295),
      Ts.fill(Nat.sub(179n, U32.to_nat(n)), Nil{}))))

# The PAT: program 1 on PID 4096.
def Ts.pat(cc: U32) -> List<&2, U32>:
  Ts.table(0, cc, [0, 176, 13, 0, 1, 193, 0, 0, 0, 1, 240, 0])

def Ts.es(typ: U32, +pid: U32) -> List<&2, U32>:
  [typ, U32.or(224, U32.shrn(pid, 8n)), U32.and(pid, 255), 240, 0]

def Ts.audio(+typ: U32) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_zero(typ), Nil{}, Ts.es(typ, 257))

# The PMT: the clock on the video's PID; the video's type (27 H.264, 36
# H.265), and the audio's (15 AAC in ADTS; 0 for no audio).
def Ts.pmt(cc: U32, video: U32, +audio: U32) -> List<&2, U32>:
  Ts.table(4096, cc, 2 <> 176 <> Bool.pick(U32, U32.is_zero(audio), 18, 23) <> 0 <> 1
    <> 193 <> 0 <> 0 <> 225 <> 0 <> 240 <> 0
    <> B.Bytes.cat(Ts.es(video, 256), Ts.audio(audio)))

# PES
# ---

# A time as the 5 bytes of a PTS.
def Pes.pts(+t: U32, rest: List<&2, U32>) -> List<&2, U32>:
  U32.or(33, U32.shln(U32.and(U32.shrn(t, 30n), 3), 1n))
    <> U32.and(U32.shrn(t, 22n), 255)
    <> U32.or(1, U32.shln(U32.and(U32.shrn(t, 15n), 127), 1n))
    <> U32.and(U32.shrn(t, 7n), 255)
    <> U32.or(1, U32.shln(U32.and(t, 127), 1n)) <> rest

# A PES packet: the stream's id (224 video, 192 audio), its size when it
# is to be said (audio; a video's may be 0), and the time.
def Pes.of(id: U32, sized: Bool, pts: U32, +data: List<&2, U32>) -> List<&2, U32>:
  0 <> 0 <> 1 <> id <> B.Bytes.put16(Bool.pick(U32, sized,
    U32.add(B.Bytes.len(data), 8), 0), 128 <> 128 <> 5 <> Pes.pts(pts, data))

# The clock: a time as the 6 bytes of a PCR, after the field's flags.
def Ts.pcr(+t: U32) -> List<&2, U32>:
  [16, U32.shrn(t, 25n), U32.and(U32.shrn(t, 17n), 255), U32.and(U32.shrn(t, 9n), 255),
    U32.and(U32.shrn(t, 1n), 255), U32.or(126, U32.shln(U32.and(t, 1), 7n)), 0]

# The adaptation field of a packet with n bytes still to carry: its
# given start (the clock, or nothing), then filling so that the field
# and the payload make 184 bytes. None when the payload fills them.
type Adapt is Data:
  Whole{}
  Adapt{field: List<&2, U32>, room: U32}

def Ts.adapt.of(+len: U32, base: List<&2, U32>, +had: U32) -> Adapt:
  # len: the field's bytes after its length byte; had: the base's.
  Adapt{len <> Bool.pick(List<&2, U32>, U32.is_zero(len), Nil{},
    Bool.pick(List<&2, U32>, U32.is_zero(had),
      0 <> Ts.fill(Nat.sub(U32.to_nat(len), 1n), Nil{}),
      B.Bytes.cat(base, Ts.fill(U32.to_nat(U32.sub(len, had)), Nil{})))),
    U32.sub(183, len)}

def Ts.adapt(+n: U32, +base: List<&2, U32>) -> Adapt:
  +had = B.Bytes.len(base)
  Bool.pick(Adapt, U32.is_zero(had) && (n >= 184 : U32), Whole{},
    Ts.adapt.of(U32.max(had, U32.sub(183, U32.min(n, 183))), base, had))

def Ts.cut.put(c: B.Cut, +room: U32, field: List<&2, U32>, adapt: Bool, +pid: U32,
  start: Bool, +cc: U32, +n: U32, acc: List<&2, U32>,
  k: U32 -> U32 -> List<&2, U32> -> List<&2, U32> -> List<&2, U32>) -> List<&2, U32>:
  match c:
    case B.Short{}:
      acc
    case B.Cut{h, rest}:
      k(U32.sub(n, U32.min(n, room)), U32.add(cc, 1), rest,
        B.Bytes.onto(Ts.head(pid, start, adapt, cc, B.Bytes.cat(field, h)), acc))

# A PES packet as TS packets, last first onto acc: the first says a
# unit starts and may carry the clock, the last is filled to size.
def Ts.cut(fuel: Nat, done: Bool, a: Adapt, +pid: U32, start: Bool, cc: U32, n: U32,
  data: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match fuel done a:
    case 0n _ _:
      acc
    case 1n+p True{} _:
      acc
    case 1n+p False{} Whole{}:
      Ts.cut.put(B.Bytes.split(184n, data), 184, Nil{}, False{}, pid, start, cc, n, acc,
        +l => c2 => r => a2 => Ts.cut(p, U32.is_zero(l), Ts.adapt(l, Nil{}), pid, False{},
          c2, l, r, a2))
    case 1n+p False{} Adapt{field, +room}:
      Ts.cut.put(B.Bytes.split(U32.to_nat(room), data), room, field, True{}, pid, start,
        cc, n, acc, +l => c2 => r => a2 => Ts.cut(p, U32.is_zero(l),
          Ts.adapt(l, Nil{}), pid, False{}, c2, l, r, a2))

# The TS packets of a PES packet on a PID, from counter cc; clock is
# the adaptation field's start for the first (Ts.pcr, or nothing).
def Ts.pes(pid: U32, cc: U32, clock: List<&2, U32>, +pes: List<&2, U32>) ->
  List<&2, U32>:
  +n = B.Bytes.len(pes)
  B.Bytes.rev(Ts.cut(U32.to_nat(U32.add(U32.div(n, 176), 2)), False{},
    Ts.adapt(n, clock), pid, True{}, cc, n, pes, Nil{}))

# How many packets a PES packet of n bytes takes (the counter moves by
# as many): the first loses 8 bytes to the clock when there is one.
def Ts.count(n: U32, clock: Bool) -> U32:
  U32.div(U32.add(U32.add(n, Bool.pick(U32, clock, 8, 0)), 183), 184)
