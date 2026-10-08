# Benches

What a bench is and when it counts as valid — [../LOOP.md](../LOOP.md). The
record format — `../../skills/evidence-loop/specs/probe.md`.

Rounds 201-205 worked with one-off probes: bench registration appeared in the
skill after them, so nothing before 206 has a record here.

**`stale (sha)` does not mean broken.** It means the code under the bench's
paths has moved since its control was last run, so the next round to reuse it
repeats that control FIRST. Only a round with a control sets `valid` again.
Marked in the curate pass after round 220.

**Curate after round 327 left all 30 newly-stale benches at `valid`, on
evidence.** The staleness is the lint-floor rounds (325, 326 — 161 mechanical
files, every test count unchanged); see `../checked/CHECKED.md` for the full
argument. Two benches were reused across that boundary and both reproduced their
controls exactly: **P-10** in round 322, all eight cells of its table identical
to round 221's, and **P-08** in round 327, all four rows identical to round
216's — the latter across 111 rounds. Demoting 30 benches to `stale` on churn
that has twice failed to move a control would send the next round rebuilding
apparatus that works.

The rule the spec states still stands and is what those two rounds did: **repeat
the control first, then trust the bench.** That is cheaper than the status field
either way.

**Curate after round 348: the same decision, and this block supplies the
evidence the 327 one had to borrow.** `stale` now ages 38 of 42 benches, because
round 337 guarded 158 log sites across 21 files. Four of this block's own
benches were BUILT after that churn and validated against it — P-38, P-39, P-40
each with a control that fired, and P-41 whose control needed two prunes removed
before it would. P-36 was built before it and re-run after, unchanged. A status
field flipped to `stale` on churn that five consecutive benches saw through would
send the next round rebuilding apparatus that works.

The two genuinely-moved benches are P-38 and P-40, whose paths are the http2
transports rounds 340 and 342 changed — and both were re-run in those rounds,
after the change, which is what the status is for.

- **[P-251](P-251-a-given-channel-that-never-connects.md)** valid (round 747), rpc_dart_websocket — a constructor-built transport over a channel to a dead port, against the bare channel with and without `ready` observed
- **[P-250](P-250-a-client-connection-across-a-server-restart.md)** valid (round 746), rpc_dart_websocket, rpc_dart_http2 — RpcClientConnection across a server restart on the same port, with a transport-closes-on-drop control
- **[P-249](P-249-the-process-exits-after-close.md)** valid (round 746), rpc_dart_http2, rpc_dart_websocket — exit latency after main returns, per arm, as a subprocess, with a server-left-running control
- **[P-248](P-248-a-foreign-runtime-release.md)** valid (round 744), rpc_dart_wasm — load() against a plugin that ignores the requested runtime id and then fails to close it
- **[P-247](P-247-two-closes-on-a-stuck-handler.md)** valid (round 743), rpc_dart — two concurrent responder close() calls while handlers of all four shapes hang, with the disposer-bound ablation
- **[P-246](P-246-rpc-dart-against-grpc-go.md)** valid (round 742), rpc_dart_http2 — rpc_dart's h2 caller against a real grpc-go server: all four call shapes, a non-ASCII status message, `grpc-timeout` (999 ms at the server) and an unknown method
- **[P-245](P-245-grpcurl-against-rpc-dart.md)** valid (round 740), rpc_dart_grpc_reflection + rpc_dart_http2 — a real `grpcurl` against RpcHttp2Server with reflection: list, describe, unary, stream, NotFound and a cancelling `grpc-timeout` all behave
- **[P-244](P-244-dropped-requests-and-the-pool.md)** valid (round 738), rpc_dart — whether requests a bidi handler stopped reading drain the connection pool: no (100000 KiB sent per call, a unary passes), against HUNG when the handler pauses instead
- **[P-243](P-243-a-second-endpoint-close.md)** valid (round 732), rpc_dart — when a second concurrent endpoint `close()` returns: at 6 ms with the transport still open before round 732, with the first at 209 ms after
- **[P-242](P-242-stop-during-the-bind.md)** valid (round 731), rpc_dart_http2 + rpc_dart_http + rpc_dart_log — whether a server stopped during its bind is listening afterwards: yes for all three before round 731, no after
- **[P-241](P-241-a-failed-test-app-start.md)** valid (round 728), rpc_dart_framework — `onStop` calls for a module started before another's `onStart` threw: `RpcApp` 1, `RpcTestApp` 0 before round 728 and 1 after
- **[P-240](P-240-teardown-order.md)** valid (round 727), rpc_dart_framework — the order of server stop and module `onStop` in `stop()` and in a failed start's rollback: the rollback had it inverted
- **[P-239](P-239-unknown-methods-against-the-otel-interceptor.md)** valid (round 725), rpc_dart_opentelemetry — spans the OTel interceptor exports for calls to unregistered names: 0 of 200, against 100 of 100 for the registered method
- **[P-238](P-238-a-deaf-reader-against-an-h2-bidi-handler.md)** valid (round 723), rpc_dart_http2 — responses an h2 bidi handler produces for a raw peer that keeps sending and grants no response credit: 66, against 100000 reading and 100000 with the pump's pause wait ablated
- **[P-237](P-237-stop-during-start.md)** valid (round 721), rpc_dart_framework — server starts, stops and running state after `RpcApp.stop()` lands inside `start()`: 1 / 0 / running before, 1 / 1 / stopped after
- **[P-236](P-236-tiny-responses-against-the-caller-window.md)** valid (round 720), rpc_dart_http2 — responses a paused h2 caller accepts before its window stops the server: 472002 empty ones charged by payload alone, 36002 weighed, 4245 at 1 KiB
- **[P-235](P-235-tiny-messages-against-the-byte-bound.md)** valid (round 719), rpc_dart + rpc_dart_http2 — RSS of parked h2 client-stream queues of two-byte messages: +413 MiB over 8 streams with the depth bound lifted and nothing weighing a message, -30 MiB once each counts 128 bytes
- **[P-234](P-234-a-closed-transport-releases-its-socket.md)** valid (round 718), rpc_dart_http2 — caller sockets left 3 s after `close()` against a peer that never closes, direct and through a CONNECT proxy: 0 and 0, against 1 with the pipe's shutdown and destroy ablated
- **[P-233](P-233-upload-into-a-deaf-server.md)** valid (round 717), rpc_dart_http — whether a caller deadline stops an HTTP/1.1 upload the server stopped reading: 2432 KiB and the socket closed, against 8192 KiB on an open socket with the abort removed
- **[P-232](P-232-what-the-default-retry-spends-on-resource-exhausted.md)** valid (round 669), rpc_dart + rpc_dart_http — bytes uploaded for a message at 2x and 10x the ceiling with and without the default retry, plus a handler cap, a rate limit and a size refusal against a retrying caller: before round 669 the size refusal was uploaded three times; now once, with the capacity arms still retried. Round 669
- **[P-231](P-231-one-stream-error-against-the-calls-beside-it.md)** valid (round 667), rpc_dart + rpc_dart_http2 — three slow calls in flight plus one offending stream (a malformed http2 frame, a request over the channel policy, a server RST under `RpcClientConnection`), against the same stream sent clean: before round 667 every innocent call failed; now none. Round 667
- **[P-230](P-230-what-follows-an-overrun.md)** valid (round 666), rpc_dart_http2 — a paused per-stream consumer on each side overrun by 8 x 4 KiB against a 16 KiB window, events printed in order: before round 666 one payload arrived behind the refusal on both sides; now none. Round 666
- **[P-229](P-229-what-a-failed-response-still-downloads.md)** valid (round 664), rpc_dart_http2 — a raw peer answering 503 HTML, 200 HTML, refused headers or an unparseable body with 1 MiB, through the endpoint and directly on the transport, plus a 103 control: before round 664 a transport user downloaded all of it with 128 ERROR records; now the stream is reset at the verdict. Round 664
- **[P-228](P-228-stream-ids-across-the-wrap.md)** valid (round 661), rpc_dart — stream ids at the top of the 31-bit space, one transport and across an `RpcClientConnection` reconnect, against a low-seeded control: before round 661 the reconnected transport replayed all five ids; now it continues after the last one issued. Round 661
- **[P-227](P-227-metadata-at-the-policy-edge-over-a-channel-pair.md)** valid (round 660), rpc_dart — an honest sender's metadata at and around `maxMetadataBytes` over a channel pair, request and response: before round 660 text at the limit, or 34000 quote characters, closed the server connection and the other call on it; now the sender refuses both. Round 660
- **[P-226](P-226-a-chaos-run-of-the-core.md)** valid (round 640), rpc_dart — 200 concurrent calls per epoch, all four shapes, chaotic handlers and callers, one epoch in six torn down mid-traffic; pair, in-memory and with resilience interceptors. 23 000 calls clean: none hung or settled twice, no responder left, RSS flat. Round 640
- **[P-225](P-225-what-a-fuzzer-finds-in-the-decoders-and-the-servers.md)** valid (round 639), rpc_dart + rpc_dart_websocket — four fuzzers: every peer-bytes decoder, a server, a client, a real websocket server. 100 000 inputs per decoder, 3300 server and 150 client sessions, 3600 websocket attacks; one defect, a repeated Sec-WebSocket-Key killing a server with compression on. Round 639
- **[P-224](P-224-where-a-streamed-message-goes.md)** valid (round 622), rpc_dart — P-147's stream against a no-endpoint floor, plus VM-profiler attribution. `4.44` vs `1.57 us/message`; nearly 60 % of samples in `dart:async`. B-204
- **[P-223](P-223-what-a-real-call-spends-on-context.md)** valid (round 621), rpc_dart — VM profiler samples over real unary calls, by context and metadata function. Context copies and header validation are about 5 % of a call; the token is 28 %. B-120
- **[P-222](P-222-what-a-discarded-compress-costs.md)** valid (round 620), rpc_dart — `compressIfSmaller` per call by size and content. About 17 us of every gzip compress is fixed set-up; at 20 bytes or fewer it is now skipped. B-206
- **[P-221](P-221-what-a-window-becomes.md)** valid (round 619), rpc_dart — a 4 MiB window of 1 KiB messages behind a paused caller, with a 1x and a 16x decoded type, one arm per process. 4036 standing, 2 decoded in every arm. B-218
- **[P-220](P-220-what-the-limiter-costs-a-message.md)** valid (round 618), rpc_dart — the rate limiter's cost per metered message, alone and inside a streamed call. Re-resolution is about 120 ns, under the end-to-end spread. B-213
- **[P-219](P-219-the-streaming-shapes-across-a-reconnect.md)** valid (round 615), rpc_dart_websocket — P-174's reconnect rig for server-stream, client-stream and bidi. All three are served across a reconnect; the bidi guard found peer bidi requests lost to the caller wrapper's async forward. B-212
- **[P-218](P-218-the-parser-and-send-copies.md)** valid (round 614), rpc_dart — parser and send-path copies per message. 1 MiB parse+keep `389 -> 257 us`, send `392 -> 232 us`; 64 B flat. B-116
- **[P-217](P-217-what-the-drain-poll-costs.md)** valid (round 612), rpc_dart — how far past the last call `drainUntilIdle` returns: at most `27 ms`, and `0` with nothing in flight. B-208
- **[P-216](P-216-an-unfinished-websocket-message.md)** valid (round 611), rpc_dart_websocket — a raw socket writes 1 MiB continuation frames without FIN against a 1 MiB policy. Before: never closed, RSS `+147 MiB` at 256 MiB. After: closed after fragment 1. B-202
- **[P-215](P-215-what-a-scope-costs.md)** valid (round 608),
  rpc_dart — the five `LogScope` derivations one unary call makes, timed against the call itself:
  `228 ns` of `66801 ns`, 0.34 %; medians of five
- **[P-214](P-214-who-holds-the-connection-queue.md)** valid (round 600),
  rpc_dart — 400 minted 1 MiB direct objects, no per-stream consumer: a PAUSED `incomingMessages`
  subscription `+392 MiB`, a consuming one `+6`, none `+376`; paused against consuming is the control
- **[P-213](P-213-what-the-wrapper-rebroadcasts.md)** valid (round 596),
  rpc_dart_websocket — events on `incomingMessages` per call over a real socket: `0.00` per unary and per
  100-message stream for the wrapper and a bare channel transport; `3.00` / `101.00` with round 508's
  routed-message skip forced off, which is the control
- **[P-212](P-212-frames-after-a-unary-request.md)** valid (round 594),
  rpc_dart — data frames sent on a unary stream while its handler runs: RSS tracks the bytes 1:1 at three
  scales (`+51/+117/+313 MiB` for 78/156/312 MiB) before the fix, `+57` and a RESOURCE_EXHAUSTED after
- **[P-211](P-211-a-flood-into-a-stalled-handler.md)** valid (round 595; N-stream arms added: `8184/16368`
  at 8/16 streams before, `4093` after),
  rpc_dart — P-210's repair: a real responder with a parked client-stream handler, a peer with its windows
  off. **RETAINED is counted by releasing the handler with the producer stopped**, so it is what the
  responder side held; RSS read `+202` and `-145` MiB for one arm. Control 257, witness 19999 before and
  1023 after, bidi sibling 1023
- **[P-210](P-210-what-the-transport-pulls-from-a-flooding-peer.md)** **broken** (round 593),
  rpc_dart — reads the transport's DEMAND via an `async*` generator counting its own yields:
  `PULLED 20001 of 20001` with flow control ON and OFF alike, 320 MiB offered, consumer paused. The control
  not differing IS the reading — flow control is a SEND-side credit protocol and never throttles reading.
  **Marked broken because residency of `+34 MiB` against 320 MiB offered with nothing refused means the frames
  are DISCARDED**, and the likeliest cause is the rig: a peer-minted stream with no responder endpoint has
  nowhere to be dispatched, so `_admitToStreamBuffer` is not shown to have been reached. Attach a responder
  with a parked handler before reuse. Carries three rig failures that each read as a result — a
  `StreamController` source measuring the bench (`+316 MiB`), a data frame for an unopened stream being
  silently dropped, and `health().details` having no buffer depth
- **[P-209](P-209-what-a-refused-bomb-leaves-behind.md)** valid (round 591),
  rpc_dart — **the control is the arm that GROWS, which is the whole reading**: 20000 successful
  decompressions (reaching `close()`) against 20000 refusals (skipping it) give `+12/+12`, `+30/+6`,
  `+31/-53` MiB across three runs. If the skipped close accumulated native filters the witness would be
  the climbing arm; it is not, and once it handed 53 MiB back mid-arm. **GC is deliberately not encouraged
  between arms** — the claim is that release happens at a finaliser rather than at the throw, so a forced
  collection would measure the finaliser working and say nothing about when. Cannot create the one condition
  that would keep the claim alive (low GC pressure) and explains why: tripping the limit requires allocating
  up to it. Also prices the sketched fix, which turned out free — `close()` after the throw is clean
- **[P-208](P-208-how-much-margin-a-timing-assertion-has.md)** valid (round 588),
  rpc_dart — **asks the one question that converts "flaky" into a quantity: what is the MARGIN?** A 250 ms
  settle requiring a parked sender, run at six settles with the counter the test throws away: the park arrives
  at `produced 66` and needs **5-25 ms**, so 10-50x and not the 250x the number looks like. **Its control is
  what refuted the previous round's explanation** — 14 busy isolates in another process at load `84.76`,
  eight times the figure blamed, and the arm still reads `waiters 1`. So external CPU pressure is not the
  variable; `dart test`'s own suite concurrency is, and `--concurrency=24` is the instrument that reproduces.
  Reports `produced` beside `waiters` deliberately: `waiters 0` means either "never got there" or "got there
  and was released", and only the counter separates them
- **[P-207](P-207-what-an-orderly-close-logs-per-in-flight-call.md)** valid (round 587),
  rpc_dart_http — **a count that SCALES, because "each call" is the claim**: `8 calls -> 8 errors`,
  `1 -> 1`, `0 -> 0`, so one record would have read as a message rather than a defect, and the 0-call arm
  says the records come from the calls and not from `close()`. The error count is read BEFORE the close too,
  so the arm asserts its own setup. **`minLevel: internal` is load-bearing**: with the default the guarded
  `internal` call is filtered, and a zero at `error` cannot be told from a log DELETED rather than moved —
  `internal 16` after is what distinguishes them. Does not read the consumer side; the status is unchanged by
  construction
