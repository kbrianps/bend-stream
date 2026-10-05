# UTF-8 and base64 (RFC 4648), both ways; from bend-smtp.
import Base

def Word.pick(c: Bool, a: U32, b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

# UTF-8
# -----

def Utf8.cont(+c: U32, n: Nat) -> U32:
  U32.or(128, U32.and(U32.shrn(c, n), 63))

# How many bytes a code point takes.
def Utf8.size(+c: U32) -> Nat:
  Bool.pick(Nat, (c < 128 : U32), 1n,
  Bool.pick(Nat, (c < 2048 : U32), 2n,
  Bool.pick(Nat, (c < 65536 : U32), 3n, 4n)))

def Utf8.put.k(k: Nat, +c: U32, rest: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 1n:
      c <> rest
    case 2n:
      U32.or(192, U32.shrn(c, 6n)) <> Utf8.cont(c, 0n) <> rest
    case 3n:
      U32.or(224, U32.shrn(c, 12n)) <> Utf8.cont(c, 6n) <> Utf8.cont(c, 0n)
        <> rest
    case _:
      U32.or(240, U32.shrn(c, 18n)) <> Utf8.cont(c, 12n) <> Utf8.cont(c, 6n)
        <> Utf8.cont(c, 0n) <> rest

# One code point's bytes, put in front of rest.
def Utf8.put(+c: U32, rest: List<&2, U32>) -> List<&2, U32>:
  Utf8.put.k(Utf8.size(c), c, rest)

def Utf8.bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      Utf8.put(c, Utf8.bytes(t))

# Base64
# ------

# The base64 digit for 0..63.
def B64.ch(+i: U32) -> Char:
  Chr{Word.pick((i < 26 : U32), (i + 65 : U32),
    Word.pick((i < 52 : U32), (i + 71 : U32),
    Word.pick((i < 62 : U32), (i - 4 : U32),
    Word.pick(U32.is_eq(i, 62), 43, 47))))}

def B64.at(+x: U32, n: Nat) -> Char:
  B64.ch(U32.and(U32.shrn(x, n), 63))

# A group of 4 digits, the last `pad` of them "=".
def B64.quad(+x: U32, pad: Nat, rest: String) -> String:
  match pad:
    case 0n:
      SCon{B64.at(x, 18n), SCon{B64.at(x, 12n), SCon{B64.at(x, 6n),
        SCon{B64.at(x, 0n), rest}}}}
    case 1n:
      SCon{B64.at(x, 18n), SCon{B64.at(x, 12n), SCon{B64.at(x, 6n),
        SCon{'=', rest}}}}
    case _:
      SCon{B64.at(x, 18n), SCon{B64.at(x, 12n), SCon{'=', SCon{'=', rest}}}}

def B64.word(+a: U32, +b: U32, +c: U32) -> U32:
  U32.or(U32.shln(a, 16n), U32.or(U32.shln(b, 8n), c))

def B64.onto(acc: String, tail: String) -> String:
  match acc:
    case SNil{}:
      tail
    case SCon{c, t}:
      B64.onto(t, SCon{c, tail})

# The 4 digits of a group, reversed, on acc; pad of them "=".
def B64.quad.rev(+x: U32, pad: Nat, acc: String) -> String:
  match pad:
    case 0n:
      SCon{B64.at(x, 0n), SCon{B64.at(x, 6n), SCon{B64.at(x, 12n),
        SCon{B64.at(x, 18n), acc}}}}
    case 1n:
      SCon{'=', SCon{B64.at(x, 6n), SCon{B64.at(x, 12n), SCon{B64.at(x, 18n), acc}}}}
    case _:
      SCon{'=', SCon{'=', SCon{B64.at(x, 12n), SCon{B64.at(x, 18n), acc}}}}

# A CRLF (reversed) before the group when `wrap` groups fill the line.
def B64.brk(full: Bool, acc: String) -> String:
  match full:
    case True{}:
      SCon{Chr{10}, SCon{Chr{13}, acc}}
    case False{}:
      acc

# The digits of bs, in front of tail; k groups are on the current line,
# and a line takes `wrap` groups (0: one line). acc holds the digits so
# far, reversed: one tail call per group, then one pass onto the tail.
def B64.go(bs: List<&2, U32>, +k: U32, +wrap: U32, acc: String, tail: String) ->
  String:
  match bs:
    case Nil{}:
      B64.onto(acc, tail)
    case Con{a, Con{b, Con{c, rest}}}:
      +full = (wrap > 0 && k >= wrap : U32)
      B64.go(rest, Word.pick(full, 1, (k + 1 : U32)), wrap,
        B64.quad.rev(B64.word(a, b, c), 0n, B64.brk(full, acc)), tail)
    case Con{a, Con{b, Nil{}}}:
      B64.onto(B64.quad.rev(B64.word(a, b, 0), 1n,
        B64.brk((wrap > 0 && k >= wrap : U32), acc)), tail)
    case Con{a, Nil{}}:
      B64.onto(B64.quad.rev(B64.word(a, 0, 0), 2n,
        B64.brk((wrap > 0 && k >= wrap : U32), acc)), tail)

def B64.encode(bs: List<&2, U32>) -> String:
  B64.go(bs, 0, 0, SNil{}, SNil{})

# Base64 in lines of 76 digits (19 groups), as MIME bodies need, then
# tail.
def B64.lines(bs: List<&2, U32>, tail: String) -> String:
  B64.go(bs, 0, 19, SNil{}, tail)

def B64.text(s: String) -> String:
  B64.encode(Utf8.bytes(s))

# Base64 decoding
# ---------------

# A base64 digit's value, or 64 for anything else.
def B64.val(+c: U32) -> U32:
  Word.pick((c >= 65 && c <= 90 : U32), (c - 65 : U32),
  Word.pick((c >= 97 && c <= 122 : U32), (c - 71 : U32),
  Word.pick((c >= 48 && c <= 57 : U32), (c + 4 : U32),
  Word.pick(U32.is_eq(c, 43), 62, Word.pick(U32.is_eq(c, 47), 63, 64)))))

def B64.keep(ok: Bool, v: U32, rest: List<&2, U32>) -> List<&2, U32>:
  match ok:
    case True{}:
      v <> rest
    case False{}:
      rest

def B64.vals(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      +v = B64.val(c)
      B64.keep((v < 64 : U32), v, B64.vals(t))

def B64.byte(+x: U32, n: Nat) -> U32:
  U32.and(U32.shrn(x, n), 255)

def B64.group(+a: U32, +b: U32, +c: U32, +d: U32) -> U32:
  U32.or(U32.or(U32.shln(a, 18n), U32.shln(b, 12n)), U32.or(U32.shln(c, 6n), d))

def B64.bytes(vs: List<&2, U32>) -> List<&2, U32>:
  match vs:
    case Con{a, Con{b, Con{c, Con{d, rest}}}}:
      +x = B64.group(a, b, c, d)
      B64.byte(x, 16n) <> B64.byte(x, 8n) <> B64.byte(x, 0n) <> B64.bytes(rest)
    case Con{a, Con{b, Con{c, Nil{}}}}:
      +x = B64.group(a, b, c, 0)
      [B64.byte(x, 16n), B64.byte(x, 8n)]
    case Con{a, Con{b, Nil{}}}:
      [B64.byte(B64.group(a, b, 0, 0), 16n)]
    case _:
      Nil{}

# The bytes of base64 text; padding and anything off the alphabet skipped.
def B64.decode(s: String) -> List<&2, U32>:
  B64.bytes(B64.vals(s))

# Bytes as text: ASCII as is, any other byte as "?" (for error messages).
def B64.ascii(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case Con{+b, t}:
      SCon{Chr{Word.pick((b < 128 : U32), b, 63)}, B64.ascii(t)}
