# AMF0, the encoding of RTMP's commands (connect, play, _result...): a
# value is a marker byte and its data. Here a message is a flat list of
# tokens, an object being AObj, then AKey and value pairs, then AEnd; that
# is enough to write the commands and to find a field of a reply, and
# it keeps the decoder one loop.
#
# Numbers are IEEE 754 doubles on the wire; the ones RTMP's commands
# carry are small whole numbers (a transaction, a stream id), so ANum
# holds a U32: the whole part of the double, 0 for a negative one.
# Arrays (marker 10) and the rest end the decoding: the tokens before
# them are what is given. Writing has them: AArr{n} opens an array of
# the n values that follow.
import Base
import ./bytes.bend as B

type Tok is Data:
  ANum{n: U32}
  AStr{s: String}
  AFlag{b: Bool}
  ANull{}
  AObj{}
  AKey{s: String}
  AEnd{}
  AArr{n: U32}

# Doubles
# -------

# The position of n's highest set bit (0 for 0 and 1).
def Amf.log2(fuel: Nat, +x: U32, +e: Nat) -> Nat:
  match fuel:
    case 0n:
      e
    case 1n+p:
      Amf.log2(p, U32.shrn(x, 1n), Bool.pick(Nat, U32.is_le(x, 1), e, Nat.add(e, 1n)))

# n as the 8 bytes of a double, in front of rest: the exponent is the
# highest bit's position, the fraction the bits below it.
def Amf.double(+n: U32, rest: List<&2, U32>) -> List<&2, U32>:
  +e = Amf.log2(32n, n, 0n)
  +m = U32.xor(n, U32.shln(1, e))
  +small = Nat.is_le(e, 20n)
  B.Bytes.put32(Bool.pick(U32, U32.is_zero(n), 0,
      U32.or(U32.shln(U32.add(1023, U32.from_nat(e)), 20n), Bool.pick(U32, small,
        U32.shln(m, Nat.sub(20n, e)), U32.shrn(m, Nat.sub(e, 20n))))),
    B.Bytes.put32(Bool.pick(U32, small, 0, U32.shln(m, Nat.sub(52n, e))), rest))

def Amf.whole.at(+e: Nat, +hi: U32, lo: U32) -> U32:
  +frac = U32.or(1048576, U32.and(hi, 1048575))
  Bool.pick(U32, Nat.is_le(e, 20n), U32.shrn(frac, Nat.sub(20n, e)),
    U32.or(U32.shln(frac, Nat.sub(e, 20n)), U32.shrn(lo, Nat.sub(52n, e))))

# The whole part of the double in hi and lo: 0 below 1 and for a
# negative one, the largest U32 for what does not fit.
def Amf.whole(+hi: U32, lo: U32) -> U32:
  +exp = U32.and(U32.shrn(hi, 20n), 2047)
  +e = U32.min(U32.sub(U32.max(exp, 1023), 1023), 32)
  Bool.pick(U32, (exp < 1023 : U32) || (hi >= 2147483648 : U32), 0,
    Bool.pick(U32, U32.is_eq(e, 32), 4294967295, Amf.whole.at(U32.to_nat(e), hi, lo)))

# Writing
# -------

def Amf.str(+s: String, rest: List<&2, U32>) -> List<&2, U32>:
  +bs = B.Bytes.of(s)
  B.Bytes.put16(B.Bytes.len(bs), B.Bytes.cat(bs, rest))

def Amf.tok(t: Tok, rest: List<&2, U32>) -> List<&2, U32>:
  match t:
    case ANum{n}:
      0 <> Amf.double(n, rest)
    case AStr{s}:
      2 <> Amf.str(s, rest)
    case AFlag{b}:
      1 <> Bool.pick(U32, b, 1, 0) <> rest
    case ANull{}:
      5 <> rest
    case AObj{}:
      3 <> rest
    case AKey{s}:
      Amf.str(s, rest)
    case AEnd{}:
      0 <> 0 <> 9 <> rest
    case AArr{n}:
      10 <> B.Bytes.put32(n, rest)

def Amf.rev(ts: List<&2, Tok>, acc: List<&2, Tok>) -> List<&2, Tok>:
  match ts:
    case Nil{}:
      acc
    case Con{t, r}:
      Amf.rev(r, t <> acc)

def Amf.put(rev: List<&2, Tok>, acc: List<&2, U32>) -> List<&2, U32>:
  match rev:
    case Nil{}:
      acc
    case Con{t, r}:
      Amf.put(r, Amf.tok(t, acc))

# The bytes of a message's tokens.
def Amf.bytes(ts: List<&2, Tok>) -> List<&2, U32>:
  Amf.put(Amf.rev(ts, Nil{}), Nil{})

# Reading
# -------

def Amf.done(acc: List<&2, Tok>) -> List<&2, Tok>:
  Amf.rev(acc, Nil{})

def Amf.num(c: B.Cut, depth: Nat, acc: List<&2, Tok>,
  k: List<&2, U32> -> Nat -> List<&2, Tok> -> List<&2, Tok>) -> List<&2, Tok>:
  match c:
    case B.Short{}:
      Amf.done(acc)
    case B.Cut{+h, rest}:
      k(rest, depth, ANum{Amf.whole(B.Bytes.u32(h), B.Bytes.u32(B.Bytes.drop(4n, h)))} <> acc)

