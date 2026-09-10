# Lens set — rpc_dart

What a lens is and how it links to the rest — [../LOOP.md](../LOOP.md). The
field format — `../../skills/improvement-loop/specs/lens.md`.

**The order below is the rank**, re-derived in the curate pass after round 220:
a sweep whose paths have moved comes first (it is due a re-measurement), then
the ones that have produced findings recently, then the rest. A lens is never
deleted — no findings is a result too, and a deleted lens gets reinvented.

## Due a re-measurement

Empty as of round 223 — the queue is drained. Every lens below has either been
swept against a known sha or is on the "nobody has taken these" list with a
reason. The next `curate` decides what ages back in.

## Imported from private memory, never applied here — take these first

Added in the curate pass after round 234, which measured the actual seam between
the two corpora: `checked/` had imported the pre-201 NEGATIVES (C-02 round 46,
C-04 round 106 and the rest), but the pre-201 defect SHAPES had no lens, so
`loop.py next` could not route to them and `stale` could not age them. Greps for
their own numbers returned nothing in the loop: `CONTINUATION`, `756 MiB`,
`check before await`, `pre-ready`, all zero hits.

- **[RPC-20](RPC-20-the-window-before-the-first-listener.md)** confirmed (round 240) — a broadcast controller discards what the peer sent before the first `listen()`, and it fails OPEN because the loss reads as "the peer does not support this". 200/200 chunks against an 8 KiB window, 8/200 after. Round 240 found it one hop up, where a wrapper DRAINS a buffered controller into an unlistened one: 0 frames against 1
- **[RPC-21](RPC-21-drive-the-lifecycle-twice.md)** confirmed (round 241) — call every lifecycle API a second time, and once after a failure: four defects in four rounds, none visible to a green suite. Round 241 added a fifth by driving reconnect twice and counting the SERVER's connections — 1.3% orphan rate, B-25. The lens C-06 had been asking for; refines U-15

## Productive lately

- **[RPC-22](RPC-22-the-refusal-path-is-reachable-by-anyone.md)** confirmed (272) — every guard on the accepted path has to be asked of the REFUSAL path separately, because that is the path anyone reaches without a valid content-type, method or credential. `_reject` drained the body with no deadline and before any counter existed: 16 of 16 slowloris sockets answered on the accepted path, 0 of 16 on the refused one, `pendingRequests` reading 0 in both; refines U-08, in the other direction from the catalog's wording
- **[RPC-18](RPC-18-dependency-buffers-below-your-limits.md)** confirmed (237) — the dependency reassembles the wire before anything becomes a message, so every ceiling you set is blind to it: 64 MiB of CONTINUATION frames starved every other client. Round 237 found the INVERSE as well — the dependency shares cheaply and the adapter above materialises, 63 KiB into 258 MiB
- **[RPC-17](RPC-17-limit-fires-after-residency.md)** confirmed (236) — the limit exists but measures the wrong thing, or runs too late. Two clauses: WHEN it fires (192 MiB body into 756 MiB RSS; 2071x through permessage-deflate) and WHAT it counts — round 236 found a queue bounded by event COUNT while the damage is bytes, 4096 x 16 MiB admitted. No catalog shape covers it
- **[RPC-16](RPC-16-check-before-await.md)** confirmed (235) — a lifecycle flag read before an await and never re-read, and the failure path that drops rather than closes. Round 235 swept its 15 sites and found a fifth instance: one unguarded cancel between two guarded closes; refines U-07
- **[RPC-01](RPC-01-flow-control-credit-on-skip.md)** confirmed (213) — credit is not returned for a frame nobody consumes, per level and per layer; refines U-07
- **[RPC-04](RPC-04-capability-hidden-by-wrapper.md)** confirmed (209) — a capability is dropped by a wrapper, or routed to one that cannot honour it; refines U-05
- **[RPC-03](RPC-03-stream-ids-restart-on-reconnect.md)** confirmed (234) — stream ids restart after a reconnect; every swap site carries the watermark, but a decorator can erase it (B-17) and a peer-started drop rewound it before it could be read (234); refines U-18
- **[RPC-15](RPC-15-remeasure-own-record.md)** confirmed (211) — re-measure the loop's own record, including what it claims its own FIXES are worth; refines U-21