- **[P-206](P-206-what-te-trailers-reaches.md)** valid (round 586),
  rpc_dart_http — **asks where a header GOES, not whether it is sent**: `headers delivered 10, carries te YES`
  -> `9, no`, read on the responder TRANSPORT's `incomingMessages` and not on the handler's `RpcContext`,
  because those are two different sets and the difference IS the finding — core's
  `_createContextFromMessage` excludes `te` by name, so no handler ever saw it. The other nine names are the
  control. Substitutes for the lead's prescribed browser console, which `B-215` puts out of reach; the "XHR
  refuses it" half stays a spec citation rather than a reading, and is moot once the header is gone
- **[P-205](P-205-what-one-buffered-request-body-costs.md)** valid (round 585),
  rpc_dart_http — **two BARE arms outside the library, there to bracket a number that alone means nothing**:
  the library's buffer against a bare `List<int>` and a bare `BytesBuilder(copy: false)`. `+205 MiB` for a
  32 MiB body sat with the list; after the fix `+0` sits with the builder. RSS read THREE times in the
  library arm — before the payload, after it, after the buffer took it — so the buffer is not charged for
  bytes the caller had already allocated. **The bare arms are a bracket and NOT a ratio**: `LIST` read `+165`
  in one run and `+528` in the next on identical input, because RSS for a growable list depends on the heap's
  state; quote which arm the library matches, never the arms themselves. Reads no TIME, and does not cover the
  multi-chunk path
- **[P-204](P-204-what-the-documented-shelf-setup-admits.md)** valid (round 584),
  rpc_dart_http — **measures RESIDENCY, because the status cannot grade this defect**: the pipeline refuses an
  over-size body either way, so `413` against `200` only says which layer refused and `RSS +37` against
  `+524 MiB` says what was resident when it did. 256 MiB streamed from one reused 1 MiB chunk, so the
  client's own share stays flat. **Four arms, and two are easy to omit**: `securityPolicy: null` is NOT the
  same arm as omitting the parameter (one measures the opt-out, the other the default), and the policy arm is
  run both FIRST and LAST because RSS does not come back down — the trailing `+0` is what kills "the second
  arm inherited the first's heap". Second half re-measures a documented sentence rather than code: an
  `Expect: 100-continue` client with a 1 s fallback reads `500 ms -> 408` against `30 s -> 200 OK`. Cannot
  separate a slow upload from a stalled one — that rig deadlocks the process at `socket.close()`, recorded on
  B-217 rather than quietly dropped
- **[P-203](P-203-what-each-http1-rejection-becomes-at-the-caller.md)** valid (round 583),
  rpc_dart + rpc_dart_http — **a TABLE, one row per rejection, with two columns because the lead's argument
  is about the second**: the gRPC status an application receives, and how many attempts the default retry
  predicate spends. `400 13/1, 405 2/1, 408 2/1, 413 8/3, 415 2/1, 503 14/3`, and 408 becomes `14/3`. The
  status column alone cannot grade a claim about retry semantics, and the attempts column alone cannot say
  which rejection it belongs to. Five unmoved rows are the control; the three named statuses at the bottom
  (`INVALID_ARGUMENT 3/1` against `INTERNAL 13/1`) are the control for the comment's claim, and they are what
  showed its conclusion never rested on its wrong premise. Fakes each HTTP status with a plain `HttpServer`
  rather than driving six hostile clients; the 408 premise is pinned by a raw-socket arm in the suite instead
- **[P-202](P-202-which-content-type-a-grpc-over-http1-response-carries.md)** valid (round 582),
  rpc_dart_http — **TWO views of one response, and they disagree, which is the whole point**: shelf's
  `headersAll` through `transport.handler` reads what the code PRODUCED (`2 [application/grpc+proto,
  application/grpc]`), `HttpClient.headers[]` through `shelf_io` reads what a peer RECEIVES (`1
  [application/grpc]` — dart:io keeps the last). The lead asked only for the first; the first alone grades
  the defect wrongly in BOTH directions, calling a duplicate nobody receives an interop break and missing
  that every caller was told the bare form whatever it asked for. Cannot see a non-dart:io adapter — none is
  in this repository's dependency set — so "another host may emit two lines" stays unmeasured
- **[P-201](P-201-what-the-http1-caller-lets-through.md)** valid (round 581),
  rpc_dart_http — a `dart:io` server answering a real `grpc-status: 9` plus N headers of noise:
  `1000 extra -> 1007 delivered` against a `CONTROL 2 extra -> 9`, now `2`. **It reads TWO things and the
  second is why it exists**: the header count AND whether the server's status survived — a probe measuring
  only the count would have called the first fix a success, when it read `headers 4, grpc-status 3`.
  First-status-wins is load-bearing: a status manufactured on the initial frame arrives ahead of the
  trailers, and recording the LAST one would have missed it. Does NOT drive a character violation
  (`HttpServer` will not emit a CR in a value) and models no attacker
- **[P-200](P-200-is-the-startup-budget-doubled.md)** valid (round 579),
  rpc_dart_isolate — a worker that never reaches `ready`, timed against three budgets across a 4x range so
  the answer is a RATIO: `1.04x / 1.00x / 1.00x`, which REFUTES "two phases, so 2x". **The stall must be
  SYNCHRONOUS** — `ready` is sent immediately after `userEntrypoint(...)` RETURNS, so a stall written as
  `Future.delayed(...).then(...)` schedules and returns and spawn succeeds in 28 ms. That first version is
  kept in the record as the negative control it accidentally was: `0.00x` with `thrown == Null` is what
  this measurement looks like when its subject never happens (`measurement.md` item 8). Reports the thrown
  TYPE beside each timing, which is the premise check
- **[P-199](P-199-what-the-transfer-costs-by-size.md)** valid (round 578),
  rpc_dart_isolate — **a SWEEP, because a copy's cost is a function of size and the lead asked for one
  point**: `32 B 2.71 vs 2.34`, `128 KiB 20.44 vs 14.03`, then inverting at `256 KiB 103.71 vs 160.67` and
  `1 MiB 383.08 vs 486.63`. Each size is the other arm's control, and the two columns cross between 128 and
  256 KiB. `fromList` is INSIDE the timed loop, which is the whole question; the worker materialises the
  TTD so the receiver's share is in the arm; minimum of three runs after 200 warm-up frames. Does NOT
  measure through the transport — raw ports carrying the two expressions the channel picks between, so the
  comparison is sound and the absolutes are not a frame's true cost
- **[P-198](P-198-does-a-failed-spawn-let-the-process-exit.md)** valid (round 577),
  rpc_dart_isolate — **the probe IS the subject**: it fails a spawn, prints, and returns from `main` with
  no `exit()` call, so the verdict is whether the command returns at all. `guard ablated -> no exit at
  25 s / 60 s / 90 s`, `guard in place -> immediate`. The printed `spawn threw ArgumentError` is the
  premise check. **Its first version was wrong in a way that read exactly like the defect**: the
  `ReceivePort` it used as the unsendable value held the process open by itself, so it hung with the fix
  in place too — bench and subject holding the same kind of handle, `measurement.md` item 6. Does NOT
  bound the hang: "never exits" means "not within 90 s"
- **[P-197](P-197-what-a-channel-close-keeps.md)** valid (round 576),
  rpc_dart — **the rig has to create a moment, not measure a quantity**: both ends queue a tagged frame
  in the SAME event-loop turn and then one closes, with nothing awaited between the three calls, because
  awaiting any of them drains the queue and the question disappears. `the CLIENT closes -> client [] /
  server [from-client]`, mirrored when the server closes, which is how "the closing side loses" is told
  from "the client loses". For the closed-send arm it reads three facts at once — the send's outcome, the
  peer's inbound list, and the sender's own `isClosed`, the third being what made the claim sharper than
  filed. **It also priced the obvious fix**: a yield before the cancel delivers the frame and breaks
  `in_memory_transport_test`'s named requirement, both orderings tried
- **[P-196](P-196-who-owns-a-sent-payload.md)** valid (round 575),
  rpc_dart — one variable, whether the sender scribbles 0xFF over its buffer after `await sendMessage`
  returns: `the receiver read 0xFF 0xFF 0xFF 0xFF` against a CONTROL at `0xAA`. The frame is built BY
  HAND, prefix and body both known, because a codec would put the body somewhere unknown and the
  scribble with it. Reads the bytes as bytes — a length or checksum would hide which end the
  corruption came from. Unchanged by its round: the behaviour IS the contract, and what the round added
  was the rule plus a test that fails if a copy is added quietly. Does NOT establish that a copy is
  wrong; B-116 priced one at `389.76 -> 191.45 us` per 1 MiB, which makes it the owner's
- **[P-195](P-195-does-the-direct-channel-keep-early-frames.md)** valid (round 574),
  rpc_dart — `pair()` with ONE event-loop turn between constructing the two transports, read through an
  observable that already exists: `flowControlConnectionCredit`, which answers `null` for a side that
  never got the peer's grant. `WITNESS server null -> 67108864`, with a no-gap arm and `memoryPair()`
  both reading `67108864` throughout — the two controls are the lead's own point, that `memoryPair` is
  safe only by building both ends in one expression. Reads BOTH sides, because which one loses is the
  finding. Drives neither of the buffer's bounds, and cannot drive the byte one at all: a
  `directPayload` weighs 0
- **[P-194](P-194-reset-or-503-at-the-end-of-a-drain.md)** valid (round 573),
  rpc_dart_http — a 30 s handler against a 200 ms drain budget, read with a **raw `package:http`
  POST** so the number is the HTTP outcome and not a caller's interpretation of it:
  `ClientException: Connection closed before full header was received -> HTTP 503`, against a CONTROL
  at `HTTP 200` whose handler finishes inside the budget. Reads once while running and once after
  `stop()`, so a reset is distinguishable from a request that never started. Picks a free port by
  binding and releasing a `ServerSocket`, since `RpcHttpServer` exposes none. **It also established
  the yield**: reordering alone still read `ClientException`, because completing the completer only
  hands the response to shelf and nothing can be awaited for the write
- **[P-193](P-193-what-in-flight-consumers-are-told-at-a-teardown.md)** valid (round 572),
  rpc_dart_http2 — three in-flight server streams, then a teardown, recording per consumer what it
  was told and when. **A hang has no number, so the measurement is the absence**: `STILL WAITING`
  against a three-second settle where the calls that do fail take ~10 ms. Drives BOTH teardowns,
  which is how `close()` came out a measured NEGATIVE — and how its MIXED `14/13/13` for one event
  surfaced. Reads leftover `streamControllers` beside the outcomes. Does NOT separate `closeAll`'s
  `error:` argument from the call: disabling only the argument still read three errors, because
  closing the controller and the terminate error race
- **[P-192](P-192-what-a-status-less-ending-costs.md)** valid (round 571),
  rpc_dart + rpc_dart_http2 — **counts server EXECUTIONS, not statuses**, because the damage is work
  re-run: one unary call named `Charge` went `status 14, ran 3 times -> status 13, ran 1`, with a
  no-retry ARM at 1 that attributes the 3 to the interceptor and a trailers-sent CONTROL returning
  "ok" at 1 that says the interceptor is attached and healthy. Both sites of the class in one file,
  the second built by writing the shape by hand on a frame-channel pair. Does NOT distinguish a dying
  channel from a forgetful peer at the CORE site — the http2 half splits on
  `goawayReceived || !isOpen` and the channel transport has no equivalent
- **[P-191](P-191-does-our-half-close-when-the-server-ends-first.md)** valid (round 570),
  rpc_dart_http2 — **the observable is at the SERVER**, because every per-stream map on our side
  reads 0 either way: a raw `ServerTransportConnection` answers as soon as the first DATA frame
  arrives, and `onDone` on its incoming side fires when the client ends its half and not otherwise.
  `WITNESS 0 of 3 -> 3 of 3` against a `CONTROL 3 of 3` whose request carries `endStream`. The
  accepted count is a second control, on the premise. **Its first version read the counts AFTER
  `transport.close()` and reported the arms backwards**, since close() terminates what the transport
  still tracks and ended the streams itself
- **[P-190](P-190-what-the-server-sees-when-a-cancel-has-no-stream.md)** valid (round 569),
  rpc_dart_http2 — a raw `ServerTransportConnection` recording the `:path` of every stream it
  accepts, which makes a phantom stream a path the client never asked for:
  `cancel after a completed call [/Svc/Echo, /Unknown/Unknown] -> [/Svc/Echo]`, and
  `a second OPENING frame on a live id [/Svc/Slow, /Svc/Again] -> [/Svc/Slow]`. **The cheapest route
  to `resetStream == false` is a COMPLETED call**, not the server-stream setup the lead asked for.
  Reads `activeStreams` beside the paths because in the overwrite arm the count is 1 before and
  after while meaning two different streams. Its second arm is kept as documentation of the trap: a
  second frame after an ANSWERING server ended the stream takes the no-methodPath branch and says
  nothing about the overwrite, which needs a server that never answers
- **[P-189](P-189-whose-answer-ends-the-call.md)** valid (round 567),
  rpc_dart + rpc_dart_http2 — what a call ends with when the peer's trailers break our policy, at
  BOTH sites of the class in one file: `http2 details-bin 10 KiB status 3 -> 9`,
  `200 trailer headers status 3 -> 9`, `core channel [frame] + RpcFrameException -> [frame, status 9]`,
  against a 16-byte-details CONTROL reading 9 throughout. **No grpc-go needed** — what the defect
  turns on is a server answering a status with one header we refuse, and `package:http2`'s own
  `ServerTransportConnection` sends arbitrary trailers. The core half gives the two sides SEPARATE
  policy objects, or the sender's own outbound check refuses the frame before the victim sees it.
  Connection health is read in every arm, which separates a lost status from a dead socket
- **[P-188](P-188-what-the-responder-mints-for-a-foreign-peer.md)** valid (round 566),
  rpc_dart — counts the tokens the RESPONDER mints for a peer that sends no correlation headers:
  `neither header 2 -> 1 / both headers 0 / a foreign x-request-id 1`, with each id's mint number
  decoded beside the count, because a count alone cannot tell one token used twice from two
  tokens. **The foreign peer needs no fake server**: `RpcMetadata.forClientRequest` carries
  content-type and grpc-accept-encoding and nothing else, so driving the pair's client side
  directly IS that shape. Second control is the load-bearing one — a foreign `x-request-id` MUST
  still mint, since `traceIdFor` can only derive from an id of ours. **Its decoder cuts at the
  FIRST underscore**, unlike P-179's, which reads `null` for roughly half of all tokens
- **[P-187](P-187-does-a-release-during-a-parked-send-leak-its-id.md)** valid (round 565),
  rpc_dart_http2 — four arms around one race: a peer RST_STREAM landing while an `endStream: true` send
  is parked on the window. `WITNESS halfClosedLocal 1 / CONTROL 0 / REACH 1 then 0 after
  releaseStreamId / STACK 0 through RpcCallerEndpoint`. **The window is owned by the rig** — hand-rolled
  SETTINGS with `INITIAL_WINDOW_SIZE=64`, because no real server holds a window closed on cue, which is
  what round 564 could not arrange. **The control's load-bearing row is `window open halfClosedLocal: 1`**,
  taken between the grant and the reset: it proves the add site is reached, so the witness's 0 after the
  fix is the guard working rather than a map nothing fills (`L-15`). Two readings it did not vary are
  `B-221`: the parked send returns `threw=null` after the reset, and the pump survives it
- **[P-186](P-186-what-bounds-a-connect-into-a-hole.md)** valid (round 563),
  rpc_dart_http2 — times a connect against three addresses: a REFUSED loopback port (10 ms, the control
  that prompt failures stay prompt), a BLACK HOLE with the bound passed explicitly (1730 ms), and the
  same hole with the bound OFF (still pending at 8 s). **That third row is the canary** — without it
  `1730ms` could be the network answering rather than the timeout firing. `198.51.100.1` is TEST-NET-2,
  reserved and unrouted, so its SYN is dropped rather than refused, which is the whole difference. **The
  bound is driven by argument, never from the default**: the shipped default is 30 s, so a probe capped
  below it reads `STILL PENDING` with the fix already in. **Deliberately NOT in the gate** — whether a
  network drops or refuses that address is outside this repo's control, and a refusing firewall turns the
  black-hole rows into the refused row.
