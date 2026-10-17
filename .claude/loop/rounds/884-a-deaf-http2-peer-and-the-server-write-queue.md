---
round: 884
verdict: FIXED
packages: [rpc_dart_http2, rpc_dart_conformance]
lens: RPC-18
bench: P-339 — new
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 884 — a deaf http2 peer and the server write queue

## Target

Lead B-301, taken by the owner in a manual session (not chosen by `select`).
Owner decisions for this session: evidence bar per lead (a hypothesis the
measurement refutes may close the lead with no fix); breaking API changes are
allowed (major bump, `!` in the commit) if a fix needs one; one commit per
lead after the full gate.

Surface: `packages/transport/rpc_dart_http2/lib/**`, the server side, over
package:http2 3.1.0. Hypothesis from reading package:http2 only (round 881):
nothing pauses the frame reader when the frame writer's buffer grows
(`wouldBuffer` is consulted in `flowcontrol/connection_queues.dart` outgoing and
`flowcontrol/stream_queues.dart:342` per-stream incoming). A trailers-only
answer is HEADERS, outside flow control, so a peer that keeps opening streams
and reads nothing would grow the server's outgoing queue without bound.

Siblings, same shape: round 881 FIXED it for `rpc_dart_socket` (P-336,
`.dart_tool/probe/r881_deaf_peer_write_backlog.dart` in rpc_dart_socket, arm
for each transport); websocket is B-300 (measured, unfixed, next in this
session). Read how 881 fixed the socket server before designing a fix here.
The conformance matrix row `I-3 a peer that never reads is not answered
without bound` (`packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart`)
skips http2; if this round confirms and fixes it, http2 joins that row.

