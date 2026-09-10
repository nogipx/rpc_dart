---
round: 302
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-23
bench: none
commit: yes
---

# Round 302 — the shape is not a density

## Target

`rpc_dart_isolate`, the whole `lib/` — the fourth package of the owner's
mandate, in order.

It is the first package in this series the detector does NOT flag: **18.2%
comment lines**, under the lens's ~20% threshold, and only one of its four files
is above it. That makes it the round worth taking rather than skipping, because
it tests the claim 300 and 301 built: if the adjacency shape is a property of
the corpus, it does not care how dense the comments are.

## Hypothesis

A package under the density threshold still carries the fusion shape. If it does
not, the shape is a symptom of comment bloat and the detector finds it for free;
if it does, the density metric and the adjacency sweep are measuring different
things and BOTH are needed.

## Before

Probe: `grep -rcE "^[[:space:]]*//"` and `grep -rc ""` over
`packages/transport/rpc_dart_isolate/lib`.

```
                        comments  total      %
isolate_transport            134    620   21.6
isolate_transport_web         78    546   14.3
isolate_transport_stub         5     32
rpc_dart_isolate.dart          4     13

package lib total            221   1211   18.2
```

## Mechanism

**The hypothesis holds, and the instance is the worst of the series.** In
`isolate_transport.dart`, one `//` block ran two unrelated subjects together
with no separator:

1. *"Attach the channel and the transport BEFORE waiting for `ready`"* — 20
   lines on why early subscription is what keeps the connection flow-control
   window from being dropped. The code it describes is at
   `hostChannel = ...` / `hostTransport = ...`, **76 lines below**.
2. *"Everything spawn() acquired is released HERE"* — 30 lines on teardown,
   describing `teardownConnection`, declared on the very next line.

So a reader of `teardownConnection` waded through twenty lines about flow
control before reaching a word about teardown, and the flow-control argument sat
nowhere near the two constructor calls it protects. Each half is where the
author was standing when they wrote it; together they document neither. The
first half now sits immediately above the two constructions, where undoing it is
what the comment warns about.

This is the declaration fusion of rounds 296-301 in `//` form — which is exactly
why round 297 had to widen the detector from `///` to all comment lines.

**A second find, and it is a rule-one divergence rather than bloat.**
`isolate_transport_stub.dart` documented itself as the *"Fallback stub for
platforms without `dart:isolate` (e.g., web)"*. The barrel three lines away says
otherwise:

```dart
export 'src/isolate_transport_stub.dart'
    if (dart.library.io) 'src/isolate_transport.dart'
    if (dart.library.js_interop) 'src/isolate_transport_web.dart';
```

Web resolves to `isolate_transport_web.dart`, a real Worker-backed
implementation — the one platform named as the example is the one platform that
never reaches this file. The stub is for a target with NEITHER `dart:isolate`
nor `dart:js_interop`. A reader who trusted it would conclude the package has no
web support at all.

The VM file's `runRpcIsolateManagerWorker` had the mirror-image problem, calling
itself a *"Web stub"* while being the VM no-op.

Also cut, by the established rule: the isolate-leak table (`beats after teardown
12` / `NEVER EXITED` against `0` / `809 ms`), the expected-vs-got startup
regression, the Chrome 404 table, and four *"used to"* constructions — a doc
correcting an earlier revision of itself.

## After

```
                        comments  total      %
isolate_transport            111    597   18.6
isolate_transport_web         68    536   12.7
isolate_transport_stub         9     36
rpc_dart_isolate.dart          4     13

package lib total            192   1182   16.2
```

**-29 comment lines**, 18.2% -> 16.2%. Zero code lines changed.

The small number is the honest result for a package already under threshold, and
`isolate_transport_stub.dart` **grew**, 5 lines to 9. That is the right outcome
and worth recording: its defect was a false statement, not verbosity, and
fixing a false statement costs lines. **The metric is a detector, not a target**
— a round that optimised it would have made that file worse.

## Canary

The analyzer over lib plus 73 passing tests show the code still compiles and
behaves, not that a comment is right — the standing limit for this lens.

The stub half has a real witness, and it is not the analyzer: the claim "(e.g.,
web)" is refuted by the conditional export in `rpc_dart_isolate.dart`, which
routes `dart.library.js_interop` to `isolate_transport_web.dart`. Restore the
old wording and the file contradicts a line of code three lines away from it.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1298/1298.
Package: `fvm dart analyze lib test` no issues; `fvm dart test -j 8` 73 passed.

## Not fixed

Nothing outstanding in this package. What remains is invariant: the
unsendable-payload rule, the stream-0 flow-control exemption, the
zero-copy-means-sendable caveat.

One package of the mandate remains: `rpc_dart_http2`, and it is the largest
transport (59 files).

## Links

RPC-23 (`applied:` gains 302). The lens gains its most important qualification:
**the fusion shape is INDEPENDENT of comment density**, established on the one
package that the detector does not flag. The density metric ranks where to
sweep; it does not decide whether to. A package under 20% can still hold the
worst instance found so far.

Second addition: the sweep can surface a rule-one divergence, not just bloat.
`isolate_transport_stub.dart` named the one platform that never reaches it, and
no gate can catch that — the compiler does not read prose, and the contradicting
evidence was a conditional export in a different file.
