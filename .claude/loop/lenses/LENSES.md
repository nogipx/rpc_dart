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

## Productive lately

- **[RPC-01](RPC-01-flow-control-credit-on-skip.md)** confirmed (213) — credit is not returned for a frame nobody consumes, per level and per layer; refines U-07
- **[RPC-04](RPC-04-capability-hidden-by-wrapper.md)** confirmed (209) — a capability is dropped by a wrapper, or routed to one that cannot honour it; refines U-05
- **[RPC-03](RPC-03-stream-ids-restart-on-reconnect.md)** confirmed (217) — stream ids restart after a reconnect; every swap site carries the watermark, but a decorator can erase it (B-17); refines U-18
- **[RPC-15](RPC-15-remeasure-own-record.md)** confirmed (211) — re-measure the loop's own record, including what it claims its own FIXES are worth; refines U-21

## Swept and fresh

- **[RPC-14](RPC-14-timeout-abandons-work.md)** swept here (223) — a timeout drops the wait but not the work; the isolate exception (B-04) swept and closed, all four sites guarded, none witnessed (L-04); refines U-17
- **[RPC-13](RPC-13-unhandled-async-error.md)** swept here (222) — an abandoned future running user code kills the isolate; ~85 sites, all guarded, but the load-bearing guard has no witness (B-20); refines U-17
- **[RPC-09](RPC-09-deadline-below-write.md)** swept here (221) — the deadline sits below a blocking write; the answer path is independent of the send, demonstrated by ablation, so it cannot arise; refines U-16
- **[RPC-02](RPC-02-refusal-trailer-violates-policy.md)** swept here (216) — the refusal trailer fails the policy it enforced; only trailers crossing a validating hop are at risk; refines U-09
- **[RPC-05](RPC-05-concurrency-limit-charge-point.md)** swept here (215) — a limit is charged, or released, at the wrong point of the lifecycle; every stateful field swept; refines U-07
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
