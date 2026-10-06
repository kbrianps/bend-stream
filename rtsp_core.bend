# The pure core of the RTSP client (RFC 2326): URLs, requests, what
# comes back on the connection (replies, and RTP packets interleaved
# with them), authentication (Basic and Digest, RFC 2617), and the
# session description (SDP, RFC 4566). Nothing here does IO, so
# LAWS.bend can state laws about it; rtsp.bend is the dialog.
import Base
import ./text.bend as T
import ./bytes.bend as B
import ./b64.bend as E
import ./md5.bend as D
import ./sha256.bend as H

# A header field.
type Hdr is Data:
  Hdr{name: String, value: String}

# URLs
# ----

# rtsp://[user[:pass]@]host[:port][/path]; no host means not an RTSP URL.
type Url is Data:
  Url{host: String, port: U32, user: String, pass: String, path: String}

def Url.none() -> Url:
  Url{"", 0, "", "", ""}

def Url.hex(+c: U32) -> U32:
  E.Word.pick((c >= 48 && c <= 57 : U32), (c - 48 : U32),
  E.Word.pick((c >= 65 && c <= 70 : U32), (c - 55 : U32),
  E.Word.pick((c >= 97 && c <= 102 : U32), (c - 87 : U32), 255)))

def Url.unpct.put(ok: Bool, +a: U32, +b: U32, rest: String) -> String:
  match ok:
    case True{}:
      SCon{Chr{(Url.hex(a) * 16 + Url.hex(b) : U32)}, rest}
    case False{}:
      SCon{'%', SCon{Chr{a}, SCon{Chr{b}, rest}}}