def Amf.text(c: B.Cut, depth: Nat, acc: List<&2, Tok>,
  k: List<&2, U32> -> Nat -> List<&2, Tok> -> List<&2, Tok>) -> List<&2, Tok>:
  match c:
    case B.Short{}:
      Amf.done(acc)
    case B.Cut{h, rest}:
      k(rest, depth, AStr{B.Bytes.text(h)} <> acc)

# A value after its marker m: 0 a number, 1 a boolean, 2 a string, 3 an
# object, 5 and 6 null and undefined, 8 an object after a 4-byte count.
def Amf.val(m: Nat, t: List<&2, U32>, depth: Nat, acc: List<&2, Tok>,
  k: List<&2, U32> -> Nat -> List<&2, Tok> -> List<&2, Tok>) -> List<&2, Tok>:
  match m t:
    case 0n t:
      Amf.num(B.Bytes.cut(8, t), depth, acc, k)
    case 1n Con{b, r}:
      k(r, depth, AFlag{U32.is_ne(b, 0)} <> acc)
    case 2n Con{a, Con{b, r}}:
      Amf.text(B.Bytes.cut(U32.or(U32.shln(a, 8n), b), r), depth, acc, k)
    case 3n t:
      k(t, Nat.add(depth, 1n), AObj{} <> acc)
    case 5n t:
      k(t, depth, ANull{} <> acc)
    case 6n t:
      k(t, depth, ANull{} <> acc)
    case 8n t:
      k(B.Bytes.drop(4n, t), Nat.add(depth, 1n), AObj{} <> acc)
    case _ _:
      Amf.done(acc)

# Inside an object: a key (16-bit size, the text) and its value, or the
# empty key and the marker 9 that end it.
def Amf.key(empty: Bool, c: B.Cut, depth: Nat, acc: List<&2, Tok>,
  k: List<&2, U32> -> Nat -> List<&2, Tok> -> List<&2, Tok>) -> List<&2, Tok>:
  match empty c:
    case True{} B.Cut{_, Con{_, rest}}:
      k(rest, Nat.sub(depth, 1n), AEnd{} <> acc)
    case False{} B.Cut{h, Con{m, rest}}:
      Amf.val(U32.to_nat(m), rest, depth, AKey{B.Bytes.text(h)} <> acc, k)
    case _ _:
      Amf.done(acc)

def Amf.key.of(+n: U32, t: List<&2, U32>, depth: Nat, acc: List<&2, Tok>,
  k: List<&2, U32> -> Nat -> List<&2, Tok> -> List<&2, Tok>) -> List<&2, Tok>:
  Amf.key(U32.is_zero(n), B.Bytes.cut(n, t), depth, acc, k)

def Amf.step(top: Bool, bs: List<&2, U32>, depth: Nat, acc: List<&2, Tok>,
  k: List<&2, U32> -> Nat -> List<&2, Tok> -> List<&2, Tok>) -> List<&2, Tok>:
  match top bs:
    case True{} Con{m, t}:
      Amf.val(U32.to_nat(m), t, depth, acc, k)
    case False{} Con{a, Con{b, t}}:
      Amf.key.of(U32.or(U32.shln(a, 8n), b), t, depth, acc, k)
    case _ _:
      Amf.done(acc)

# Every turn takes at least a byte, so the fuel is the byte count.
def Amf.toks(fuel: Nat, bs: List<&2, U32>, +depth: Nat, acc: List<&2, Tok>) ->
  List<&2, Tok>:
  match fuel:
    case 0n:
      Amf.done(acc)
    case 1n+p:
      Amf.step(Nat.is_eq(depth, 0n), bs, depth, acc, b => d => a => Amf.toks(p, b, d, a))

# The tokens of a message's bytes.
def Amf.of(+bs: List<&2, U32>) -> List<&2, Tok>:
  Amf.toks(Nat.add(U32.to_nat(B.Bytes.len(bs)), 1n), bs, 0n, Nil{})

# Looking things up
# -----------------

# The n-th token (0 the first), Null when there is none.
def Amf.at(ts: List<&2, Tok>, n: Nat) -> Tok:
  match ts n:
    case Con{t, _} 0n:
      t
    case Con{_, r} 1n+p:
      Amf.at(r, p)
    case Nil{} _:
      ANull{}

def Amf.string(t: Tok) -> String:
  match t:
    case AStr{s}:
      s
    case _:
      ""

def Amf.number(t: Tok) -> U32:
  match t:
    case ANum{n}:
      n
    case _:
      0

# The string under a key, at any depth; "" when there is none.
def Amf.get(ts: List<&2, Tok>, +key: String) -> String:
  match ts:
    case Con{AKey{k}, Con{AStr{+v}, r}}:
      Bool.pick(String, String.eq(k, key), v, Amf.get(r, key))
    case Con{_, r}:
      Amf.get(r, key)
    case Nil{}:
      ""
