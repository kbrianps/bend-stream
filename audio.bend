# Audio from RTP.
#
# AAC (RFC 3640, the "AAC-hbr" mode every camera and server uses): a
# packet's payload is a list of 16-bit headers, each the size of a
# frame in 13 bits, and then the frames. A frame is given after an ADTS
# header, which says what the stream's configuration (the SDP's
# config=) says: profile, rate, channels; that is AAC as a file or a TS
# holds it.
#
# G.711 (RFC 3551: PCMA, the A-law of payload type 8, and PCMU, the
# mu-law of type 0), what most cameras send: the payload is the
# samples, one byte each, 8000 a second, and is given as it is.
import Base
import ./bytes.bend as B
import ./rtsp_core.bend as C
import ./frame.bend as F

# pt: the payload type. rate: the RTP clock (0: no audio). obj, freq,
# chan: AAC's configuration (chan alone for G.711). base: the first
# time seen (based: one was). codec: "AAC", "PCMA", "PCMU", or "".
type Aud is Data:
  Aud{pt: U32, rate: U32, obj: U32, freq: U32, chan: U32, base: U32, based: Bool,
    codec: String}

# What a packet gave: its frames, and the state.
type Sound is Data:
  Sound{frames: List<&2, F.Frame>, a: Aud}

# No audio: a payload type no packet has.
def Aud.none() -> Aud:
  Aud{4096, 0, 0, 0, 0, 0, False{}, ""}

def Aud.hex(s: String, acc: List<&2, U32>) -> List<&2, U32>:
  match s:
    case SCon{Chr{a}, SCon{Chr{b}, t}}:
      Aud.hex(t, U32.or(U32.shln(U32.and(C.Url.hex(a), 15), 4n), U32.and(C.Url.hex(b), 15))
        <> acc)
    case _:
      B.Bytes.rev(acc)

# The configuration's first two bytes: 5 bits of object type, 4 of
# rate index, 4 of channels.
def Aud.cfg(aac: Bool, pt: U32, rate: U32, cfg: List<&2, U32>) -> Aud:
  match aac cfg:
    case True{} Con{+a, Con{+b, _}}:
      Aud{pt, rate, U32.shrn(a, 3n), U32.or(U32.shln(U32.and(a, 7), 1n), U32.shrn(b, 7n)),
        U32.and(U32.shrn(b, 3n), 15), 0, False{}, "AAC"}
    case _ _:
      Aud.none()

# G.711: 8000 samples a second unless the description says otherwise,
# one channel.
def Aud.g711(yes: Bool, pt: U32, +clock: U32, name: String, else: Aud) -> Aud:
  match yes:
    case True{}:
      Aud{pt, Bool.pick(U32, U32.is_zero(clock), 8000, clock), 0, 0, 1, 0, False{}, name}
    case False{}:
      else

# The audio of a description's stream, if it is AAC or G.711. The two
# G.711 payload types are fixed, so a description may leave their names
# out.
def Aud.of(m: C.Media) -> Aud:
  C.Media{kind, +pt, +codec, +clock, _, fmtp} = m
  +named = Bool.not(String.is_empty(codec))
  +audio = String.eq(kind, "audio")
  Aud.g711(String.eq(codec, "PCMA") || (audio && Bool.not(named) && U32.is_eq(pt, 8)),
    pt, clock, "PCMA",
    Aud.g711(String.eq(codec, "PCMU") || (audio && Bool.not(named) && U32.is_eq(pt, 0)),
      pt, clock, "PCMU",
      Aud.cfg(String.eq(codec, "MPEG4-GENERIC") && U32.is_ne(clock, 0), pt, clock,
        Aud.hex(C.Sdp.param(fmtp, "config"), Nil{}))))

def Aud.rate(a: Aud) -> U32:
  Aud{_, rate, _, _, _, _, _, _} = a
  rate

def Aud.codec(a: Aud) -> String:
  Aud{_, _, _, _, _, _, _, c} = a
  c

def Aud.on(a: Aud) -> Bool:
  U32.is_ne(Aud.rate(a), 0)

def Aud.pt(a: Aud) -> U32:
  Aud{pt, _, _, _, _, _, _, _} = a
  pt

def Aud.chans(a: Aud) -> U32:
  Aud{_, _, _, _, c, _, _, _} = a
  c

