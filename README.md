# bend-stream

RTSP and RTMP clients written in [Bend 2](https://github.com/HigherOrderCO/Bend2). The protocols are all Bend; one C file, `net.c`, gives the sockets what Base's lack: hosts by name, TLS and reads with a deadline.

It is a library (a session gives frames, see below) and a recorder built on it:

```sh
bend pull.bend -o pull
./pull rtsp://user:pass@camera.example:554/stream out.ts 10
./pull rtmp://192.168.0.20/live/cam out.flv 10
```

`rtsps://` and `rtmps://` are the same under TLS (OpenSSL's `libssl` is opened at run time). The certificate is checked against the host's name and the system's store, or against the PEM file that `STREAM_CAFILE` names.

The last argument is how many seconds to record (10 when left out). The program prints what it did, or the error:

```
ok: H264, 125 frames, 142543 bytes
```

## What it does

**RTSP** (RFC 2326)

- `DESCRIBE`, `SETUP`, `PLAY`, `GET_PARAMETER` as keep-alive at half the session's timeout, `TEARDOWN`.
- Basic and Digest (MD5) authentication, from the user and password in the URL.
- SDP: picks the video stream and its control URL.
- RTP over the RTSP connection (interleaved TCP).
- H.264 (RFC 6184: single units, STAP-A, FU-A) and H.265 (RFC 7798: single units, aggregation packets, fragmentation units).
- Gives whole pictures (access units in Annex B form) and, when the audio is AAC (RFC 3640), its frames, each with its time.
- The recorder writes them raw (`ffplay out.h264` plays it) or, to a file named `.ts`, as MPEG-TS with the audio and the time of each frame, which is what a recording wants.

**RTMP**

- The plain handshake, the chunk stream in both directions (all four header types, extended timestamps, Set Chunk Size), AMF0.
- `connect`, `createStream`, `play`; answers pings and sends acknowledgements.
- Gives the audio and video messages and the metadata as tags; the recorder writes them as an FLV file, whatever the codecs, or takes the H.264 and AAC frames out into a `.ts` or a raw file.
- A login goes in the URL's query (`rtmp://host/app?user=...&pass=...`), as the servers that use one expect.

## The library

A session gives frames; what to do with them is the program's business. Bend's functions cannot be called twice, so there is no callback: the program asks for the next frame, as with `av_read_frame`.

```python
import ./rtsp.bend as S
import ./opts.bend as E
import ./frame.bend as F

# open: connect, log in, set the streams up, play
r : S.Opened() <- S.Rtsp.open(E.Opts.new("rtsp://user:pass@camera/stream"))
#   Done{s}   a session
#   Fail{e}   an E.Err: why, a code, words

# next: one frame, and the session to go on with
r : S.Read() <- S.Rtsp.next(s)
#   Done{(s, F.Video{pts, key, data})}   a picture: its NAL units in Annex B form
#   Done{(s, F.Audio{pts, data})}        AAC frames, each after an ADTS header
#   Fail{e}                              the session is over, the connection closed

S.Rtsp.close(s)
```

[`examples/frames.bend`](examples/frames.bend) is that loop, whole, printing each frame; [`pull.bend`](pull.bend) is the recorder.

**Options** (`opts.bend`): `E.Opts.new(url)`, then any of `E.Opts.login(o, user, pass)` (instead of the URL's), `E.Opts.wait(o, ms)` (how long the server may stay silent; 10 s), `E.Opts.audio(o, False{})` (video only), `E.Opts.ca(o, "ca.pem")` (the certificate to trust under TLS).

**Frames** (`frame.bend`): `pts` is in 90 kHz ticks since the stream's first frame; `key` says a decoder can start there. `S.Rtsp.about(s)` gives the session back with an `F.Info`: the codec (`"H264"` or `"H265"`), the parameter sets the server announced, whether there is audio.

**Errors** (`opts.bend`): an `E.Err{why, code, msg}`. `why` is what a program acts on:

| `why` | Meaning | What to do |
|---|---|---|
| `NoRoute` | cannot connect (name, port, network) | try again later |
| `Silent` | the server sent nothing for `wait` ms | try again |
| `Hangup` | the connection closed or broke | try again |
| `Ended` | the stream came to its end (RTMP) | nothing: not a failure |
| `NoLogin` | wrong or missing user and password | ask for another |
| `NoStream` | the server has no such stream | give up |
| `Unsafe` | TLS failed (certificate, handshake) | give up |
| `Refused` | the server said no to a request | give up |
| `Garbled` | what came is not the protocol | give up |
| `BadUrl` | not a URL of this protocol | give up |

`E.Err.show(e)` puts one in a line, and `E.Err.again(e)` says whether opening again may work (the first three).

**Recording** (`rec.bend`): `W.Rec.for(path, info)` makes a recorder for the form the file's name asks for (`.ts`, or raw), and `W.Rec.put(rec, frame)` gives the bytes to write and the recorder to go on with.

**RTMP** (`rtmp.bend`) is the same three calls, `M.Rtmp.open`, `M.Rtmp.next`, `M.Rtmp.close`, and gives tags (`K.Tag{typ, ts, data}`): written after `K.Flv.header()`, each as `K.Flv.of(tag)`, they are an FLV file. `V.Flv.frames(state, tag)` (`flv.bend`) takes the frame out of a tag, the same `F.Frame` an RTSP session gives, so an RTMP stream records to `.ts` too.

## Files

| File | What is in it |
|---|---|
| `rtsp_core.bend` | Pure: URLs, requests, replies and interleaved frames, authentication, SDP |
| `rtp.bend`, `depay.bend` | Pure: RTP packets, H.264 and H.265 units, Annex B; frames out of packets |
| `frame.bend` | What a session gives: `Frame` and `Info` |
| `rec.bend`, `ts.bend`, `audio.bend` | Pure: frames into a file (raw, MPEG-TS: PAT, PMT, PES, the clock), AAC with ADTS headers |
| `flv.bend` | Pure: frames out of RTMP's tags (AVC and AAC as FLV holds them) |
| `rtmp_core.bend` | Pure: handshake, chunks, commands, what a message means, FLV |
| `amf.bend` | Pure: AMF0 |
| `bytes.bend`, `text.bend`, `b64.bend`, `md5.bend` | Pure helpers |
| `rtsp.bend`, `rtmp.bend` | The IO: the two sessions |
| `opts.bend` | Pure: options, and errors with a reason |
| `conn.bend` | A connection's opening, reads and writes |
| `net.bend`, `net.c`, `net.js` | The sockets: names, TLS, deadlines (native only; the JS side refuses) |
| `pull.bend`, `examples/` | The recorder, and smaller programs that use the library |
| `LAWS.bend`, `PROOF.bend` | The laws and their proofs |

## Laws

`bend PROOF.bend` prints `ALL PROOFS CHECK` only while every law in [`LAWS.bend`](LAWS.bend) holds. Among them:

- no piece of an RTSP request carries a CR or LF, for every string, so a URL or a header value cannot start another header or request (by induction);
- the Digest answer is the example of RFC 2617 3.5, and Basic the one of RFC 7617;
- an H.264 unit split in FU-A fragments comes out whole, and a fragment whose start was lost gives nothing;
- AMF0 numbers are the right IEEE 754 doubles, and a field of a status object is found after a round trip;
- an FLV tag has the bytes the format says;
- the PAT is byte for byte the one every muxer writes, CRC included, and a PES packet of any size comes out in whole 188-byte packets.

## Tests

```sh
./test.sh
```

It proves the laws, builds the binary, starts a local [mediamtx](https://github.com/bluenviron/mediamtx) fed by `ffmpeg`, records from it over both protocols and checks each file with `ffprobe`. It also covers TLS, with a certificate made on the spot. It needs `mediamtx`, `ffmpeg`, `ffprobe` and `openssl`. `AUTH=basic ./test.sh` runs it with Basic instead of Digest, and `OTHERS=1 ./test.sh` adds an RTMP pull from SRS and from nginx-rtmp (in Docker).

Beyond the script, the RTSP client was run against real recorders: an Intelbras MHDX DVR and a Hikvision DS-7632NXI-K2 NVR in H.264, and a camera in H.265.

## Limits

- RTSP: only RTP over the RTSP connection (no UDP). Audio only as AAC: G.711, which many cameras send, is not read.
- Sound and picture are lined up by their first packets, not by RTCP sender reports.
- RTMP: playing only, no publishing. A missing login shows as "the server closed the connection".
- The TS takes the RTP timestamp for both the presentation and the decoding time, which is wrong for a stream with B-frames (cameras rarely make them).
- The FLV keeps the server's timestamps, so it may not start at zero. Frames out of RTMP are H.264 and AAC only (no enhanced RTMP).
- There is no reconnection: a session that fails says why, and the program opens another.
- Native only: `bend pull.bend` alone runs the JS side, which has no sockets of this kind.
- Bytes are linked lists in Bend: expect about 280 MB of memory for a 640x360 stream.

Tested with Bend 2.0.35.

## License

MIT
