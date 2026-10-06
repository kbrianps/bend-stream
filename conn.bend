# What the RTSP and RTMP clients share: errors with a reason, and a
# connection's opening, reads, writes and failures in continuation
# style (the next step is handed the socket back). A step that fails
# closes the socket and ends in Fail, whatever the result T was to be.
# The sockets are net.c's: hosts by name, TLS, reads with a deadline.
import Base
import ./bytes.bend as B
import ./net.bend as X

# Options
# -------

# url: the stream's address. user, pass: the login, when it is not in
# the URL. wait: how long, in ms, the server may stay silent. audio:
# whether to ask for the audio too. ca: a PEM file to check a TLS
# server's certificate against, "" for the system's store.
type Opts is Data:
  Opts{url: String, user: String, pass: String, wait: U32, audio: Bool, ca: String}

def Opts.new(url: String) -> Opts:
  Opts{url, "", "", 10000, True{}, ""}

def Opts.login(o: Opts, user: String, pass: String) -> Opts:
  Opts{url, _, _, wait, audio, ca} = o
  Opts{url, user, pass, wait, audio, ca}

def Opts.wait(o: Opts, ms: U32) -> Opts:
  Opts{url, user, pass, _, audio, ca} = o
  Opts{url, user, pass, ms, audio, ca}

def Opts.audio(o: Opts, yes: Bool) -> Opts:
  Opts{url, user, pass, wait, _, ca} = o
  Opts{url, user, pass, wait, yes, ca}

def Opts.ca(o: Opts, path: String) -> Opts:
  Opts{url, user, pass, wait, audio, _} = o
  Opts{url, user, pass, wait, audio, path}

def Opts.wait.of(o: Opts) -> U32:
  Opts{_, _, _, w, _, _} = o
  w

def Opts.url(o: Opts) -> String:
  Opts{u, _, _, _, _, _} = o
  u

def Opts.ca.of(o: Opts) -> String:
  Opts{_, _, _, _, _, c} = o
  c

# Errors
# ------

# Why something failed, for a program to act on: try again later
# (NoRoute, Silent, Hangup), ask for another password (NoLogin), give up
# (NoStream, Unsafe, Refused, Garbled, BadUrl). Ended is no failure:
# the stream came to its end.
type Why is Data:
  NoRoute{}
  Unsafe{}
  NoLogin{}
  NoStream{}
  Silent{}
  Hangup{}
  Refused{}
  Garbled{}
  BadUrl{}
  Ended{}

# An error: why, the system's or the server's code (0 for none), and
# words for a person.
type Err is Data:
  Err{why: Why, code: U32, msg: String}

def Res(T: Type) -> Type:
  Result<&1, &1, Err, T>

def Recv() -> Type:
  Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>

def Sent() -> Type:
  Socket & Result<&1, &1, U32 & String, Unit>

def Why.name(w: Why) -> String:
  match w:
    case NoRoute{}:
      "cannot connect"
    case Unsafe{}:
      "TLS failed"
    case NoLogin{}:
      "login refused"
    case NoStream{}:
      "no such stream"
    case Silent{}:
      "timed out"
    case Hangup{}:
      "connection closed"
    case Refused{}:
      "refused"
    case Garbled{}:
      "protocol error"
    case BadUrl{}:
      "bad URL"
    case Ended{}:
      "stream ended"

def Why.ended(w: Why) -> Bool:
  match w:
    case Ended{}:
      True{}
    case _:
      False{}

# An error in a line: "login refused (401): wrong user or password".
def Err.show(e: Err) -> String:
  Err{why, +code, msg} = e
  Why.name(why) ++ Bool.pick(String, U32.is_zero(code), "", " (" ++ U32.show(code) ++ ")")
    ++ ": " ++ msg

# The socket closed and the error given.
def Conn.fail(-T: Type, s: Socket, why: Why, code: U32, msg: String) -> IO(Res(T)):
  do IO<Res(T)>:
    X.Net.close(s)
    IO.pure(Res(T), Fail{Err{why, code, msg}})

def Conn.got.n(-T: Type, s: Socket, buf: List<&2, U32>, +piece: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Res(T))) -> IO(Res(T)):
  more(s, B.Bytes.cat(buf, piece), B.Bytes.len(piece))

