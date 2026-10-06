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