- **[P-185](P-185-two-paths-release-one-connection.md)** valid (round 562),
  rpc_dart_http2 — three instruments for two claims: callback counts per connection, a 200x
  connect-and-RST loop inside a guarded zone **followed by a real call** ("still running" is a flag a
  dying isolate still reports), and the address read in three socket states. **That third arm is the
  positive control that turns an absence into a refutation** — `just accepted` and `peer reset, still
  open` both answer, `after our own destroy()` throws, so the throwing state needs OUR end closed and
  the accept path cannot be in it. No logger attached anywhere, because the read is unconditional while
  only being used under `isDebug`. `opened=1` in every row is a third control: the guard added for the
  close half was never needed for the open half.
- **[P-184](P-184-a-start-guard-behind-its-own-await.md)** valid (round 560),
  rpc_dart_http + rpc_dart_http2 — two files, one question: what two concurrent starts do to a server
  that is already binding. **A FIXED port is the whole rig** — with `port: 0` each concurrent bind gets
  its own ephemeral port, nothing fails, and the catch under test never runs; the first version hung
  with no output rather than reporting that. Four observables, because the two packages fail
  differently: what each start returned, `isRunning`, `endpoints`, a real call, and whether the port
  is free after `stop()`. **That last one is the only thing that can see http2's defect**, since
  `stop()` returns normally and `isRunning` is already false — every in-process check says the server
  is down, and a bind attempt from outside says the listener is still there. `THREE concurrent
  start()` answering `ok:x` is a second control and a refutation of the lead's own claim.
- **[P-183](P-183-what-reaches-the-wire-when-a-parked-send-meets-a-half-close.md)** valid (round 558),
  rpc_dart_http2 — **records three observables, not a verdict**: the sink's contents in arrival order,
  and whether the parked send returned or threw. `parked send, then endStreamNow() -> data 0B eos=true`
  against a CONTROL of `data 64B, data 0B` is what makes the missing frame a loss rather than a rig
  that never delivers. Needs no server: the pump parks because its controller's subscription is
  paused, so a sink nothing listens to reproduces a closed peer window exactly. The `dispose()` arm
  is its own control for the second half — the sink is EXPECTED to stay empty there, so an arm that
  only counted frames would have called that case correct. Does not cover the lead's third claim
  (`_halfClosedLocal` leaking an entry per stream), which is the caller transport's bookkeeping.
- **[P-182](P-182-where-terminate-s-error-lands.md)** valid (round 557),
  rpc_dart_http2 — **measures WHERE an error arrives**, by destination: the zone handler, the call
  site's `catch`, or nowhere. Four arms on `terminate()` (healthy or socket destroyed, future
  dropped or awaited) all silent, against a POSITIVE CONTROL where `finish()` escapes
  `Bad state: Cannot add event after closing`. **That control is the whole probe** — four clean rows
  mean "terminate is safe" or "this rig cannot produce the condition", and nothing else separates
  them. Its first version had no working control: the peer was a bare TCP listener and `finish()`
  never completed against it, so the silence would have read as proof. Measured on package:http2
  3.1.0 only, and does not drive the transport's own `reconnect()`.
- **[P-181](P-181-which-branch-took-the-fragment.md)** valid (round 553),
  rpc_dart — **a TRACER, not a measurement**: it prints every record the pipeline decides to
  emit, in order, with each inbound frame announced before the pipeline sees it. Built because
  three read statuses said `status 4` and none said which of five paths took the second fragment
  of a split frame. What it showed was the fragment delivered AND parsed with no answer after
  it — which moved the question from routing to "what silently dropped the answer", and the only
  silent exit there is a closed responder. The subclass overrides `add` on the CONTROLLER, since
  `child()` returns a plain `LogScope` and a scope subclass loses its override the moment the
  pipeline derives one. Cannot see a decision nothing logs: the two silent guard clauses were
  found by elimination, not here.
- **[P-180](P-180-what-the-window-actually-charges.md)** valid (round 552),
  rpc_dart — **separates WIRE size from DECODED size, which is what B-195's reading was
  missing**: the message carries a padding string that is serialized and a length the receiver
  would allocate, so one window can be driven with 18 bytes standing for 1 KiB or 1 KiB standing
  for 1 KiB. Reports the IMPLIED charge per message, window over count, so "the window is exact"
  is readable without arithmetic in prose — `66 x 993 B = 65 538` against 65 536. Four controls,
  each of which alone flips the conclusion: a second settle time (a bound does not move, a rate
  doubles), the field off, wire held while decoded varies, and resume (a bound releases, a wedge
  does not). Also reads the SENDER's `flowControlStateSizes`, where `sendCredit: 0` tells a
  generous window from one never applied — which is how the round's defect was found. Does NOT
  measure memory: its `nominal` column is size x count and labelled as arithmetic, because the
  paused messages stop below the decode.
- **[P-179](P-179-how-many-tokens-one-call-mints.md)** valid (round 551),
  rpc_dart — **counts the secure draws one unary call makes, and identifies each.** The
  instrument needs no instrumentation: every token's last 4 bytes carry a process-wide monotonic
  counter, so a token is its own receipt — decode it and bytes 12..16 are its mint number.
  `RpcContext.empty() 1 token / the call itself 0 / one call with no context 1`, and every id in
  the call — caller `requestId`, both wire headers, both the handler sees — carries the SAME mint
  number, which is the control that rules out "one count, several ids". `one token 42.4 us`.
  Cannot compare its cost SHARE with round 511's (42.4 of 264.5 over a byte pipe against ~40 of
  ~97), and does not vary the call shape, so streaming is uncovered.
- **[P-178](P-178-minting-against-holding.md)** valid (round 549),
  rpc_dart — **measures ATTRIBUTION, not a count**: how much memory exists because the queue holds
  these objects, over and above what exists anyway. `HOLDING -1 MiB` against `MINTING 313 MiB` for
  400 direct objects of 1 MiB, which settles that "a directPayload weighs nothing" is a statement
  about the SHAPE rather than the mechanism. **Its `after building` control caught the rig twice**
  — a zero-filled `Uint8List` is not resident until written, so 400 MiB of allocation moved RSS by
  6 and the queue cost read `1 MiB`; and both arms in one process made the second's baseline the
  first's high-water mark, so the deltas were not comparable. One arm per PROCESS, selected by
  argument. Cannot answer which shape applications actually use — that is not a fact about this
  library.
- **[P-177](P-177-does-every-ending-return-the-slot.md)** valid (round 546),
  rpc_dart — **the instrument for the OPPOSITE failure**, built because holding a slot until
  completion turns "admits too much" into "refuses everything for the life of the connection" if
  any ending forgets to give it back. Five endings — completion, an error status, a cancel, a
  deadline, a peer that simply stops answering — each run `ceiling + 2` times SEQUENTIALLY, so a
  slot released one turn late still counts. **Its control row is what makes it a probe at all**:
  five rows of zero refusals read identically against a ceiling that had been deleted, so one arm
  keeps its calls overlapping and must refuse. The first version lacked it, and labelled the
  control's correct refusal `<- A SLOT LEAKED`.
- **[P-176](P-176-which-wire-does-max-metadata-bytes-mean.md)** valid (round 544),
  rpc_dart + rpc_dart_http — **prices a decision's PREMISE before it is implemented.** Three
  counts of the same metadata side by side: the text `validateMetadata` totals, the JSON a frame
  channel encodes, the header lines HTTP sends. The knob is the SHAPE, not the size — a
  per-header framing overhead is invisible at few large headers (all three agree within 1%,
  which is the control) and dominant at many small ones. Two refutations: the framing differs by
  transport (`8.2` B/header JSON against exactly `4.0` HTTP), and the JSON size depends on a
  value's CONTENT rather than its length (`127` bytes against `227` for the same 100
  characters). Its JSON figure copies a private encoder, which is why the round's TEST uses the
  public `encodeMetadata` instead — a bench may stand in for the code under test to size a
  question, a regression test may not.
- **[P-175](P-175-does-compression-enabled-need-a-codec.md)** valid (round 543),
  rpc_dart — **the knob is the REGISTRY, not the platform.** A platform difference is the
  obvious way to ask whether `compressionEnabled` needs a codec, and the wrong way: it needs a
  browser, takes minutes, and conflates "fails on the web" with "fails because the registry is
  empty". `unregister('gzip')` puts a VM run into dart2js's shipped state in under a second.
  Reads the DECLARED encoding off the responder's inbound metadata rather than inferring it
  from the outcome, since a call can fail for many reasons and only one is the header. **Its
  first version used `memoryPair` and reported every arm healthy** — the declaration is guarded
  by `!supportsZeroCopy`, so a zero-copy pair never reaches it, and an arm that cannot touch the
  code under test reads exactly like a pass.
- **[P-174](P-174-what-a-reused-peer-id-answers.md)** valid (round 541),
  rpc_dart_websocket + rpc_dart — **measures the ANSWER a caller gets, not a frame count.** Two
  callers on two connections share one stream number, and the only way to say the wrong one was
  served is to read what each was told: row 1 handed the caller asking `two` the answer to `one`.
  The collision is the server's ordinary behaviour, not staged — a dropped connection gets a FRESH
  endpoint, which numbers from the bottom. Captures the client pipeline's own records at `internal`,
  because ignored-as-a-repeat, served, and torn-down-by-the-old-call all look identical from
  outside. Supersedes `P-161`'s open question: that bench said in its own record that it never drove
  a pipeline.
- **[P-173](P-173-do-repeated-metadata-values-survive.md)** valid (round 540),
  rpc_dart_http — **quotes and COUNTS every value, because the question is how many there are and
  Dart's list printing cannot answer it**: `['Mon', '29 Sep …']` and `['Mon, 29 Sep …']` have the
  same `toString()`, and the first reading of this probe called a split intact for that reason.
  Its response arm uses two standard fields whose comma sits INSIDE one value (`date`,
  `www-authenticate`), with single-value headers in the same table as the control. Passes
  `methodPath:` explicitly — rebuilding `RpcMetadata` from `.headers` drops it and no request
  fires.
- **[P-172](P-172-who-owns-the-http-client.md)** valid (round 539),
  rpc_dart_http — **two directions, two instruments.** Whether an injected client survives is asked by
  USING it afterwards, because "was `close()` called" is the correct outcome for one kind of client and
  the defect for the other. Whether an OWNED client is still closed cannot be asked that way at all — it
  is unreachable from outside — so it is read as a TCP descriptor across the close. That second arm is
  the control, and it is what stops the fix being a trade. A missing `lsof` exits 2.
- **[P-171](P-171-does-a-mounted-handler-route.md)** valid (round 538),
  rpc_dart_http — **the rig IS the documented composition**, not a description of it: the mount is built
  from shelf's own `Request.change(path:)`, which is what `shelf_router.mount` does, so the real
  mechanism is exercised with nothing added to the dependency list. Two readings per run — the
  `methodPath` the transport saw and the caller's outcome — because a wrong path and a missing service
  give the same status from different causes. Its control is the UNMOUNTED arm, which is also the reason
  the defect survived: there the two path forms are identical.
- **[P-170](P-170-does-the-rejection-drain-run-at-all.md)** valid (round 537),
  rpc_dart_http — **two claims, two instruments**: a library rule asked of a bare shelf `Request` in
  three lines, and a re-run of `checked/C-31` against the REAL transport behind `shelf_io`. Its first
  version used a hand-written stand-in server and reported `closed with nothing` where the transport
  reports `408` — the two differ in exactly the detail under test, so **a stand-in for the code under
  test measures its author**. Control: the undeadlined arm, without which `384 KiB` is just a number.
- **[P-169](P-169-does-abandoning-a-call-stop-the-download.md)** valid (round 536),
  rpc_dart_http — **reads the abandoned side from the OTHER end**, because a dropped future reports
  nothing locally whether the work stopped or not: the server streams a long response and records how
  far it got and whether it finished. Two readings, since "wrote fewer" alone also describes a server
  that crashed. Its control (a call nobody abandons) is identical BEFORE the fix — which is the finding
  — and separates after it, which is what says the transport still completes ordinary calls.
- **[P-168](P-168-what-does-a-clean-close-cost.md)** valid (round 535),
  rpc_dart_websocket — **its control is the SDK doing the same thing with none of our code in the
  way**, which is what lets a zero be read as "this line costs nothing" rather than as a broken
  timer. Three arms, minima of five, because noise here only adds time. Subscribes `incoming` in
  every arm on purpose: an unlistened single-subscription controller changes what `close()` can do
  and would make the arms incomparable.
- **[P-167](P-167-does-pause-reach-the-socket.md)** valid (round 534),
  rpc_dart_websocket — **reframes a memory question as a DEMAND question**, because P-128
  established RSS across arms here is noise: the source is an `async*` generator counting its own
  yields, which suspends while its subscription is paused, so "did the pause reach the producer" is
  a count with no allocator in the loop. Reads BOTH sides — pulled and delivered — since the defect
  is that they disagree. Controls: unpaused, and paused-then-resumed, which rule out a channel that
  stopped reading and a pause that never lifts.
- **[P-166](P-166-does-a-timed-out-connect-hold-its-descriptor.md)** valid (round 533),
  rpc_dart_websocket — **counts the leaked thing from OUTSIDE the runtime** (`lsof` against this
  process), because a held descriptor leaves the process working, the socket invisible to Dart and
  the attempt failing on time: every in-process observable sits behind a retry schedule the OS
  owns. **Both of its assumptions are asserted, not assumed** — every attempt must settle as
  `TimeoutException` (or the address is not a black hole here) and a missing `lsof` exits 2 —
  because either failing silently yields the answer the fix is supposed to produce. Control: forty
  opens that succeed and close.
- **[P-165](P-165-what-does-a-health-check-cost.md)** valid (round 532),
  rpc_dart_websocket — **reads the noise and the ANSWER from one run**, because a fix can trade
  one for the other and a server that went quiet by not answering would score perfectly on the
  first. Counts error records inside a `LogController` subclass rather than off a filtered
  record stream — the guard around a log call cannot be seen downstream of the filter. Its
  control is ten real handshakes, without which `0 errors` is equally consistent with a counter
  that counts nothing.
- **[P-164](P-164-what-happens-to-a-connection-accepted-mid-shutdown.md)** valid (round 531),
  rpc_dart_websocket — **reads the KIND of ending, not a boolean**: refused, torn down, or
  never closed. A shutdown has two phases and each wrecks a connection differently, so one
  "did it break" arm describes neither. **Its drain arm needs a REAL in-flight call** — the
  first version had none, so the drain returned on its first poll and the arm became a
  duplicate of the next one, two identical rows reading as a consistent finding rather than a
  broken rig. Controls: a restart that WAITS, and a server that never stops — without them
  "held nothing" is indistinguishable from "delivered nothing".
- **[P-163](P-163-is-shutdown-linear-in-connections.md)** valid (round 530),
  rpc_dart_websocket — **fixes the per-item cost small and varies N**, because the property
  under test is the serialisation and the honest magnitude (dart:io's close timeout for a
  peer that never answers) needs a raw TCP peer and makes every arm slow. Read as a RATIO to
  the single-peer arm, so the assertion does not encode the machine. Its control is twenty
  peers whose close is INSTANT — without it the growth is equally consistent with a
  per-endpoint bookkeeping cost. Its channel's inbound controller must stay OPEN:
  `Stream.empty()` tears the endpoint down before `stop()` sees it and every arm reads fast
  for the wrong reason.
