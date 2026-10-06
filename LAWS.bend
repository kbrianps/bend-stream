# The laws of bend-stream: the claims PROOF.bend must prove. `bend
# PROOF.bend` fails while any is open or false. They are about the pure
# files; everything that touches the network is in rtsp.bend, rtmp.bend
# and conn.bend.
import Base
import ./text.bend as T
import ./bytes.bend as B
import ./amf.bend as A
import ./rtsp_core.bend as C
import ./rtmp_core.bend as K
import ./rtp.bend as R
import ./ts.bend as S
import ./audio.bend as U

def Laws.nals(o: R.Out) -> List<&2, List<&2, U32>>:
  R.Out{n, _} = o
  n

def Laws.zeros(n: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      Laws.zeros(p, 0 <> acc)

def Laws.state(o: R.Out) -> R.Dep:
  R.Out{_, s} = o
  s

# RTSP
# ----

# LAW: a piece of a request holds no CR or LF, for every string: a URL
# or a header value cannot start another header or another request.
law request_one_line:
  for s: String
  {T.Text.has_nl(C.Rtsp.text(s)) == False{} : Bool}

# LAW: the Digest answer is the one of RFC 2617 3.5.
law digest_rfc2617:
  {C.Auth.response("Mufasa", "testrealm@host.com", "Circle Of Life", "GET",
    "/dir/index.html", "dcd98b7102dd2f0e8b11d0f600bfb0c093", True{}, "0a4f113b")
    == "6629fae49393a05397450978507c4ef1" : String}

# LAW: Basic is the example of RFC 7617 2.
law basic_rfc7617:
  {C.Auth.basic("Aladdin", "open sesame") == "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ=="
    : String}

# RTP
# ---

# LAW: an H.264 unit sent as two FU-A fragments comes out whole, after
# a start code, its header rebuilt from the two fragment headers.
law fua_joined:
  {R.Nal.annexb(Laws.nals(R.H264.push(Laws.state(R.H264.push(R.Dep.new(),
    [124, 133, 1, 2])), [124, 69, 3, 4]))) == [0, 0, 0, 1, 101, 1, 2, 3, 4]
    : List<&2, U32>}

# LAW: an end fragment whose start was lost gives nothing.
law fua_orphan:
  {Laws.nals(R.H264.push(R.Dep.new(), [124, 69, 3, 4])) == Nil{}
    : List<&2, List<&2, U32>>}

# AMF0 and RTMP
# -------------

# LAW: whole numbers are IEEE 754 doubles on the wire.
law amf_doubles:
  {[A.Amf.double(1, Nil{}), A.Amf.double(4071, Nil{})]
    == [[63, 240, 0, 0, 0, 0, 0, 0], [64, 175, 206, 0, 0, 0, 0, 0]]
    : List<&2, List<&2, U32>>}

# LAW: a field of a status object is found after the bytes are read back.
law amf_status_code:
  {A.Amf.get(A.Amf.of(A.Amf.bytes([A.AStr{"onStatus"}, A.ANum{0}, A.ANull{}, A.AObj{},
    A.AKey{"level"}, A.AStr{"status"}, A.AKey{"code"}, A.AStr{"NetStream.Play.Start"},
    A.AEnd{}])), "code") == "NetStream.Play.Start" : String}

# LAW: an FLV tag is its 11-byte header, the data, and the size of both.
law flv_tag:
  {K.Flv.tag(9, 16777217, [1, 2])
    == [9, 0, 0, 2, 0, 0, 1, 1, 0, 0, 0, 1, 2, 0, 0, 0, 13] : List<&2, U32>}

# LAW: a path is the application and the stream; the query stays with
# the part it follows.
law where_parts:
  {[K.Where.of("/live/cam?k=1"), K.Where.of("/a/b/c"), K.Where.of("/priv?user=x")]
    == [K.Where{"live", "cam?k=1"}, K.Where{"a/b", "c"}, K.Where{"priv?user=x", ""}]
    : List<&2, K.Where>}

# MPEG-TS
# -------

# LAW: the PAT is the packet every muxer writes for one program on PID
# 4096, its CRC included, and a packet is 188 bytes.
law ts_pat:
  {[B.Bytes.take(21n, S.Ts.pat(0)), [B.Bytes.len(S.Ts.pat(0)),
    B.Bytes.len(S.Ts.pmt(0, 27, 15))]]
    == [[71, 64, 0, 16, 0, 0, 176, 13, 0, 1, 193, 0, 0, 0, 1, 240, 0, 42, 177, 4, 178],
      [188, 188]] : List<&2, List<&2, U32>>}

# LAW: a PES packet of any size comes out in whole packets: 100 bytes
# with the clock in one, 184 bytes without it in one, 185 in two.
law ts_whole_packets:
  {[B.Bytes.len(S.Ts.pes(256, 0, S.Ts.pcr(90000), Laws.zeros(100n, Nil{}))),
    B.Bytes.len(S.Ts.pes(257, 0, Nil{}, Laws.zeros(184n, Nil{}))),
    B.Bytes.len(S.Ts.pes(257, 0, Nil{}, Laws.zeros(185n, Nil{}))),
    S.Ts.count(100, True{}), S.Ts.count(184, False{}), S.Ts.count(185, False{})]
    == [188, 188, 376, 1, 1, 2] : List<&2, U32>}

# LAW: a time is the 5 bytes of a PTS (1 second: 90000 ticks).
law ts_pts:
  {S.Pes.pts(90000, Nil{}) == [33, 0, 5, 191, 33] : List<&2, U32>}

# Audio
# -----

# LAW: the configuration 1208 is AAC-LC, 44100 Hz, one channel, and a
# frame of 100 bytes gets the ADTS header that says so and 107 bytes.
law aac_adts:
  {[U.Aud.hex("1208", Nil{}), U.Aud.adts(100, 2, 4, 1)]
    == [[18, 8], [255, 241, 80, 64, 13, 127, 252]] : List<&2, List<&2, U32>>}

# LAW: a second of any clock is 90000 ticks, and a frame of 1024
# samples at 48 kHz is 1920.
law aac_ticks:
  {[U.Aud.ticks(44100, 44100), U.Aud.ticks(48000, 48000), U.Aud.ticks(8000, 8000),
    U.Aud.ticks(1024, 48000)] == [90000, 90000, 90000, 1920] : List<&2, U32>}
