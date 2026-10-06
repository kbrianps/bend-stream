// Net
// ===
//
// The JS backend has no sockets by name or TLS here: every call fails
// with EOPNOTSUPP (95). Run natively.

function net_connect(host, port) {
  return io_fail(95);
}

function net_tls(sock, host, cafile, cert, key) {
  return io_fail(95);
}

function net_send(sock, data) {
  return io_fail(95);
}

function net_poll(sock, max, ms) {
  return io_fail(95);
}

function net_close(sock) {
  return io_fail(95);
}

io_eff(CID(Net.connect), net_connect);
io_eff(CID(Net.tls), net_tls);
io_eff(CID(Net.send), net_send);
io_eff(CID(Net.poll), net_poll);
io_eff(CID(Net.close), net_close);
