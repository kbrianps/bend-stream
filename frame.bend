# What a session gives a program: frames, and what they are frames of.
import Base

# Video: one picture's access unit, its NAL units in Annex B form (each
# after 00 00 00 01); key says a decoder can start at it. Audio: AAC
# frames, each after its ADTS header. pts is the time to show or play
# it, in 90 kHz ticks since the stream's first frame of that kind.
type Frame is Data:
  Video{pts: U32, key: Bool, data: List<&2, U32>}
  Audio{pts: U32, data: List<&2, U32>}

# A stream's description: the video's codec ("H264" or "H265") and its
# parameter sets in Annex B form, as the server announced them (they
# may also come in the stream); whether there is audio this client
# reads (AAC), its sample rate and channels.
type Info is Data:
  Info{codec: String, sets: List<&2, U32>, audio: Bool, rate: U32, chans: U32}

def Info.codec(i: Info) -> String:
  Info{c, _, _, _, _} = i
  c

def Info.sets(i: Info) -> List<&2, U32>:
  Info{_, s, _, _, _} = i
  s

def Info.audio(i: Info) -> Bool:
  Info{_, _, a, _, _} = i
  a

def Info.h265(i: Info) -> Bool:
  String.eq(Info.codec(i), "H265")
