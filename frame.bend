# What a session gives a program: frames, and what they are frames of.
import Base

# Video: one picture's access unit, its NAL units in Annex B form (each
# after 00 00 00 01); key says a decoder can start at it. Audio: what
# the description's audio says it is: AAC frames, each after its ADTS
# header, or G.711 samples, a byte each. pts is the time to show or play
# it, in 90 kHz ticks since the stream's first frame of that kind.
type Frame is Data:
  Video{pts: U32, key: Bool, data: List<&2, U32>}
  Audio{pts: U32, data: List<&2, U32>}

def Frame.pts(f: Frame) -> U32:
  match f:
    case Video{pts, _, _}:
      pts
    case Audio{pts, _}:
      pts

# The frame d ticks later: for a stream that goes on after another.
def Frame.later(f: Frame, d: U32) -> Frame:
  match f:
    case Video{pts, key, data}:
      Video{U32.add(pts, d), key, data}
    case Audio{pts, data}:
      Audio{U32.add(pts, d), data}

# A stream's description: the video's codec ("H264" or "H265") and its
# parameter sets in Annex B form, as the server announced them (they
# may also come in the stream); the audio's codec ("AAC", "PCMA" or
# "PCMU" for G.711's A-law and mu-law; "" when there is none this
# client reads), its sample rate and channels.
type Info is Data:
  Info{codec: String, sets: List<&2, U32>, audio: String, rate: U32, chans: U32}

def Info.codec(i: Info) -> String:
  Info{c, _, _, _, _} = i
  c

def Info.sets(i: Info) -> List<&2, U32>:
  Info{_, s, _, _, _} = i
  s

def Info.audio(i: Info) -> String:
  Info{_, _, a, _, _} = i
  a

def Info.rate(i: Info) -> U32:
  Info{_, _, _, r, _} = i
  r

def Info.chans(i: Info) -> U32:
  Info{_, _, _, _, c} = i
  c

def Info.h265(i: Info) -> Bool:
  String.eq(Info.codec(i), "H265")
