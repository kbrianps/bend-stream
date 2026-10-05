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

def Laws.nals(o: R.Out) -> List<&2, List<&2, U32>>:
  R.Out{n, _} = o
  n

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