- **[P-162](P-162-what-status-does-each-ending-give.md)** valid (round 528),
  rpc_dart_websocket — **drives the ENDINGS, not the codes.** Which code a mapping table
  should give is unanswerable from the table; the question is which code a real failure
  actually produces, and one of them does not come from the peer at all. Its reset arm
  PRODUCES an RST (Dart has no SO_LINGER, so it relays bytes, stops draining, then destroys
  a socket with unread bytes queued) and **asserts the close code it got**, so a rig that
  degraded to FIN cannot read as a pass. Controls: a code the peer really sent, and a clean
  goodbye. Note it does not EXIT — the table prints and the process hangs, so piping it
  through `tail` shows nothing.
- **[P-161](P-161-does-a-stale-id-reach-the-new-socket.md)** valid (round 527),
  rpc_dart_websocket — **puts the same question to a GUARDED operation and an unguarded
  one, for the same stale id at the same moment**, and varies the one thing the guard
  cannot see: whether the peer reopened the number. Read at the WIRE, by counting frames
  written to the new socket, because the guard is membership in two sets the reconnect
  clears and the traffic refills — every bookkeeping observable sits downstream of that.
  The connection pool is switched off so a returned credit is exactly one frame. Its
  control is an arm with no reconnect, without which `dropped` is equally consistent with
  a pipe that never carried anything.
- **[P-160](P-160-is-a-routable-name-callable.md)** valid (round 525),
  rpc_dart — **asks BOTH questions per row** — routable by the policy, buildable by the
  caller — because a disagreement between two limits on one quantity is invisible when
  either is read alone. The disagreement IS the measurement; a count of refusals would
  say nothing. Its control is a name past the policy's own limit, where both answers
  turn negative together, and the short rows are the other half: at 32 characters both
  are positive, so neither column is stuck.
- **[P-159](P-159-is-metadata-bounded-in-total.md)** valid (round 523),
  rpc_dart — every header individually LEGAL, varying only how many, which is the
  whole design: one oversized header would make the refusal say nothing about totals.
  **Prints the REASON for each refusal**, and that is what makes the last row readable
  — it is refused by the header COUNT, not by size, so it is not evidence of a size
  bound. Its control is one header past the per-header limit, which IS refused;
  without it, four rows of ACCEPTED are equally consistent with `validateMetadata`
  checking nothing at all.
- **[P-158](P-158-does-a-cancel-cut-the-retry-backoff.md)** valid (round 521),
  rpc_dart — **its never-cancelled control was added second and is what made the table
  readable**: with only the two cancel arms both read ~1.7 s and the result was
  uninterpretable, because there was nothing for them to be shorter THAN. Against
  `5237 ms` it is clear cancellation shortens the call. Reports the STATUS as well as
  the time — `1` says cancellation won, `14` says the retries were exhausted — and
  leaves two numbers explicitly unexplained rather than rounding them off.
- **[P-157](P-157-what-the-client-ceiling-counts.md)** valid (round 520),
  rpc_dart — **each SIDE carries its own policy, over a hand-built byte pipe, and that
  is the rig's whole correctness.** `RpcChannelTransport.pair(policy:)` gives both
  sides the same one, and from the caller a server refusing at ITS ceiling is
  indistinguishable from a client doing so — the first run produced `4 refused` and
  the lead looked refuted. The both-sides run is now kept as the CONTROL: it proves
  the mechanism works and the rig can provoke a refusal, so `0 refused` on the
  client-only run is the client declining to count rather than the probe failing to
  fill anything.
- **[P-156](P-156-how-many-timers-does-a-call-arm.md)** valid (round 519),
  rpc_dart — a Zone is the only place that sees every `Timer` whoever creates it, so
  counting by reading would mean trusting the reading found them all. **Everything
  runs inside ONE zone, endpoints included, and that is the rig's whole
  correctness**: a subscription creates its timers in the zone it was registered in,
  so endpoints built outside it leave every RESPONDER timer uncounted — which is the
  half the lead is about. The first version did that and reported `1.0 timers/call`
  with the deadline apparently free. Its controls are the no-deadline arms, which
  make the figure attributable — and which produced the larger finding, a nine-timer
  floor on a server stream.
- **[P-155](P-155-does-unary-survive-a-fragmented-frame.md)** valid (round 518),
  rpc_dart — the lead's own note says no shipped transport can show this, so the
  fragmenting channel is BUILT: every DATA frame re-framed as two on the same stream,
  with the end-of-stream bit kept on the second only. **Its second control is the
  other two call shapes in the same run** — same transport, channel, codec and
  payload, only the responder differs — which is what makes "unary only" a
  measurement rather than a reading. A **fresh context per call** matters more than
  it looks: one shared context is one deadline, so the first arm to time out left the
  others none and all three read TIMEOUT for a single arm's failure.
- **[P-154](P-154-do-the-three-header-builders-agree.md)** valid (round 517),
  rpc_dart — diffs three builders by reading the WIRE, because two of them are private
  and what a peer receives is what the claim is about. **Its false start is the
  lesson**: the transport's connection window-update is itself a metadata frame and
  precedes the request, so the first version reported `x-rpc-conn-window-update` alone
  from all three arms — three identical rows, which is exactly what the true answer
  also looks like. The with-context arms are the control that catches it, since
  `grpc-timeout` varying is what proves the rig can see a difference at all.
- **[P-153](P-153-what-an-application-status-logs.md)** valid (round 516),
  rpc_dart — **counts by overriding `LogController.add`, which is the method round
  515 paid for**: `LogScope.child()` returns a plain scope, so a subclass override is
  lost wherever code derives one, and both endpoints here do. Prints the SCOPE and
  MESSAGE, not just a count — that is what showed the caller's two records came from
  different sites rather than one firing twice. **Two of its three controls run the
  other way**: INTERNAL and a bare `StateError` must still log, because silencing
  everything would pass the witness perfectly.
- **[P-152](P-152-how-long-does-a-drain-take.md)** valid (round 514),
  rpc_dart — a poll interval is invisible in any measurement that lets the work take
  longer than the interval, so the handler parks on a completer and the moment it
  finishes is controlled exactly. **Its control did more than validate the rig**: the
  120 ms arm read `156 ms` before against `122 ms` after, which is how the round
  learned polling added ~36 ms of rounding even when the work dominated — a fact the
  lead does not mention. A 60 ms settle before the drain starts, because a drain with
  nothing yet in flight returns immediately and measures nothing.
- **[P-151](P-151-does-compression-make-a-message-bigger.md)** valid (round 513),
  rpc_dart — **its first version would have refuted a true claim**, and the record
  keeps why: it used `'a' * n` as the payload while testing whether compression makes
  messages BIGGER, which is the case least likely to grow. Incompressible input is
  what tests growth; the repeated-character rows survive as the control, and they
  carry the design argument too — gzip beats plain even at 32 B when bytes repeat, so
  a size threshold would discard a real saving. The `compression OFF` column makes
  every row a paired comparison rather than an absolute to be interpreted. Measures
  bytes only: the lead's CPU half is not instrumented here at all.
- **[P-150](P-150-what-the-log-guard-costs.md)** valid (round 512),
  rpc_dart — **its control is `LogScope.noop`, whose `isInternal` is a literal
  `false`**, which is what a real bool read costs on this machine; without it "235 ns"
  has no scale, and with it the round could say honestly that its own fix reaches 7x
  a bool read rather than 1x. The 20 overrides are deliberately NON-matching, which is
  both the worst case for a longest-prefix scan and the ordinary one. Reported in
  nanoseconds because microseconds would round the quantity away. The noop arm is also
  the honest reminder that most deployments never pay this at all.
- **[P-149](P-149-what-the-id-draws-cost-a-call.md)** valid (round 511),
  rpc_dart — **ablates the generator in place and re-times the whole call**, because a
  microbench of `Random.secure()` invites the objection that it is not measuring what
  a call actually pays. The microbench is supporting evidence only: two tokens at
  ~31 us predicts ~62 us of saving where ~40 us is measured, and being in the right
  range without being exact is what says it measures the right thing without
  substituting for the real path. **One number in it is explicitly NOT a share of
  anything** and the probe prints that warning itself — the 6-link context chain is a
  synthetic worst case, and an earlier draft quoted it as "37.8% of a call",
  double-counting against a figure it was never measured inside.
- **[P-148](P-148-how-many-frames-is-a-unary-call.md)** valid (round 510),
  rpc_dart — counts frames where one `send` on the byte channel is exactly one frame,
  so nothing inside the library needs instrumenting. **Then DECODES each frame and
  prints its stream id, which is what turned a cost item into a defect**: a count of 4
  is unremarkable, `grpc-status 12` three times on `s3` is one call answered three
  times. The metadata payload is printed because whether a frame carries a
  `methodPath` decides if the responder treats it as a new call. One call is made and
  the counters reset before the measured one, since the first call on a connection
  pays setup. Its controls are the two arms that must NOT change — a success and a
  throwing handler — both byte-for-byte identical across the fix.
- **[P-147](P-147-what-an-empty-middleware-wrapper-costs.md)** valid (round 509),
  rpc_dart — **the same FILE as P-146, registered under its own number**, because
  round 508's bench already measured this exact quantity and rebuilding it would have
  been the waste. Reports run-set MINIMA rather than medians, and says why: noise here
  only ever adds time, so the floor is closest to the quantity. That mattered — two
  run sets read `4.710` against `5.763` and looked conclusive, and the next set's
  median of `5.949` would have reversed it; seven sets later the minima never overlap.
- **[P-146](P-146-what-the-second-dispatch-costs.md)** valid (round 508),
  rpc_dart — **two files because the lead makes two claims needing different
  instruments**, and the one it leads with turned out to be the smaller. Retention is
  read through the PUBLIC API with no access to private state: a
  `BufferedBroadcastController` replays to a late subscriber, so attaching one after
  the stream is fully consumed counts exactly what was held for nobody. The speed arm
  reports a five-run distribution rather than a figure — a single comparison read 16%
  where the real effect is 6% — and its control is that per-message cost is NOT flat
  across counts, which says only the largest arm measures a per-message cost at all.
- **[P-145](P-145-what-the-receive-path-copy-costs.md)** valid (round 507),
  rpc_dart — turns a copy COUNT read off the source into a cost. **Measures the layer
  the lead names**: a first version echoed through `RpcCallerEndpoint` and the JSON
  codec dominated at 1 MiB, which would have attributed the time to the wrong layer
  entirely. Each size is run twice — payload left a view, payload copied out —
  because a receive path that hands out views reads as infinitely fast per byte, and
  only the second is the end-to-end figure a receiver pays. Its controls are a raw
  `setRange` of the same megabyte (so the figures have something to be a fraction of,
  generously, since it stays cache-hot) and the 64 B rows, which must NOT move.
- **[P-144](P-144-how-much-is-held-before-the-refusal.md)** valid (round 506),
  rpc_dart — measures the PEAK, not the outcome: the limit fires either way, so "is
  the frame refused" is the wrong question and a test asking it passes against the
  defect. Counts bytes accepted before the error, **yielding a microtask turn between
  chunks** — without that the writer outruns the decoder and the figure measures how
  fast the probe can call `add`. One bit varies (the metadata flag) at a size chosen
  to sit between the two ceilings, and the control is that same size without the
  flag: legal, accepted in full in both tables, which pins the cause to the
  classification and keeps a small after-figure from reading as a broken rig.
- **[P-143](P-143-what-a-call-gets-when-the-list-moves.md)** valid (round 505),
  rpc_dart — measures the error TYPE the caller receives, not whether the call
  succeeded, because the defect and the fix agree that a call interrupted by
  `close()` fails; only the type differs (`ConcurrentModificationError` versus
  `RpcCancelledException`). Two controls, and the second localises the defect: with
  the collection EMPTY the loop never awaits, so it never observes the mutation —
  without that arm, "close() breaks an in-flight call" explains the table equally
  well and the fix gets aimed at the wrong function. Timing is one-sided by
  construction: a mistimed disturbance shows up as an unexpected `OK`, never as a
  false positive.
- **[P-142](P-142-which-paths-reach-one-method.md)** valid (round 504),
  rpc_dart — holds the REGISTRATION fixed and varies the PATH, which is what
  refuted the lead's "low likelihood": an ordinary package-qualified service is
  enough and only the request is crafted. **Three levels, and the first two cannot
  answer what a grammar fix has to answer** — the caller transport validates
  outbound metadata against the same policy, so an ordinary call is refused locally
  and says nothing about a foreign peer; the third level hand-builds the frame past
  it. Its controls include `/a/c` and `/zzz/c` staying UNIMPLEMENTED, and the honest
  path through the raw level reading "accepted" in both tables — a unary call needs
  a payload the frame omits, so an accepted path answers nothing and that is
  otherwise indistinguishable from being ignored. **The interceptor level was built
  to confirm an auth bypass and refuted it.**
- **[P-141](P-141-what-a-failed-registration-leaves-behind.md)** valid (round 503),
  rpc_dart — varies WHERE a failure lands relative to the mutation, and prints
  three things per arm: what threw, the state the failure left, and whether the one
  recovery a caller has still works. The third is what turns an untidy internal
  state into a defect. Its control is a clean contract registered twice, also
  refused — without it the shared "already registered" message reads as the finding
  instead of as correct behaviour. Measures the actual KEY SETS, not counts: an
  early version had the recovery contract reuse a method name the failing contract
  also declared, so the after-state was identical to the before-state and the arm
  proved nothing.