Bench: none valid for http2. Why the rig cannot drive it: a package:http2
client cannot see a stream retire while it reads nothing, so it stops at the
server's MAX_CONCURRENT_STREAMS (maxActiveStreams, 4096 by default) — that is
the many-streams bound, not this one. The bench is a RAW peer over a plain
socket: connection preface + SETTINGS, then HEADERS frames it encodes itself
(HPACK; a literal header block without indexing is enough), each with
END_STREAM, past maxActiveStreams, never reading the socket (or reading
nothing at the TCP level so the server's socket send buffer fills). Measure
what the server holds (its write backlog / RSS per stream at three scales)
against a control peer that reads. Mind lesson L-10 (a hand-built peer must
use the library's serializer — the gRPC message framing) and RPC-18 (the
buffer lives in the dependency, below our limits).

Records weighed: B-301 (the lead), P-336 / round 881 (sibling fix), B-300
(sibling, unfixed), C-29 (stream limits' real scope). P-86 (round 400) reads
"bounded by the dependency's own read backpressure"; its peer was a
package:http2 client, which stops at its own stream count, so it never reached
the case this round measures. Current code (no pause on package:http2's reader)
and the bench below decided it, not that record.

## Hypothesis

A raw HTTP/2 peer that opens unary calls past maxActiveStreams and never reads
makes the rpc_dart_http2 server's outgoing queue grow without bound, while a
peer that reads keeps it flat.

## Before

```
P-339, RpcHttp2Server, no contracts: each call an unknown method answered
trailers-only (~134 B). Peer: a child process on a RawSocket.
                    calls    peer wrote     waiting when the peer reads
reads (control)    200000    26367 KiB      0: all 200000 answers read while sending
deaf                20000     2636 KiB       2617 KiB, 20000 answers (inside the kernel)
deaf               200000    26367 KiB      26171 KiB, 200000 answers
deaf               400000    52734 KiB      52343 KiB, 400000 answers
```

The kernel holds at most 8192 KiB here (`net.inet.tcp.autosndbufmax` and
`autorcvbufmax`, 4 MiB each), so about 18 MiB at 200k and 44 MiB at 400k sat
in the server process: 134 B per call, linear, no stall, no close. Server
peak RSS +164.7 MiB at 200k and +375.4 MiB at 400k (one process, read as a
direction only). The keepalive (30 s PING, 30 s timeout) ends a fully deaf
peer after about a minute; at 26 MiB in 13 s that bounds nothing.

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/r884_deaf_h2_peer.dart`
(arms `deaf`, `reads`; flags `inproc`, `data`, `stopdeaf`). Speed:
`packages/transport/rpc_dart_http2/.dart_tool/probe/r884_throughput.dart`.

## Mechanism

`RpcHttp2ResponderTransport.overStreams` handed package:http2 the socket as
its sink, and package:http2 never pauses its frame reader: when the socket is
full it marks its writer buffered and queues answers in
`ConnectionMessageQueueOut` while it reads on. Flow control holds DATA, but a
trailers-only answer is HEADERS, so a peer that reads nothing and opens calls
that end at once (no stream stays live, so maxActiveStreams never counts them)
had every answer queued.

## After

```
                    calls    peer wrote             waiting when the peer reads
deaf, fixed        200000     5277 KiB (STALLED)     5238 KiB, 40028 answers
deaf, fixed, in-process, HEADERS + DATA per call:     2917 KiB, 18675 answers
```

`overStreams` now writes through `Http2WriteBacklog`: a counted controller fed
to the socket with `addStream`, and a pausable wrapper on the socket's bytes.
Past 1 MiB unsent it stops reading the peer until half has gone out. It never
pauses package:http2's own writer.

Matrix row, http2 cell: green in 7 s; the server takes ~9500-18000 calls and
pauses, and takes everything once the peer reads again.

Speed, an honest reader on one connection, medians of 7-9 runs, two runs per
side, the original wiring restored in place for the original column (load
average 8-10 during all of them):

```
                         original        fixed
4000 x 1 KiB unary       1520, 1559 ms   1620, 1513 ms
500 x 64 KiB unary       1318, 1165 ms   1209 ms
server stream 200x64 KiB 1352, 1363 ms   1414, 1290 ms
```

No difference above the run-to-run spread. `server.stop()` with the peer still
deaf and the backlog over the limit: 2014 ms (the default drain).

## Canary

Witness: `I-3 a peer that never reads is not answered without bound | http2`
in `packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart`.

- Bound off (`1 < 0 &&` in `_write`'s pause condition): failed with
  "Expected: a value less than or equal to <60000> Actual: <99747> ... the
  server took 99747 calls from a peer that reads nothing, and holds every
  unsent answer".
- Release off (`1 < 0 &&` in `_taken`'s resume condition): failed with
  "the peer reads again, and the server took only 3747 of the 18000 calls it
  wrote".
- The wiring off (`incoming` handed to the header-block guard instead of
  `backlog.reads(incoming)`): failed with "Actual: <96500>".

Restored: green. The guard is `_write`'s pause; the release is `_taken`'s
resume.

The first version of the fix also paused package:http2's writer while over
the limit. The full gate failed the http2 cell with "Bad state: Cannot add
event after closing" from `BufferedBytesWriter.add`
(`ConnectionMessageQueueOut._trySendMessages`), and "teardown: http2 server
stop still running": a writer resumed after its connection closed fires
`bufferEmptyEvents` and writes into its closed sink. The shipped version
never pauses it; package:http2 then writes everything into the counted
controller, where the bytes are counted. DATA stays bounded by the stream
windows, which are what pace a producer (`StreamMessageQueueOut` reads the
stream window, not the connection writer).

The matrix row's first http2 version failed even with the fix: 98247 calls
taken. Instrumented (L-07): the server's unsent bytes stayed 0, and `netstat`
showed 7.5 MB in the deaf peer's receive queue. With answers of ~130 B and a
peer in the same process the kernel absorbs about 60k answers, so the
calls-taken bound cannot tell bounded from unbounded. The http2 peer now opens
its windows (SETTINGS_INITIAL_WINDOW_SIZE and the connection window to
2^31 - 1) and asks for 1 KiB echo answers, which flow control then does not
hold.

Verdict check (`loop.py review`): 1 yes, the control is the same peer reading;
the canaries flip one condition each; 2 yes, 26171 vs 0 KiB waiting at 200k,
and 100000 vs ~9500 calls in the row; 3 yes, the probe counts at a peer that
read nothing against the kernel's ceiling, the row counts the server's
handlers; 4 yes, the canary shows the same window reaching 99747; 5 yes,
quoted above; 6 yes, two halves, two canaries, plus the wiring; 7 yes; 8 see
Target: P-86 was read and set aside on its peer, not on its prose; 9 none
new — L-07 paid again (a bound that read 0 unsent, answered by netstat in one
step), and the pause-the-writer failure is recorded on RPC-18; 10 yes, see
Siblings; severity quotes the S1 rubric line and the 52343 KiB at 400k; A1
yes, the raw peer has no policy, the server the default; A2 volume; L1 not a
refusal, and maxActiveStreams (4096) never counts calls that end at once; P1
no public type changed: `Http2WriteBacklog` is in `lib/src` and not exported,
and `overStreams` keeps its signature.

## Gate

Final run, after the last edit: `melos run analyze` SUCCESS; `melos run
test:unit:quiet --no-select` SUCCESS (conformance +622 ~157, rpc_dart_http2
+369, rpc_dart_socket +34, rpc_dart_websocket +331, rpc_dart +2265 ~1);
`melos run format:check` SUCCESS; `melos run license:check` compliant.
Scoped before it: rpc_dart_http2 at `-j 8` green, the conformance package
green.

Five quiet-gate runs in all. The first failed the http2 cell with the
writer-pause version (Canary above). The next three, on the shipped code,
failed tests that pass alone, at a 5-minute load average of 27-49 (12 of
those processes were this round's own load bench): http2
`graceful_drain_on_stop_test` "a restart during a drain" ('status 14'; then
3 of 3 green under 12 spinning processes), conformance "i3 an oversized
message that never finishes: socket" (already in B-297), conformance "i9
online again after the server restarts: websocket", socket "a refused TCP
connect is UNAVAILABLE" ('ok'), http2 "stop() during the bind". The socket
and websocket ones never reach rpc_dart_http2. The drain test and the i9 row
are added to B-297's list; the fifth run, at a load average of 9, was green.

## Siblings

- http2: fixed here
- socket: fixed in round 881, the same matrix row green in this round's runs
- websocket: deferred — B-300 (the same row, KNOWN FAILING; the fix needs the
  dart:io WebSocket, which web_socket_channel 3.x hides)
- http: n/a — dart:io's `_HttpConnection` pauses the parser for the next
  request until `outgoing.done`, so at most one answer per connection is
  queued (the row's skip, C-76)
- channel: n/a — no network peer; both ends are code in this process
- isolate: n/a — no network peer; the other end is an isolate this process
  spawned
- wasm: n/a — no network peer; the guest runs inside the host process
- responder: fixed here (`overStreams`, which `RpcHttp2Server` builds every
  connection with, plain and TLS)
- caller: n/a — a caller must not pause: if both ends paused, each would wait
  for the other to read; a deaf server grows a caller's queue only by the
  caller's own sends

## Not fixed

- websocket, B-300: the same unbounded queue, measured in round 881.
- A server built with the plain `RpcHttp2ResponderTransport(connection:)`
  constructor gets no bound: the connection is built before rpc_dart sees it.
  The constructor's doc says so, as it already did for the header-block bound.
- The TLS path goes through the same `overStreams`, but no deaf TLS peer was
  measured: `SecureSocket`'s own buffer sits between the counted controller
  and the kernel.
- DATA on streams already open is still bounded only by the windows the PEER
  grants; a peer that opens them to 2^31 - 1 and reads nothing may let a
  producing server-stream handler queue up to that. Unmeasured: B-303.
- B-272 awaits the owner and was not weighed as a target.

## Links

RPC-18; P-339 (new, promoted to the matrix row); B-301 (closed), B-303 (new),
B-300,
B-297 (two more load reds named); P-336, P-86, P-335; L-07, L-10, L-24
applied; C-29.