# Percent-decoding (RFC 3986 2.1), for a user or password with "@" or
# ":" in it; a "%" not followed by two hex digits stays.
def Url.unpct(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{Chr{37}, SCon{Chr{+a}, SCon{Chr{+b}, t}}}:
      Url.unpct.put((Url.hex(a) < 16 && Url.hex(b) < 16 : U32), a, b, Url.unpct(t))
    case SCon{c, t}:
      SCon{c, Url.unpct(t)}

def Url.port(m: Maybe<&2, U32>, dflt: U32) -> U32:
  match m:
    case None{}:
      dflt
    case Some{p}:
      p

# "host[:port]"; dflt: the port when absent.
def Url.host(hp: List<&2, String>, dflt: U32, user: String, pass: String,
  path: String) -> Url:
  match hp:
    case Con{h, Nil{}}:
      Url{h, dflt, user, pass, path}
    case Con{h, Con{p, Nil{}}}:
      Url{h, Url.port(U32.read(p), dflt), user, pass, path}
    case _:
      Url.none()

# "user[:pass]", percent-decoded.
def Url.creds(up: List<&2, String>, hp: List<&2, String>, dflt: U32,
  path: String) -> Url:
  match up:
    case Con{u, Nil{}}:
      Url.host(hp, dflt, Url.unpct(u), "", path)
    case Con{u, Con{p, rest}}:
      Url.host(hp, dflt, Url.unpct(u), Url.unpct(String.join(p <> rest, ":")), path)
    case _:
      Url.host(hp, dflt, "", "", path)

# "[user[:pass]@]host[:port]"; the last "@" divides them.
def Url.auth(+ps: List<&2, String>, dflt: U32, path: String) -> Url:
  +n = Nat.sub(List.length(&2, String, ps), 1n)
  Url.creds(String.split(String.join(List.take(&2, String, ps, n), "@"), ':'),
    String.split(String.join(List.drop(&2, String, ps, n), "@"), ':'), dflt, path)

def Url.rest(parts: List<&2, String>, dflt: U32) -> Url:
  match parts:
    case Con{a, Nil{}}:
      Url.auth(String.split(a, '@'), dflt, "")
    case Con{a, rest}:
      Url.auth(String.split(a, '@'), dflt, "/" ++ String.join(rest, "/"))
    case Nil{}:
      Url.none()

# The URL after "scheme://" (scheme in lower case, with its "://"), on
# its default port when it names none; anything else gives no host.
def Url.of(+url: String, +scheme: String, dflt: U32) -> Url:
  Bool.pick(Url, String.starts_with(String.to_lower(url), scheme),
    Url.rest(String.split(String.drop(url, String.length(scheme)), '/'), dflt),
    Url.none())

def Url.esc(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{Chr{32}, t}:
      "%20" ++ Url.esc(t)
    case SCon{c, t}:
      SCon{c, Url.esc(t)}

# The URL as it goes in a request: no user or password, spaces escaped,
# no line end.
def Url.show(u: Url, scheme: String) -> String:
  Url{host, port, _, _, path} = u
  T.Text.clean(scheme ++ host ++ ":" ++ U32.show(port) ++ Url.esc(path))

def Url.host.of(u: Url) -> String:
  Url{h, _, _, _, _} = u
  h

def Url.port.of(u: Url) -> U32:
  Url{_, p, _, _, _} = u
  p

def Url.user(u: Url) -> String:
  Url{_, _, x, _, _} = u
  x

def Url.pass(u: Url) -> String:
  Url{_, _, _, x, _} = u
  x

def Url.path(u: Url) -> String:
  Url{_, _, _, _, x} = u
  x

# Requests
# --------

# A line of a request with no CR or LF in it, whatever went in, and the
# CRLF that ends it: no method, URL or header value can start another
# line. LAWS.bend proves it for every string.
def Rtsp.text(raw: String) -> String:
  T.Text.clean(raw)

def Rtsp.line(raw: String) -> String:
  Rtsp.text(raw) ++ "\r\n"

def Rtsp.fields(hs: List<&2, Hdr>) -> String:
  match hs:
    case Nil{}:
      SNil{}
    case Con{h, t}:
      Hdr{n, v} = h
      Rtsp.line(n ++ ": " ++ v) ++ Rtsp.fields(t)

# A request: the request line, CSeq, User-Agent, the given headers, and
# the empty line (RFC 2326 6).
def Rtsp.request(method: String, uri: String, cseq: U32, hs: List<&2, Hdr>) ->
  String:
  Rtsp.line(method ++ " " ++ uri ++ " RTSP/1.0") ++ Rtsp.line("CSeq: " ++ U32.show(cseq))
    ++ Rtsp.line("User-Agent: bend-stream") ++ Rtsp.fields(hs) ++ "\r\n"

# What arrives
# ------------

# A reply: its status code (0 for a request the server sends us), its
# headers and its body.
type Resp is Data:
  Resp{code: U32, headers: List<&2, Hdr>, body: List<&2, U32>}

# The first whole thing in a buffer, and what follows it: a reply; an
# interleaved packet ("$", channel, length; RFC 2326 10.12); Need when it
# is not all there yet; Bad when it can be neither.
type Msg is Data:
  Need{}
  Bad{}
  Reply{resp: Resp, rest: List<&2, U32>}
  Frame{chan: U32, data: List<&2, U32>, rest: List<&2, U32>}

def Hdr.trim(s: String) -> String:
  String.trim(s)

def Hdr.of(parts: List<&2, String>) -> Hdr:
  match parts:
    case Con{n, rest}:
      Hdr{String.to_lower(String.trim(n)), String.trim(String.join(rest, ":"))}
    case Nil{}:
      Hdr{"", ""}

# The header lines after the first, each as a field with its name in
# lower case.
def Hdr.parse(ls: List<&2, String>) -> List<&2, Hdr>:
  match ls:
    case Nil{}:
      Nil{}
    case Con{l, t}:
      Hdr.of(String.split(l, ':')) <> Hdr.parse(t)

# The first value of a header (name in lower case), or "".
def Hdr.get(hs: List<&2, Hdr>, +name: String) -> String:
  match hs:
    case Nil{}:
      ""
    case Con{h, t}:
      Hdr{n, v} = h
      Bool.pick(String, String.eq(n, name), v, Hdr.get(t, name))

def Hdr.keep(hit: Bool, v: String, rest: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      v <> rest
    case False{}:
      rest

# Every value of a header, in order.
def Hdr.all(hs: List<&2, Hdr>, +name: String) -> List<&2, String>:
  match hs:
    case Nil{}:
      Nil{}
    case Con{h, t}:
      Hdr{n, v} = h
      Hdr.keep(String.eq(n, name), v, Hdr.all(t, name))

def Resp.code(r: Resp) -> U32:
  Resp{c, _, _} = r
  c

def Resp.headers(r: Resp) -> List<&2, Hdr>:
  Resp{_, h, _} = r
  h

def Resp.body(r: Resp) -> List<&2, U32>:
  Resp{_, _, b} = r
  b

def Resp.get(r: Resp, name: String) -> String:
  Hdr.get(Resp.headers(r), name)

def Rtsp.num(m: Maybe<&2, U32>) -> U32:
  match m:
    case None{}:
      0
    case Some{n}:
      n

# The n-th word of a list, or "".
def Rtsp.word(ws: List<&2, String>, n: Nat) -> String:
  match ws n:
    case Nil{} _:
      ""
    case Con{w, _} 0n:
      w
    case Con{_, t} 1n+p:
      Rtsp.word(t, p)

# The status of "RTSP/1.0 200 OK"; 0 for any other first line.
def Rtsp.status(+ws: List<&2, String>) -> U32:
  Bool.pick(U32, String.starts_with(Rtsp.word(ws, 0n), "RTSP/"),
    Rtsp.num(U32.read(Rtsp.word(ws, 1n))), 0)

def Rtsp.uncr(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{Chr{13}, t}:
      Rtsp.uncr(t)
    case SCon{c, t}:
      SCon{c, Rtsp.uncr(t)}

# The end of a message's head: the bytes before the first empty line,
# and the bytes after it. acc: the head so far, reversed.
def Rtsp.head(bs: List<&2, U32>, acc: List<&2, U32>) -> B.Cut:
  match bs:
    case Nil{}:
      B.Short{}
    case Con{13, Con{10, Con{13, Con{10, rest}}}}:
      B.Cut{B.Bytes.rev(acc), rest}
    case Con{b, t}:
      Rtsp.head(t, b <> acc)

def Rtsp.body(c: B.Cut, code: U32, hs: List<&2, Hdr>) -> Msg:
  match c:
    case B.Short{}:
      Need{}
    case B.Cut{body, rest}:
      Reply{Resp{code, hs, body}, rest}

def Rtsp.reply.with(code: U32, +hs: List<&2, Hdr>, rest: List<&2, U32>) -> Msg:
  Rtsp.body(B.Bytes.cut(Rtsp.num(U32.read(Hdr.get(hs, "content-length"))), rest), code,
    hs)

def Rtsp.reply.lines(ls: List<&2, String>, rest: List<&2, U32>) -> Msg:
  match ls:
    case Nil{}:
      Bad{}
    case Con{first, t}:
      Rtsp.reply.with(Rtsp.status(String.split(first, ' ')), Hdr.parse(t), rest)

def Rtsp.reply(c: B.Cut) -> Msg:
  match c:
    case B.Short{}:
      Need{}
    case B.Cut{head, rest}:
      Rtsp.reply.lines(String.split(Rtsp.uncr(B.Bytes.text(head)), '\n'), rest)

def Rtsp.frame(chan: U32, c: B.Cut) -> Msg:
  match c:
    case B.Short{}:
      Need{}
    case B.Cut{data, rest}:
      Frame{chan, data, rest}

def Rtsp.demux.text(letter: Bool, buf: List<&2, U32>) -> Msg:
  match letter:
    case True{}:
      Rtsp.reply(Rtsp.head(buf, Nil{}))
    case False{}:
      Bad{}

# The first message in the buffer. A "$" opens an interleaved packet;
# a letter opens a reply (or a request from the server); the CR and LF
# some servers leave between messages are skipped.
def Rtsp.demux(buf: List<&2, U32>) -> Msg:
  match buf:
    case Nil{}:
      Need{}
    case Con{36, Con{chan, Con{a, Con{b, t}}}}:
      Rtsp.frame(chan, B.Bytes.cut(U32.or(U32.shln(a, 8n), b), t))
    case Con{36, _}:
      Need{}
    case Con{13, t}:
      Rtsp.demux(t)
    case Con{10, t}:
      Rtsp.demux(t)
    case Con{+c, t}:
      Rtsp.demux.text((c >= 65 && c <= 90 : U32), c <> t)

# Authentication
# --------------

# A challenge (WWW-Authenticate): its scheme in lower case ("" for
# none) and Digest's parameters.
type Chal is Data:
  Chal{scheme: String, realm: String, nonce: String, opaque: String, qop: String,
    algo: String}

def Chal.none() -> Chal:
  Chal{"", "", "", "", "", ""}

# A parameter list cut at its commas, those inside quotes kept: where
# the scan is (in quotes, after a backslash), the item so far (reversed)
# and the items (reversed).
type Scan is Data:
  Scan{q: Bool, esc: Bool, cur: String, acc: List<&2, String>}

def Chal.scan.ch(st: Scan, +c: U32) -> Scan:
  Scan{+q, +esc, +cur, +acc} = st
  +ch = {SCon{Chr{c}, cur} : String}
  Bool.pick(Scan, esc, Scan{q, False{}, ch, acc},
  Bool.pick(Scan, q && U32.is_eq(c, 92), Scan{q, True{}, cur, acc},
  Bool.pick(Scan, U32.is_eq(c, 34), Scan{Bool.not(q), False{}, cur, acc},
  Bool.pick(Scan, Bool.not(q) && U32.is_eq(c, 44),
    Scan{q, False{}, "", String.trim(String.reverse(cur)) <> acc},
    Scan{q, False{}, ch, acc}))))

def Chal.scan.go(s: String, st: Scan) -> Scan:
  match s:
    case SNil{}:
      st
    case SCon{Chr{c}, t}:
      Chal.scan.go(t, Chal.scan.ch(st, c))

def Chal.scan.fin(st: Scan) -> List<&2, String>:
  Scan{_, _, cur, acc} = st
  List.reverse(&2, String, String.trim(String.reverse(cur)) <> acc)

# "k=v, k="v, w"" as "k=v" items with the quotes taken off.
def Chal.items(s: String) -> List<&2, String>:
  Chal.scan.fin(Chal.scan.go(s, Scan{False{}, False{}, "", Nil{}}))

def Chal.kv(parts: List<&2, String>) -> Hdr:
  match parts:
    case Con{k, rest}:
      Hdr{String.to_lower(String.trim(k)), String.trim(String.join(rest, "="))}
    case Nil{}:
      Hdr{"", ""}

def Chal.kvs(xs: List<&2, String>) -> List<&2, Hdr>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      Chal.kv(String.split(x, '=')) <> Chal.kvs(t)

def Chal.with(scheme: String, +ps: List<&2, Hdr>) -> Chal:
  Chal{String.to_lower(scheme), Hdr.get(ps, "realm"), Hdr.get(ps, "nonce"),
    Hdr.get(ps, "opaque"), String.to_lower(Hdr.get(ps, "qop")),
    String.to_upper(Hdr.get(ps, "algorithm"))}

def Chal.words(ws: List<&2, String>) -> Chal:
  match ws:
    case Con{scheme, rest}:
      Chal.with(scheme, Chal.kvs(Chal.items(String.join(rest, " "))))
    case Nil{}:
      Chal.none()

# One WWW-Authenticate value.
def Chal.of(v: String) -> Chal:
  Chal.words(String.split(String.trim(v), ' '))

def Chal.all(vs: List<&2, String>) -> List<&2, Chal>:
  match vs:
    case Nil{}:
      Nil{}
    case Con{v, t}:
      Chal.of(v) <> Chal.all(t)

def Chal.scheme(c: Chal) -> String:
  Chal{s, _, _, _, _, _} = c
  s

def Chal.algo(c: Chal) -> String:
  Chal{_, _, _, _, _, a} = c
  a

# Whether this one can be answered: Basic, or Digest with MD5 (the
# default when no algorithm is named) or SHA-256 (RFC 7616).
def Chal.digest(+c: Chal) -> Bool:
  String.eq(Chal.scheme(c), "digest")
    && (String.is_empty(Chal.algo(c)) || String.eq(Chal.algo(c), "MD5")
      || String.eq(Chal.algo(c), "SHA-256"))

def Chal.basic(c: Chal) -> Bool:
  String.eq(Chal.scheme(c), "basic")

def Chal.first(cs: List<&2, Chal>, +digest: Bool) -> Chal:
  match cs:
    case Nil{}:
      Chal.none()
    case Con{+c, t}:
      Bool.pick(Chal, Bool.pick(Bool, digest, Chal.digest(c), Chal.basic(c)), c,
        Chal.first(t, digest))

def Chal.or.at(none: Bool, a: Chal, b: Chal) -> Chal:
  match none:
    case True{}:
      b
    case False{}:
      a

def Chal.or(+a: Chal, b: Chal) -> Chal:
  Chal.or.at(String.is_empty(Chal.scheme(a)), a, b)

# The challenge to answer among a reply's: the first Digest one this
# client can answer, if there is one (the password does not travel; a
# server lists the one it prefers first, RFC 7616 3.7), else Basic, else
# none.
def Chal.pick(+cs: List<&2, Chal>) -> Chal:
  Chal.or(Chal.first(cs, True{}), Chal.first(cs, False{}))

def Auth.md5(s: String) -> String:
  D.Md5.hex(D.Md5.hash(E.Utf8.bytes(s)))

def Auth.sha256(s: String) -> String:
  D.Md5.hex(H.Sha.hash(E.Utf8.bytes(s)))

# The hash a Digest challenge names, in hex.
def Auth.hash(sha: Bool, s: String) -> String:
  match sha:
    case True{}:
      Auth.sha256(s)
    case False{}:
      Auth.md5(s)

def Auth.esc(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{Chr{34}, t}:
      "\\\"" ++ Auth.esc(t)
    case SCon{Chr{92}, t}:
      "\\\\" ++ Auth.esc(t)
    case SCon{c, t}:
      SCon{c, Auth.esc(t)}

# A quoted string (RFC 2617 1.2), its quotes and backslashes escaped.
def Auth.q(s: String) -> String:
  "\"" ++ Auth.esc(T.Text.clean(s)) ++ "\""

# Digest's response (RFC 2617 3.2.2, RFC 7616 3.4.1): with qop=auth the
# nonce count and the client nonce enter the hash; without it, the 2069
# form. sha: SHA-256 instead of MD5.
def Auth.response(+user: String, +realm: String, pass: String, method: String,
  +uri: String, +nonce: String, auth: Bool, +cnonce: String, +sha: Bool) -> String:
  +ha1 = Auth.hash(sha, user ++ ":" ++ realm ++ ":" ++ pass)
  +ha2 = Auth.hash(sha, method ++ ":" ++ uri)
  Bool.pick(String, auth,
    Auth.hash(sha, ha1 ++ ":" ++ nonce ++ ":00000001:" ++ cnonce ++ ":auth:" ++ ha2),
    Auth.hash(sha, ha1 ++ ":" ++ nonce ++ ":" ++ ha2))

def Auth.opt(+v: String, text: String) -> String:
  Bool.pick(String, String.is_empty(v), "", text)

def Auth.digest(c: Chal, +user: String, pass: String, method: String, +uri: String,
  +cnonce: String) -> String:
  Chal{_, +realm, +nonce, +opaque, +qop, +algo} = c
  +auth = String.contains(qop, "auth")
  "Digest username=" ++ Auth.q(user) ++ ", realm=" ++ Auth.q(realm) ++ ", nonce="
    ++ Auth.q(nonce) ++ ", uri=" ++ Auth.q(uri) ++ ", response=\""
    ++ Auth.response(user, realm, pass, method, uri, nonce, auth, cnonce,
      String.eq(algo, "SHA-256")) ++ "\""
    ++ Auth.opt(algo, ", algorithm=" ++ algo)
    ++ Auth.opt(opaque, ", opaque=" ++ Auth.q(opaque))
    ++ Bool.pick(String, auth, ", qop=auth, nc=00000001, cnonce=" ++ Auth.q(cnonce), "")

def Auth.basic(user: String, pass: String) -> String:
  "Basic " ++ E.B64.text(user ++ ":" ++ pass)

def Auth.value.at(digest: Bool, basic: Bool, c: Chal, user: String, pass: String,
  method: String, uri: String, cnonce: String) -> String:
  match digest basic:
    case True{} _:
      Auth.digest(c, user, pass, method, uri, cnonce)
    case False{} True{}:
      Auth.basic(user, pass)
    case False{} False{}:
      ""

# The Authorization value that answers a challenge for this request, or
# "" when there is none to answer. cnonce: a fresh random string.
def Auth.value(+c: Chal, user: String, pass: String, method: String, uri: String,
  cnonce: String) -> String:
  Auth.value.at(Chal.digest(c), Chal.basic(c), c, user, pass, method, uri, cnonce)

# The headers that carry it: none when the value is empty.
def Auth.headers(+v: String) -> List<&2, Hdr>:
  Bool.pick(List<&2, Hdr>, String.is_empty(v), Nil{}, [Hdr{"Authorization", v}])

# Session description
# -------------------

# A media stream of a description: its kind ("video", "audio"), payload
# type, codec ("H264", in upper case) and clock rate (from a=rtpmap),
# control URL (a=control) and format parameters (a=fmtp).
type Media is Data:
  Media{kind: String, pt: U32, codec: String, clock: U32, control: String,
    fmtp: String}

# A description: the session's control URL and its streams.
type Sdp is Data:
  Sdp{control: String, medias: List<&2, Media>}

def Media.none() -> Media:
  Media{"", 0, "", 0, "", ""}

# The reading so far: the session's control, the streams done
# (reversed), the stream being read and whether there is one.
type Sdp.St is Data:
  St{control: String, done: List<&2, Media>, cur: Media, has: Bool}

def Sdp.push(has: Bool, cur: Media, done: List<&2, Media>) -> List<&2, Media>:
  match has:
    case True{}:
      cur <> done
    case False{}:
      done

# "m=video 0 RTP/AVP 96": the kind and the first payload type.
def Sdp.m(+ws: List<&2, String>) -> Media:
  Media{Rtsp.word(ws, 0n), Rtsp.num(U32.read(Rtsp.word(ws, 3n))), "", 0, "", ""}

def Sdp.after(s: String, n: Nat) -> String:
  String.trim(String.drop(s, n))

# "96 H264/90000" into the stream, when it is about its payload type.
def Sdp.rtpmap(+ws: List<&2, String>, m: Media) -> Media:
  Media{+kind, +pt, +codec, +clock, +control, +fmtp} = m
  +enc = String.split(Rtsp.word(ws, 1n), '/')
  Bool.pick(Media, U32.is_eq(Rtsp.num(U32.read(Rtsp.word(ws, 0n))), pt),
    Media{kind, pt, String.to_upper(Rtsp.word(enc, 0n)),
      Rtsp.num(U32.read(Rtsp.word(enc, 1n))), control, fmtp},
    Media{kind, pt, codec, clock, control, fmtp})

# "96 a=1; b=2" into the stream, when it is about its payload type.
def Sdp.fmtp(+v: String, m: Media) -> Media:
  Media{+kind, +pt, +codec, +clock, +control, +fmtp} = m
  +ws = String.split(v, ' ')
  Bool.pick(Media, U32.is_eq(Rtsp.num(U32.read(Rtsp.word(ws, 0n))), pt),
    Media{kind, pt, codec, clock, control, String.trim(String.join(List.drop(&2,
      String, ws, 1n), " "))},
    Media{kind, pt, codec, clock, control, fmtp})

def Sdp.control(v: String, m: Media) -> Media:
  Media{kind, pt, codec, clock, _, fmtp} = m
  Media{kind, pt, codec, clock, v, fmtp}

def Sdp.line(st: Sdp.St, +l: String) -> Sdp.St:
  St{+control, +done, +cur, +has} = st
  Bool.pick(Sdp.St, String.starts_with(l, "m="),
    St{control, Sdp.push(has, cur, done), Sdp.m(String.split(Sdp.after(l, 2n), ' ')),
      True{}},
  Bool.pick(Sdp.St, String.starts_with(l, "a=control:"),
    Bool.pick(Sdp.St, has, St{control, done, Sdp.control(Sdp.after(l, 10n), cur), has},
      St{Sdp.after(l, 10n), done, cur, has}),
  Bool.pick(Sdp.St, String.starts_with(l, "a=rtpmap:"),
    St{control, done, Sdp.rtpmap(String.split(Sdp.after(l, 9n), ' '), cur), has},
  Bool.pick(Sdp.St, String.starts_with(l, "a=fmtp:"),
    St{control, done, Sdp.fmtp(Sdp.after(l, 7n), cur), has},
    St{control, done, cur, has}))))

def Sdp.lines(ls: List<&2, String>, st: Sdp.St) -> Sdp.St:
  match ls:
    case Nil{}:
      st
    case Con{l, t}:
      Sdp.lines(t, Sdp.line(st, l))

def Sdp.fin(st: Sdp.St) -> Sdp:
  St{control, done, cur, has} = st
  Sdp{control, List.reverse(&2, Media, Sdp.push(has, cur, done))}

# A description from its text.
def Sdp.of(text: String) -> Sdp:
  Sdp.fin(Sdp.lines(String.split(Rtsp.uncr(text), '\n'),
    St{"", Nil{}, Media.none(), False{}}))

def Media.kind(m: Media) -> String:
  Media{k, _, _, _, _, _} = m
  k

def Media.pt(m: Media) -> U32:
  Media{_, p, _, _, _, _} = m
  p

def Media.codec(m: Media) -> String:
  Media{_, _, c, _, _, _} = m
  c

def Media.control(m: Media) -> String:
  Media{_, _, _, _, c, _} = m
  c

def Media.fmtp(m: Media) -> String:
  Media{_, _, _, _, _, f} = m
  f

def Sdp.find(ms: List<&2, Media>, +kind: String) -> Media:
  match ms:
    case Nil{}:
      Media.none()
    case Con{+m, t}:
      Bool.pick(Media, String.eq(Media.kind(m), kind), m, Sdp.find(t, kind))

# The first stream of a kind (one with no kind when there is none).
def Sdp.media(s: Sdp, kind: String) -> Media:
  Sdp{_, ms} = s
  Sdp.find(ms, kind)

def Sdp.session(s: Sdp) -> String:
  Sdp{c, _} = s
  c

def Sdp.param.of(parts: List<&2, String>) -> Hdr:
  match parts:
    case Con{k, rest}:
      Hdr{String.to_lower(String.trim(k)), String.trim(String.join(rest, "="))}
    case Nil{}:
      Hdr{"", ""}

def Sdp.params(xs: List<&2, String>) -> List<&2, Hdr>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      Sdp.param.of(String.split(x, '=')) <> Sdp.params(t)

# A format parameter's value ("a=1; b=2" has "b" as "2"), or "".
def Sdp.param(fmtp: String, name: String) -> String:
  Hdr.get(Sdp.params(String.split(fmtp, ';')), name)

def Sdp.sets(xs: List<&2, String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      E.B64.decode(x) <> Sdp.sets(t)

def Sdp.some(s: String) -> Bool:
  Bool.not(String.is_empty(String.trim(s)))

# The parameter sets a stream announces, decoded: H.264's SPS and PPS
# (sprop-parameter-sets, RFC 6184 8.1), or H.265's VPS, SPS and PPS
# (sprop-vps, sprop-sps, sprop-pps; RFC 7798 7.1).
def Sdp.sprops(+fmtp: String) -> List<&2, List<&2, U32>>:
  Sdp.sets(List.filter(~String, ~Sdp.some,
    List.append(&2, String, String.split(Sdp.param(fmtp, "sprop-parameter-sets"), ','),
    List.append(&2, String, String.split(Sdp.param(fmtp, "sprop-vps"), ','),
    List.append(&2, String, String.split(Sdp.param(fmtp, "sprop-sps"), ','),
      String.split(Sdp.param(fmtp, "sprop-pps"), ','))))))

# The URL a control attribute names (RFC 2326 C.1.1): itself when
# absolute, the base for "*" or none, else the base and it.
def Rtsp.control(+base: String, +control: String) -> String:
  Bool.pick(String, String.starts_with(String.to_lower(control), "rtsp://"), control,
  Bool.pick(String, String.is_empty(control) || String.eq(control, "*"), base,
    Bool.pick(String, String.ends_with(base, "/"), base, base ++ "/") ++ control))

# The session id of a Session header ("id;timeout=60").
def Rtsp.session(v: String) -> String:
  String.trim(Rtsp.word(String.split(v, ';'), 0n))

def Rtsp.timeout.of(ps: List<&2, String>) -> U32:
  match ps:
    case Nil{}:
      60
    case Con{+p, t}:
      +kv = String.to_lower(String.trim(p))
      Bool.pick(U32, String.starts_with(kv, "timeout="),
        U32.max(Rtsp.num(U32.read(String.drop(kv, 8n))), 2), Rtsp.timeout.of(t))

# The seconds a Session header gives the session without a request
# ("id;timeout=30"); 60 when it says nothing (RFC 2326 12.37).
def Rtsp.timeout(v: String) -> U32:
  Rtsp.timeout.of(String.split(v, ';'))

def Rtsp.signed.with(+auth: String, method: String, uri: String, cseq: U32,
  +session: String, hs: List<&2, Hdr>) -> String:
  Rtsp.request(method, uri, cseq, List.append(&2, Hdr, hs,
    List.append(&2, Hdr, Bool.pick(List<&2, Hdr>, String.is_empty(session), Nil{},
      [Hdr{"Session", session}]), Auth.headers(auth))))

# A request for this session: the given headers, the Session header once
# there is one, and the Authorization that answers the server's
# challenge for this method and URL.
def Rtsp.signed(c: Chal, user: String, pass: String, +method: String, +uri: String,
  cseq: U32, cnonce: String, +session: String, hs: List<&2, Hdr>) -> String:
  Rtsp.signed.with(Auth.value(c, user, pass, method, uri, cnonce), method, uri, cseq,
    session, hs)

# What is wrong with a description for pulling video, or "": there must
# be a video stream, in H.264 or H.265.
def Sdp.problem(+m: Media) -> String:
  Bool.pick(String, String.is_empty(Media.kind(m)), "the stream has no video",
  Bool.pick(String, String.eq(Media.codec(m), "H264") || String.eq(Media.codec(m), "H265"),
    "", "the video is " ++ Media.codec(m) ++ ", not H.264 or H.265"))