- **[P-140](P-140-what-the-rate-limiter-admits.md)** valid (round 502, extended 542),
  rpc_dart — holds the LIMIT fixed and varies the call SHAPE, 100 opens per arm
  against `global: max 5`, so every number is comparable and `5` versus `100`
  needs no reasoning. Three controls covering three different rig failures: unary
  (the shape known to charge, so a 100 there invalidates every row), the same bidi
  shape with one message (which is what makes the empty-stream arms about
  ADMISSION rather than about bidi being unmetered — and it is the arm that reads
  collateral damage, dropping to 2 under an additive fix), and one call with ten
  messages (because "the open covers message one" is one edit from "the open
  covers every message"). Round 542 added a clock the run MOVES: the only way to read what a
  refused call cost the counter that did admit it is to roll the binding window over and ask
  what budget is left, since an admission count alone cannot see a counter draining behind a
  tighter one.
- **[P-139](P-139-which-errors-open-the-breaker.md)** valid (round 501),
  rpc_dart — the arms vary the STATUS a method throws, not the count, so the rig
  is about classification; every arm ends with a call to a DIFFERENT healthy
  method, which is how the blast radius of one shared breaker instance gets
  measured at all. Its control is the cancellation arm: `closed`/`0` where every
  other row reads `open`/`5`, so the rig demonstrably distinguishes the two
  states. Also answers two questions a regression test needed: an unregistered
  method returns `RpcStatusException(12)` rather than timing out, and a throwing
  response codec arrives as a bare `StateError`.
- **[P-138](P-138-does-a-cancelled-asstream-detach.md)** valid (round 500),
  rpc_dart — **twelve lines with no library code in them**, because the lead's
  mechanism was a claim about `Future.asStream()` rather than about this
  repository. Its control is the uncancelled arm: `100` fired against `0`, same
  loop and one line different, which is what makes the zero admissible. Its
  level-2 arm is a worked example of what NOT to trust — RSS across 20 000 calls,
  `+24 MiB` against `-25 MiB` with the signs flipping between runs
- **[P-137](P-137-does-ping-honour-its-context.md)** valid (round 499), rpc_dart
  — a transport decorator that swallows ONLY the ping frame, so nothing ends that
  stream and every arm is a statement about the caller's own bound rather than
  about the peer. **Two controls pulling opposite ways**: a peer that answers must
  stay fast, and a ping with NO bound asked for must STILL hang — without the
  second, "everything returns quickly" reads as success while the fix has
  invented a bound nobody requested
- **[P-136](P-136-what-bounds-a-call-with-no-deadline.md)** valid (round 498),
  rpc_dart — a handler that never answers, a transport decorator recording the
  `grpc-timeout` header, and two counters inside the handler. **Its own budget is
  65 s, one second over the library's hidden 60 s**, which is what makes "the
  library gave up at 60.0s" readable against "the probe gave up at 65.0s on a call
  nothing bounds". Four minutes to run, and there is no shortcut: the number under
  test IS 60 seconds, and a shorter stand-in exercises the deadline path, which
  works. Its control rows are also what proved a witness mis-aimed — the deadline
  path cancels the handler via the call scope, so a short-deadline test passes
  whether or not the timeout path notifies
- **[P-135](P-135-does-the-window-reach-a-direct-object.md)** valid (round 497),
  rpc_dart — **varies the LIMIT rather than ablating a guard**, which is the only
  way to separate "unmetered" from "metered with a generous bound": shrink the
  window 64-fold and the codec path moves 32x while zero-copy does not move at
  all. Its draining-consumer arm is a control that shows the bench CANNOT see the
  defect from the paused rows alone, because the library does not throttle
  producers by decision. Counts in the HANDLER; RSS was tried first and abandoned
  for negative deltas
- **[P-134](P-134-what-reassembling-one-large-message-costs.md)** valid (round
  496), rpc_dart — **five message sizes at ONE chunk size, reported as us/KiB**,
  because "is it slow" and "is it quadratic" are different questions and a single
  timing answers only the first. Flat means linear; doubling with the message
  means quadratic. Feeds `Uint8List.sublistView` pieces so the harness's own
  slicing is not in the number, and warms up first or the first scale pays the
  JIT for the rest
- **[P-133](P-133-which-part-of-reconnect-answers-what.md)** valid (round 495),
  rpc_dart_websocket — **makes the SEGMENTS of one method separately
  addressable**: a fake channel whose close is slow holds the teardown await
  open, a slow factory holds the next one, and each arm issues one call 50 ms in.
  The already-fixed segment is the control. Reports `health()` alongside the
  status, which is where its second finding came from. Trap: the fake's stream
  must stay OPEN — `Stream.empty()` ends at once and the transport then treats
  the peer as dropped at construction, making every arm read alike
- **[P-132](P-132-does-the-peer-id-set-return-to-zero.md)** valid (round 494),
  rpc_dart_websocket — reads `peerStreamIds` out of `health().details`, which the
  round had to ADD (the wrapper delegated health to its inner transport, which
  cannot see either of the wrapper's own sets). **Measures an INVARIANT, not a
  size**: the set means "streams the peer minted and this side is still
  answering", so on an idle connection the answer is zero or it is wrong — no
  threshold needed. Built through the transport's CONSTRUCTOR, not `connect()`,
  because only that takes `platformHandlesPing` and so puts the rig on the
  app-level heartbeat a browser is on
- **[P-131](P-131-does-a-large-host-to-guest-frame-keep-its-place.md)** valid
  (round 492), rpc_dart_wasm — 5 frames of 192 KiB and 50 small ones issued in
  ONE turn, three bursts, on a device. **Its `_CountingBridge` decorator asserts
  the bench's own precondition**: forwards in flight must peak above 1, or the
  run proves nothing about ordering. Copy that anywhere the hypothesis is a
  RACE — a bench that failed to drive the concurrency is green in exactly the
  way a negative is
- **[P-130](P-130-does-a-reclaimed-stream-answer-its-request.md)** valid (round
  491), rpc_dart_http — counts requests `arrived` and `answered` in a shelf
  middleware wrapped around `responder.handler`, so "answered" means the future
  the server awaits actually completed. **The caller cannot be the instrument**:
  it reports `RpcDeadlineExceededException` in every arm because its own
  deadline fires regardless of what the server does
- **[P-129](P-129-which-ceiling-stops-a-finite-http1-stream.md)** valid (round
  490), rpc_dart_http — **two ceilings of different kinds, so the shapes are
  chosen to trip exactly one each**: `1500 x 10 B` is inside any byte budget and
  past the 1024-message count, `20 x 1 MiB` the reverse. Both answer
  RESOURCE_EXHAUSTED, so only the shape that provoked it says which fired. The
  control is the same contract over a channel pair, which meets neither ceiling
  the same way
- **[P-128](P-128-what-an-http1-server-stream-retains.md)** valid (round 489),
  rpc_dart_http — peak RSS against production at three scales, plus the caller's
  delivered item count, which is what turns the cost into a defect (`received 0`
  in every over-limit arm). **Run it LARGEST FIRST**: RSS never returns, so in
  ascending order every arm after the first reads `+0` whatever happens and the
  first mixes warm-up with retention
- **[P-127](P-127-what-a-cancel-puts-on-the-http1-wire.md)** valid (round 488),
  rpc_dart_http — records every request PATH at the server, because the caller
  reports `RpcCancelledException` whether or not a phantom request went out, so
  the caller's own outcome cannot be the instrument. Two levels: through the
  endpoint for the ordinary cancel, and on the transport directly for the window
  before the request fires, which core releases too quickly to reach otherwise
- **[P-126](P-126-what-a-second-opening-frame-detaches.md)** valid (round 487),
  rpc_dart — counts two things from INSIDE the handler's own closure (did it
  observe its cancel, did its disposer run), so the numbers say what the handler
  saw rather than what the pipeline believes it sent. **Its second arm is a
  worked example of an instrument that reads zero for the wrong reason**:
  counted on `getMessagesForStream(id)` the repeat-ping arm reads `2 -> 2` in
  both arms AND with the fix ablated, because that controller closes when the
  ping ends; counted on `incomingMessages` filtered by id it reads `2 -> 4`
- **[P-125](P-125-what-one-bad-frame-costs-a-reconnecting-client.md)** valid
  (round 486), rpc_dart + rpc_dart_websocket — **counts the transports a factory
  BUILDS**, one per reconnect, with the websocket transports constructed bare so
  the proxy is the only reconnect machinery in the rig. Four arms, each with its
  own control; the load-bearing one is the FOURTH, which sends arm 2's identical
  `RpcFrameException.policy` with `closeOnProtocolError: true` and must still
  read `1 -> 2`. A fix keyed on the error type passes the first three arms and
  fails that one
- **[P-124](P-124-what-one-calls-unavailable-costs-the-others.md)** valid (round
  485), rpc_dart + rpc_dart_websocket — **two calls on one socket, only one of
  them failing.** Counts sockets ACCEPTED at a real `RpcWebSocketServer`, so the
  blast radius is a connection count rather than an inference from a log. Its
  control is the same rig with one constant changed — the status the failing
  handler throws — and the arm that keeps the fix honest is a third one where
  the path really dies, carrying its own ablation: remove the reconnect and it
  falls from `sockets=2, slow:x` to `sockets=1, RpcNoConnectionException`
- **[P-123](P-123-what-the-two-shims-actually-share.md)** valid (round 482),
  rpc_dart_wasm — **the instrument B-93 named and nobody ran.** Extracts every
  top-level named function from both boot literals by BRACE MATCHING (a
  non-greedy regex stops at the first inner `}` and silently compares a prefix),
  normalises indentation (the literals sit at different nesting depths, so a byte
  compare reports 100% drift and means nothing), and buckets them IDENTICAL /
  DIFFERENT / one-sided. **5 identical of 14, all trivial**; every difference
  host-forced. Its control is that it returns BOTH answers in one pass — an
  extractor stuck on either verdict cannot. Its first run was wrong in both
  directions and printed an equally tidy table, so it now asserts its own `"""`
  line bounds and exits 2 when either literal moves
- **[P-122](P-122-a-goaway-written-after-the-sink-closed.md)** valid (round 480),
  rpc_dart_http2 — **the same defect as P-40, rebuilt so it runs WITHOUT us.**
  B-35's decision left one task, the upstream report, and a report measured
  through `RpcHttp2CallerTransport` asks a maintainer to install this library to
  see their own bug. Both ends are `package:http2` here. It sharpened the finding
  twice: the trigger is `finish()` on a connection that **never opened a
  stream** (every arm with traffic is silent), and `finish()` completes
  **normally**, so the invariant is that the error never reaches its future
  rather than that it arrives late. 5 of 5 runs, http2 3.1.0 (latest). Two
  companion files on purpose — the matrix with the controls, and a minimal
  `upstream_minimal.dart` that is the pasted issue text kept as a file that RUNS
  rather than a quotation that rots. Its own first version was VOID and says so
- **[P-121](P-121-does-the-ceiling-reach-keepalive.md)** valid (round 479),
  rpc_dart_http2 — **the sweep arm: does the stream ceiling reach HTTP/2
  keepalive?** P-120 found the websocket heartbeat closed a healthy connection at
  `maxActiveStreams`, and `startHttp2Keepalive` is the same loop with the same
  `catch (error) { … onDead(error) }`. Reading says it cannot bite — the probe is
  `connection.ping`, a protocol frame charged to no stream limit — and this is
  that argument turned into a measurement: `ready` at 4 of 4 held and at 3 of 4.
  **The third arm is the reason it is a bench**: two `ready`s are equally
  consistent with a keepalive that never fired in the 700 ms window, so a frozen
  relay (both sockets open, bytes stopped) shows the same loop at the same
  interval flipping health to `down`. Clean, and clean for a structural reason —
  a future `ping` that allocated anything would put the shape back in play
- **[P-120](P-120-what-a-heartbeat-mistakes-for-death.md)** valid (round 479),
  rpc_dart_websocket — **what does a heartbeat mistake for a dead peer?** Built
  for the item B-71's decision called unresolved — a heartbeat competing with a
  long call for the connection window — and reading moved the question before the
  first arm ran: the ping sends only `sendMetadata`, which never consults credit,
  so the window is not where they meet. `createStream()` is. Every arm runs
  against a LIVE responder, so **every close it reports is a false positive by
  construction**: `CLOSED` at 4 of 4 ids held, `open` at 3 of 4, `open` under a
  120000 x 1 KiB stream. The one-id-free arm is load-bearing — same peer, same
  interval, same wait — and the "before fix" column is not hypothetical, it is
  what this round's fix looked like when first written
- **[P-119](P-119-inside-the-waking-turn.md)** valid (round 475),
  rpc_dart — **the seam is the RECEIVE side, and it is free.** P-118 measured the
  flow-control window at the controller's API and stopped, because the
  transport-level consequence needs a caller inside the turn a grant lands and
  "every entry point is async". True of the SEND side: the transport also LISTENS,
  `IRpcMultiplexedChannel` is five members, and a `StreamController(sync: true)`
  for `incoming` runs `handleInbound` → `_onGrant` → `wakeAll()` before `add`
  returns — so the woken sender's continuation is a queued microtask and the next
  statement is in the window. Measures the ORDER the transport handed to the
  channel, recorded inside `send`. **The control is asserting the frame is still
  parked BEFORE the grants**: without it, "the ending came second" is equally
  consistent with nothing having parked, which is how round 445's 0-of-200 went
  void. Policy must SEED the sender or nothing parks at all
- **[P-118](P-118-the-turn-a-grant-lands.md)** valid (round 469),
  rpc_dart — **an interleaving CONSTRUCTED rather than raced for**, which is what
  repaired a 0-of-200 void arm. `RpcFlowController` driven at its own API (it is on
  no barrel; `channel_transport.dart` is its only importer): spend the window, park
  a frame, deliver the peer's grant through `handleInbound`, then contend in that
  same synchronous turn. `fast path took it=true, parked sender resumed=FALSE`
  against a control at `false/TRUE`. **Two void versions preceded it and the tell
  was one extra column**: `returnCredit` is the RECEIVE side and never wakes a
  sender, and `initialSendWindowBytes: null` leaves the sender unseeded so
  `tryConsume` can never refuse — both read as "the fast path won" while measuring
  nothing, and `parked sender resumed=true` with the credit exactly spent is what
  contradicted them
- **[P-117](P-117-where-the-parity-rules-meet.md)** valid (round 468),
  rpc_dart_http2 + core — **two arms at different LEVELS, and neither substitutes**:
  `resumeStreamIdsAfter` driven at its own boundary at every parity (does the rule
  work?) and through `RpcClientConnection` across three swaps, three ids between
  each — an ODD count on purpose, so a naive carry lands on an even one (is the
  rule ever asked?). Control: the alignment deleted, which reports `PARITY BROKEN`
  on three rows — **and leaves the proxy arm CLEAN**, which is the sharper result.
  An ablation that cannot reach an arm has said something about that arm:
  `lastIssuedStreamId` is `_nextStreamId - 2`, odd by construction, so the
  alignment is never exercised there
- **[P-116](P-116-how-long-until-a-web-client-notices.md)** valid (round 466),
  rpc_dart_websocket — **a web-platform gap measured without a browser**: the stub
  `openWebSocket` IS the portable fallback as well as the web one, so both
  implementations run on the VM against one server, differing in exactly the code
  under test. **The server has to be RAW** — handshake by hand, then total silence
  — because a `dart:io` WebSocket server answers a ping inside its own
  implementation, and against one of those neither arm can detect anything and both
  read clean. `626ms` versus `NEVER`, with `io` + no interval as the control that
  also reads NEVER. Second half, for the owner's cost question, is deliberately
  reported as INCONCLUSIVE: the arm ORDER dominates, and the **ping count** is what
  exposed the first version as void — at 2000 messages the stream outran the first
  timer tick and zero pings landed while the row read "free"
- **[P-115](P-115-does-an-id-come-back-after-a-reconnect.md)** valid (round 465),
  all three caller-side reconnect machines in one run — mint an id, **leave the
  call open**, reconnect, mint another, then `finishSending(oldId)`. The open call
  is load-bearing: an id is only reusable-and-harmful while something still holds
  it. The second measure is what makes the first mean something — two equal
  integers are a curiosity, a teardown landing on a live call is the defect the
  lead describes. Control: `_nextStreamId = 1` restored in http2's reconnect, the
  reset its own comment says is deliberately absent, which reads `1 / 1 / YES`.
  **That control also answered a question about another machine**: with http2
  rewound, the PROXY arm still read `no`, so its `_idWatermark` carries the
  sequence across a transport that restarts its own
- **[P-114](P-114-does-a-retry-survive-the-reconnect-window.md)** valid (round 464),
  core + rpc_dart_websocket — **a sentence, measured**: a prior round chose
  FAILED_PRECONDITION for the reconnect window because "a synthetic UNAVAILABLE is
  RETRYABLE and invites the caller to repeat what cannot work". One call through
  `RpcRetryInterceptor` fired 100 ms into an 800 ms window, first backoff 250 ms —
  `status=9 after 0ms` versus `OK pong after 711ms`. The DURATION is the measure:
  0 ms proves no retry was attempted, 711 ms proves the retry waited the window
  out rather than racing it. Timings chosen so the question has a fair answer both
  ways — a window longer than the retry budget would prove only that retries can be
  exhausted. Control: the same call with no reconnect, 30 ms
- **[P-113](P-113-what-one-state-tells-a-caller.md)** valid (round 464),
  rpc_dart_websocket + rpc_dart_http2 + core — **two arms per machine, which is the
  design**: a send during a reconnect that is IN FLIGHT, and one after a reconnect
  that FAILED. Every earlier record collapses those into "disconnected"; separated,
  they turn out to want opposite advice, and `health()` already told them apart
  (`degraded` / `unhealthy`) while the status did not. One injectable factory with a
  `stall` and a `failNext`, so both arms come off one transport in one process.
  Reports the exception TYPE as well as the code, because http2 read the right code
  by ACCIDENT — from a discarded connection rather than from its guard. Controls: a
  send with no reconnect (accepted), and one after it completes (accepted)
- **[P-112](P-112-what-a-caller-ceiling-is-for.md)** valid (round 463),
  rpc_dart_http + rpc_dart_http2 + core — twelve concurrent calls against a handler
  that PARKS, ceiling 4 on the caller and 1024 on the responder, one arm per caller
  transport. **The parked handler is what makes the ceiling observable**: with a
  handler that returns, calls retire faster than they are issued and twelve never
  hold four slots at once. Three measures, and the third answers the lead's
  counter-hypothesis — admitted/refused, peak concurrent HANDLER entries counted on
  the far side of the wire, and for HTTP/1.1 peak concurrent requests open at the
  server (12 of 12, so the connection pool bounds nothing). Two further arms: a
  SEQUENTIAL one, which is RPC-05's ratchet canary made into a measurement, and the
  four ENDINGS run with the second release site ablated — which is how that site is
  known redundant rather than assumed necessary. Controls: the two siblings for the
  outcome, a high ceiling for the refusal
- **[P-111](P-111-content-type-across-the-layers.md)** valid (round 462),
  core + rpc_dart_http + rpc_dart_http2 — the MATRIX is the bench: four inputs
  against three responder layers in one run, each on its own wire (a real
  `HttpClient`, a raw http2 client, a channel pair whose caller transport rewrites
  the header — `content-type` is reserved, so a context cannot reach it). Every row
  prints what the responder SAW, because an "absent" arm the client library filled
  in is void rather than clean. **One file imports all three packages**: a pub
  workspace centralises `package_config.json`, so a probe under any member resolves
  every member's deps. Controls on three axes — the spelling the library sends, the
  `+proto` subtype its HTTP/1.1 caller actually sends, and the same input crossed
  with both policy modes. The core arm's first version rebuilt `RpcMetadata` from
  `headers` alone, dropped the first-class `methodPath`, and timed out on all four
  rows INCLUDING the control, which is the only reason it was caught in one run
- **[P-110](P-110-a-200-with-no-grpc-status.md)** valid (round 460),
  rpc_dart_http — a raw `HttpServer`, because only a non-conforming peer ends a
  response without a status. **200 is the load-bearing choice**: the caller
  synthesises a status from the HTTP code for non-2xx, so at any other code the
  trailer set is never empty and the arm does not exist. Body built with the
  library's own serializer (L-10). Controls: `grpc-status: 0` on the same server
  returning cleanly, and `grpc-status: 5` reported as itself — so the UNAVAILABLE is
  neither the harness nor a catch-all
- **[P-109](P-109-a-message-at-exactly-the-limit.md)** valid (round 458),
  rpc_dart_http + core — an off-by-five defect cannot be measured approximately, so
  **the limit is set to the message's own serialized length**: "exactly at the
  limit" is then true by construction and nothing has to predict what CBOR does to
  a 1000-character string. Varies the TRANSPORT, holds message and limit fixed.
  Two arms on the far side: `limit + 5` accepted everywhere (so the refusal is the
  five bytes) and `limit - 1` refused everywhere (so widening the bound did not
  remove it). The handler echoes the LENGTH it received, so an acceptance also
  proves nothing was truncated
- **[P-108](P-108-what-the-case-of-grpc-encoding-changes.md)** valid (rounds 456, 461),
  rpc_dart_http2 + core — varies the SPELLING against the same codec, and crosses
  it with the compression FLAG, because the flag decides whether a decompressor is
  looked up at all. **Two halves, and the second is where the defect lives**: a
  hand-built peer (where the case turns out to be INERT at flag 0) and the
  library's OWN caller with the encoding in the call context — which is the
  supported way to select it, so the lead's assumption that a foreign peer was
  needed was backwards. Controls: `identity` in every arm, `absent` for the null
  branch, and `nosuchcodec` to show the refusal machinery is informative — which is
  what makes the opaque INTERNAL elsewhere worth noticing (B-91)
- **[P-107](P-107-does-a-body-that-looks-framed-survive-unchanged.md)** valid (rounds 455, 461),
  rpc_dart_http2 — constructs the input rather than hoping to observe it, and
  READING came first: knowing the function is fed `RpcMessageParser` output, which
  is de-framed, is what made the arm constructible at all. Measured at the
  TRANSPORT boundary, because there is no `RpcBytes` message type to carry
  arbitrary bytes through a contract. **The control is a body of the SAME length
  whose first byte cannot be a compression flag**, so the heuristic could never
  fire on it — without that, "the crafted body was re-framed" is equally
  consistent with everything being re-framed for another reason. LENGTH alone
  separates the outcomes, which is why both arms use 13 bytes
- **[P-106](P-106-what-a-late-frame-on-a-closed-stream-is-told.md)** valid (rounds 454, 467),
  rpc_dart — varies the endpoint's DRAIN FLAG and holds the arriving frame fixed.
  **One COMPLETE call first is the setup that matters**: it is what puts the id in
  the closed-stream set, and without it the arm measures a fresh stream instead of
  a finished one. Stream 1 on purpose, so the late frame is provably not new. The
  third arm is a GUARD rather than a control — moving a refusal later is the change
  that can disable it — and it is what surfaced B-90, because the refusal COUNT
  matters as much as its presence
- **[P-105](P-105-what-each-teardown-block-clears.md)** valid (round 452),
  rpc_dart_http2 — one arm per teardown path on a stream left MID-FLIGHT, so no
  ending clears the state before the path under test runs. A silent server is the
  point. **The instrument had to be built first**: `_outgoingPumps`,
  `_fcOutstanding` and the stream-controller router were private, which is why the
  lead sat unmeasured for 26 rounds — three counts in `health()` made it
  askable. Control is `releaseStreamId` on the same shape, `1 -> 0` every run, and
  the BEFORE value is asserted too because an arm with no pump to lose would pass
  silently. Carries a VOID arm: a 256 KiB send did not park, so the hang the
  sibling's comment promises was not reproduced
- **[P-104](P-104-is-a-responder-side-deadline-bounded.md)** valid (round 451),
  rpc_dart — a handler yielding every 100 ms against a 300 ms deadline, so the
  ITEM COUNT is the clock. **The reading is a responder-side LOG record, not the
  caller's exception**: one `grpc-timeout` header arms a timer on BOTH ends, so
  `RpcDeadlineExceededException` at the caller is equally consistent with the
  responder doing nothing. Only `_onDeadlineExceeded` emits its notice. Control is
  the no-deadline arm, where the line is ABSENT — which is the whole risk with a
  log-based reading. `RpcResponderEndpoint` takes a `LogController`, not a
  `LogScope`. Carries a VOID arm on purpose: a hand-driven responder read
  `payloads=0` in the timeout row AND its control
- **[P-103](P-103-a-send-during-the-reconnect-factory-await.md)** valid (round 449),
  rpc_dart_http2 — the window is a matter of TIMING, so it is made 800 ms wide on
  purpose rather than raced. **Reads `health()` INSIDE the window**, which is what
  turns "the send was refused" into a refutation rather than an untested claim:
  without it the refusal could be the flag having been set after all. Controls on
  both sides of the window, both ACCEPTED. `connect()` does not take the
  injectable factory — only `viaSocket` does
- **[P-102](P-102-cancel-against-a-send-that-never-completes.md)** valid (round 448),
  rpc_dart — supplies the transport class a comment merely NAMED: a decorator
  whose end-of-stream send never completes. Reports a hang as the string `hung`,
  so it is an assertable value rather than a test that dies on a timeout.
  **Two controls**, the same path with the send completing and the SIBLING
  ordering against the same hanging send — the second is what makes the reading
  about ordering. **Trap**: the wrapper must NOT implement `IRpcStreamReset`, or
  the notice takes the reset path and never reaches `sendMetadata`
- **[P-101](P-101-an-ending-with-no-status-per-frame-type.md)** valid (round 447),
  rpc_dart_http2 — holds the missing grpc-status fixed and varies the FRAME TYPE
  the ending rides on. Extends round 429's raw-HTTP/2 probe with two cases rather
  than building a server again. **Three controls**: the same frame type with a
  status (so the fix did not just stop ending streams), the same malformation on
  the already-guarded DATA path (the sharpest pair in the table), and the shape
  measured at the CORE boundary, which is what proved the gap http2-local and
  refuted the owner's decision. **Trap**: print the label BEFORE the arm —
  `'${await run(x)}'` evaluates first, so each trace lands under the previous
  heading, which is how the first reading looked like a passing arm
- **[P-100](P-100-does-raising-maxheaders-raise-anything.md)** valid (round 446),
  rpc_dart — varies the KNOB and holds the input fixed, which is the shape for
  any "this limit is wired to nothing" claim. Four static arms plus three
  end-to-end ones, the count read INSIDE the handler so the caller's own object
  can be compared against what crossed. **Three controls, and the third is what
  stops a wrong reading**: asking `validateMetadata` about the same 200 headers,
  without which the context's truncation and the policy's refusal are
  indistinguishable and the defect reads as "the limit works"
- **[P-99](P-99-which-ending-paths-wait-for-a-parked-send.md)** valid (round 445),
  rpc_dart — which of the four send paths waits for a credit-parked frame before
  ending the stream. Six arms over both transport pairs; the reading is the ORDER
  of arrival at the peer, not a quantity. **Two controls**: the ablation (the
  witness flips to OVERTAKEN) and the guarded sibling run on the SAME pair kind
  as each witness — a witness on `memoryPair` controlled only on `pair()` would
  not establish the rule. **It also corrects P-58**: a pair never parks on the
  LATENCY-shaped park and parks reliably on the VOLUME-shaped one, so no relay is
  needed here. One arm is VOID and says so (B-88)
- **[P-98](P-98-the-same-context-down-two-call-shapes.md)** valid (round 444),
  rpc_dart — one caller `RpcContext` sent down two call shapes, so the SHAPE is
  the only variable. Seven arms over a channel pair; the reading is the
  difference between two arms holding the same context. **Two controls, and one
  would not have done**: the sibling shape (whose merge site has the filter) and
  a clean context down the shape under test — A1 differing from both is what
  separates "the header is the cause" from "ping is broken". Two further arms
  BOUND the severity rather than reassure: the reserved keys a peer acts on do
  reach the frame and change nothing, because their consumers gate on
  `methodPath == null`
- **[P-97](P-97-truncated-stream-shape-d.md)** valid (round 429), rpc_dart —
  how does a server stream END when the peer vanishes mid-stream? Three arms
  over a channel pair; the reading is the COMBINATION of items delivered, error
  or not, and whether `onDone` ran clean — `items=2, NO ERROR, endedClean=true`
  is a truncated response nobody can tell from a complete one. **The third arm
  is the control and it is what makes the negative readable**: a handler that
  ends properly, so the probe has to report `NO ERROR` for something
- **[P-96](P-96-response-pump-outlives-its-call.md)** valid (round 426),
  rpc_dart — does a producer stop when its call ends, and on WHICH endings? Six
  arms, one per way a bidi call can end; the number is messages pulled in the
  250 ms after the ending, counted inside the `async*` generator. **+1 is a pump
  that stopped, +30-odd is one that did not**, with two controls at +1. Also
  reports whether `responder.done` fired, which separates "an ending nobody
  watched" from "an ending with no signal at all" — two arms are the second kind
- **[P-95](P-95-bridge-cancel-paths.md)** valid (round 425), rpc_dart — how long
  does a CONSUMER's `cancel()` take on a bridge whose source is a user `async*`
  parked at an await? Five arms, 3000 ms cap. The control is the same parked
  source through a controller that drops the cancel Future instead of returning
  it: 6 ms against HUNG, so the park alone does not produce the number, the
  await does. Two arms are real code paths with the defect absent, one of them a
  full server-stream call — the premise check for B-56's designated extraction
  source
- **[P-94](P-94-unary-listener-fanout.md)** valid (round 423), rpc_dart — how
  many listeners sit on the connection-wide broadcast per parked unary handler?
  **A COUNT, not a duration**: the defect is O(N) listener invocations per
  inbound frame, and a wall clock on an in-memory pair measures the machine — an
  earlier record of this shape (48 ms against 333) is a reading nobody can
  reproduce on other hardware. The control is one flag, `listensToTransport`,
  and reads exactly N+1 against a flat 1: `2/11/51/201` at 1/10/50/200 parked
  handlers. Does NOT measure the per-frame cost of each listener, nor the duty
  they were carrying — that is the witness's GUARD
- **[P-93](P-93-malformed-reads-as-a-limit.md)** valid (round 412),
  rpc_dart_http2 — does malformed framing read as a resource limit? **The two
  arms differ by FIVE BYTES and nothing else** — same connection, same headers,
  one gRPC prefix apart — which is the entire design: with any other difference,
  a difference in the answer would not be attributable to the classification.
  `8` and `8` before, `8` and `13` after
- **[P-92](P-92-what-the-peer-is-told-per-type.md)** valid (round 408),
  rpc_dart — what a handler's error TYPE costs the peer. **Three of its five
  arms are controls and they are the whole design**: a type inside the
  hierarchy, the supported `RpcStatusException`, and a foreign `StateError`.
  Without them "the subjects come back INTERNAL" and "everything comes back
  INTERNAL" are the same output. The foreign arm doubles as the standing GUARD:
  `wireStatusFor` is default-deny, so if it ever stops being redacted the deny
  has been broken by whatever widened the hierarchy
- **[P-91](P-91-what-a-dead-worker-looks-like.md)** valid (round 407),
  rpc_dart_isolate — the isolate's row in P-90's table, for a transport with
  neither `_disconnected` nor `reconnect()`. Its arms come from READING
  `spawn()` — an errorPort and an exitPort that after startup do the same thing
  — rather than from guessing, and `kill()` is the control on both, since it
  reaches neither port. All three deaths answer UNAVAILABLE, including an
  uncaught throw from a timer after the handler's frame is gone
- **[P-90](P-90-which-type-escapes-when-disconnected.md)** valid (round 405),
  websocket and http2 — which type escapes a disconnected transport. **Its
  design IS its control**: each arm polls the transport's own `health()` until
  it stops reporting healthy and PRINTS what it says, before touching the guard,
  because otherwise "the two transports behave differently" and "one of them had
  not noticed yet" are the same output. That gate is what turned a recorded
  curiosity into B-61
- **[P-89](P-89-drive-what-the-message-prescribes.md)** valid (round 404),
  framework + websocket + http2 — do exactly what an error message says and
  nothing else. Three files because the sites live in three packages. Two
  design notes worth reusing: every arm carries its PRE-STATE (`first call:
  served`), so an arm that never reached the state it names cannot read as
  clean — P-84's `grpc-status` lesson in another currency; and a message with an
  `and` in it is SPLIT into one arm per claim, because "a failed reconnect
  leaves the transport recoverable" buys nothing if it only means
  `isClosed == false`
- **[P-88](P-88-does-the-drain-converge.md)** valid (round 403), websocket and
  http2 — does a graceful drain converge or merely expire? **Broken in 402 and
  repaired in 403, with both sets of numbers kept side by side**, which is the
  reason to read it. Broken: the ordering between the transports REVERSED with
  load (`112 ms / 70` against `8 ms / 6`, then the opposite at 64 lanes), because
  `drainUntilIdle` samples an instantaneous count and 5 ms handlers always leave
  a gap, so both exited on the first zero sample and admission never came into
  it. Repaired by parking eight server-streams across the drain so the count
  cannot read zero: `websocket 3006 ms / 1347 served after` against `http2
  3016 ms / 4` — **337x**, direction independent of load. One load-shape change
  between noise and three orders of magnitude
- **[P-87](P-87-restart-the-way-the-error-says.md)** valid (round 401),
  rpc_dart_websocket — restart the server the way its own `StateError` says to,
  one arm per remedy the message names. The arms differ ONLY in how the
  connections stream was built, so a difference is attributable to that.
  Contaminated observable, caught and recorded: the abandoned-socket flag was
  first read after the arm's own `sink.close()` and reported `closed` — its own
  teardown, the same trap as P-84's first rebuild
- **[P-86](P-86-a-peer-that-never-reads.md)** valid (round 400),
  rpc_dart_http2 — what a peer that never reads its own refusals costs the
  server. "Never reads" is a RELAY whose server-to-peer subscription is paused,
  not a peer that skips `listen`: dart:io drains into its own buffer, so that
  version applies no pressure at all. Two controls, and the second is the
  unusual one — the counters are read TWICE, twelve seconds apart, because one
  sample cannot separate a plateau from a slow climb and that distinction is the
  whole verdict. Its RSS column decides nothing and says so: the process holds
  both peers and two of three arms read NEGATIVE
- **[P-85](P-85-what-a-refusal-grind-costs.md)** valid (round 399),
  rpc_dart_http2 — what a refusal grind costs, **against a served-call control**,
  which is the whole point: RPC-22's question is comparative and an absolute
  refusal cost means nothing. Bytes come from a RELAY between peer and server,
  because neither endpoint can report both directions without the other's
  cooperation. Two columns earn their place — `ops`, because the
  backstop-bearing arm stops part-way and dividing by the attempt count would
  understate it 6x; and `grpc-status`, which caught this round's first ablation
  arm measuring the wrong site (`maxHeaderValueBytes: 8` refuses the request's
  own `content-type`, so it never reached the framing path)
- **[P-84](P-84-what-a-refused-stream-leaves.md)** valid (round 397),
  rpc_dart_http2 — what a refused stream leaves on the responder. **Two rebuilds
  worth reading**: it first read the counters after `conn.terminate()`, which
  runs `close()` and clears every map, so both arms said 0 and it measured its
  own teardown; and its first control was a POST with no body, which the
  pipeline refuses for its own reason, so there was no served arm at all. Every
  arm now reports the `grpc-status` the peer saw. Control is `open, never
  ended`, reading 200/200. Grown twice since: round 396 added the pump column
  and a `streaming, mid-answer` arm (200 live writers, the retention control for
  it), round 397 the framing-violation arms and `activeResponders` — and there
  the PAIR is the measurement, one refusal driven with a half-close and one
  without, since that is the only difference between 0 and 200
- **[P-83](P-83-the-flood-on-each-construction-path.md)** valid (round 394),
  rpc_dart_http2 — the same CONTINUATION flood against three construction paths,
  the server being the control. **Its number is FRAMES ACCEPTED, not RSS**: the
  unguarded arm read +178 MiB and +27 MiB across runs for identical input, while
  65-against-4096 is deterministic. Recorded because RSS is the more quotable
  figure and would have been the wrong one to quote
- **[P-82](P-82-what-n-handlers-cost-every-frame.md)** valid (round 393),
  rpc_dart — what N live unary handlers cost every other frame. **Its first
  version read a FLAT line and was wrong**: it pumped with a server-stream while
  the parked responders sit on the server, whose broadcast carries inbound
  frames only. Two planted counters said `3` listener entries for 3000 frames;
  pumped upstream the same counter reads 600 400 at N=200. A flat line means
  "no defect" and "cannot reach it" equally. Control is N=1
- **[P-81](P-81-a-close-reason-in-bytes.md)** valid (round 392),
  rpc_dart_websocket — does a protocol close survive a non-ASCII reason? **Its
  fixture IS the design**: 84 characters and 138 bytes, both bounds asserted in
  the test, because the arm only isolates the byte-vs-character bug if it clears
  the byte cap AND sits under the old character trim. A first version used 140
  characters and failed its own second assertion
- **[P-80](P-80-what-the-client-is-told-when-the-handler-fails.md)** valid (round
  389), rpc_dart — what the client is told when a bidi handler's source fails.
  **Measures with an OVERALL deadline, not a per-event `Stream.timeout`**, which
  is the only reason it can see this defect: the answer was *never ended*, and a
  per-event timeout re-arms on every payload. Its first witness asserted only
  `isNot(contains('ended OK'))` and passed on the broken tree
- **[P-79](P-79-close-during-an-add-stream.md)** valid (round 386), rpc_dart —
  `close()` while an `addStream` runs, inside `runZonedGuarded` so an unhandled
  async error is COUNTED rather than killing the probe. **Its control is the
  PRODUCER SHAPE**: the identical path reads 1 zone error with a source that
  survives its own error and 0 with an `async*` that ends at its throw — which
  is exactly why round 384's witness passed. B-54's arm lives here too
- **[P-78](P-78-cancel-before-the-trailer.md)** valid (round 385),
  rpc_dart_http2 — four arms differing by ONE thing each, the link and the
  instant the consumer lets go, which is what turned "the connection sometimes
  dies" into `50 ms + cancel before the trailer`. Its relay also ATTRIBUTES the
  hangup (labelled pipes) and a `LogController` on the server says rpc_dart
  never sees it — two instruments, not one. B-53
- **[P-77](P-77-the-endings-over-http2.md)** valid (round 385), rpc_dart_http2 —
  C-41's endings over real HTTP/2 on both links. Worth reading for how a
  useless reading became a usable one: a fresh connection per duplex case (the
  death FOLLOWS a call that succeeded) and a SEQUENTIAL arm beside the
  concurrent one (concurrency is not the variable)
- **[P-76](P-76-the-endings-over-an-isolate.md)** valid (round 385),
  rpc_dart_isolate — the same matrix over a real isolate, serialized AND
  zero-copy, the codec-less branch no endings matrix had ever run. Counters come
  back OVER THE WIRE from the worker, so the baseline is 1 and the unary arm is
  what fixes it
- **[P-75](P-75-both-directions-saturated.md)** valid (round 384),
  rpc_dart_websocket + core — both directions of ONE bidi call past the
  flow-control window at the same time, the only configuration in which one can
  hold the other. Its two SINGLE-direction arms are the control that makes the
  stall readable: each runs flat out, so the stall in the mirror arm is the
  handler's coupling and not the library's, and the resume proves back-pressure
  rather than deadlock
- **[P-74](P-74-the-endings-over-a-real-socket.md)** valid (round 384),
  rpc_dart_websocket + core — C-41's seven endings over a real socket and over a
  Dart TCP relay with a 50 ms round trip. Two things P-63 lacks: **a unary call
  after every scale**, because an ending that WEDGES a connection leaves every
  counter at zero, and the duplex cases. Its sensitivity proof is the `deadline`
  row, the one arm that reads non-zero
- **[P-73](P-73-does-an-abort-kill-the-http2-connection.md)** valid (round 384),
  rpc_dart_http2 — a control MATRIX rather than a number: eight arms differing
  one variable at a time, which is what eliminated the await and the sink path
  and left *responses in flight at the instant of the reset* as the only thing
  every dead arm shares. B-53
- **[P-72](P-72-a-request-sink-that-errors.md)** valid (round 384), rpc_dart —
  what the server keeps when a bidi request sink errors: 1 / 6 / 26 and
  permanent, against a half-close and an explicit `abort()` at 0. The **paced**
  arm is the one that earns its place — it separates *the fix drops a message*
  from *the abort raced a message still in flight*
- **[P-71](P-71-the-first-chunk-under-slicing.md)** valid (round 383),
  rpc_dart_websocket — B-44's shape (17 chunks, ids on the first only) through
  toxiproxy's `slicer`. **Every field is a function of the index**, so lost,
  reordered, duplicated and mis-decoded are four distinguishable outcomes rather
  than one. **Its control is recorded as WEAK and that is what made round 383
  inconclusive**: the ablation was meant to drop frame 0 and print the
  consumer's symptom, and instead removed the responder's dispatch, proving only
  that the probe separates delivered from not-delivered. Sharper control named
  in the record. Runs on the VM, so it tests the wire and not the runtime
- **[P-70](P-70-the-request-direction.md)** valid (round 382), rpc_dart — how
  many messages the library pulls from the CALLER's producer while a handler
  that read one stalls. Two controls: a draining handler that pulls the producer
  dry (so a low number is a bound, not a slow producer), and an ablation of
  `deferFlowCredit`. **The ablation did more than confirm sensitivity — it
  corrected attribution**, moving the arm the lead did NOT name and leaving the
  one it did, which is how `_pipelineFedRequestStream` was identified as the
  CLIENT-STREAM path rather than bidi's
- **[P-69](P-69-what-the-initial-window-buys.md)** valid (round 380),
  rpc_dart_websocket — how many frames a caller gets out BEFORE the first grant
  can throttle it, through toxiproxy at 50 ms RTT with a handler that never
  reads. **The RTT is not optional**: credit exists only once a grant arrives,
  so on an in-process pair the field looks inert — which is how round 366 came
  to call it useless. The `null` arm is the control that matters, running the
  producer to exhaustion (40000 frames, 156.25 MiB), so every other row is a
  real bound rather than a slow producer. Reproduces the field's own doc comment
  to within 0.01 MiB, which is a second control from a different session
- **[P-68](P-68-backpressure-through-toxiproxy.md)** valid (round 378),
  rpc_dart + rpc_dart_websocket — back-pressure over a link with a real RTT, via
  **toxiproxy** (its own container, not the one another project is using) with a
  50 ms latency toxic on each stream. **Its ablation runs THROUGH the proxy**,
  not beside it, which is what makes the latency rig demonstrably sensitive
  rather than merely slower. Answers the question P-58 raised and comes out the
  other way: latency does NOT change this result. Trap: reach a docker-published
  port over IPv4 explicitly — `localhost` resolves to `::1` first and returns
  `000`. Has bandwidth, jitter and slicing available and used none of them
- **[P-67](P-67-the-subscription-on-real-transports.md)** valid (round 377),
  websocket + http2 + isolate — three files, one per package, real servers on
  loopback and a real spawned isolate, no fakes. **Its evidence is the
  ablation**: removing round 373's dispatch from CORE (which all three resolve
  from local source through the pub workspace) collapses every `silent` arm to
  0 HANG while every `control` survives, on all three. Loopback only, which is
  adequate for this question and NOT for a flow-control one (P-58)