def Conn.got(-T: Type, m: Recv(), buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Res(T))) -> IO(Res(T)):
  (s, r) = m
  match r:
    case Fail{e}:
      (code, msg) = e
      Conn.fail(T, s, Hangup{}, code, "recv: " ++ msg)
    case Done{None{}}:
      Conn.fail(T, s, Silent{}, 0, "the server sent nothing for too long")
    case Done{Some{Nil{}}}:
      Conn.fail(T, s, Hangup{}, 0, "the server closed the connection")
    case Done{Some{Con{h, t}}}:
      Conn.got.n(T, s, buf, h <> t, more)

# More bytes onto the buffer, waiting at most ms, and how many came.
def Conn.recv.n(-T: Type, s: Socket, ms: U32, buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> U32 -> IO(Res(T))) -> IO(Res(T)):
  do IO<Res(T)>:
    m : Recv() <- X.Net.poll(s, 65536, ms)
    Conn.got(T, m, buf, more)

# More bytes onto the buffer, waiting at most ms.
def Conn.recv(-T: Type, s: Socket, ms: U32, buf: List<&2, U32>,
  more: Socket -> List<&2, U32> -> IO(Res(T))) -> IO(Res(T)):
  Conn.recv.n(T, s, ms, buf, s2 => b2 => _ => more(s2, b2))

def Conn.sent(-T: Type, m: Sent(), k: Socket -> IO(Res(T))) -> IO(Res(T)):
  (s, r) = m
  match r:
    case Done{_}:
      k(s)
    case Fail{e}:
      (code, msg) = e
      Conn.fail(T, s, Hangup{}, code, "send: " ++ msg)

def Conn.send(-T: Type, s: Socket, bs: List<&2, U32>, k: Socket -> IO(Res(T))) ->
  IO(Res(T)):
  do IO<Res(T)>:
    m : Sent() <- X.Net.send(s, bs)
    Conn.sent(T, m, k)

# Text as bytes (a request's lines are ASCII).
def Conn.say(-T: Type, s: Socket, text: String, k: Socket -> IO(Res(T))) -> IO(Res(T)):
  Conn.send(T, s, B.Bytes.of(text), k)

def Conn.shut.sent(m: Sent()) -> IO(Unit):
  (s, _) = m
  X.Net.close(s)

# A last word to the server, sent or not, and the socket closed.
def Conn.shut(s: Socket, last: List<&2, U32>) -> IO(Unit):
  match last:
    case Nil{}:
      X.Net.close(s)
    case Con{h, t}:
      do IO<Unit>:
        m : Sent() <- X.Net.send(s, h <> t)
        Conn.shut.sent(m)

def Conn.secured(-T: Type, m: Sent(), k: Socket -> IO(Res(T))) -> IO(Res(T)):
  (s, r) = m
  match r:
    case Done{_}:
      k(s)
    case Fail{e}:
      (code, msg) = e
      Conn.fail(T, s, Unsafe{}, code, msg)

def Conn.opened(-T: Type, r: Result<&1, &1, U32 & String, Socket>, tls: Bool,
  host: String, ca: String, k: Socket -> IO(Res(T))) -> IO(Res(T)):
  match r tls:
    case Fail{e} _:
      (code, msg) = e
      IO.pure(Res(T), Fail{Err{NoRoute{}, code, msg}})
    case Done{s} False{}:
      k(s)
    case Done{s} True{}:
      do IO<Res(T)>:
        m : Sent() <- X.Net.tls(s, host, ca, "", "")
        Conn.secured(T, m, k)

# A connection to host:port, under TLS when asked: the certificate is
# checked against the host's name and the system's store, or the PEM
# file ca names (for a server with a certificate of its own making).
def Conn.open(-T: Type, +host: String, port: U32, tls: Bool, ca: String,
  k: Socket -> IO(Res(T))) -> IO(Res(T)):
  do IO<Res(T)>:
    r : Result<&1, &1, U32 & String, Socket> <- X.Net.connect(host, port)
    Conn.opened(T, r, tls, host, ca, k)
