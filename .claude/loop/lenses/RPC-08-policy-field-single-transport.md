---
refines: U-19
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: policy fields are enforced by each transport separately
breaks: a security hole on the transport nobody picked.
applied: [205, 394, 414, 501, 504, 517, 518, 523, 524, 525, 540, 542, 543, 544, 545, 546, 547, 548, 553, 554, 556, 560, 563, 566, 567, 569, 571, 581, 584, 602, 613, 635, 745, 749, 750, 754, 755]
status: confirmed (round 754)
rank: 25
---

# RPC-08 — A policy field checked on one transport

## Shape

A new `RpcSecurityPolicy` field is enforced where it was written and inert at
its neighbours. The neighbours need not be transports: any N places that make
the same KIND of decision are siblings.

## Detector

The matrix «policy field x transport package»; for each cell, a behavioural
probe, not a grep for a mention. Widen it past policy fields to CAPABILITIES —
this repo has three servers, three caller transports and three responder
transports filling the same roles, so one battery run against all of them gives
a built-in control and there is no arguing about what "correct" means.

Two shapes, and both pay:

1. *One sibling has X, the other does not* → the gap is a defect.
2. *NEITHER has X, but the protocol or ecosystem expects it* → a missing
   feature. Graceful shutdown came from asking what gRPC servers have that these
   did not: neither drained on `stop()`, so a rolling deploy dropped every
   in-flight call.

> **OWNER'S QUALIFIER (round 101): match BEHAVIOUR, not code, and across every
> transport EXCEPT `rpc_dart_http`.** Transport-specific implementations are
> expected; do NOT force a shared abstraction because two siblings look
> asymmetric in source. http2 in particular follows its own specification and
> rpc_dart does not control both ends of it, so its code will diverge. What must
> match is the behaviour of the finished system, and what must never differ is
> leaks or security holes. `rpc_dart_http` is unary-only, so the streaming shapes
> do not exist there at all — the four streaming-capable transports (http2,
> websocket, isolate, wasm) are the set that must behave identically. **Treat a
> code-shape difference as a lead, not as a defect in itself.**

**Batteries worth running:** an in-flight call when the peer dies; a call after
close; an unregistered method; an oversized message; `close()` twice; `isClosed`
versus `health()` agreement. Every sibling battery must include a streaming
shape. When a transport has a VM and a WEB implementation of the same API, diff
those two as siblings as well. A census of who reads each field
(dart-runner `find_references`, `scope: lib`) says where to aim a probe; it is
not the probe.

To read what an http2 server actually advertises: raw socket, send the preface
plus an empty SETTINGS frame, decode the server's SETTINGS at the byte level —
package:http2 exposes no accessor. Kept as `advertised_stream_limit_test.dart`
and `.dart_tool/probe/advertised_settings.dart`.

## Ask

Is the field MENTIONED or ENFORCED? Does the refusal name that very field? And
for a capability: when one sibling is EXEMPTED from a shared safeguard because
it "has its own", does the substitute actually run? *The exemption is a comment,
not evidence* — http2 set the rpc-level window to null on the grounds that
HTTP/2 has native flow control, so every generic test of the rpc-level window
passed while the native one was bypassed at two hops.

Also: which of the pair CHECKS and which only documents? What is left to a
DEPENDENCY's default? Who is the victim?

## Evidence

Checking that "the field is mentioned somewhere" gave full coverage, while a
behavioural probe found a whole transport where it was inert. The capability
axis, imported after round 234, is the productive one once defect-hunting goes
barren (three rounds running, 80, 81, 82). Clean results from the battery are in
`../checked/C-28-sibling-batteries-that-came-back-clean.md`.

