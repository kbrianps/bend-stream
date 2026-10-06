# Net: connections by host name that may be TLS, read with a deadline
# (net.c, native only). A connection is a Socket; after Net.tls,
# Net.send, Net.poll and Net.close go through the TLS session.
import Base

# A host (name or IP) and port; tries every address it resolves to.
def Net.connect(host: String, port: U32) ->
  IO(Result<&1, &1, U32 & String, Socket>):
  import "./net.c"
  import "./net.js"

# A verified TLS 1.2+ session on the socket, for host; cafile "" trusts
# the system's certificate store; cert and key ("" for none) are PEM
# files with this side's certificate, for a server that asks for one.
def Net.tls(sock: Socket, host: String, cafile: String, cert: String,
  key: String) -> IO(Socket & Result<&1, &1, U32 & String, Unit>):
  import "./net.c"
  import "./net.js"

def Net.send(sock: Socket, data: List<&2, U32>) ->
  IO(Socket & Result<&1, &1, U32 & String, Unit>):
  import "./net.c"
  import "./net.js"

# Up to max bytes; Some{[]} when the peer closed, None{} after ms.
def Net.poll(sock: Socket, max: U32, ms: U32) ->
  IO(Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>):
  import "./net.c"
  import "./net.js"

def Net.close(sock: Socket) -> IO(Unit):
  import "./net.c"
  import "./net.js"
