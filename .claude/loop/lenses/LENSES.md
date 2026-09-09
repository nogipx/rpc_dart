# Lens set — rpc_dart

What a lens is and how it links to the rest — [../LOOP.md](../LOOP.md). The
field format — `../../skills/improvement-loop/specs/lens.md`.

- **[RPC-01](RPC-01-flow-control-credit-on-skip.md)** confirmed (208) — credit is not returned for a frame nobody consumes, per level and per layer; refines U-07
- **[RPC-02](RPC-02-refusal-trailer-violates-policy.md)** swept here (216) — the refusal trailer fails the policy it enforced; only trailers crossing a validating hop are at risk; refines U-09
- **[RPC-03](RPC-03-stream-ids-restart-on-reconnect.md)** confirmed (217) — stream ids restart after a reconnect; every swap site carries the watermark, but a decorator can erase it (B-17); refines U-18
- **[RPC-04](RPC-04-capability-hidden-by-wrapper.md)** confirmed (209) — a capability is dropped by a wrapper, or routed to one that cannot honour it; refines U-05
- **[RPC-05](RPC-05-concurrency-limit-charge-point.md)** swept here (215) — a limit is charged, or released, at the wrong point of the lifecycle; every stateful field swept; refines U-07
- **[RPC-06](RPC-06-native-plugin-layers.md)** confirmed (180, off-journal) — a defect in Swift or Kotlin, where Dart greps never look; refines U-14, U-03
- **[RPC-07](RPC-07-web-as-separate-runtime.md)** confirmed (090, off-journal) — green on the VM, broken on dart2js; refines U-03
- **[RPC-08](RPC-08-policy-field-single-transport.md)** confirmed (119, off-journal), applied in 205 — a policy field inert at a neighbouring transport; refines U-19
- **[RPC-09](RPC-09-deadline-below-write.md)** swept here (210) — the deadline sits below a blocking write; the answer path is independent of the send, so it cannot arise; refines U-16
- **[RPC-10](RPC-10-shared-layer-blast-radius.md)** confirmed (150, off-journal) — a shared-layer fix's blast radius is overstated; refines U-11
- **[RPC-11](RPC-11-package-outside-workspace.md)** confirmed (186, off-journal) — a package outside the workspace is invisible to the gate; refines U-03
- **[RPC-12](RPC-12-cancel-into-request-stream.md)** retracted (204), applied in 202, 203, 204 — a contract mistaken twice for a defect
- **[RPC-13](RPC-13-unhandled-async-error.md)** swept here (121, off-journal) — an abandoned future running user code kills the isolate; refines U-17
- **[RPC-14](RPC-14-timeout-abandons-work.md)** swept here (067, off-journal), except isolate — a timeout drops the wait but not the work; refines U-17
- **[RPC-15](RPC-15-remeasure-own-record.md)** confirmed (211) — re-measure the loop's own record, including what it claims its own FIXES are worth; refines U-21

Sweeps marked «off-journal» have nothing to age against: `stale` always shows
them as needing a re-measurement. That is correct — the code has changed since,
and the sha of that sweep is unknown.
