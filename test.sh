#!/usr/bin/env bash
# The tests: the laws, then both clients against a local mediamtx fed by
# ffmpeg. Needs mediamtx (in PATH, ~/bin, or $MEDIAMTX), ffmpeg and ffprobe.
# OTHERS=1 adds SRS and nginx-rtmp, which need Docker.
cd "$(dirname "$0")" || exit 1
BEND=${BEND:-bend}
MTX=${MEDIAMTX:-$(command -v mediamtx || echo "$HOME/bin/mediamtx")}
T=$(mktemp -d)
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fails=$((fails + 1)); }

$BEND PROOF.bend 2>&1 | grep -q "ALL PROOFS CHECK" && ok "laws proven" || bad "laws"
$BEND pull.bend -o "$T/pull" > "$T/build.log" 2>&1 && ok "builds" || { bad "build"; cat "$T/build.log"; exit 1; }
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout "$T/key.pem" -out "$T/cert.pem" > /dev/null 2>&1

cat > "$T/mtx.yml" <<Y
rtspAddress: :18554
rtspAuthMethods: [${AUTH:-digest}]
rtpAddress: :18000
rtcpAddress: :18001
rtmpAddress: :11935
encryption: optional
rtspsAddress: :18322
serverKey: $T/key.pem
serverCert: $T/cert.pem
rtmpEncryption: optional
rtmpsAddress: :11936
rtmpServerKey: $T/key.pem
rtmpServerCert: $T/cert.pem
hls: no
webrtc: no
srt: no
authInternalUsers:
  - user: any
    pass:
    ips: ['127.0.0.1']
    permissions:
      - action: publish
  - user: cam
    pass: s3gredo
    permissions:
      - action: read
        path: priv
  - user: any
    pass:
    permissions:
      - action: read
        path: open
      - action: read
        path: hevc
      - action: read
        path: g711
paths:
  open:
  priv:
  hevc:
  g711:
Y
"$MTX" "$T/mtx.yml" > "$T/mtx.log" 2>&1 &
pids=$!
trap 'kill $pids 2>/dev/null; rm -rf "$T"' EXIT
sleep 1.5
SRC="-loglevel error -re -f lavfi -i testsrc=size=640x360:rate=25"
X264="-c:v libx264 -preset ultrafast -tune zerolatency -g 25 -bf 0 -pix_fmt yuv420p"
ffmpeg $SRC -f lavfi -i sine=frequency=440:sample_rate=44100 $X264 -c:a aac -b:a 64k \
  -f flv rtmp://127.0.0.1:11935/open > /dev/null 2>&1 &
pids="$pids $!"
ffmpeg $SRC $X264 -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:18554/priv > /dev/null 2>&1 &
pids="$pids $!"
ffmpeg $SRC -c:v libx265 -preset ultrafast -tune zerolatency -g 25 -bf 0 \
  -x265-params log-level=error -pix_fmt yuv420p -f rtsp -rtsp_transport tcp \
  rtsp://127.0.0.1:18554/hevc > /dev/null 2>&1 &
pids="$pids $!"
ffmpeg $SRC -f lavfi -i sine=frequency=440:sample_rate=8000 $X264 -c:a pcm_alaw -ar 8000 -ac 1 \
  -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:18554/g711 > /dev/null 2>&1 &
pids="$pids $!"
# Wait for the four streams to be up (the encoders take a moment).
for path in open priv hevc g711; do
  for i in $(seq 30); do
    grep -q "is publishing to path '$path'" "$T/mtx.log" && break
    sleep 0.5
  done
done
sleep 1

# pull NAME URL FILE CODEC: 3 seconds recorded, and ffprobe finds frames
# of that codec in the file.
pull() {
  out=$(timeout 60 "$T/pull" "$2" "$T/$3" 3 2>&1 | tail -1)
  n=$(ffprobe -v error -count_frames -select_streams "${5:-v}" \
    -show_entries stream=codec_name,nb_read_frames -of csv=p=0 "$T/$3" 2>/dev/null | tail -1)
  case "$out/$n" in
    ok:*/$4,[1-9]*) ok "$1 (${n#*,} frames)" ;;
    *) bad "$1: $out / $n" ;;
  esac
}
# fails NAME URL WORDS: the pull ends in an error that says WORDS.
fails() {
  out=$(timeout 60 "$T/pull" "$2" "$T/x" 2 2>&1 | tail -1)
  if echo "$out" | grep -q -E "^error.*($3)"; then ok "$1"; else bad "$1: $out"; fi
}

pull "rtsp: H.264 with a login" rtsp://cam:s3gredo@127.0.0.1:18554/priv a.h264 h264
pull "rtsp: H.264 from an RTMP publisher" rtsp://127.0.0.1:18554/open b.h264 h264
pull "rtsp: H.265" rtsp://127.0.0.1:18554/hevc c.h265 hevc
pull "rtsp: H.264 into MPEG-TS" rtsp://cam:s3gredo@127.0.0.1:18554/priv o.ts h264
pull "rtsp: H.265 into MPEG-TS" rtsp://127.0.0.1:18554/hevc p.ts hevc
pull "rtsp: with AAC into MPEG-TS, the video" rtsp://127.0.0.1:18554/open q.ts h264
pull "rtsp: with AAC into MPEG-TS, the audio" rtsp://127.0.0.1:18554/open r.ts aac a
# Sound and picture start together, within a fifth of a second.
gap=$(ffprobe -v error -show_entries stream=start_time -of csv=p=0 "$T/r.ts" 2>/dev/null \
  | sort -u | awk 'NR==1{a=$1} END{d=$1-a; if (d<0) d=-d; print (d<0.2) ? "ok" : d}')
