---
round: 428
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-07
bench: none — the evidence is two ablations restoring round 310's defect in
  place, each failing a different clause's witness with a real message
commit: yes
---

# Round 428 — the file the test could not import

## Target

**B-31**, second of the four the owner listed. Round 310 fixed a real defect —
a payload that cannot be structured-cloned closed the WHOLE web channel and
swallowed the reason — and the fix has had no test for 118 rounds.

The lead's decision is route 3: `@visibleForTesting` on the class plus a
~40-line VM test, chosen over a cheaper policy extraction, and sold on this:

> The cost is contained in a way that matters here: the test runs **on the VM**.
> Nothing in the failure path needs `dart:js_interop` — only the `_send`
> callback does, and the test supplies it.

## Hypothesis

L-13 again: re-measure the sentence. The claim is about the CHANNEL's failure
path, and a test does not import a path — it imports a FILE.

## Before

`isolate_transport_web.dart` opens with `dart:js_interop` and
`package:web/web.dart`. A VM test that imports it does not fail an assertion; it
fails to compile, and not only on those two lines — `package:web` and
`isolate_manager`'s web files produce hundreds of errors:

```
Failed to load "test/b31_import_probe_test.dart":
  .../isolate_manager-6.3.2/lib/src/utils/extract_array_buffers.dart:6:9:
    Error: Type 'JSArrayBuffer' not found.
  .../web-1.1.1/lib/src/helpers.dart:81:10:
    Error: Type 'JSFunction' not found.
  ... ~20 000 characters of the same
```

**So the decided route could not have worked as written.** `@visibleForTesting`
makes a class nameable; it does not make a library loadable. The annotation
would have been added, the test would not have compiled, and the round would
have discovered it after widening the surface.

## Mechanism

The class did not need to be in that file. `_WebMultiplexedChannel`,
`_BridgeMessage`, `_BridgeType` and the four helpers use `dart:async`,
`dart:typed_data` and rpc_dart types and **nothing else** — the JS dependency is
all in `spawn`, `_workerSelf` and the `isolate_manager` controllers. Read, then
checked by moving them and compiling.

## After

`lib/src/web_bridge.dart` holds the wire format, the channel and the helpers;
`isolate_transport_web.dart` imports it and keeps the Worker plumbing. The
witness is an ordinary VM test with a stub `send` and no Worker at all.

**This costs LESS surface than the approved route, not more.** Route 3 would
have annotated a class inside a file the package barrel conditionally EXPORTS.
`web_bridge.dart` is not exported by anything; it is reachable only through
`package:rpc_dart_isolate/src/...`, which is an `implementation_imports` lint
for anyone outside. The public API is unchanged, and the class is testable.

Both halves the owner asked for are asserted, plus a third:

```
WITNESS  the caller is told WHAT went wrong      named ArgumentError, stream id
WITNESS  the other calls on the channel survive  isClosed false, frames 3 and 5
                                                 still sent either side of it
WITNESS  the channel still RECEIVES afterwards   an inbound frame still arrives
GUARD    an explicit close still closes
GUARD    the peer's close frame still closes
```

## Canary

Round 310's defect, restored in place, in its two separable halves:

```
ablation                          witnesses that failed
await close(); return;            all THREE:
  (close on a send failure)         "Expected: throws ArgumentError ...
                                     Actual: emitted <null>"
                                    "one bad payload closed the channel, taking
                                     every other in-flight call with it"
                                    "the inbound half was torn down with it"
return;                           ONE, the first:
  (swallow the reason, no close)    "swallowing the reason reports this as
                                     UNAVAILABLE, which is a claim about the
                                     worker rather than about the payload"
```

The second ablation is what says the witnesses isolate the two clauses rather
than one implying the other: swallow without closing and the survival witnesses
stay GREEN. Both GUARDs stayed green under both.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run test:web       SUCCESS -- 12 suites, isolate on Chrome among them
melos run format:check   SUCCESS
melos run license:check  compliant, 1600/1600
rpc_dart_isolate alone   SUCCESS
```

`test:web` matters more than usual here: it is what compiles
`isolate_transport_web.dart` for dart2js and runs the isolate package on Chrome,
so it is the check that the move did not break the half that still needs a
browser.

## Not fixed

**The Worker plumbing is still untested**, and moving the channel does not
change that: `spawn`'s startup race, the `ready` ack, the worker-death listeners
and `runRpcIsolateManagerWorker` all need a real Worker. B-31 was only ever
about the channel; this says so rather than letting the green suite imply more.

**`test/b31_import_probe_test.dart` is a leftover and SAFE TO DELETE.** It began
as the probe that measured the import failure, and the loop runs without a shell
that may remove files, so it ships as a one-line placeholder pointing at the two
files that replaced it. Not hidden in a commit message: the file says so itself.

## Links

- B-31 — closed. Its decision's route was unworkable; the round delivered what
  the decision WANTED (a real witness, both halves, on the VM) by another means
  and at a lower surface cost
- L-13 — third round running where a decision's premise was the thing to check.
  Here the sentence was about a code PATH and the obstacle was the FILE
- RPC-07 — the web as a separate runtime: this is the same boundary the lens is
  about, met from the testing side
- round 310 — the defect this finally witnesses
