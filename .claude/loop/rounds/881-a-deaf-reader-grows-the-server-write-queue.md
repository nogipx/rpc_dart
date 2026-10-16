---
round: 881
verdict: FIXED
packages: [rpc_dart_socket, rpc_dart_conformance]
lens: RPC-18
bench: P-336 — new
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 881 — a deaf reader grows the server write queue

## Target

Lead `../backlog/B-298-the-socket-channel-writes-with-no-bound-on-what-the-peer-has-not-read.md`
(open, fresh, rank 2), measured for the first time. It is an I-3 question
("memory per peer is bounded", S1), reachable by any peer that connects, with
no auth in front: the strongest candidate in `next`.

Files and symbols:
- `packages/transport/rpc_dart_socket/lib/src/rpc_socket_channel.dart` —
  `RpcSocketChannel.send` (line ~221) calls `_socket.add(data)` and returns;
  the read side (`_onChunk`, `_sub`) is paused only by a paused `_incoming`
  consumer, never by the write backlog. The class doc (lines 26-29) claims
  "what bounds the bytes in flight is rpc_dart's flow control". Flow control
  credits DATA per stream; a unary call answered at once (metadata, one small
  message, trailer) is not held by it, so a peer that never reads its TCP
  socket and keeps opening such calls may grow dart:io's write buffer without
  bound while the server keeps reading its requests.
- `packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart` —
  its doc says it has the same design. `websocket_io_connections.dart:75,169`
  sets `pingInterval` 30 s by default, but dart:io resets that ping timer on
  incoming data, so a deaf reader that keeps SENDING is never pinged out;
  measure, do not assume. Round 713 fixed this shape for pings only.

Bench: none valid on these paths for this question (`find --path` on both
channel files lists no deaf-TCP-reader probe). Build one, modelled on P-86
(round 400, http2 deaf peer via TCP): a raw TCP client that writes the socket
preface (`RpcSocketChannel.preface`) and N unary call frames, and never reads
— not listening to a dart:io `Socket` leaves bytes in the kernel, which fills
and then stalls the server's writes. The conformance helpers in
`packages/test/rpc_dart_conformance/test/support/hostile.dart` (around line
286, `SocketMember`) already write a preface and frames over a raw socket.
Observable: server-process memory (RSS or `ProcessInfo.currentRss` in a
spawned server, per L-21 count the socket in the process that owns it) against
N answered calls, N = 1k/10k/50k. Control: the same peer with a draining
listener. The control has to show the bench can see the gap: deaf grows
linearly in N, draining stays flat. Keep each run under four minutes.

Siblings (`transport` group): the config's ```siblings block lacks
`rpc_dart_socket`, but the matrix has `SocketMember`
(`support/members.dart:512`) and I-3 holds across it; account for it as a
member. http2: bounded by the h2 package's read backpressure (round 400,
P-86; re-check with the same bench, cheap). http/1.1: one request per
connection at a time, pipelined headers not read while the first runs (C-76).
channel, isolate, wasm: no TCP peer; say so with the reason. A witness should
be a row in `i3_memory_per_peer_test.dart` (no row there drives a deaf TCP
reader today; its groups are paused-reader, stream limit, unfinished message,
ping flood).

Weighed and dismissed:
- B-297, B-270 — intermittent test timeouts, no reproduction; bench chores,
  not an S1 surface.
- B-299 — a stale socket file treated as any connect failure: a client-side
  connect-path correctness question, below an unbounded-memory one.
- B-290 — outside the round scope (owner, core and transports only).
- RPC-02 STALE sweep (16 files moved since 7ee9fab3) — a refusal-trailer
  re-read with one FIXED in ten rounds; lower yield and lower severity than
  an unmeasured I-3 hole.
- `checked/` has no record on a write backlog to a deaf reader (searched:
  C-03 is http2 PING, C-19 is http2 consumer refusal, C-76 is http/1.1
  pipelining).

## Hypothesis

A TCP peer that never reads and keeps starting unary calls the server answers
immediately grows the socket server's (and the websocket server's) memory
linearly in the number of answered calls, with no bound and no close, because
the channel keeps reading requests while dart:io's write queue holds every
unsent response. Against a draining control peer the same load stays flat.
If the server's footprint stays flat for the deaf peer too (something below
pauses the read), the verdict is CLEAN, with the mechanism named.

## Before

```
P-336, server on TCP, every call an unknown method answered by a trailer
                         calls    peer wrote   waiting when peer reads   server rss peak
raw-deaf (RawSocket,    200000    23046 KiB     59375 KiB                 +174 MiB
  read events off)
deaf (paused Socket)     20000     2304 KiB      5937 KiB
reads                    20000     2304 KiB         0 KiB (all received while sending)
ws-deaf (RpcWebSocket   200000    23046 KiB     59375 KiB
  Server, paused sub)
```

The kernel holds at most 8192 KiB here (`net.inet.tcp.autosndbufmax` and
`autorcvbufmax`, 4 MiB each), and the raw peer reads nothing, so about 50 MiB
of the 59375 KiB sat in the server process. Linear: 297 B per call at both
20k and 200k. The server read every request and never closed.

Matrix witness, new row: socket 1718 / 100000 calls taken at the first poll
(still rising), websocket 99500 / 100000, bound 60000.

Probe: `packages/transport/rpc_dart_socket/.dart_tool/probe/r881_deaf_peer_write_backlog.dart`
(arms `raw-deaf`, `deaf`, `reads`, `ws-deaf`);
speed: `packages/transport/rpc_dart_socket/.dart_tool/probe/r881_throughput.dart`.

