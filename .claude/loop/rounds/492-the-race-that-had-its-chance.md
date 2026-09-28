---
round: 492
verdict: CLEAN
packages: [rpc_dart_wasm]
lens: RPC-06
bench: P-131 — new
commit: yes
---

# Round 492 — the race that had its chance

## Target

B-101, eighth in the audit's rank. The first native lead of this intake and the
first that needed a device at all.

Lens RPC-06 — a defect in Swift or Kotlin, where Dart greps never look, and in
the contract across that boundary which is neither language. The claim is about
Kotlin's forward path; the evidence had to come from a running device.

## Hypothesis

Two host-to-guest forward paths with different latencies, no serialisation above
them, so a small frame overtakes a large one and the guest reads a frame header
from the middle of another frame's payload. Refuted if the platform layer
preserves order despite the two paths — or if the bench could not make the two
paths overlap, which is a different answer and had to be distinguishable.

## Before

The code is as filed, confirmed by reading: `forwardBytesToRuntime` branches at
`NAMED_DATA_THRESHOLD` into an async JS IIFE that awaits
`consumeNamedDataAsArrayBuffer` versus a synchronous base64 eval; each platform
message gets its own `scope.launch`; and **nothing above serialises** — neither
`RpcFrameMultiplexedChannel.send` nor `RpcFlutterWasmBridge.send` holds a lock.

```
                    peak in flight   overlapped   >=64 KiB   result
android  1 big + 50 small     52         152          1      all echoes correct
android  5 big + 50 small x3 110         492         15      all echoes correct
ios      5 big + 50 small x3  56         329         15      all echoes correct
```

Probe: `packages/transport/rpc_dart_wasm/example/integration_test/host_to_guest_order_test.dart`

## Mechanism

Not reproduced. The reading of why is that `androidx.javascriptengine` evaluates
one script per isolate and `evaluateJavaScriptAsync` completes only once the
IIFE's promise settles, so the large path's delivery precedes the next script —
a property of the DEPENDENCY, and **unverified**. `checked/C-57` records it as
such, with what would reopen the lead.

## After

n/a — nothing changed. The fix sketch (a Mutex per runtime, or routing every
frame through named data) would serialise forwards and is not needed today.

## Canary

n/a for a fix, but the round has the equivalent and it is the point of the
bench: **the precondition is asserted.** A `_CountingBridge` decorator counts
forwards in flight and the test fails if the peak is not above 1. The first
version of this round would have reported a clean pass from `peak in flight: 1`,
which proves nothing about ordering — for a RACE, a bench that did not drive the
concurrency produces exactly the same green as a negative.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

`melos run test:wasm:device` on the Android emulator (API 30): `+25 ~2 All tests
passed!`. The new test alone on an iOS 18.6 simulator: `+1 All tests passed!`.
Run on BOTH because the two forward paths share no code — config.md's rule, and
here the test is shared so it had to be shown on each.

## Not fixed

**B-101's own mechanism, because it did not reproduce.** The lead is closed as a
negative rather than a defect, with the unverified dependency property named.

**A large frame concurrent with an unawaited flow-control GRANT** — the lead
names it as a trigger and nothing pins one. Grants are small and were certainly
among the 492 overlaps counted; no assertion isolates one.

## Links

Lens RPC-06. Bench P-131 (new). Negative `checked/C-57`. Lead B-101 (closed).
`guest_to_host_order_test.dart` is the same question in the other direction and
is what suggested asking this one.
