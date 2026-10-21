---
refines: U-19
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: policy fields are enforced by each transport separately
breaks: a security hole on the transport nobody picked.
applied: [205, 394, 414, 501, 504, 517, 518, 523, 524, 525, 540, 542, 543, 544, 545, 546, 547, 548, 553, 554, 556, 560, 563, 566, 567, 569, 571, 581, 584, 602, 613, 635, 745, 749, 750, 754, 755, 770, 772, 776, 801, 900]
status: confirmed (round 801)
rank: 25
---

# RPC-08 — A policy field checked on one transport

## Shape

A new `RpcSecurityPolicy` field is enforced where it was written and inert at
its neighbours. The neighbours need not be transports: any N places that make
the same KIND of decision are siblings.

## Detector

The matrix «policy field x transport package»; per cell, a behavioural probe,
not a grep for a mention. Widen it past policy fields to CAPABILITIES: three
servers, three caller transports and three responder transports fill the same
roles, so one battery run against all of them is its own control.

Two shapes, and both pay:

1. *One sibling has X, the other does not* → the gap is a defect.
2. *NEITHER has X, but the protocol or ecosystem expects it* → a missing
   feature. Graceful shutdown came from asking what gRPC servers have: neither
   drained on `stop()`, so a rolling deploy dropped every in-flight call.

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

**Batteries:** an in-flight call when the peer dies; a call after close; an
unregistered method; an oversized message; `close()` twice; `isClosed` versus
`health()` agreement. Each includes a streaming shape. A VM and a WEB
implementation of one API are siblings too. A census of who reads each field
(dart-runner `find_references`, `scope: lib`) aims a probe; it is not the probe.

http2's advertised SETTINGS: raw socket, send the preface plus an empty SETTINGS
frame, decode the reply by bytes (package:http2 has no accessor). Kept as
`advertised_stream_limit_test.dart` and `.dart_tool/probe/advertised_settings.dart`.

## Ask

Is the field MENTIONED or ENFORCED? Does the refusal name that very field? When
a sibling is EXEMPTED from a shared safeguard because it "has its own", does the
substitute run? *The exemption is a comment, not evidence* — http2 set the
rpc-level window to null because HTTP/2 has native flow control, so every
generic test passed while the native one was bypassed at two hops.

Also: which of the pair CHECKS and which only documents? What is left to a
DEPENDENCY's default? Who is the victim?

## Evidence

"Mentioned somewhere" gave full coverage; a behavioural probe found a whole
transport where the field was inert. The capability axis, imported after round
234, pays once defect-hunting goes barren (rounds 80, 81, 82). Clean battery
results: `../checked/C-28-sibling-batteries-that-came-back-clean.md`.