[ "$gap" = "ok" ] && ok "ts: audio and video start together" || bad "ts: streams start $gap s apart"
# The TS carries each picture's time: ffprobe reads the 25 pictures a
# second the source makes, and the whole file decodes without a complaint.
for f in o.ts p.ts; do
  rate=$(ffprobe -v error -select_streams v -show_entries stream=r_frame_rate -of csv=p=0 "$T/$f" 2>/dev/null | head -1)
  errs=$(ffmpeg -v error -i "$T/$f" -f null - 2>&1 | grep -v -c -i "non-existing\|no frame\|missing reference\|Could not find ref\|RPS\|POC")
  [ "$rate" = "25/1" ] && [ "$errs" = "0" ] && ok "ts: $f times and decodes" || bad "ts: $f rate $rate, $errs decode errors"
done
pull "rtsp: the audio alone, AAC" rtsp://127.0.0.1:18554/open v.aac aac a
pull "rtsp: with G.711, the video into MPEG-TS" rtsp://127.0.0.1:18554/g711 w.ts h264
# G.711 is a byte a sample, 8000 a second: 3 seconds are about 24000 bytes.
"$T/pull" rtsp://127.0.0.1:18554/g711 "$T/x.alaw" 3 > /dev/null 2>&1
size=$(stat -c %s "$T/x.alaw" 2>/dev/null || echo 0)
codec=$(ffprobe -v error -f alaw -ar 8000 -show_entries stream=codec_name -of csv=p=0 "$T/x.alaw" 2>/dev/null)
[ "$size" -gt 16000 ] && [ "$size" -lt 40000 ] && [ "$codec" = "pcm_alaw" ] \
  && ok "rtsp: the audio alone, G.711 ($size bytes)" || bad "rtsp: G.711: $size bytes, $codec"
streams=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$T/w.ts" 2>/dev/null | grep -c audio)
[ "$streams" = "0" ] && ok "ts: G.711 is left out of a TS" || bad "ts: $streams audio streams with G.711"
fails "rtsp: wrong password" rtsp://cam:errada@127.0.0.1:18554/priv "login refused"
fails "rtsp: no such path" rtsp://127.0.0.1:18554/nada "no such stream|refused"
fails "rtsp: nothing listening" rtsp://127.0.0.1:18999/x "cannot connect"
fails "not a URL" http://127.0.0.1/x "bad URL"
pull "rtmp: video" rtmp://127.0.0.1:11935/open d.flv h264
pull "rtmp: audio" rtmp://127.0.0.1:11935/open e.flv aac a
pull "rtmp: a login in the query" "rtmp://127.0.0.1:11935/priv?user=cam&pass=s3gredo" f.flv h264
pull "rtmp: into MPEG-TS, the video" rtmp://127.0.0.1:11935/open s.ts h264
pull "rtmp: into MPEG-TS, the audio" rtmp://127.0.0.1:11935/open t.ts aac a
pull "rtmp: the raw video" rtmp://127.0.0.1:11935/open u.h264 h264
fails "rtmp: no login" rtmp://127.0.0.1:11935/priv "connection closed"
fails "rtmp: nothing listening" rtmp://127.0.0.1:11999/x "cannot connect"
pull "a host by name" rtsp://localhost:18554/open k.h264 h264
fails "a name that does not exist" rtsp://nao-existe.invalid/x "cannot connect"
fails "rtsps: a certificate nobody vouches for" rtsps://localhost:18322/open "TLS failed"
fails "rtmps: a certificate nobody vouches for" rtmps://localhost:11936/open "TLS failed"
export STREAM_CAFILE="$T/cert.pem"
pull "rtsps: TLS, the CA given" rtsps://localhost:18322/open l.h264 h264
pull "rtsps: TLS with a login" rtsps://cam:s3gredo@localhost:18322/priv m.h264 h264
pull "rtmps: TLS, the CA given" rtmps://localhost:11936/open n.flv h264
unset STREAM_CAFILE

# OTHERS=1: the same RTMP pull from two other servers, in Docker.
if [ -n "$OTHERS" ]; then
  docker run -d --rm --name bs-srs -p 11938:1935 ossrs/srs:5 > /dev/null
  docker run -d --rm --name bs-nginx -p 11937:1935 tiangolo/nginx-rtmp > /dev/null
  trap 'kill $pids 2>/dev/null; docker stop bs-srs bs-nginx > /dev/null 2>&1; rm -rf "$T"' EXIT
  sleep 4
  for port in 11938 11937; do
    ffmpeg $SRC -f lavfi -i sine=frequency=440:sample_rate=44100 $X264 -c:a aac -b:a 64k \
      -f flv rtmp://127.0.0.1:$port/live/cam > /dev/null 2>&1 &
    pids="$pids $!"
  done
  sleep 4
  pull "rtmp: SRS, video" rtmp://127.0.0.1:11938/live/cam g.flv h264
  pull "rtmp: SRS, audio" rtmp://127.0.0.1:11938/live/cam h.flv aac a
  pull "rtmp: nginx-rtmp, video" rtmp://127.0.0.1:11937/live/cam i.flv h264
  pull "rtmp: nginx-rtmp, audio" rtmp://127.0.0.1:11937/live/cam j.flv aac a
  fails "rtmp: a stream nobody publishes (10 s)" rtmp://127.0.0.1:11938/live/nada "timed out"
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