- **[P-66](P-66-does-the-subscription-reach-every-wiring.md)** valid (round 376),
  rpc_dart — asks round 373's question of the wirings 373 never ran: the peer
  endpoint, the zero-copy branch, and eight concurrent calls. **Its evidence is
  the ablation, not the good values** — removing 373's dispatch collapses every
  `silent` arm to 0 HANG while every `control` survives, which says the probe
  sees the defect AND that it was present on all three. Trap: the zero-copy arm
  first failed in both columns, which is a broken rig rather than a finding
  (measurement item 4) — that branch needs `RpcInMemoryTransport.pair()`
- **[P-65](P-65-the-third-copy-of-the-same-pause.md)** valid (round 374),
  rpc_dart — the same back-pressure question as P-61 and P-62, asked of the
  THIRD copy: the endpoint's own `_pumpBidirectionalResponses`. **The one an
  ordinary application reaches** — the sinks need the caller/responder classes
  built directly, this one is an `async*` handler on a contract. Control is a
  server-stream handler whose relay already forwards pause, on the same rig,
  landing on the window and unchanged before and after
- **[P-64](P-64-are-the-two-directions-independent.md)** valid (round 373),
  rpc_dart — with one direction of a bidi call idle, finished or busy, what does
  the OTHER side observe? **The control is one line of the caller's own code**:
  the same handler driven with `Stream.empty()` instead of a request stream that
  never closes, `5 DONE` against `0 HANG`, which named the trigger as the
  half-close rather than the payload. Carries a HOP CHECK that samples the
  server mid-call, because "the caller got nothing" cannot separate *the
  responder never heard of this call* from *the answer was lost* — that is what
  found the second hop instead of assuming it (L-07)
