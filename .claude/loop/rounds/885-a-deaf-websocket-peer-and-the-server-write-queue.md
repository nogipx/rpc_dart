---
round: 885
verdict: FIXED
packages: [rpc_dart_websocket, rpc_dart_conformance]
lens: RPC-18
bench: P-336 — reused
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 885 — a deaf websocket peer and the server write queue

## Target

Lead B-300 (measured in round 881, P-336 arm `ws-deaf`), taken by the owner
in a manual session (not chosen by `select`). Owner decisions for this
session: breaking API changes ARE allowed (major bump, `!` in the commit), but
the owner picks between real design options; one commit per lead after the
full gate.

Files: `packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart`
(`RpcWebSocketChannel.send` -> `WebSocketSink.add`, nothing ties reads to the
write backlog) and `lib/src/websocket_io_connections.dart`
(`rpcWebSocketConnections` yields `Stream<WebSocketChannel>`, which hides the
dart:io `WebSocket`). The lead explains why round 881's socket fix does not
carry over: web_socket_channel 3.x drains its sink through a
`StreamChannelController` into package:web_socket `sendBytes` -> dart:io
`WebSocket.add`, so no backpressure reaches `sink.addStream`. dart:io's own
`WebSocket.addStream` does see it.

Sibling fixes to copy the shape from: round 881 (`RpcSocketChannel`, counted
controller through `Socket.addStream`, pause reads past 1 MiB unsent) and
round 884 (`Http2WriteBacklog` in rpc_dart_http2, same 1 MiB / resume at
half; and its lesson: never pause a writer that can be resumed after close).
Witness exists: conformance row `I-3 a peer that never reads is not answered
without bound | websocket` in
`packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart`, KNOWN
FAILING under its id (99500 of 100000 calls taken vs a bound of 60000).
Round 884 changed that row's peer (windows opened, 1 KiB answers) — re-read
it before relying on the 881 numbers. Re-run P-336 `ws-deaf` as the control
first (repeat the bench, per the measurement checklist).