## Mechanism

`RpcSocketChannel.send` called `Socket.add`, which queues in dart:io with no
size you can read, and the read side was paused only by a paused consumer.
Flow control holds DATA, but a call answered by metadata and a trailer is
outside it, so a peer that reads nothing and keeps starting calls had every
answer queued while the server kept reading its requests.

## After

```
                         calls    peer wrote             waiting when peer reads   server rss peak
raw-deaf, fixed         200000     2452 KiB (STALLED)     6318 KiB                  +31 MiB
```

The server stops reading past 1 MiB unsent, so the peer's own writes stall
once the kernel is full. Matrix row, socket: green; the server took 7920-8420
calls before pausing, and all 21000-24500 written once the peer read again.

Speed, honest reader on one TCP connection, medians of 5-7 runs, the original
`Socket.add` path (restored in place for the run) against the fix:

```
                       original    fixed
4000 x 1 KiB unary      947 ms     944 ms
500 x 64 KiB unary      652 ms     636 ms (633 on a second run)
```

## Canary

Witness: `I-3 a peer that never reads is not answered without bound | socket`
in `packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart`.

- Bound off (`1 < 0 &&` in `_write`'s pause condition): failed with
  "Expected: a value less than or equal to <60000> Actual: <100000> ... the
  server took 100000 calls from a peer that reads nothing, and holds every
  unsent answer".
- Release off (`1 < 0 &&` in `_taken`'s resume condition): failed with
  "the peer reads again, and the server took only 7920 of the 24500 calls it
  wrote".
- The server's flag off (`maxWriteBacklogBytes: null` from `RpcSocketServer`):
  failed with "Actual: <100000>", as the first.

Restored: green. The guard is `_write`'s pause; the release is `_taken`'s
resume. The websocket cell failed alongside in every run (99000-99500) and is
KNOWN FAILING under B-300.

Verdict check (`loop.py review`): 1 yes, the canary flips only the pause; 2
yes, 59375 vs 6318 KiB and 100000 vs 7920 calls; 3 yes, the matrix counts the
server's handlers, the probe counts at a peer that reads nothing, against the
kernel's ceiling; 4 yes, the canary shows the same window reaching 100000; 5
yes, quoted above; 6 yes, two halves, two canaries, plus the flag; 7 yes; 8
see Target, and the http line below is the SDK's code, not C-76's prose; 9
none — L-15 and L-07 applied: the first witness used 32 KiB DATA answers,
which park in the send window, and one instrumented run read `unsent=0` at
every 4 MiB read; 10 yes, quoted; A1 yes, the raw peer has no policy, the
server the default; A2 volume; L1 not a refusal, maxActiveStreams (4096) is
never reached by calls that end at once; P1 a named optional parameter and a
field on a class nothing in the repository implements or extends.

## Gate

After the last format (L-24: the first `analyze` caught one
`curly_braces_in_flow_control_structures` that format had made, fixed):
`melos run analyze` SUCCESS; `melos run test:unit:quiet --no-select` SUCCESS
(conformance +621 ~158, rpc_dart_socket +30, rpc_dart_websocket +331,
rpc_dart_http2 +369, rpc_dart +2265); `melos run format:check` SUCCESS;
`melos run license:check` compliant. Before it, the conformance package alone
at `-j 4` exposed the release wait as quadratic (`waitForCount` recounts every
event per event: 13.5k calls took 10 s); the row polls now, 1.7 s.

## Siblings

- socket: fixed here
- websocket: deferred — B-300 (the same witness: 99500 of 100000 taken; the
  fix needs the dart:io WebSocket, which web_socket_channel 3.x hides)
- http2: deferred — B-301 (not measured: a package:http2 client cannot open
  streams past MAX_CONCURRENT_STREAMS while it reads nothing)
- http: n/a — dart:io's `_HttpConnection` pauses the parser for the next
  request until `outgoing.done` (`_http/http_impl.dart` 3346-3377), so at most
  one answer per connection is queued
- channel: n/a — no network peer; both ends are code in this process
- isolate: n/a — no network peer; the other end is an isolate this process
  spawned
- wasm: n/a — no network peer; the guest runs inside the host process
- responder: fixed here (`RpcSocketServer` sets the limit)
- caller: n/a — a caller writes its own calls and credit for DATA it has
  consumed; nothing a peer sends is answered by the caller outside that, so a
  deaf server grows its queue only by the caller's own sends. It does not
  pause on purpose: two pausing ends wait on each other

## Not fixed

- websocket, B-300: the same unbounded queue, measured. web_socket_channel
  3.x feeds `WebSocket.add` through a `StreamChannelController`, so no
  backpressure reaches `sink.addStream`, and the server's public connection
  type (`Stream<WebSocketChannel>`) hides the dart:io socket. A fix changes
  what the server accepts.
- http2, B-301: unmeasured; the bench is a raw HTTP/2 peer.
- The client side of `RpcSocketChannel` does not pause: if both ends paused,
  each would wait for the other to read.
- A DATA answer to a deaf peer parks in the send window instead and is bounded
  by maxActiveStreams (C-29), not by this.
- B-272 awaits the owner and was not weighed as a target.

## Links

RPC-18; P-336 (new, promoted to the matrix row); B-298 (closed), B-300,
B-301 (new); L-07, L-15, L-24 applied; C-29.
