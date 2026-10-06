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
import ./opts.bend as E
import ./flv.bend as V
import ./frame.bend as F
import ./depay.bend as D
import ./rec.bend as W

def Laws.nals(o: R.Out) -> List<&2, List<&2, U32>>:
  R.Out{n, _} = o
  n

def Laws.zeros(n: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      Laws.zeros(p, 0 <> acc)

def Laws.tag(o: V.Out) -> List<&2, F.Frame>:
  V.Out{fs, _} = o
  fs

def Laws.flv(o: V.Out) -> V.Flv:
  V.Out{_, st} = o
  st

def Laws.wrote(w: W.Wrote) -> List<&2, U32>:
  W.Wrote{bs, _} = w
  bs

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
    "/dir/index.html", "dcd98b7102dd2f0e8b11d0f600bfb0c093", True{}, "0a4f113b", False{})
    == "6629fae49393a05397450978507c4ef1" : String}

# LAW: SHA-256 is the one of FIPS 180-4: the empty message and "abc".
law sha256_vectors:
  {[C.Auth.sha256(""), C.Auth.sha256("abc")]
    == ["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]
    : List<&2, String>}

# LAW: the Digest answer of RFC 7616 3.9.1 over SHA-256.
law digest_rfc7616_sha256:
  {C.Auth.response("Mufasa", "http-auth@example.org", "Circle of Life", "GET",
    "/dir/index.html", "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", True{},
    "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ", True{})
    == "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1" : String}

# LAW: the same exchange over MD5, as the RFC gives it.
law digest_rfc7616_md5:
  {C.Auth.response("Mufasa", "http-auth@example.org", "Circle of Life", "GET",
    "/dir/index.html", "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", True{},
    "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ", False{})
    == "8ca523f5e9506fed4657c9700eebdbec" : String}

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

# Errors
# ------

# LAW: a program is told to try again exactly when the network or the
# server faltered, never after an answer that will not change.
law retry_only_what_may_pass:
  {[E.Why.again(E.NoRoute{}), E.Why.again(E.Silent{}), E.Why.again(E.Hangup{}),
    E.Why.again(E.NoLogin{}), E.Why.again(E.NoStream{}), E.Why.again(E.Unsafe{}),
    E.Why.again(E.Refused{}), E.Why.again(E.Garbled{}), E.Why.again(E.BadUrl{}),
    E.Why.again(E.Ended{})]
    == [True{}, True{}, True{}, False{}, False{}, False{}, False{}, False{}, False{},
      False{}] : List<&2, Bool>}

# LAW: G.711 needs no name in a description: payload type 8 is the
# A-law and 0 the mu-law, at 8000 samples a second; and a stream that is
# no audio is no G.711, whatever its payload type.
law g711_by_number:
  {[U.Aud.codec(U.Aud.of(C.Media{"audio", 8, "", 0, "", ""})),
    U.Aud.codec(U.Aud.of(C.Media{"audio", 0, "", 0, "", ""})),
    U.Aud.codec(U.Aud.of(C.Media{"audio", 97, "PCMA", 8000, "", ""})),
    U.Aud.codec(U.Aud.of(C.Media{"", 0, "", 0, "", ""})),
    U32.show(U.Aud.rate(U.Aud.of(C.Media{"audio", 8, "", 0, "", ""})))]
    == ["PCMA", "PCMU", "PCMA", "", "8000"] : List<&2, String>}

# LAW: a lost stream is given up for good only when waiting cannot help:
# the login, the certificate or the URL is wrong.
law give_up_only_on_what_lasts:
  {[E.Why.lasting(E.NoLogin{}), E.Why.lasting(E.Unsafe{}), E.Why.lasting(E.BadUrl{}),
    E.Why.lasting(E.NoRoute{}), E.Why.lasting(E.Silent{}), E.Why.lasting(E.Hangup{}),
    E.Why.lasting(E.NoStream{}), E.Why.lasting(E.Refused{}), E.Why.lasting(E.Garbled{}),
    E.Why.lasting(E.Ended{})]
    == [True{}, True{}, True{}, False{}, False{}, False{}, False{}, False{}, False{},
      False{}] : List<&2, Bool>}

# RTMP's tags
# -----------

# LAW: H.265 as enhanced RTMP carries it. A configuration tag (top bit,
# "hvc1", packet type 0) with one parameter set AA BB, then a key
# picture with no time offset (packet type 3) holding the unit 26 01:
# the picture comes out in Annex B form, the parameter set in front,
# and the stream is known as H265.
law flv_hevc:
  {[Laws.tag(V.Flv.frames(Laws.flv(V.Flv.frames(V.Flv.new(), K.Tag{9, 0,
      [144, 104, 118, 99, 49, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        255, 1, 32, 0, 1, 0, 2, 170, 187]})),
      K.Tag{9, 40, [147, 104, 118, 99, 49, 0, 0, 0, 2, 38, 1]}))]
    == [[F.Video{0, True{}, [0, 0, 0, 1, 170, 187, 0, 0, 0, 1, 38, 1]}]]
    : List<&2, List<&2, F.Frame>>}

# LAW: a classic H.264 tag: the configuration is read after the three
# bytes of time offset every AVC tag has, and a picture of two units
# comes out as two units.
law flv_avc:
  {[Laws.tag(V.Flv.frames(Laws.flv(V.Flv.frames(V.Flv.new(), K.Tag{9, 0,
      [23, 0, 0, 0, 0, 1, 66, 192, 30, 255, 225, 0, 2, 103, 66, 1, 0, 1, 104]})),
      K.Tag{9, 0, [39, 1, 0, 0, 0, 0, 0, 0, 1, 65, 0, 0, 0, 2, 65, 154]}))]
    == [[F.Video{0, False{}, [0, 0, 0, 1, 65, 0, 0, 0, 1, 65, 154]}]]
    : List<&2, List<&2, F.Frame>>}

# LAW: G.711 in a tag is its samples, and the tag says which law.
law flv_g711:
  {[Laws.tag(V.Flv.frames(V.Flv.new(), K.Tag{8, 0, [114, 213, 85]})),
    Laws.tag(V.Flv.frames(V.Flv.new(), K.Tag{8, 0, [130, 255]}))]
    == [[F.Audio{0, [213, 85]}], [F.Audio{0, [255]}]] : List<&2, List<&2, F.Frame>>}

# For every input
# ---------------
# The laws above are examples: one input, the answer the standard gives.
# These hold for every value of what they name.

# LAW: the joining of two byte lists that every buffer here is built
# with (it walks the first list twice, in constant stack) is the plain
# joining of lists, for every two lists.
law cat_is_append:
  for a: List<&2, U32>
  for b: List<&2, U32>
  {B.Bytes.cat(a, b) == List.append(&2, U32, a, b) : List<&2, U32>}

# LAW: no reason to fail both lasts and is worth another try.
law lasting_never_again:
  for w: E.Why
  {Bool.and(E.Why.lasting(w), E.Why.again(w)) == False{} : Bool}

# LAW: what is not an RTP packet completes no frame and changes nothing,
# whatever the state.
law no_rtp_no_frame:
  for pt: U32
  for sound: Bool
  for m: D.Asm
  {D.Asm.packet(R.NoRtp{}, pt, sound, m) == D.Got{Nil{}, m} : D.Got}

# LAW: a tag that is neither audio nor video holds no frame and changes
# nothing, whatever the state.
law data_tag_no_frame:
  for st: V.Flv
  for ts: U32
  for data: List<&2, U32>
  {V.Flv.frames(st, K.Tag{18, ts, data}) == V.Out{Nil{}, st} : V.Out}

# LAW: an audio file takes the audio as it comes and nothing of a picture.
law sound_file:
  for pts: U32
  for key: Bool
  for data: List<&2, U32>
  {[W.Rec.put(W.Snd{}, F.Audio{pts, data}), W.Rec.put(W.Snd{}, F.Video{pts, key, data})]
    == [W.Wrote{data, W.Snd{}}, W.Wrote{Nil{}, W.Snd{}}] : List<&2, W.Wrote>}

# LAW: a raw video file takes no audio, whatever is still to be written.
law raw_file_no_audio:
  for sets: List<&2, U32>
  for pts: U32
  for data: List<&2, U32>
  {W.Rec.put(W.Raw{sets}, F.Audio{pts, data}) == W.Wrote{Nil{}, W.Raw{sets}} : W.Wrote}

# LAW: a TS that announced no audio never carries an audio packet,
# whatever its counters and whatever the frame.
law ts_no_audio_unless_announced:
  for h265: Bool
  for vcc: U32
  for acc: U32
  for tcc: U32
  for n: U32
  for sets: List<&2, U32>
  for pts: U32
  for data: List<&2, U32>
  {Laws.wrote(W.Rec.put(W.Ts{h265, False{}, vcc, acc, tcc, n, sets}, F.Audio{pts, data}))
    == Nil{} : List<&2, U32>}