- **[P-63](P-63-what-survives-a-bidi-call.md)** valid (round 372), rpc_dart —
  eleven counters read after a bidi call settles, across seven ways of ending
  it, at three scales on ONE connection. **Its evidence is the ablation, not the
  zeros**: every cell is 0, and a zero cannot be told from a blind instrument, so
  removing the bidi responder's cleanup is what shows the same counters climbing
  5 / 25 / 85. Unary rides along as the control shape. Says nothing about RSS,
  about latency-shaped endings, or about duplex semantics
- **[P-62](P-62-does-the-handler-run-ahead-of-the-wire.md)** valid (round 371),
  rpc_dart — the mirror of P-61 on the RESPONSE side: how many messages the
  library pulls out of the HANDLER's producer while the consumer is not reading,
  counted inside that producer. Control is `ServerStreamResponder`, which
  already forwards pause through `relay.onPause`, on the same rig in the same
  run; it lands on the window and reports the same number before and after, so
  the reading is of the mechanism and not the timing. `responseSink` is only
  reachable on the responder class, so that arm builds it directly
- **[P-61](P-61-does-the-producer-run-ahead-of-the-transport.md)** valid (round 370),
  rpc_dart — how many messages the library pulls out of an application's
  producer while the handler is stalled, counted INSIDE the producer's own
  generator so it measures demand the library created. **The control is the
  sibling and it lands ON the window** (66 x 16 KiB = 1.03 MB against a 1 MB
  window), which is what makes the reading a measurement rather than "fewer".
  Exists because B-49 deliberately refused to borrow the sibling's own 32.8 MB
  figure, taken on a different API
- **[P-60](P-60-what-the-caller-is-told-about-a-short-read.md)** valid (round 369),
  rpc_dart — can a caller tell that the other side read everything it sent? Both
  numbers are taken where an APPLICATION reads them (what the handler was given,
  what the caller was told), never from a private field. **Three controls in the
  same run**: `fullRead` differs by exactly one line of handler code, `throws`
  proves a non-OK ending is readable on this path at all, and the server-stream
  mirror answers differently — so an `OK` is the call being reported successful
  rather than the bench being blunt. Does NOT establish whether
  `droppedRequests` is reachable by any path: two were tried, neither reached it,
  and the probe budget was spent
- **[P-59](P-59-the-four-shapes-under-the-same-edge-case.md)** valid (round 368),
  rpc_dart — the same edge case asked of all four call shapes at once, reporting
  three things per cell: payloads the consumer received, the exception type that
  ended the call, and errors that reached the zone. **The third has the teeth** —
  a clean `DONE` where the handler failed is silent truncation, an `uncaught` is
  exit 255. Ends with a deliberate `listen((_) async { throw ... })` that must
  report `+1`, because otherwise a `0` cannot be told from "nothing was
  watching"; it stayed at +1 after round 368's fix. Trap: cancelling the call
  with `close()` closes the producer's sink too, so the later `add` is API misuse
  rather than the case under test — the route that leaves the sink open is the
  cancellation token
- **[P-58](P-58-does-a-sender-park-over-a-real-socket.md)** valid (round 366),
  rpc_dart + rpc_dart_websocket — does a sender actually park on the flow-control
  window, over a real WebSocket through a TCP relay that delays every chunk by a
  fixed amount in both directions. **Exists because the obvious harness lies**:
  `RpcChannelTransport.pair()` reports "never parks" in every row, including the
  ones a real socket parks in, so every flow-control question answered against
  the in-process pair is answered about a system nobody runs. Its control is the
  5.0.1 shape (`initialSendWindowBytes: null`), which never parks where 6.0.0
  does. Park duration tracks RTT exactly — 20/40/200 ms — so it measures the wait
  for the peer's first grant rather than congestion. Reports peak
  `flowControlStateSizes['waiters']` per policy, which is what B-47 needs to be
  decided
- **[P-57](P-57-guest-to-host-frame-order.md)** valid (round 365), rpc_dart_wasm
  — do 10k guest frames arrive in order, compared against the generated sequence
  so a swap, a duplicate and a gap all fail the same assertion. Its iOS row is
  the first measurement that the undocumented WebKit FIFO convention actually
  holds rather than being assumed
- **[P-56](P-56-guest-timer-lag.md)** valid (round 365), rpc_dart_wasm — how late
  a guest `Timer` is, clocked INSIDE the guest because a bridge round trip costs
  more than the delays under test. Each platform is the other's control, and
  building it is what found the `performance.now()` gap: the Android arm threw
  where iOS reported numbers
- **[P-55](P-55-what-a-wasm-call-costs.md)** valid (round 364), rpc_dart_wasm —
  what one call over the bridge costs, p50/p95/p99 at four payload sizes, with a
  discarded warm-up. **Its empty-unary row is the control for every other row**:
  that an empty call and a 1 KiB call cost the same is the finding — the price is
  the round trip, not the bytes. Published in the README with its hardware named,
  because an emulator is a floor and not a prediction
- **[P-54](P-54-unstripped-module-syntax.md)** valid (round 363), rpc_dart_wasm —
  what a caller is told when the dart2wasm glue uses a module form the plugin
  does not strip, by mutating the REAL glue one way per arm. **Its control is
  the finding**: swapping the line-anchored check for a `contains` takes the
  device suite from `+21 ~2` to `+3 ~2 -13`, because `export`/`import` appear 19
  times in the glue and only 4 at statement position
- **[P-53](P-53-android-main-thread-during-transfer.md)** **broken** (round 362),
  rpc_dart_wasm android — platform-channel round-trip latency as a direct read of
  Android main-thread availability, with an idle control in the same run. It
  resolves THAT the byte path occupies the main thread and not BY WHAT: its own
  ablation (Base64 back on Main) reads no worse than the fix. Kept because the
  negative is the result, and because the design — measure the thread, not frame
  timings two layers away — is the reusable part