# The 7 bytes in front of a frame of n bytes.
def Aud.adts(+n: U32, obj: U32, freq: U32, +chan: U32) -> List<&2, U32>:
  +len = U32.add(n, 7)
  [255, 241, U32.or(U32.or(U32.shln(U32.and(U32.sub(obj, 1), 3), 6n), U32.shln(freq, 2n)),
      U32.shrn(chan, 2n)),
    U32.or(U32.shln(U32.and(chan, 3), 6n), U32.and(U32.shrn(len, 11n), 3)),
    U32.and(U32.shrn(len, 3n), 255), U32.or(U32.shln(U32.and(len, 7), 5n), 31), 252]

def Aud.frame(c: B.Cut, n: U32, obj: U32, freq: U32, chan: U32, acc: List<&2, U32>,
  k: List<&2, U32> -> List<&2, U32> -> List<&2, U32>) -> List<&2, U32>:
  match c:
    case B.Short{}:
      B.Bytes.rev(acc)
    case B.Cut{au, rest}:
      k(rest, B.Bytes.onto(au, B.Bytes.onto(Aud.adts(n, obj, freq, chan), acc)))

# Every frame of a payload after its ADTS header, in order: a header
# per frame, its top 13 bits the size.
def Aud.frames(hdrs: List<&2, U32>, data: List<&2, U32>, +obj: U32, +freq: U32,
  +chan: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match hdrs:
    case Con{h0, Con{h1, t}}:
      +n = U32.or(U32.shln(h0, 5n), U32.shrn(h1, 3n))
      Aud.frame(B.Bytes.cut(n, data), n, obj, freq, chan, acc, rest => acc2 =>
        Aud.frames(t, rest, obj, freq, chan, acc2))
    case _:
      B.Bytes.rev(acc)

# A span of the RTP clock in 90 kHz ticks, without leaving 32 bits: the
# rates in use are multiples of 25.
def Aud.ticks(+d: U32, rate: U32) -> U32:
  +r = U32.max(U32.div(rate, 25), 1)
  U32.add((U32.div(d, r) * 3600 : U32), U32.div((U32.mod(d, r) * 3600 : U32), r))

def Aud.split(c: B.Cut, a: Aud, +rts: U32) -> Sound:
  match c:
    case B.Short{}:
      Sound{Nil{}, a}
    case B.Cut{hdrs, data}:
      Aud{pt, +rate, +obj, +freq, +chan, base, +based, codec} = a
      +b = Bool.pick(U32, based, base, rts)
      Sound{[F.Audio{Aud.ticks(U32.sub(rts, b), rate),
          Aud.frames(hdrs, data, obj, freq, chan, Nil{})}],
        Aud{pt, rate, obj, freq, chan, b, True{}, codec}}

def Aud.push.at(hn: U32, t: List<&2, U32>, a: Aud, rts: U32) -> Sound:
  Aud.split(B.Bytes.cut(hn, t), a, rts)

# An AAC payload: its frames together, at the time of the first.
def Aud.aac(a: Aud, rts: U32, payload: List<&2, U32>) -> Sound:
  match payload:
    case Con{l0, Con{l1, t}}:
      Aud.push.at(U32.div(U32.add(U32.or(U32.shln(l0, 8n), l1), 7), 8), t, a, rts)
    case _:
      Sound{Nil{}, a}

# A G.711 payload: its samples as they are.
def Aud.samples(a: Aud, +rts: U32, payload: List<&2, U32>) -> Sound:
  Aud{pt, +rate, obj, freq, chan, base, +based, codec} = a
  +b = Bool.pick(U32, based, base, rts)
  Sound{[F.Audio{Aud.ticks(U32.sub(rts, b), rate), payload}],
    Aud{pt, rate, obj, freq, chan, b, True{}, codec}}

def Aud.push.by(aac: Bool, a: Aud, rts: U32, payload: List<&2, U32>) -> Sound:
  match aac:
    case True{}:
      Aud.aac(a, rts, payload)
    case False{}:
      Aud.samples(a, rts, payload)

# A payload into the state.
def Aud.push(+a: Aud, rts: U32, payload: List<&2, U32>) -> Sound:
  Aud.push.by(String.eq(Aud.codec(a), "AAC"), a, rts, payload)

