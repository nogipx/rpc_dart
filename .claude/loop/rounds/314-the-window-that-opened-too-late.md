---
round: 314
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-15
bench: none
commit: yes
---

# Round 314 — the window that opened too late

## Target

A failure the owner pasted from a full-suite run:

```
[rpc_dart_http]: 00:12 +121 -1: aborted_body_frees_the_pipeline_stream_test.dart
  Expected: a value greater than <0>
    Actual: <0>
  the aborted requests must reach the transport at all
```

Taken immediately and ahead of anything on the backlog, for two reasons. A red
gate is the loop's own stop condition, and **the first question is whether it is
a regression from rounds 308-313**, which touched this exact transport:
`rpc_http_responder_transport` had its per-stream router replaced in 308.

## Hypothesis

Either 308's `RpcStreamRouter` swap broke the abort path, or the test is a flake
whose previous de-flake was incomplete. The file's last commit is
`e7cd2d9b test(rpc_dart_http): de-flake round 271's rise-check`, so the second
is live.

## Before

```
standalone, this tree      PASSES, ~2 s, 2 of 2
reported, full suite       FAILS at the rise-check, ~12 s
```

Not a regression. The assertion that failed reads
`health().details['pendingRequests']`, which is `_pending.length` — a field
round 308 never touched. The router swap moved `_streamControllers`, and
`_pending` is a different map with a different lifecycle.

**The mechanism, from the code rather than from the failure text.**
`_abortMidBody` destroys its socket the moment the headers and five bytes are
out:

```dart
socket.add(const <int>[0, 0, 0, 0, 4]);
await socket.flush();
socket.destroy();
```

So the server can answer that request two ways: `bodyReadTimeout` at 2 s, or a
read ERROR as soon as the destroyed socket is observed — promptly. Which one
wins is TCP and scheduling.

The test opened its observation window AFTER the four aborts:

```dart
for (...) await _abortMidBody(rig.port);
expect(await _peak(...), greaterThan(0));
```

On an unloaded machine the 2 s timeout path dominates and the window catches the
rise. Under a loaded 14-package run the error path answers all four before the
first poll, and the guard reads 0 **on a server that did everything right**.

The previous de-flake (round 271's) fixed the QUESTION — a peak rather than a
simultaneous count — and left the WINDOW. Both flakes print the identical
`Actual: <0>`, which is why the first fix looked complete.

## Mechanism

The peak observation now starts BEFORE the aborts and runs concurrently with
them, so the window contains the event whichever path answers it. Nothing about
the product changed.

## After

```
standalone            PASSES, ~2 s
full workspace suite  14 packages, 0 failures; rpc_dart_http 123
```

## Canary

The old ordering, restored, plus a 4 s delay standing in for the load:

```
00:12 +0 -1: a body that never arrives leaves no stream in the pipeline [E]
  Expected: a value greater than <0>
    Actual: <0>
  the aborted requests must reach the transport at all
```

**The reported failure reproduced exactly** — same message, same value, same
~12 s shape as the run the owner pasted. That is what makes this a diagnosis
rather than a guess: the bench sees the defect, and the defect is in the bench.

Reverted, green in ~2 s.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1318/1318.

## Not fixed

`_peak` still returns a peak over a fixed budget rather than latching on the
first non-zero reading. A latch would be strictly stronger and is a smaller
change than this one was — but the budget form is what the second assertion
needs anyway (it wants the settle, not just the rise), and splitting them buys
nothing measured.

The config's known-flake list names only `audit_frame_reassembly_linear_test`.
This file has now flaked twice for two different reasons and is NOT on that
list; it is not added, because it is not a wall-clock flake — both causes were
observation-window bugs, and both are fixed.

## Links

RPC-15 — re-measuring an earlier record. The record here is a previous round's
de-flake, and the finding is that it treated one of two causes. B-31, B-30 and
the rest of the backlog are untouched.

The lesson this round would have paid for if it were new: **two flakes can print
the same assertion failure and have different causes**, so a de-flake is only
finished when the mechanism is named, not when the message stops appearing. It
is not filed as `L-N` because round 271's own comment already records the first
half, and a lesson needs a price in numbers that this round did not pay twice.
