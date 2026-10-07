---
round: 704
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-20
bench: none — a Chrome test reading the worker's connection credit, run against a dart2js worker and a dart2wasm module worker (`.dart_tool/probe/zz_grant_wasm_test.dart.txt`, artefacts in `.dart_tool/probe/isolate_wasm_worker/`)
commit: yes
release: changelog
---

# Round 704 — the window grant reaches a module worker

## Target

B-163: the web host's transport advertises its connection flow-control window
from its constructor, before the worker has necessarily installed
`onmessage`; a module worker (dart2wasm) instantiates asynchronously and drops
what arrives earlier.

## Hypothesis

On a dart2wasm module worker the grant is lost and the worker's connection
credit stays null -- unbounded.

## Before

The echo worker gained a `Credit` method returning its transport's
`flowControlConnectionCredit`. In Chrome:

```
dart2js classic worker,  dart2js host        credit set     3/3
dart2wasm module worker, dart2wasm host       Expected: not 'null'  Actual: 'null'
```

The call itself worked, so the pipe was up and only the early frame was lost.

## Mechanism

As hypothesised: the grant is the host transport's first frame, sent while the
module is still compiling; the browser dispatches it to a worker with no
listener. Later frames -- `init`, sent after the worker reports its scope
wired -- arrive.

## Fix

`WebMultiplexedChannel(holdUntilReleased: true)` keeps outgoing frames until
`release()`, then sends them in order. The host builds its channel that way
and releases it once `ensureInitialized` completes -- the worker is listening
from then on. A VM test pins the hold-and-order behaviour; the dart2js Chrome
test joins `test:web` as its own invocation (round 702).

## After

```
dart2wasm module worker   credit set   3/3
dart2js classic worker    credit set   (control, unchanged)
```

## Canary

`holdUntilReleased: false` on the host: `Actual: 'null'` again. Restored:
green.

## The verdict questions

1. Yes: one canary; dart2js the control.
2. Yes: the module-worker case the lead named.
3. Yes: the worker's own credit.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Not a policy question: nothing is traded.
8. None.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`, `test:web` (the new
invocation included, 0 failures).

## Not fixed

The dart2wasm worker case is not in the gate: it needs the worker compiled
with dart2wasm and a host run with `-c dart2wasm`; the probe is kept beside
its artefacts.

## Links

Lead `../backlog/B-163-isolate-web-early-grant-on-a-module-worker.md` closed.
Lens `../lenses/RPC-20-the-window-before-the-first-listener.md` -- `applied: [..., 704]`.
