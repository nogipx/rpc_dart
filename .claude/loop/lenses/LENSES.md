# Lens set — rpc_dart

What a lens is and how it links to the rest — [../LOOP.md](../LOOP.md). The
field format — `../../skills/improvement-loop/specs/lens.md`.

- **[RPC-01](RPC-01-flow-control-credit-on-skip.md)** confirmed (162, off-journal) — credit is not returned on the frame-skip path; refines U-07
- **[RPC-02](RPC-02-refusal-trailer-violates-policy.md)** confirmed (153, off-journal) — the refusal trailer fails the policy it enforced; refines U-09
- **[RPC-03](RPC-03-stream-ids-restart-on-reconnect.md)** confirmed (100, off-journal) — stream ids restart after a reconnect; refines U-18
- **[RPC-04](RPC-04-capability-hidden-by-wrapper.md)** confirmed (094, off-journal) — a wrapper does not forward a capability interface; refines U-05
- **[RPC-05](RPC-05-concurrency-limit-charge-point.md)** confirmed (114, off-journal) — a limit is charged at the wrong point of the lifecycle; refines U-07
- **[RPC-06](RPC-06-native-plugin-layers.md)** confirmed (180, off-journal) — a defect in Swift or Kotlin, where Dart greps never look; refines U-14, U-03
- **[RPC-07](RPC-07-web-as-separate-runtime.md)** confirmed (090, off-journal) — green on the VM, broken on dart2js; refines U-03
- **[RPC-08](RPC-08-policy-field-single-transport.md)** confirmed (119, off-journal), applied in 205 — a policy field inert at a neighbouring transport; refines U-19
- **[RPC-09](RPC-09-deadline-below-write.md)** confirmed (168, off-journal) — the deadline sits below a blocking write; refines U-16
- **[RPC-10](RPC-10-shared-layer-blast-radius.md)** confirmed (150, off-journal) — a shared-layer fix's blast radius is overstated; refines U-11
- **[RPC-11](RPC-11-package-outside-workspace.md)** confirmed (186, off-journal) — a package outside the workspace is invisible to the gate; refines U-03
- **[RPC-12](RPC-12-cancel-into-request-stream.md)** retracted (204), applied in 202, 203, 204 — a contract mistaken twice for a defect
- **[RPC-13](RPC-13-unhandled-async-error.md)** swept here (121, off-journal) — an abandoned future running user code kills the isolate; refines U-17
- **[RPC-14](RPC-14-timeout-abandons-work.md)** swept here (067, off-journal), except isolate — a timeout drops the wait but not the work; refines U-17
- **[RPC-15](RPC-15-remeasure-own-record.md)** confirmed (201) — re-measure the loop's own record; refines U-21

Sweeps marked «off-journal» have nothing to age against: `stale` always shows
them as needing a re-measurement. That is correct — the code has changed since,
and the sha of that sweep is unknown.
