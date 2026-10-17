---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r884_deaf_h2_peer.dart
round: 884
commit: fea0d0c3
paths: [packages/transport/rpc_dart_http2/lib/**]
status: valid
promoted: packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart
---

# P-339 — a raw HTTP/2 peer that never reads keeps opening calls

`fvm dart run <file> <deaf|reads> <calls> [inproc] [data] [stopdeaf]` from
anywhere in the workspace. The server is `RpcHttp2Server` with no contracts, so
every call is an unknown method answered trailers-only (one ~134 B HEADERS
frame). The peer is a child process on a RawSocket: client preface, empty
SETTINGS, then HEADERS frames with END_STREAM whose block comes from
package:http2's own `HPackEncoder`. `deaf` keeps read events off until it has
sent everything; `inproc` runs the peer in the server's isolate, `data` adds a
DATA frame to each call, `stopdeaf` times `server.stop()` with the peer still
deaf. It is the only raw h2 peer here that goes past MAX_CONCURRENT_STREAMS:
each call ends at once, so no stream stays live. Promoted as the http2 cell of
the row "a peer that never reads is not answered without bound".

## Measures

The answer bytes and frames waiting for the peer when it starts reading, read
at the peer, against the kernel's ceiling (8192 KiB here: 4 MiB send + 4 MiB
receive). Above the ceiling, the rest sat in the server process. `STALLED`
means the server stopped reading the peer.

## Control

`reads`, the same peer reading all along, and the scale: linear in calls means
nothing pauses.

```
arm      calls    peer wrote             waiting when peer reads
reads    200000   26367 KiB              all 200000 answers read while sending
deaf      20000    2636 KiB               2617 KiB, 20000 answers (inside the kernel)
deaf     200000   26367 KiB              26171 KiB, 200000 answers
deaf     400000   52734 KiB              52343 KiB, 400000 answers
```
