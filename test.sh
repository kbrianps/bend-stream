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
paths:
  open:
  priv:
  hevc:
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
sleep 3

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
  case "$out" in
    error*"$3"*) ok "$1" ;;
    *) bad "$1: $out" ;;
  esac
}

pull "rtsp: H.264 with a login" rtsp://cam:s3gredo@127.0.0.1:18554/priv a.h264 h264
pull "rtsp: H.264 from an RTMP publisher" rtsp://127.0.0.1:18554/open b.h264 h264
pull "rtsp: H.265" rtsp://127.0.0.1:18554/hevc c.h265 hevc
fails "rtsp: wrong password" rtsp://cam:errada@127.0.0.1:18554/priv "wrong user or password"
fails "rtsp: no such path" rtsp://127.0.0.1:18554/nada "DESCRIBE was refused"
fails "rtsp: nothing listening" rtsp://127.0.0.1:18999/x "connect"
fails "not a URL" http://127.0.0.1/x "not an RTSP URL"
pull "rtmp: video" rtmp://127.0.0.1:11935/open d.flv h264
pull "rtmp: audio" rtmp://127.0.0.1:11935/open e.flv aac a
pull "rtmp: a login in the query" "rtmp://127.0.0.1:11935/priv?user=cam&pass=s3gredo" f.flv h264
fails "rtmp: no login" rtmp://127.0.0.1:11935/priv "closed"
fails "rtmp: nothing listening" rtmp://127.0.0.1:11999/x "connect"
pull "a host by name" rtsp://localhost:18554/open k.h264 h264
fails "a name that does not exist" rtsp://nao-existe.invalid/x "connect"
fails "rtsps: a certificate nobody vouches for" rtsps://localhost:18322/open "tls"
fails "rtmps: a certificate nobody vouches for" rtmps://localhost:11936/open "tls"
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
  fails "rtmp: a stream nobody publishes (10 s)" rtmp://127.0.0.1:11938/live/nada "nothing for 10"
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
