---
round: 718
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-234 — new
commit: yes
release: none
---

# Round 718 — the proxy pipe closes its socket

## Target

`RawSocketPipe`, the newest code in the transports (round 716) and not yet
read by any lens. It re-implements, for the HTTP CONNECT path, a duty that
`dart:io`'s `Socket` performs on the direct path: release the socket when
HTTP/2 tears the connection down. RPC-25 asks that duty of both copies side
by side.

## Hypothesis

On an ordinary close, HTTP/2 closes the sink and cancels `incoming`.
`RawSocketPipe.close()` only calls `shutdown(send)`. `incoming` has no
`onCancel`, and `destroy()` runs only on a header-block violation. So against
a peer that never closes its end, the proxy path keeps an open socket after
`transport.close()`, while the direct path does not.

## Before

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/r718_closed_transport_leaves_socket.dart`.
A forwarder sits between the caller and a real h2 server. It handles a
CONNECT (proxy arm) or forwards straight away (direct arm), and never passes
the caller's FIN upstream, so the server never closes. Counted on the caller
process by `lsof -n -P`: sockets connected to the forwarder's port.

```
  arm                 open   3 s after close()   FIN reached the peer
  CONTROL direct        1          0                  true
  proxy, plaintext      1          0                  true
  ablation: close() without shutdown, destroy() a no-op
  proxy, plaintext      1          1                  false
```

## Mechanism

The hypothesis does not hold. With the shutdown in place the caller's socket
is gone from the process within 3 s on both paths. Disabling `destroy()`
alone changes nothing (still 0), so the release comes from the
`shutdown(send)` path, not from `destroy()`. Only with the shutdown removed
too does the socket stay.

## After

n/a — nothing to fix.

## Canary

n/a — no fix. Bench sensitivity: with `close()` doing nothing and `destroy()`
a no-op, the proxy arm reads 1 socket 3 s after close, against 0.

## The verdict questions

1. Yes. The ablated arm differs by the two disabled lines. The direct arm
   differs by the socket type alone.
2. Yes: 1 against 0.
3. Library side: the caller process's own socket table, filtered to the
   caller's connection.
4. Not zero: the ablation reads 1. The window is 3 s on a loopback.
5. No fix, so no witness.
6. n/a.
7. CLEAN, with a valid control.
8. Yes, filed as `../lessons/L-21-count-the-socket-where-it-lives.md`. Four
   dead instruments came first. Peer-side signals cannot tell a half-close
   from a close: both put one FIN on the wire, and writing into it brought an
   RST even against a bare `RawSocket.shutdown(send)` client. The process's
   own socket table was the instrument that could tell them apart.
A1. One process. The forwarder and the server have no policy; the caller uses
    the default `RpcSecurityPolicy`.
A2. Neither: lifecycle, not volume or latency.
L1. n/a — no refusal involved.

## Gate

No library change. Both ablations were reverted and `git status` showed no
library file before the record was written.

## Not fixed

Nothing found. Not covered: the TLS arm, where the pipe wraps a
`RawSecureSocket`; and a teardown by `terminate()` after keepalive death,
rather than `close()`.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 718]`.
New bench `../probes/P-234-a-closed-transport-releases-its-socket.md`.