## Swept and fresh

- **[RPC-19](RPC-19-one-flag-two-lifecycle-meanings.md)** swept here (238) — one boolean meaning both "the caller closed us" and "the connection is gone"; no third instance, because a flag conflates two meanings only where two exist. The give-away is a recovery API that works exactly once; refines U-18

- **[RPC-14](RPC-14-timeout-abandons-work.md)** swept here (246) — a timeout drops the wait but not the work; the isolate exception (B-04) swept and closed, all four sites guarded, none witnessed (L-04). Re-swept at 246 over the diff since 223: no new timeout sites at all; refines U-17
- **[RPC-13](RPC-13-unhandled-async-error.md)** confirmed (round 242) — an abandoned future running user code kills the isolate; ~85 sites guarded at 222, and the re-sweep at 242 found the thrower rather than the site: a user `onStateChanged` inside an unhandled `.then()`, unhandled 1 -> 0 and transports built 0 -> 2. The load-bearing guard still has no witness (B-20); refines U-17
- **[RPC-09](RPC-09-deadline-below-write.md)** swept here (244) — the deadline sits below a blocking write; the answer path is independent of the send, demonstrated by ablation, so it cannot arise. Re-swept over 6 moved files: the one parking site still has all three wake paths, close() among them; refines U-16
- **[RPC-02](RPC-02-refusal-trailer-violates-policy.md)** swept here (243) — the refusal trailer fails the policy it enforced; only trailers crossing a validating hop are at risk. Re-swept over 10 moved files: 12 of 12 message-carrying sites capped, including the two refusal paths added since; refines U-09
- **[RPC-05](RPC-05-concurrency-limit-charge-point.md)** confirmed (round 271) — a limit is charged, or released, at the wrong point of the lifecycle; every stateful policy field swept at 215. Round 245 asked WHAT a limit charges instead of where, and found metadata weighing zero against the buffer's byte bound: 256 MiB against a 16 MiB cap. Round 271 asked WHO ELSE was charged: the HTTP/1.1 responder discharged its own budget on a failed body read and left the pipeline's parked for 60 s; refines U-07
- **[RPC-11](RPC-11-package-outside-workspace.md)** confirmed (220) — a package outside the workspace is invisible to the gate; wasm's Dart is analysed and formatted by nothing, clean anyway; refines U-03
- **[RPC-07](RPC-07-web-as-separate-runtime.md)** confirmed (219) — green on the VM, broken on dart2js; the gate is a census, nine of twelve packages get a build-and-construct check (B-18); refines U-03
- **[RPC-08](RPC-08-policy-field-single-transport.md)** confirmed (119, off-journal), applied in 205 — a policy field inert at a neighbouring transport; refines U-19

## Nobody has taken these, and why

- **[RPC-06](RPC-06-native-plugin-layers.md)** confirmed (180, off-journal), `applied: []` — a defect in Swift or Kotlin, where Dart greps never look; refines U-14, U-03.
  **Not taken because it needs toolchains this environment may not have**: `analyze:native` wants Xcode for the Swift half and a kotlinc plus an Android SDK for the Kotlin half, and `test:wasm:device` wants a booted simulator or emulator. `analyze:native` exits 2 when nothing was checked, so a run that verifies nothing cannot read as a pass — which is right, and also why the lens cannot be closed by running it blind.
- **[RPC-10](RPC-10-shared-layer-blast-radius.md)** confirmed (150, off-journal), `applied: []` — a shared-layer fix's blast radius is overstated; refines U-11.
  **Not taken because it is methodological**: its damage is a wrong claim in a commit message rather than a defect in the code, so it sits below the severity bar the config sets from round 191 on. Worth applying if the bar is ever lowered, or as part of a `curate`.

## Retracted

- **[RPC-12](RPC-12-cancel-into-request-stream.md)** retracted (204), applied in 202, 203, 204 — a contract mistaken twice for a defect

Sweeps marked «off-journal» have nothing to age against: `stale` always shows
them as needing a re-measurement. That is correct — the code has changed since,
and the sha of that sweep is unknown.