FIX DESIGN (owner's choice, 2026-10-17): count BELOW dart:io, inside
`_BoundedSocket` in `lib/src/websocket_bounded_upgrade.dart`. The server path
is `rpcWebSocketConnections` -> `_PolicyAwareConnections` -> `upgradeBounded`
-> dart:io `WebSocket.fromUpgradedSocket(_BoundedSocket(...))`, so every byte
dart:io writes passes `_BoundedSocket.addStream`. Write through a counted
controller into the real socket's `addStream`; past 1 MiB unsent PAUSE reading
the raw socket, resume at half (as rounds 881/884). No public API change.
Server side only: `connectBounded` (the client) stays unbounded — two pausing
ends would wait for each other. A foreign `Stream<WebSocketChannel>` (shelf,
hand-built) stays unbounded: document it in the server's doc/README, as
round 884 did for http2's plain constructor. Rejected by the owner: our own
`WebSocketChannel` subclass (same coverage, more code) and a breaking server
type. A spike in that file from an interrupted run was reverted; start clean.
Also the lead's open point: dart:io's ping timeout closes a fully deaf peer
after ~2 pingIntervals, but a peer that answers pings and reads nothing else
is not closed — that is the case to measure.

## Hypothesis

A websocket peer that stops reading and keeps opening calls grows the
rpc_dart_websocket server's unsent queue without bound; with reads paused
past a write-backlog bound, the server holds a bounded amount and the I-3
websocket cell turns green.

## Before

```
P-336, RpcWebSocketServer over rpcWebSocketConnections (compression off, the
default), no contracts: each call an unknown method answered by a trailer.
Peer: a child process, raw websocket client, read events off after the 101.
                     calls    peer wrote    waiting when the peer reads   server rss peak
ws-raw-deaf         200000    24218 KiB      60546 KiB                     +180 MiB
ws-raw-deaf         400000    48437 KiB     121093 KiB                     +295 MiB
```

The kernel holds at most 8192 KiB (4 MiB send + 4 MiB receive), so about
51 MiB at 200k and 110 MiB at 400k sat in the server: ~300 B per call,
linear, no stall. The control is the same peer against the fixed server
(After) and the canaries below; `ws-raw-reads` is no control for the queue
(it reads all along, and its 3 s write timeout fired on the server's CPU).

Probe: `packages/transport/rpc_dart_socket/.dart_tool/probe/r881_deaf_peer_write_backlog.dart`
(arms `ws-raw-deaf`, `ws-raw-reads`). Speed:
`packages/transport/rpc_dart_websocket/.dart_tool/probe/r885_throughput.dart`
and `r885_pipelined.dart`; stop with a deaf peer: `r885_stop_deaf.dart`, same
directory.

## Mechanism

dart:io's WebSocket writes every frame through `Socket.addStream` and never
stops reading while that write is queued, so each answer to a peer that reads
nothing waited in dart:io's outgoing controller. web_socket_channel hides the
dart:io WebSocket, but not the `Socket` the bounded upgrade hands it.

## After

```
                     calls    peer wrote             waiting when the peer reads   server rss peak
ws-raw-deaf, fixed  200000     2493 KiB (STALLED)     6233 KiB                      +45 MiB
```

`_BoundedSocket.addStream` on the server now writes through `_WriteBacklog`:
dart:io's stream is never paused, its bytes land in a counted controller fed
to the real socket's `addStream`, and past 1 MiB unsent the raw socket is not
read until half has gone out. The end of the write (failure or destroy)
releases the pause. `connectBounded` (the client) passes no backlog.

Matrix row `I-3 a peer that never reads is not answered without bound`:
websocket cell green in 9 s (http2 8 s, socket 7 s in the same run). Its
peer is now a raw socket like the other two cells (upgrade by hand, each
batch one masked binary frame, read events off); the dart:io client it
replaced parsed every answer in the test's process, and the release then
needed ~20 s against the row's 10 s (see Canary).

Speed, an honest reader, one connection, server and caller in one process
(r885_throughput, medians of 7-9 runs), the original wiring restored in place
(`backlog: null`) for the original column, load average 7-12:

```
                               original          fixed
4000 x 1 KiB unary             2139 ms           2154 ms
500 x 64 KiB unary              788 ms            738 ms
server stream 200 x 64 KiB      147, 150 ms       158, 157 ms
server stream 2000 x 64 KiB    1449 ms           1399 ms
100000 calls pipelined, client in a child process (r885_pipelined, 3 runs)
                               7918 ms           8068 ms
the same, client in-process    13452 ms          12106 ms
```

No difference above the run-to-run spread (the 200-item stream differs by
~8 ms of a 127-191 ms range; at 2000 items the fixed side is faster).
`server.stop()` with a deaf peer stalled over the limit: 5 ms (original, peer
not stalled: 12 ms).

## Canary

Witness for the bound and its release: `I-3 a peer that never reads is not
answered without bound | websocket` in
`packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart`.

With the row's raw websocket peer:

- Bound off (`1 < 0 &&` in the pause condition in `_addStream`): failed with
  "Expected: a value less than or equal to <60000> Actual: <99500> ... the
  server took 99500 calls from a peer that reads nothing, and holds every
  unsent answer".
- Release off (`1 < 0 &&` in `_taken`'s resume condition): failed with
  "Expected: a value greater than or equal to <19000> Actual: <8000> ... the
  peer reads again, and the server took only 8000 of the 19000 calls it
  wrote".
- Wiring off (`backlog: null` in `upgradeBounded`): failed with "Actual:
  <100000> ... the server took 100000 calls".

The same three failed the same way with the earlier dart:io-client peer
(99500, 8000 of 100000, 99000).

Witness for the end-of-write release: `WITNESS: a deaf peer that drops past
the backlog limit is let go` in
`packages/transport/rpc_dart_websocket/test/a_deaf_peer_is_not_answered_without_bound_test.dart`.
With `_release()` in `_addStream`'s `whenComplete` switched off (`if (1 < 0)`)
it failed with "Expected: true Actual: <false> the peer is gone, and the
server never saw its connection end" (polled 10 s). Restored: green, and the
I-3 row green.

The guard is the pause in `_addStream`; the release is `_taken`'s resume; the
teardown release is `whenComplete`.

The first green attempt of the row failed the RELEASE with the fix in place:
"the server took only 88500 of the 100000 calls it wrote", then 81500 and
91500. Instrumented (L-07: pause/resume timestamps in the backlog, the taken
count every 100 ms): the server cycled pause/resume as designed, the event
loop busy ~1.4 s per cycle; r885_pipelined then showed an honest in-process
reader of 100000 calls needs 12-13 s with or without the fix. The 10 s wait
measured the test's own client, not the server. Lengthening the wait to 30 s
turned the cell green in ~20 s, but the next full gate failed a
load-sensitive neighbour (Gate), so the peer became the raw socket the
socket and http2 cells already use, and the wait went back to 10 s.

Verdict check (`loop.py review`): 1 yes, the control is the same peer against
the server with the backlog, and the canaries flip one condition each; 2 yes,
60546 vs 6233 KiB waiting at 200k, and 99500 vs ~8500 calls in the row; 3 yes,
the probe counts what reached a peer that read nothing against the kernel's
ceiling, the row counts the server's handlers; 4 yes, the canary shows the
same window reaching 99500; 5 yes, quoted above; 6 yes, three halves, three
canaries plus the wiring; 7 yes; 8 yes, see Target (taken by the owner; B-300
re-measured, not trusted); 9 none new: L-07 paid again (a red release
answered by timestamps in one step); 10 yes, see Siblings; severity quotes the
S1 rubric line, 121093 KiB at 400k, linear; A1 yes, the raw peer has no
policy, the server the default; A2 volume; L1 not a refusal; P1 no public
type changed: `_WriteBacklog` and `_BoundedSocket` are private to
`lib/src/websocket_bounded_upgrade.dart`, which is not exported.

## Gate

NOT GREEN. `melos run analyze` SUCCESS (after the last format, L-24);
`melos run format:check` SUCCESS; `melos run license:check` compliant.
`melos run test:unit:quiet --no-select`: RED in all six runs on the final
tree and in both controls, each time on one load-sensitive network test that
rotated between runs (table in B-297): i3 oversized socket (4), i9 websocket
restart (1), i1 http working peer (1); controls: i9 websocket restart with
the fix and the deaf cell skipped, rpc_dart_http `policy_reaches_endpoint_test`
with no fix. Every other package green in every run (rpc_dart +2265 ~1,
rpc_dart_websocket +332, rpc_dart_http2 +369, rpc_dart_socket +34).

Scoped, green: rpc_dart_websocket `-j 8` (+332, the new test included); the
conformance package alone (+623 ~156), next to rpc_dart_websocket's suite, and
under 10 spinning processes; the I-3 file alone; the I-9 file alone twice.

Two of the three reds run on the socket and http transports, which this
round did not change; the third, i9 websocket restart, failed with the same
text in round 884, before this change; and the control without the fix was
red too.

Then GREEN: the dispatcher re-ran `melos run test:unit:quiet --no-select` on
the same tree with no bench running (load average 7.7, falling from 15.5):
exit 0, SUCCESS. The six reds ran next to this round's own load benches.

## Siblings

- websocket: fixed here (the server's bounded upgrade; the row's websocket
  cell, 99500 -> <= 60000 calls taken)
- http2: clean — the same witness, test `I-3 a peer that never reads is not
  answered without bound | http2` in i3_memory_per_peer_test.dart, green in
  this round's run in 8 s (fixed in round 884)
- http: n/a — dart:io's `_HttpConnection` does not read the next request
  until `outgoing.done`, so at most one answer per connection is queued (the
  row's skip, C-76)
- channel: n/a — no network peer; both ends are code in this process
- isolate: n/a — no network peer; the other end is an isolate this process
  spawned
- wasm: n/a — no network peer; the guest runs inside the host process
- socket (not a group member): fixed in round 881; the same row green here
- responder: fixed here (`upgradeBounded`, which `rpcWebSocketConnections`
  uses for every connection with compression off)
- caller: n/a — a caller must not pause: if both ends paused, each would wait
  for the other to read; `connectBounded` passes no backlog

## Not fixed

Server write paths in rpc_dart_websocket, counted: 3. One fixed
(`upgradeBounded`). Two stay unbounded, documented in the README and in
`rpcWebSocketConnections`' doc, as the owner decided:

- `rpcWebSocketConnections` with compression on: dart:io's
  `WebSocketTransformer` upgrades the socket, so there is no `_BoundedSocket`
  to count in.
- any other `Stream<WebSocketChannel>` (shelf_web_socket, a hand-built
  transformer): the socket is upgraded before rpc_dart sees it.

Also: the backlog bounds what waits, not how far reads run ahead of it.
Calls already read when reads pause are still answered, so in the row's
instrumented run (the earlier dart:io-client peer) 5137207 bytes were unsent
when the connection ended: what
waits is 1 MiB plus the answers to calls read before the pause, not 1 MiB.
P-336 (a peer in another process) stalled at 6233 KiB waiting, kernel
included. The keepalive's effect on a peer whose reads are
paused (its pong goes unread) was not measured. B-272 awaits the owner and
was not weighed.

## Links

RPC-18; P-336 (reused, `ws-raw-*` arms); B-300 (closed); L-07 applied;
round 880 (rows hold to an ending), round 881, round 884; C-76.
