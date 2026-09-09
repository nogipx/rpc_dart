---
file: packages/core/rpc_dart/.dart_tool/probe/handler_slots_return.dart
round: 214 — the validating round
commit: 359c79ad
paths: [packages/core/rpc_dart/lib/src/endpoint/**]
status: valid
---

# P-06 — does a handler slot come back on every teardown path?

Endpoints over `RpcChannelTransport.pair()` with `maxConcurrentHandlers: 3`.
Six calls are churned through one teardown path, then twelve concurrent `park`
calls are opened and the PEAK number of handlers running at once is read from
inside the handler. Capacity that did not come back shows up as a peak below
the ceiling.

Run it with `melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/handler_slots_return.dart`. The knob is the churn mode; add one
by adding a case to the switch. Six churned against a ceiling of three is
deliberate — one leak per call would exhaust the ceiling twice over.

## Measures

Peak concurrent handlers during a burst that exceeds the ceiling, counted in the
handler itself, which is the only place that knows a handler is really running.
The comment on `_respSlotHeld` records why nothing else will do: counting
streams reported 3 while 37 handlers ran.

## Control

The `normal` mode — calls that simply complete — plus, and this is the one that
makes it a bench, an ABLATION: `_releaseHandlerSlot` made a no-op. At
validation:

```
                      peak, released      peak, ablated
  normal                    3                   0
  throw                     3                   0
  cancel                    3                   0
  deadline                  3                   0
```

Zero across the board under the ablation, so the bench sees a slot leak at full
strength; three across the board with the release in place, so all four teardown
paths return what they charged. `deadline` is the interesting row: the handler
ignores its cancellation token, so the slot deliberately outlives the stream and
is released only when the work actually ends.