- **[P-52](P-52-connect-headers-and-timeout.md)** valid (round 361),
  rpc_dart_websocket — what `connect()` can and cannot express. **The headers
  half is read on the SERVER side**, off a recording `HttpServer`, so the number
  is what crossed the wire rather than what the client believes it set. Its
  `after reconnect()` row is what decides whether the feature is usable: a token
  that goes only on the first upgrade authenticates exactly once
- **[P-51](P-51-three-core-diagnostics.md)** valid (round 360), core — three
  places the library answers wrongly rather than failing, in one file. **Each
  section's control is the SIBLING that gets the same question right**, which is
  what makes each defect legible rather than merely surprising. Its section (b)
  came back CLEAN and is kept for that reason: the negative is the result, and
  deleting the arm would leave the next round re-deriving it
- **[P-50](P-50-calls-inside-the-reconnect-window.md)** valid (round 359),
  rpc_dart_websocket — six transport methods against three transport states, as
  a table. **Two of the three arms ARE the controls**: `healthy` and
  `disconnected` are the states the code means to have, so a correct transport
  makes the third column equal one of them. Its `finishSending` row returning in
  every arm is load-bearing rather than noise — that method runs from `finally`
  blocks, so a fix that made it throw would be worse than the defect
- **[P-49](P-49-send-into-a-dead-socket.md)** valid (round 358), rpc_dart_websocket
  — does a websocket send throw when the socket is already gone, one arm per way
  it can be dead. **Each arm prints its sampled flags BEFORE the send**, because
  one arm throws into the root zone and takes the process with it: a row that
  never prints is a row that was never measured. Rebuilt once — the first version
  drove a full endpoint pair and could not tell the arms apart, because `onDone`
  always won the race
- **[P-48](P-48-boot-failure-on-a-real-guest.md)** valid (round 356), rpc_dart_wasm
  — what a failed boot hands back, inside a REAL dart2wasm guest on a device.
  **The only bench that can see `rpc_wasm.dart` at all**: it is
  `dart:js_interop`, so no VM runs it and `test:wasm`/`test:web` cannot reach a
  line. Its control is the suite's other nine guest tests, which exercise the
  second, successful boot over the same JS globals — so an ablation that breaks
  the retry is told apart from one that corrupts the error
- **[P-47](P-47-native-text-encoding.md)** valid (round 355), rpc_dart_wasm —
  what reaches Dart when native sends non-ASCII text, in characters sent against
  characters arrived WITH the byte count beside them: on a byte-per-character
  read the arrived count equals the byte count, so the pair names the failure
  mode. Its ASCII arm is the control and is also the reason the defect shipped
- **[P-46](P-46-drain-in-peer-mode.md)** valid (round 354), websocket server and
  core endpoints — does a graceful drain see a peer-mode call. Reads
  `activeResponders` off the endpoint's own `collectEndpointMetrics()`, the same
  map the drain polls, so the column says what the DRAIN saw; `null` rather than
  `0` is what identifies an absent key from an idle server
- **[P-45](P-45-text-frame-blast-radius.md)** valid (round 353), websocket and
  core transports — what one stray frame costs the calls already in flight. Its
  `connection alive` column is the instructive part: it reads the same in every
  arm, which is exactly what the channel-level suite was asserting while every
  call on the connection died
- **[P-44](P-44-capabilities-through-the-proxy.md)** valid (round 352), core
  resilience and endpoint — what the layers above lose to a transport wrapper,
  in EFFECT rather than in `is`: the largest response the caller's parser takes,
  whether a codec-free call is accepted, whether the responder pipeline could
  defer metering. Rebuilt once because the frame channel's OWN policy refused the
  body in both arms — a neighbouring limit firing first
- **[P-43](P-43-cancelled-stream-probe.md)** valid (round 351), core resilience —
  what a circuit breaker admits after a half-open STREAM probe, by how the probe
  ended. Its control is the same consumer that does NOT cancel, with the source
  closed at the same point in both arms — the first version varied the cancel and
  the source's termination together and could not tell the two apart
- **[P-42](P-42-does-terminate-reject.md)** valid (round 347), http2 — which
  connection state puts an error in the zone, with a REACHABILITY column that is
  the control: three arms reported zero unhandled errors while the line under
  test never ran. Its last row, `finish()` and nothing after it, is what
  identifies the source — `finish()` throws after its own future completes, so
  whatever is in flight when it lands looks like the culprit
- **[P-41](P-41-per-stream-state-is-reclaimed.md)** valid (round 343), http2 —
  does per-stream state come back to zero after the calls that made it, read from
  the transports' own `health()` details so nothing needs instrumenting. Its
  control had to delete **both** prunes: `_streamParsers` is removed in two
  places and either alone suffices, so the single-site ablation changed nothing
  and read exactly like a bench that cannot see a leak (L-01)
- **[P-40](P-40-policy-violation-backstop.md)** valid (round 342), http2 + core —
  what bounds a peer that only sends frames the policy refuses, at the DEFAULT
  policy. Its control is the shared layer's 256-violation backstop, and reaching
  that control needs a hostile CHANNEL STUB: since round 340 a well-behaved
  sender refuses to emit the frame, so `RpcChannelTransport.pair()` reads
  "refused after 0 sends" and looks like no inbound check at all
- **[P-39](P-39-aggregate-metadata-bound.md)** valid (round 341), rpc_dart_http —
  whether `maxMetadataBytes` is enforced, asked with a raw HTTP/1.1 POST because
  our own caller would never build the block. **960 000 bytes accepted against a
  64 KiB bound**, every header individually legal, and dart:io imposes no limit
  of its own. Its control is a second server at `maxHeaders: 8`: without a row
  that refuses, the 200s prove nothing
- **[P-38](P-38-outbound-metadata-against-the-policy.md)** valid (round 340),
  http2 + core — whether a transport refuses outbound metadata its own policy
  forbids, with `RpcChannelTransport.pair()` as the control arm because four of
  five transports already have the check. Carries the trap that cost a
  measurement: a limit chosen to be violated must still admit the control, or
  the peer refuses every call and it reads as connection poisoning
- **[P-37](P-37-guard-versus-filter.md)** valid (round 338), core — whether the
  level guard predicts the filter it stands in for, asked at the controller's own
  stream rather than of the guard. Two of four configurations disagreed and one
  was a MUTE. Needs no instrumentation, which is what makes it cheap to re-run
  after any change to `_resolveLevel`
- **[P-36](P-36-discarded-log-strings-every-shape.md)** valid (round 337), core —
  log messages built for a level that discards them, per round trip, on **all
  four call shapes** and under **two logger configurations**. Round 333's
  ancestor took one shape and one configuration and so measured 6 discarded
  messages where serverStream had 42; attaching a real logger at `error` removes
  none of them. Core-only by construction: a wrong guard in a transport leaves
  every cell unchanged
- **[P-35](P-35-upgraded-then-silent.md)** valid (round 288), rpc_dart_websocket —
  P-25's question one stage later: the peer COMPLETES the upgrade and then never
  speaks websocket, so it answers no PING. A raw socket on purpose — a real
  client would answer them, which is the one thing it must not do
- **[P-34](P-34-isize-understates-on-web.md)** valid (round 286), core — **a bench
  that is also the regression test**, because the thing measured is a platform
  difference and the only honest way to show one is the identical code on both
  runtimes. Forges the ISIZE trailer so the fixture builds without `dart:io`;
  asserts the contract, PRINTS the time
- **[P-33](P-33-hostile-reflection-requests.md)** valid (round 284), core —
  P-28's shape aimed at the OTHER hand-rolled parser here, the reflection
  service's request decoder. Prints the response SIZE and not just a verdict,
  which is the only reason its one interesting row is visible
- **[P-32](P-32-rapid-reset-cpu.md)** valid (round 283), http2 — what a flood
  costs an UNRELATED client, measured as a second connection's call latency
  rather than as CPU. Report the WORST case, not the median: only the worst moves
  here, and a median-only reading calls every arm identical
- **[P-31](P-31-metadata-is-never-paced.md)** valid (round 282), core — **the
  first SEND-path bench here**: does this path apply backpressure? A real
  transport pair, a consumer that TOOK a stream and paused, and the observable is
  whether a send blocks. Its control parks at exactly the window, which is what
  makes it a measurement rather than a coincidence
- **[P-30](P-30-pre-method-budget-weighs-payload-only.md)** valid (round 280),
  core — the pre-method budget with the pipeline's admission check TRANSCRIBED
  beside it, because the thing under test is which frames get in and a bench that
  admits everything cannot see it. Carries its own ablation: pass `old` to charge
  the pre-fix expression without touching the library
- **[P-29](P-29-metadata-weighs-characters.md)** valid (round 279), core — P-21
  extended with the shape P-21 lacks: many TINY headers, where characters and
  cost diverge 12x. Two traps it had to survive — the metadata must be DECODED
  from a wire frame or Dart interns the literals and the cost vanishes, and
  `maxRss` one-arm-per-process because `currentRss` went negative
- **[P-28](P-28-hostile-frames.md)** valid (round 278), core — seventeen named
  malformed frames through the real decoder, each with a hand-written header so
  the declared length can lie. Sorts outcomes into typed refusal / short-read /
  **leaked Error**, which is the one that matters
- **[P-27](P-27-rapid-reset.md)** valid (round 277), http2 and core — HTTP/2
  Rapid Reset, and **the only bench here that speaks HTTP/2 to the server without
  rpc_dart's own caller**: reuse it for anything needing frame-level control.
  Carries a `diagnose` arm, which is what caught a fixture that could not
  dispatch a handler at all
- **[P-26](P-26-refused-upgrade-has-no-deadline.md)** valid (round 276),
  rpc_dart_websocket — P-23's shape aimed at the origin gate. Three arms, and the
  REQUEST SHAPE is the load-bearing one: dart:io hands a connection-upgrade
  request no body, so the holding attack is a plain POST and the upgrade-shaped
  one reads as clean
- **[P-25](P-25-a-tcp-syn-builds-an-endpoint.md)** valid (round 274), http2 and
  websocket — what a connection that never speaks costs a server, counted on the
  library's own `endpoints` and a contract-construction counter (RSS moved by
  -28.7 to +0.4 MiB across identical runs and is unusable). Three controls: the
  keepalive arm, the preface arm, and the sibling server
- **[P-24](P-24-read-after-the-408.md)** valid (round 273), rpc_dart_http — does
  the server keep reading after it has answered? Measured as the PEER's send
  pressure with every flush deadlined, so a stopped read is a number rather than
  a hang. The control is the same bench against a server with no deadline
- **[P-23](P-23-the-refusal-path-has-no-deadline.md)** valid (round 272),
  rpc_dart_http — N slowloris sockets against a REJECTION exit, counting how many
  the server lets go inside a window. The control is one header: `application/grpc`
  reaches the guarded read, `text/plain` reaches the unguarded one
- **[P-22](P-22-body-that-never-arrives.md)** valid (round 271), rpc_dart_http and
  the responder pipeline — what a body that never arrives costs, reported as TWO
  budgets: the transport's `pendingRequests` and the pipeline's `openStreams`.
  The control is the ablation, not the completed-request arm, and the `abort`
  arm's 503 is a neighbouring limit
- **[P-21](P-21-metadata-escapes-the-byte-bound.md)** valid (round 245), core
  buffering — which dimension of a frame does the queue's byte bound see? The
  same 64 KiB as payload stops at 256 frames / 16 MiB, as metadata ran to 4096 /
  256 MiB. The unmoving payload arm is the control
- **[P-20](P-20-throwing-state-callback.md)** valid (round 242), core resilience —
  what a throwing user callback costs on the reconnect path. Counts what the
  throw PREVENTED as well as what it emitted: unhandled 1 and transports built 0
  against a control's 0 and 2
- **[P-19](P-19-sequential-reconnect-orphan-rate.md)** valid (round 241),
  rpc_dart_http2 — how often does a SEQUENTIAL reconnect orphan a connection?
  5 in 390 direct cycles, 0 in 90 through the stalling proxy, and it names WHICH
  of the three connections leaked, which is what separates this from the
  concurrent defect. Underpowered for judging a fix: read its last paragraph
- **[P-18](P-18-early-frames-through-the-proxy.md)** valid (round 240), core
  resilience and transports — do frames that arrived before the app subscribed
  survive a hop? Two controls, because one cannot tell "never existed" from
  "dropped here": 0 late through the proxy against 1 early through it and 1
  straight off the transport. Its first build measured nothing and says why
- **[P-17](P-17-retry-until-the-peer-returns.md)** valid (round 238), reconnect —
  does the recovery API work more than ONCE? Server down, four failed attempts,
  server back, a real call — twice. Records both ways it lied first: the rig
  closing its own client, and an ablation aimed at the wrong observable
- **[P-16](P-16-hpack-reference-flood.md)** valid (round 237), http2 headers —
  what does a header block cost once decoded? Attributes the decoder and the
  adapter separately: +7 MiB vs +258 MiB for the same 63 KiB block, with
  `distinct: 1` the number that refuted the first hypothesis
- **[P-15](P-15-pending-queue-dimension.md)** valid (round 236), core buffering —
  which dimension does the unlistened queue bound? Same pendingCount at three
  payload sizes while the retained bytes scale 64 -> 256 -> 1024 MiB; +549 vs
  +2 MiB through a real transport. Records the two RSS traps it was rebuilt for
- **[P-14](P-14-detach-with-a-throwing-cancel.md)** valid (round 235), core
  resilience — does a throwing `onCancel` on a user-supplied transport abandon
  it? One arm differs by that throw alone: leaked 0 vs 1, unhandled zone errors
  0 vs 1, and the reconnect that never happened
- **[P-13](P-13-ids-after-a-peer-started-reconnect.md)** valid (round 234), websocket
  and core reconnect — does the stream-id sequence survive a reconnect the PEER
  started? Two arms differing by one event: 1 then 3 when this side calls
  `reconnect()`, 1 then 1 when the socket dies first, and a dead call's
  half-close then ended a live one
- **[P-12](P-12-zero-grant-reads-as-legacy.md)** valid (round 229), core transports —
  is a zero grant read as a peer that does not participate? A FOREIGN peer driven
  at the channel level, which is the only way to reach the path: 800 KiB through
  a 64 KiB window against 20 KiB in the control
- **[P-11](P-11-connection-debt-with-a-paused-consumer.md)** valid (round 228), core transports —
  does the connection pool come back from a consumer that stops? Round 206's
  bench with a third arm; three controls reach 3072 KiB, the paused one wedges
  at the pool. Supersedes P-01, which is the same file before that arm
- **[P-10](P-10-parked-sender-learns.md)** valid (round 221), core transports —
  does a parked sender learn its call is over? Written in 210, registered in 221
  once an ablation showed it can see a credit hang
- **[P-09](P-09-watermark-survives-a-decorator.md)** valid (round 217), core resilience —
  does the stream-id watermark survive a user's decorator?
- **[P-08](P-08-refusal-survives-a-tight-cap.md)** valid (round 216), http2 and core —
  does a refusal survive the policy it just enforced?
- **[P-07](P-07-pre-method-budget-returns.md)** valid (round 215), core endpoint —
  does the pre-method byte budget come back?
- **[P-06](P-06-handler-slots-return.md)** valid (round 214), core endpoint —
  does a handler slot come back on every teardown path?
- **[P-05](P-05-slow-consumer-is-throttled.md)** valid (round 213),
  rpc_dart_http2 — a consumer that falls behind is failed; ACCEPTED behaviour,
  see [C-19](../checked/C-19-http2-refuses-a-slow-consumer.md)
- **[P-04](P-04-parked-waiters-drain.md)** stale (0d071c55), core transports —
  does an abandoned upload leave its sender parked?
- **[P-03](P-03-wrapper-keeps-the-bound.md)** stale (906437a2), rpc_dart_http2 —
  does a transport bound survive `RpcHttp2Server.transportWrapper`?
- **[P-02](P-02-http2-aborted-call-pool.md)** stale (1d5efdda), rpc_dart_http2 —
  does an http2 connection survive a cancelled stalled call?
- **[P-01](P-01-connection-window-debt.md)** stale (c48a14d8), core transports —
  how much a sender gets out before the connection pool wedges
