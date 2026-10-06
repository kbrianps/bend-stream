# The proofs of LAWS.bend. `bend PROOF.bend` prints ALL PROOFS CHECK
# once every law holds.
import Base
import ./text.bend as T
import ./bytes.bend as B
import ./amf.bend as A
import ./rtsp_core.bend as C
import ./rtmp_core.bend as K
import ./rtp.bend as R
import ./ts.bend as S
import ./audio.bend as U
import ./opts.bend as E
import ./flv.bend as V
import ./frame.bend as F
import ./depay.bend as D
import ./rec.bend as W
import ./LAWS.bend as Laws

# One cleaned char on a clean rest: a newline is dropped, any other
# char is kept, and either way no newline comes out.
def Lemma.clean_put(
  b: Bool, c: Char, r: String,
  ih: {T.Text.has_nl(r) == False{} : Bool},
  e: {b == T.Text.is_nl(c) : Bool}
) -> {T.Text.has_nl(T.Text.clean.put(b, c, r)) == False{} : Bool}:
  match b:
    case True{}:
      ih
    case False{}:
      %e : {Bool.or(_, T.Text.has_nl(r)) == False{} : Bool}
      ih

def Laws.request_one_line(s):
  match s:
    case SNil{}:
      {==}
    case SCon{+c, +t}:
      Lemma.clean_put(T.Text.is_nl(c), c, T.Text.clean(t), Laws.request_one_line(t),
        {==})

def Laws.digest_rfc2617():
  {==}

def Laws.basic_rfc7617():
  {==}

def Laws.fua_joined():
  {==}

def Laws.fua_orphan():
  {==}

def Laws.amf_doubles():
  {==}

def Laws.amf_status_code():
  {==}

def Laws.flv_tag():
  {==}

def Laws.where_parts():
  {==}

def Laws.ts_pat():
  {==}

def Laws.ts_whole_packets():
  {==}

def Laws.ts_pts():
  {==}

def Laws.aac_adts():
  {==}

def Laws.aac_ticks():
  {==}

def Laws.retry_only_what_may_pass():
  {==}

def Laws.g711_by_number():
  {==}

def Laws.give_up_only_on_what_lasts():
  {==}

def Laws.sha256_vectors():
  {==}

def Laws.digest_rfc7616_sha256():
  {==}

def Laws.digest_rfc7616_md5():
  {==}

def Laws.flv_hevc():
  {==}

def Laws.flv_avc():
  {==}

def Laws.flv_g711():
  {==}

# What is left of a list reversed onto another and then onto a third:
# the second reversed onto the first joined to the third.
def Lemma.onto(a: List<&2, U32>, b: List<&2, U32>, c: List<&2, U32>) ->
  {B.Bytes.onto(B.Bytes.onto(a, b), c) == B.Bytes.onto(b, List.append(&2, U32, a, c))
    : List<&2, U32>}:
  match a:
    case Nil{}:
      {==}
    case Con{+x, +t}:
      Lemma.onto(t, x <> b, c)

def Laws.cat_is_append(a, b):
  Lemma.onto(a, Nil{}, b)

def Laws.lasting_never_again(w):
  match w:
    case E.NoRoute{}:
      {==}
    case E.Unsafe{}:
      {==}
    case E.NoLogin{}:
      {==}
    case E.NoStream{}:
      {==}
    case E.Silent{}:
      {==}
    case E.Hangup{}:
      {==}
    case E.Refused{}:
      {==}
    case E.Garbled{}:
      {==}
    case E.BadUrl{}:
      {==}
    case E.Ended{}:
      {==}
    case E.Moved{}:
      {==}

def Laws.no_rtp_no_frame(pt, sound, m):
  {==}

def Laws.data_tag_no_frame(st, ts, data):
  {==}

def Laws.sound_file(pts, key, data):
  {==}

def Laws.raw_file_no_audio(sets, pts, data):
  {==}

def Laws.ts_no_audio_unless_announced(h265, vcc, acc, tcc, n, sets, pts, data):
  {==}
