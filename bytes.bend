# Bytes: a List<&2, U32> of values below 256. Big-endian numbers (the
# network's order) and the little-endian ones RTMP has here and there,
# cuts of a buffer, and bytes as text. The loops are tail calls: a
# nested recursion costs a frame per byte in Bend, and a video frame is
# tens of thousands of bytes.
import Base

# Numbers
# -------

# The big-endian number in the first n bytes (missing bytes count as 0).
def Bytes.be(n: Nat, bs: List<&2, U32>, +acc: U32) -> U32:
  match n bs:
    case 1n+p Con{b, t}:
      Bytes.be(p, t, U32.or(U32.shln(acc, 8n), U32.and(b, 255)))
    case 1n+p Nil{}:
      Bytes.be(p, Nil{}, U32.shln(acc, 8n))
    case _ _:
      acc

def Bytes.u8(bs: List<&2, U32>) -> U32:
  Bytes.be(1n, bs, 0)

def Bytes.u16(bs: List<&2, U32>) -> U32:
  Bytes.be(2n, bs, 0)

def Bytes.u24(bs: List<&2, U32>) -> U32:
  Bytes.be(3n, bs, 0)

def Bytes.u32(bs: List<&2, U32>) -> U32:
  Bytes.be(4n, bs, 0)

# The little-endian U32 in the first 4 bytes.
def Bytes.u32le(bs: List<&2, U32>) -> U32:
  match bs:
    case Con{a, Con{b, Con{c, Con{d, _}}}}:
      U32.or(U32.or(a, U32.shln(b, 8n)), U32.or(U32.shln(c, 16n), U32.shln(d, 24n)))
    case _:
      0

def Bytes.b(+x: U32, n: Nat) -> U32:
  U32.and(U32.shrn(x, n), 255)

# x as 2, 3 and 4 big-endian bytes, in front of rest.
def Bytes.put16(+x: U32, rest: List<&2, U32>) -> List<&2, U32>:
  Bytes.b(x, 8n) <> Bytes.b(x, 0n) <> rest

def Bytes.put24(+x: U32, rest: List<&2, U32>) -> List<&2, U32>:
  Bytes.b(x, 16n) <> Bytes.b(x, 8n) <> Bytes.b(x, 0n) <> rest

def Bytes.put32(+x: U32, rest: List<&2, U32>) -> List<&2, U32>:
  Bytes.b(x, 24n) <> Bytes.b(x, 16n) <> Bytes.b(x, 8n) <> Bytes.b(x, 0n) <> rest

# x as 4 little-endian bytes, in front of rest.
def Bytes.put32le(+x: U32, rest: List<&2, U32>) -> List<&2, U32>:
  Bytes.b(x, 0n) <> Bytes.b(x, 8n) <> Bytes.b(x, 16n) <> Bytes.b(x, 24n) <> rest

# Cuts
# ----

# acc reversed in front of tail.
def Bytes.onto(acc: List<&2, U32>, tail: List<&2, U32>) -> List<&2, U32>:
  match acc:
    case Nil{}:
      tail
    case Con{b, t}:
      Bytes.onto(t, b <> tail)

def Bytes.rev(bs: List<&2, U32>) -> List<&2, U32>:
  Bytes.onto(bs, Nil{})

# a then b, without a frame per byte of a.
def Bytes.cat(a: List<&2, U32>, b: List<&2, U32>) -> List<&2, U32>:
  Bytes.onto(Bytes.rev(a), b)

def Bytes.len.go(bs: List<&2, U32>, +n: U32) -> U32:
  match bs:
    case Nil{}:
      n
    case Con{_, t}:
      Bytes.len.go(t, U32.add(n, 1))

def Bytes.len(bs: List<&2, U32>) -> U32:
  Bytes.len.go(bs, 0)

# A buffer cut after its first n bytes: both parts, or Short when it
# has fewer (then nothing is taken).
type Cut is Data:
  Short{}
  Cut{head: List<&2, U32>, rest: List<&2, U32>}

def Bytes.cut.go(n: Nat, bs: List<&2, U32>, acc: List<&2, U32>) -> Cut:
  match n bs:
    case 0n rest:
      Cut{Bytes.rev(acc), rest}
    case 1n+p Con{b, t}:
      Bytes.cut.go(p, t, b <> acc)
    case 1n+p Nil{}:
      Short{}

def Bytes.cut(n: U32, bs: List<&2, U32>) -> Cut:
  Bytes.cut.go(U32.to_nat(n), bs, Nil{})

def Bytes.drop(n: Nat, bs: List<&2, U32>) -> List<&2, U32>:
  match n bs:
    case 1n+p Con{_, t}:
      Bytes.drop(p, t)
    case _ rest:
      rest

def Bytes.take.go(n: Nat, bs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match n bs:
    case 1n+p Con{b, t}:
      Bytes.take.go(p, t, b <> acc)
    case _ _:
      Bytes.rev(acc)

# The first n bytes (fewer if there are fewer).
def Bytes.take(n: Nat, bs: List<&2, U32>) -> List<&2, U32>:
  Bytes.take.go(n, bs, Nil{})

# Text
# ----

def Bytes.text.go(bs: List<&2, U32>, acc: String) -> String:
  match bs:
    case Nil{}:
      String.reverse(acc)
    case Con{b, t}:
      Bytes.text.go(t, SCon{Chr{b}, acc})

# Each byte as the char of that code (ASCII; Latin-1 above it).
def Bytes.text(bs: List<&2, U32>) -> String:
  Bytes.text.go(bs, SNil{})

def Bytes.of.go(s: String, acc: List<&2, U32>) -> List<&2, U32>:
  match s:
    case SNil{}:
      Bytes.rev(acc)
    case SCon{Chr{c}, t}:
      Bytes.of.go(t, U32.and(c, 255) <> acc)

# Each char as one byte (for text known to be ASCII).
def Bytes.of(s: String) -> List<&2, U32>:
  Bytes.of.go(s, Nil{})

# Parts kept last-first, joined in order in front of acc.
def Bytes.join(parts: List<&2, List<&2, U32>>, acc: List<&2, U32>) -> List<&2, U32>:
  match parts:
    case Nil{}:
      acc
    case Con{p, t}:
      Bytes.join(t, Bytes.cat(p, acc))

def Bytes.split.go(n: Nat, bs: List<&2, U32>, acc: List<&2, U32>) -> Cut:
  match n bs:
    case 1n+p Con{b, t}:
      Bytes.split.go(p, t, b <> acc)
    case _ rest:
      Cut{Bytes.rev(acc), rest}

# The first n bytes and the rest; all of it and nothing when it has
# fewer.
def Bytes.split(n: Nat, bs: List<&2, U32>) -> Cut:
  Bytes.split.go(n, bs, Nil{})
