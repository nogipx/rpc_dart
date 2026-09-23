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
