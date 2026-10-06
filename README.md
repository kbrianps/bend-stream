# bend-stream

RTSP and RTMP clients written in [Bend 2](https://github.com/HigherOrderCO/Bend2). The protocols are all Bend; one C file, `net.c`, gives the sockets what Base's lack: hosts by name, TLS and reads with a deadline.

It records a camera or a stream into a file:

```sh
bend pull.bend -o pull
./pull rtsp://user:pass@camera.example:554/stream out.h264 10
./pull rtmp://192.168.0.20/live/cam out.flv 10
```

`rtsps://` and `rtmps://` are the same under TLS (OpenSSL's `libssl` is opened at run time). The certificate is checked against the host's name and the system's store, or against the PEM file that `STREAM_CAFILE` names.

The last argument is how many seconds to record (10 when left out). The program prints what it did, or the error:

```
ok: H264, 144 packets, 520 units, 142543 bytes
```

## What it does

**RTSP** (RFC 2326)

- `DESCRIBE`, `SETUP`, `PLAY`, `GET_PARAMETER` as keep-alive at half the session's timeout, `TEARDOWN`.
- Basic and Digest (MD5) authentication, from the user and password in the URL.
- SDP: picks the video stream and its control URL.
- RTP over the RTSP connection (interleaved TCP).
- H.264 (RFC 6184: single units, STAP-A, FU-A) and H.265 (RFC 7798: single units, aggregation packets, fragmentation units).
- Writes the raw stream in Annex B form, the parameter sets of the SDP first (`ffplay out.h264` plays it); or, to a file named `.ts`, MPEG-TS with the time of each picture, which is what a recording wants. A TS also takes the audio when it is AAC (RFC 3640).

**RTMP**

- The plain handshake, the chunk stream in both directions (all four header types, extended timestamps, Set Chunk Size), AMF0.
- `connect`, `createStream`, `play`; answers pings and sends acknowledgements.
- Writes the audio and video messages and the metadata as an FLV file, whatever codecs the server sends.
- A login goes in the URL's query (`rtmp://host/app?user=...&pass=...`), as the servers that use one expect.

## From your own program

```python
import ./rtsp.bend as S
import ./rtmp.bend as M
import ./conn.bend as N

# 10 seconds of each
r : N.Out() <- S.Rtsp.pull("rtsp://user:pass@192.168.0.10/stream", "cam.h264", 10000)
r : N.Out() <- M.Rtmp.pull("rtmp://192.168.0.20/live/cam", "cam.flv", 10000)
```

The result is `Done{Pulled{packets, units, bytes, kind}}` or `Fail{(code, message)}`.

## Files

| File | What is in it |
|---|---|
| `rtsp_core.bend` | Pure: URLs, requests, replies and interleaved frames, authentication, SDP |
| `rtp.bend` | Pure: RTP packets, H.264 and H.265 units, Annex B |
| `mux.bend`, `ts.bend`, `audio.bend` | Pure: access units, MPEG-TS (PAT, PMT, PES, the clock), AAC with ADTS headers |
| `rtmp_core.bend` | Pure: handshake, chunks, commands, what a message means, FLV |
| `amf.bend` | Pure: AMF0 |
| `bytes.bend`, `text.bend`, `b64.bend`, `md5.bend` | Pure helpers |
| `rtsp.bend`, `rtmp.bend`, `conn.bend` | The IO: the two dialogs over a socket |
| `net.bend`, `net.c`, `net.js` | The sockets: names, TLS, deadlines (native only; the JS side refuses) |
| `pull.bend` | The command line |
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

- RTSP: only RTP over the RTSP connection (no UDP). Audio only as AAC and only into a TS: G.711, which many cameras send, is left out.
- Sound and picture are lined up by their first packets, not by RTCP sender reports.
- RTMP: playing only, no publishing. A missing login shows as "the server closed the connection".
- The TS takes the RTP timestamp for both the presentation and the decoding time, which is wrong for a stream with B-frames (cameras rarely make them).
- The FLV keeps the server's timestamps, so it may not start at zero.
- A server silent for 10 seconds ends the pull; there is no reconnection.
- Native only: `bend pull.bend` alone runs the JS side, which has no sockets of this kind.
- Bytes are linked lists in Bend: expect about 280 MB of memory for a 640x360 stream.

Tested with Bend 2.0.35.

## License

MIT