- **Round 39** — peer death: websocket was FATAL (a call reached the closed inner transport, status 14 into the root zone, isolate killed); http2 LIED, `health()` saying "transport ready" with the server gone.
- **Round 51** — isolate: the VM half was clean, the WEB half had no `worker.onerror` wiring (ef43ee29), so a 404'd worker gave a healthy transport after 10 s with every call hanging. The web implementation is where a platform's death signal is easy to forget; an accepted-but-unused parameter (`startupTimeout`, waits hard-coded to 5 s with `onTimeout: () {}`) is worth grepping for on sight.
- **Round 80** — websocket got server-side keepalive in round 63 and http2 had the same hole: endpoints 5, contracts disposed 0 at t+30s, against 0/5 by t+5s with `pingInterval`. Truncated-stream battery in the same sweep: http2 ended a stream with `errors=[] done=true`, silent data loss; unary hid it because core's unary caller already treats "closed without a response" as an error.
- **Round 92** — slow-reader battery: websocket +1023 items flat, http2 +33906 (132.4 MiB) climbing; no response-direction backpressure (2a0476ef). Probe traps: `HttpServer.close(force: true)` does not kill upgraded WebSockets; `close(force: false)` is not a drain (caller HUNG 20 s). **Measure the observable the user experiences, not the API you changed.**
- **Round 139** — http2 called `ServerTransportConnection.viaStreams` with no `ServerSettings`, so it advertised MAX_CONCURRENT_STREAMS 1000 whatever `maxActiveStreams` said (06328514). **Not passing a setting is not neutral; the dependency's opinion silently overrides the library's.** The fix raised the effective ceiling 1000 -> 4096 (~33 MB -> ~136 MB per connection at the ~33 KiB/stream of `../checked/C-29-the-real-scope-of-the-stream-limits.md`).
- **Round 205** — channel transports: peaks of 30/3/1 against the ceilings with a no-ceiling control, and 20 half-open streams reclaimed to 0 in 3 s.
- **Round 501** — two interceptors classifying errors: `RpcRetryInterceptor`'s predicate was chosen, `RpcCircuitBreakerInterceptor`'s was the `failureOn == null ||` fallthrough. **Read side by side, one of the two never had the decision made; if one is argued for and the other is a fallthrough, the fallthrough is the finding.** Do not finish by copying the sibling: the breaker's fix is deliberately wider. `../probes/P-139-which-errors-open-the-breaker.md`
- **Round 504** — `rpcMethodPathFromKey` splits on the last dot and its doc says a method name may not contain one; `parseRpcMethodPath` admitted dots in both halves, so two pairs produced one key. **Ask which of the pair actually CHECKS; a precondition stated in the doc of the function that relies on it is enforced nowhere.** A round-trip test cannot find this; injectivity (two inputs that must map apart) can. The lens has paid on three unrelated kinds of pair, worth a curate pass on whether it wants its own lens. `../probes/P-142-which-paths-reach-one-method.md`, `../rounds/504-the-invariant-only-the-doc-enforced.md`, B-113.
- **Round 517** — B-125 claimed the three request-metadata builders drifted; read on the wire, they agreed. **A negative that arrives too easily deserves a second look:** the first rig's identical rows were all `x-rpc-conn-window-update`; the control is a dimension that MUST differ (`grpc-timeout`). Separate a lead's argument from its evidence: the refactor becomes the owner's preference. `../probes/P-154-do-the-three-header-builders-agree.md`, `../rounds/517-the-drift-that-had-not-happened.md`, `../checked/C-59`, B-125.
- **Round 518** — against a channel splitting every frame, `unary status 13` while both streaming shapes answered in the same run. **A sibling that TOLERATES something shows how to fix the one that does not; when a defect spans layers, a fix to one can be a regression** (INTERNAL became a hang via `preBindMessages.first` and `_cleanupStream`), so revert. Documenting an INVARIANT instead, as round 507 did on `IRpcChannel.incoming`, is the owner's call. `../probes/P-155-does-unary-survive-a-fragmented-frame.md`, `../rounds/518-the-fix-that-turned-an-error-into-a-hang.md`, B-126.
- **Round 523** — `maxMetadataBytes` was never totalled: `64 headers x 8192 B = 524818 B` accepted, 8x the limit, the 128-header row refused by COUNT; channel transports were covered by `RpcChannelFrame._decodeAt`, the HTTP ones not. **Check WHICH field produced a refusal, not just that one occurred; and the control has to be the thing that DOES work** (one oversized header refused). Do two layers bounding "the same" quantity count the same bytes? (Round 520 found the same confusion in `maxActiveStreams`.) `../probes/P-159-is-metadata-bounded-in-total.md`, `../rounds/523-the-knob-that-is-off-by-sixteen.md`, B-197, B-129.
- **Round 524** — fix: a running total inside the header loop, refused at 64 KiB before all is resident (the accepted-versus-retained distinction of round 506). **For a fix that TIGHTENS a limit, the guards are the whole review:** within-limit passes, single oversized header refused for its own reason, too many headers refused by count, a larger configured limit admits more. `../rounds/524-the-sum-nobody-was-taking.md`.
- **Round 525** — a hardcoded 128 in `forClientRequest` against the policy's 1024: names of 129 to ~1018 chars are routable and uncallable. **Measure the band, not either end; the control is an input past BOTH limits plus short inputs where both pass.** Say when a sibling fix is not a one-liner (a static with no policy in scope) and ask what the constant was meant to be first. `../probes/P-160-is-a-routable-name-callable.md`, `../rounds/525-routable-and-uncallable.md`, B-198.
- **Round 553** — unary could not take a gRPC frame split across messages; two attempts reverted. **A divergence two rounds failed to close is usually blocked on a QUESTION, not on work:** `RpcMessageParser` returning nothing meant both incomplete and refused; one getter on the parser's buffer separated them. **Ask the component that KNOWS, not the convenient one; and a canary that PASSES can be a design finding** (three answer sites racing). `../rounds/553-the-parser-knew-all-along.md`, `../probes/P-181-which-branch-took-the-fragment.md`, B-126.
- **Round 554** — the other two shapes still diverged (`server stream status 4`, `client stream got:0`). **When N shapes disagree, put the rule in the one component they all run through** (`StreamProcessor`); a rule at one layer must cover every way that layer is ENTERED; a witness covering two shapes in one test can only show one failure. `../rounds/554-one-rule-where-the-parser-is.md`, B-216, B-218.
- **Round 556** — five transports' `rpc_dart` floors: seven of eight swept core symbols (e.g. `IRpcReconnectableTransport`) are in no published core (`rpc_dart-6.3.0`). **A green gate is no evidence for a property that binds only outside the workspace; read the published artefact (`git show <tag>`).** **Check who the victim is before grading severity** — the owner's answer here was that nobody but they consume these packages, which drops the finding to near zero. `bump:rpc_dart` on all 20 where 9 were proven widened the change past its measurement. `../rounds/556-no-published-core-satisfies-any-floor.md`, B-154.
- **Round 560** — a start guard assigned after the bind's await, in both HTTP servers: http bound and answering status 14 behind `isRunning=true`, http2 serving behind `isRunning=false` with the port leaked by `stop()`. **The same cause can produce opposite symptoms, so sweep by SHAPE, not symptom;** when a teardown releases an OS resource, the witness has to ask the OS; a claim flag has three release points (failure, teardown, never on success). `../rounds/560-the-guard-was-behind-the-await.md`, `../probes/P-184-a-start-guard-behind-its-own-await.md`, B-151.
- **Round 563** — `_proxyHandshakeTimeout` bounded the CONNECT response, not the socket connect or TLS: black-holed with the bound off was STILL PENDING at 8 s, 1730 ms with it. **A field whose doc names a risk shows somebody saw it, not that they covered it; `timeout:` and `.timeout()` are not the same fix (the wrapper leaks the socket); a default longer than the probe is indistinguishable from none.** `../rounds/563-the-bound-the-comment-described-and-did-not-provide.md`, `../probes/P-186-what-bounds-a-connect-into-a-hole.md`, B-182.
- **Round 584** — round 394 widened the neighbour to a CONSTRUCTION PATH; here `RpcHttpResponderTransport`'s checks sit behind `if (policy != null)` and its own example omits the policy, while `RpcHttpServer` defaults it: 413 / RSS +37 MiB with the policy, 200 / +524 MiB omitted. **A policy OFF by default is inert in exactly this lens's way; an explicit `null` is not the same arm as an omitted parameter; and the fix for a default is often a sentence the sibling already wrote.** `../rounds/584-the-documented-setup-was-the-unsafe-one.md`, `../probes/P-204-what-the-documented-shelf-setup-admits.md`, B-150, B-223.
- **Round 745** — the census by `find_references`: all 18 fields across core, http and http2 in one table, every empty cell explained; the one behavioural split, `closeOnProtocolError` not honoured by the http2 caller, is on purpose. `../rounds/745-the-policy-matrix-from-the-analyzer.md`.
- **Round 754** — websocket's `connectTimeout` covers the upgrade (round 361), http2's stopped at TCP/TLS: a peer that never sends SETTINGS left a call waiting at 8 s and `health` healthy; after, 14 / 2009 ms with a 2 s bound. **Ask what the protocol's own handshake is, not only the socket's.** `../rounds/754-a-silent-h2-peer-reads-online.md`, `../probes/P-259-a-peer-that-never-sends-settings.md`, B-269.
- **Round 755** — the same peer against websocket: the bound covered the upgrade but defaulted to null (http2's is 30 s), so `RpcClientConnection` sat in Connecting; now 30 s, null still opts out. **Compare the siblings' defaults, not only their parameters** — the shape of round 584 in a second package. `../rounds/755-websocket-connect-had-no-default-bound.md`.
