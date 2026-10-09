---
round: 219
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-07
bench: none — the gate itself is the instrument
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; answered the `loop.py review` prompt against the record, and Q4 is the one that shapes the verdict, see below
commit: no
---

# Round 219 — what the web gate actually covers

## Target

Not B-17, though `next` still names it. Its decision was measured
unimplementable in round 218 and the replacement is with the owner; re-running
it would repeat that round exactly. So: the next rule, a lens never applied —
RPC-07, "green on the VM, broken on dart2js".

## Hypothesis

`melos run test:web` reads like a web gate. The lens's damage is code that is
web-reachable and only ever exercised on the VM, so the first question is not
"does it pass" but "what does it run".

## Before

```
melos run test:web, exit 0, twelve suites green:

  rpc_dart                 the WHOLE suite on node
  rpc_dart_compression     20   (whole suite)
  rpc_dart_grpc_reflection 95   (whole suite)
  rpc_dart_opentelemetry    4   web_smoke_test.dart only
  rpc_dart_websocket        4   websocket_web_smoke_test.dart only
  rpc_dart_http             3   web_smoke_test.dart only
  rpc_dart_log              3   client_web_smoke_test.dart only
  rpc_data                  3   web_smoke_test.dart only
  rpc_blob                  2   web_smoke_test.dart only
  rpc_blob_webdav           1   web_smoke_test.dart only
  rpc_data_sqlite           2   web_smoke_test.dart only
  rpc_blob_sqlite           2   web_smoke_test.dart only
  rpc_dart_isolate          6   three files, on CHROME, serialised
```

## Mechanism

Three packages run their whole suite on dart2js; nine contribute between one and
six hand-written smoke tests. That is not an oversight — the rest of those
suites bind sockets and spawn servers, which node cannot do — but it means the
sentence "web is covered" is true only of core, compression and reflection.

For everything else the web guard is a compile-and-construct check plus a
handful of round trips. It will catch "this package no longer builds for JS",
which is what it was written for, and it will not catch the bug classes the lens
is actually about: `async*` cancellation, ints above 2^53, clock resolution,
`Random.secure`, VM-only codecs.

## After

n/a — nothing changed.

## Canary

n/a — no fix, and no bench: the gate IS the instrument here, and its output is
the measurement.

## Gate

`melos run test:web` green, exit 0. No code changed.

## Not fixed

**Review Q4 is answered NO, and it decides the verdict.** "If it is bounded, is
it proven the mechanism could emit anything at all?" — this round proves the
suites pass and counts what they contain. It does NOT prove a dart2js defect
would have been caught, because nothing was ablated: no deliberate 2^53 overflow
or `async*` cancel was introduced to see whether any of these twelve suites goes
red.

So the verdict is CLEAN in the narrow sense that the gate passes and its scope is
now written down with numbers, and the lens stays `confirmed` rather than
`swept here`. Calling a coverage census a sweep would be the overstatement round
210 recorded about its own probes.

The real hunt — pick a bug class, plant it in a web-reachable path in one of the
nine smoke-only packages, and see whether anything goes red — is filed as B-18.

## Links

Lead `../backlog/B-18-web-guard-is-a-census-not-a-sweep.md` — new.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` — `applied: [219]`, with the
coverage table.
Round `218-generation-tagging-cannot-work.md` — why B-17 was not the target.