- **Round 39** — peer death: websocket FATAL (call hit the closed inner transport, status 14 into the root zone, isolate killed); http2 LIED, `health()` "transport ready" with the server gone.
- **Round 51** — isolate's WEB half lacked `worker.onerror` (ef43ee29): a 404'd worker read healthy after 10 s, every call hanging; VM half clean. Grep for accepted-but-unused parameters (`startupTimeout`; waits hard-coded to 5 s with `onTimeout: () {}`).
- **Round 80** — http2 lacked the server keepalive websocket got in round 63: endpoints 5, contracts disposed 0 at t+30s, against 0/5 by t+5s with `pingInterval`. Truncated stream: http2 ended `errors=[] done=true`, silent loss; unary hid it as core treats "closed without a response" as an error.
- **Round 92** — slow reader: websocket +1023 items flat, http2 +33906 (132.4 MiB) climbing; no response backpressure (2a0476ef). `HttpServer.close(force: true)` leaves upgraded WebSockets; `close(force: false)` is not a drain (caller HUNG 20 s). **Measure what the user observes, not the API you changed.**
- **Round 139** — http2's `ServerTransportConnection.viaStreams` got no `ServerSettings`: MAX_CONCURRENT_STREAMS 1000 whatever `maxActiveStreams` said (06328514). **Not passing a setting lets the dependency's default win.** Fix: ceiling 1000 -> 4096 (~33 MB -> ~136 MB per connection at ~33 KiB/stream, `../checked/C-29-the-real-scope-of-the-stream-limits.md`).
- **Round 205** — channel transports: peaks 30/3/1 against the ceilings with a no-ceiling control; 20 half-open streams reclaimed to 0 in 3 s.
- **Round 501** — `RpcRetryInterceptor`'s error predicate was chosen, `RpcCircuitBreakerInterceptor`'s was the `failureOn == null ||` fallthrough. **Of a pair, the fallthrough is the finding.** Do not copy the sibling: the breaker's fix is deliberately wider. `../probes/P-139-which-errors-open-the-breaker.md`
- **Round 504** — `rpcMethodPathFromKey` splits on the last dot (its doc forbids dotted method names); `parseRpcMethodPath` admitted dots, so two pairs gave one key. **Ask which of the pair CHECKS; a precondition only in a doc is enforced nowhere.** Injectivity finds it, round-trips cannot. Paid on three kinds of pair; a curate pass may split it out. `../probes/P-142-which-paths-reach-one-method.md`, `../rounds/504-the-invariant-only-the-doc-enforced.md`, B-113.
- **Round 517** — B-125's drift of the three request-metadata builders was absent on the wire. **Recheck an easy negative:** the first rig's identical rows were all `x-rpc-conn-window-update`; the control must differ (`grpc-timeout`). The refactor becomes the owner's preference. `../probes/P-154-do-the-three-header-builders-agree.md`, `../rounds/517-the-drift-that-had-not-happened.md`, `../checked/C-59`, B-125.
- **Round 518** — a channel splitting every frame: `unary status 13`, streaming answered. **The tolerant sibling shows the fix; across layers a fix can regress** (INTERNAL became a hang via `preBindMessages.first` and `_cleanupStream`); reverted. Documenting an INVARIANT, as round 507 did on `IRpcChannel.incoming`, is the owner's call. `../probes/P-155-does-unary-survive-a-fragmented-frame.md`, `../rounds/518-the-fix-that-turned-an-error-into-a-hang.md`, B-126.
- **Round 523** — `maxMetadataBytes` never totalled: `64 headers x 8192 B = 524818 B` accepted, 8x the limit; 128 refused by COUNT. `RpcChannelFrame._decodeAt` covered channels, not HTTP. **Check WHICH field refused; the control is what DOES work** (one oversized header). Do two layers count the same bytes? (Round 520: `maxActiveStreams`.) `../probes/P-159-is-metadata-bounded-in-total.md`, `../rounds/523-the-knob-that-is-off-by-sixteen.md`, B-197, B-129.
- **Round 524** — fix: a running total in the header loop, refused at 64 KiB before all is resident (round 506's accepted-versus-retained). **For a TIGHTENED limit the guards are the review:** within-limit passes, one oversized header refused for its own reason, too many by count, a larger limit admits more. `../rounds/524-the-sum-nobody-was-taking.md`.
- **Round 525** — `forClientRequest` hardcoded 128 against the policy's 1024: names of 129 to ~1018 chars routable but uncallable. **Measure the band; control past BOTH limits plus short inputs.** Say when a sibling fix is not a one-liner (a static, no policy in scope); ask what the constant meant first. `../probes/P-160-is-a-routable-name-callable.md`, `../rounds/525-routable-and-uncallable.md`, B-198.
- **Round 553** — unary rejected a gRPC frame split across messages; two attempts reverted. `RpcMessageParser`'s empty result meant incomplete or refused; one buffer getter split them. **A divergence two rounds failed to close waits on a QUESTION; ask the component that KNOWS. A PASSING canary can be a design finding** (three answer sites racing). `../rounds/553-the-parser-knew-all-along.md`, `../probes/P-181-which-branch-took-the-fragment.md`, B-126.
- **Round 554** — the other shapes still diverged (`server stream status 4`, `client stream got:0`). **Put the rule in the one component all N shapes pass** (`StreamProcessor`), on every entry path; one test per shape, since a shared one shows one failure. `../rounds/554-one-rule-where-the-parser-is.md`, B-216, B-218.
- **Round 556** — seven of eight core symbols in five transports' `rpc_dart` floors (e.g. `IRpcReconnectableTransport`) are in no published core (`rpc_dart-6.3.0`). **A green gate proves nothing outside the workspace; read the artefact (`git show <tag>`). Check the victim:** the owner is the only consumer, so near zero. `bump:rpc_dart` on 20 where 9 were proven over-reached. `../rounds/556-no-published-core-satisfies-any-floor.md`, B-154.
- **Round 560** — both HTTP servers set the start guard after the bind's await: http answered status 14 behind `isRunning=true`; http2 served behind `isRunning=false`, port leaked by `stop()`. **One cause, opposite symptoms: sweep by SHAPE;** ask the OS about OS resources; a claim flag releases on failure and teardown, never on success. `../rounds/560-the-guard-was-behind-the-await.md`, `../probes/P-184-a-start-guard-behind-its-own-await.md`, B-151.
- **Round 563** — `_proxyHandshakeTimeout` bounded the CONNECT response, not socket connect or TLS: black-holed, STILL PENDING at 8 s unbounded, 1730 ms bounded. **A doc naming a risk is not coverage; `timeout:` is not `.timeout()` (that leaks the socket); a default longer than the probe equals none.** `../rounds/563-the-bound-the-comment-described-and-did-not-provide.md`, `../probes/P-186-what-bounds-a-connect-into-a-hole.md`, B-182.
- **Round 584** — round 394 made a CONSTRUCTION PATH a sibling. `RpcHttpResponderTransport` checks behind `if (policy != null)` and its example omits it; `RpcHttpServer` defaults it: 413 / RSS +37 MiB with, 200 / +524 MiB without. **A policy OFF by default is inert; explicit `null` is not omission; the sibling often wrote the fix.** `../rounds/584-the-documented-setup-was-the-unsafe-one.md`, `../probes/P-204-what-the-documented-shelf-setup-admits.md`, B-150, B-223.
- **Round 745** — `find_references` census: 18 fields across core, http, http2, every empty cell explained; `closeOnProtocolError` unhonoured by the http2 caller on purpose. `../rounds/745-the-policy-matrix-from-the-analyzer.md`.
- **Round 754** — websocket's `connectTimeout` covers the upgrade (round 361), http2's stopped at TCP/TLS: a peer never sending SETTINGS left a call waiting at 8 s, `health` healthy; after, 14 / 2009 ms with a 2 s bound. **Bound the protocol's handshake, not only the socket's.** `../rounds/754-a-silent-h2-peer-reads-online.md`, `../probes/P-259-a-peer-that-never-sends-settings.md`, B-269.
- **Round 755** — same peer, websocket: the bound defaulted to null (http2's 30 s), so `RpcClientConnection` sat in Connecting; now 30 s, null opts out. **Compare siblings' defaults, not only parameters** (round 584's shape again). `../rounds/755-websocket-connect-had-no-default-bound.md`.
- **Round 801** — the caller pipeline set `grpc-accept-encoding` behind `!supportsZeroCopy`, so `compressionEnabled` was ignored on isolate and the memory pair: default `identity,gzip` gzipped every codec response (630 against 460 ms, 4000 x 16 KiB). Found via the matrix's I-3 cell, whose premise (no byte pacing) was wrong. **A capability flag gating a SETTING makes it a sibling axis.** `../rounds/801-a-zero-copy-caller-offered-gzip-it-never-enabled.md`.
