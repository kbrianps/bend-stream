# What a program says to a session and what a session says back when it
# fails: the options, and errors with a reason. Pure: the laws hold them.
import Base

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

# Whether opening again may work: the network or the server faltered
# (NoRoute, Silent, Hangup), as against an answer that will not change.
def Why.again(w: Why) -> Bool:
  match w:
    case NoRoute{}:
      True{}
    case Silent{}:
      True{}
    case Hangup{}:
      True{}
    case _:
      False{}

def Err.again(e: Err) -> Bool:
  Err{why, _, _} = e
  Why.again(why)

# An error in a line: "login refused (401): wrong user or password".
def Err.show(e: Err) -> String:
  Err{why, +code, msg} = e
  Why.name(why) ++ Bool.pick(String, U32.is_zero(code), "", " (" ++ U32.show(code) ++ ")")
    ++ ": " ++ msg
