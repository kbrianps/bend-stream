# SHA-256 (FIPS 180-4), for Digest authentication with SHA-256 (RFC
# 7616). Bytes are U32s below 256; a block is 16 big-endian words.
import Base

# x rotated right by n bits (0 < n < 32).
def Sha.rotr(+x: U32, +n: Nat) -> U32:
  U32.or(U32.shrn(x, n), U32.shln(x, Nat.sub(32n, n)))

# The round constants: the first 32 bits of the fractional parts of the
# cube roots of the first 64 primes.
def Sha.k() -> List<&2, U32>:
  [1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993,
    2453635748, 2870763221, 3624381080, 310598401, 607225278, 1426881987,
    1925078388, 2162078206, 2614888103, 3248222580, 3835390401, 4022224774,
    264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
    2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711,
    113926993, 338241895, 666307205, 773529912, 1294757372, 1396182291,
    1695183700, 1986661051, 2177026350, 2456956037, 2730485921, 2820302411,
    3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
    430227734, 506948616, 659060556, 883997877, 958139571, 1322822218,
    1537002063, 1747873779, 1955562222, 2024104815, 2227730452, 2361852424,
    2428436474, 2756734187, 3204031479, 3329325298]

def Sha.s0(+x: U32) -> U32:
  U32.xor(Sha.rotr(x, 7n), U32.xor(Sha.rotr(x, 18n), U32.shrn(x, 3n)))

def Sha.s1(+x: U32) -> U32:
  U32.xor(Sha.rotr(x, 17n), U32.xor(Sha.rotr(x, 19n), U32.shrn(x, 10n)))

def Sha.at.or(m: Maybe<&2, U32>) -> U32:
  match m:
    case None{}:
      0
    case Some{x}:
      x

def Sha.at(xs: List<&2, U32>, i: Nat) -> U32:
  Sha.at.or(List.get(&2, U32, xs, i))

# The message schedule: n more words after a window of the last 16 (the
# oldest first), each made of four of them; onto acc, the last first.
def Sha.more(n: Nat, +win: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      +w = (Sha.s1(Sha.at(win, 14n)) + Sha.at(win, 9n) + Sha.s0(Sha.at(win, 1n))
        + Sha.at(win, 0n) : U32)
      Sha.more(p, List.append(&2, U32, List.drop(&2, U32, win, 1n), [w]), w <> acc)

# The 64 words of a block's schedule, from its 16.
def Sha.sched(+ws: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, ws, List.reverse(&2, U32, Sha.more(48n, ws, Nil{})))

# The eight words of the state.
type Sha is Data:
  Sha{a: U32, b: U32, c: U32, d: U32, e: U32, f: U32, g: U32, h: U32}

# The 64 steps over one block: a constant and a schedule word each.
def Sha.steps(ks: List<&2, U32>, ws: List<&2, U32>, st: Sha) -> Sha:
  match ks ws:
    case Con{k, kt} Con{w, wt}:
      Sha{+a, +b, +c, d, +e, +f, +g, h} = st
      +t1 = (h + U32.xor(Sha.rotr(e, 6n), U32.xor(Sha.rotr(e, 11n), Sha.rotr(e, 25n)))
        + U32.xor(U32.and(e, f), U32.and(U32.not(e), g)) + k + w : U32)
      +t2 = (U32.xor(Sha.rotr(a, 2n), U32.xor(Sha.rotr(a, 13n), Sha.rotr(a, 22n)))
        + U32.xor(U32.and(a, b), U32.xor(U32.and(a, c), U32.and(b, c))) : U32)
      Sha.steps(kt, wt, Sha{(t1 + t2 : U32), a, b, c, (d + t1 : U32), e, f, g})
    case _ _:
      st

def Sha.sum(x: Sha, y: Sha) -> Sha:
  Sha{a, b, c, d, e, f, g, h} = x
  Sha{i, j, k, l, m, n, o, p} = y
  Sha{(a + i : U32), (b + j : U32), (c + k : U32), (d + l : U32), (e + m : U32),
    (f + n : U32), (g + o : U32), (h + p : U32)}

# The first n big-endian words of a byte list.
def Sha.words(n: Nat, bs: List<&2, U32>) -> List<&2, U32>:
  match n bs:
    case 1n+p Con{a, Con{b, Con{c, Con{d, rest}}}}:
      U32.or(U32.or(U32.shln(a, 24n), U32.shln(b, 16n)), U32.or(U32.shln(c, 8n), d))
        <> Sha.words(p, rest)
    case _ _:
      Nil{}

# Every 64-byte block folded into the state; fuel: the block count.
def Sha.blocks(fuel: Nat, +bs: List<&2, U32>, +st: Sha) -> Sha:
  match fuel:
    case 0n:
      st
    case 1n+p:
      Sha.blocks(p, List.drop(&2, U32, bs, 64n),
        Sha.sum(st, Sha.steps(Sha.k(), Sha.sched(Sha.words(16n, bs)), st)))

def Sha.zeros(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      0 <> Sha.zeros(p)

# A word's four bytes, big-endian.
def Sha.be(+x: U32) -> List<&2, U32>:
  [U32.shrn(x, 24n), U32.and(U32.shrn(x, 16n), 255), U32.and(U32.shrn(x, 8n), 255),
    U32.and(x, 255)]

# The message padded: a 1 bit, zeros up to 56 mod 64, the bit length in
# 64 bits (messages here are far below 512 MB, so its high word is 0).
def Sha.pad(+bs: List<&2, U32>) -> List<&2, U32>:
  +n = U32.from_nat(List.length(&2, U32, bs))
  +z = ((119 - n % 64) % 64 : U32)
  List.append(&2, U32, bs, 128 <> List.append(&2, U32, Sha.zeros(U32.to_nat(z)),
    0 <> 0 <> 0 <> 0 <> Sha.be((n * 8 : U32))))

def Sha.out(st: Sha) -> List<&2, U32>:
  Sha{a, b, c, d, e, f, g, h} = st
  List.append(&2, U32, Sha.be(a), List.append(&2, U32, Sha.be(b),
    List.append(&2, U32, Sha.be(c), List.append(&2, U32, Sha.be(d),
      List.append(&2, U32, Sha.be(e), List.append(&2, U32, Sha.be(f),
        List.append(&2, U32, Sha.be(g), Sha.be(h))))))))

def Sha.run(+p: List<&2, U32>) -> List<&2, U32>:
  Sha.out(Sha.blocks(U32.to_nat((U32.from_nat(List.length(&2, U32, p)) / 64 : U32)), p,
    Sha{1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924,
      528734635, 1541459225}))

# The 32 bytes of the SHA-256 of bs.
def Sha.hash(bs: List<&2, U32>) -> List<&2, U32>:
  Sha.run(Sha.pad(bs))
