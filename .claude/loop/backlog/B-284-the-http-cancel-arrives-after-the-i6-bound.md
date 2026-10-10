---
status: decided by owner (round 809)
round: 804
commit: 4b9a575d
paths: [packages/transport/rpc_dart_http/lib/**, packages/test/rpc_dart_conformance/test/i6_cancel_reaches_responder_test.dart, packages/test/rpc_dart_conformance/test/i5_resources_return_test.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/r804_client_abort.dart
reason: owner decision — I-6 says 1 s on every transport, and http's only cancel signal is a TCP close the platform reports about 2.1 s late
release: none
rank: 7
---

# B-284 — the http cancel arrives after the i6 bound

Round 804 made a caller's cancel reach the handler under `RpcHttpServer`
(B-280). It arrives as the close of the caller's connection, the only
cancel signal HTTP/1.1 has, and here that close reaches the other side
about 2.1 s after it happens:

```
P-295, one process, macOS, Dart 3.10.1, sandbox on and off:
  raw Socket.destroy()        -> server onDone   +2.07 s
  raw Socket.close() (FIN)    -> server onDone   +2.10 s
  HttpClientRequest.abort()   -> server onDone   +2.10 s
rpc_dart_http, direct          cancel -> handler token   2.03-2.12 s
conformance matrix (+ proxy)   cancel -> handler token   about 4.2 s
```

So the I-6 http cells (1 s) and the I-5 http callerCancels cells (2 s) stay
KNOWN FAILING with the new reason; with the windows widened to 5 s and 8 s
all ten pass. Where the 2.1 s comes from is NOT measured: a separate-process
client (`nc`) was inconclusive, and Linux was not tried.

**The question for the owner:** does I-6's 1 s hold for a transport whose
only cancel signal is a TCP close? Options:

1. I-6 states a per-transport exception: http within the platform's
   close-detection time. The cells then assert a wider bound for http.
2. Keep 1 s, leave the cells KNOWN FAILING, and measure on Linux first:
   if the 2.1 s is macOS-only, the bound may hold on the servers that
   matter.
3. Accept it as is and close this lead.

Round 809 measured more (P-295's `r809_close_latency.dart`): the same 2.1 s
with the client in ANOTHER PROCESS (2101 ms) and with a `RawSocket` server
(2097 ms), so the delay is below `Socket` and below rpc_dart.

## Owner decision

Owner, 2026-10-10 (owner review after round 809): option 2, measure on
Linux first. If a server there sees a client's close well inside 1 s, I-6's
bound stays and the http cells come off KNOWN FAILING where it holds; if
Linux shows the same delay, put the question again with that number. The
bench to run there is `r809_close_latency.dart` (both arms) and the I-6 http
cells with `--run-skipped`.
