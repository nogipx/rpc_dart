---
round: 585
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-25
bench: P-205 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: breaking
---

# Round 585 — the buffer the sibling had already replaced

## Target

`B-148` — the HTTP/1.1 caller buffers the request body in a growable `List<int>`
and copies it again with `Uint8List.fromList`. Filed **high** confidence, `cost`,
and the lead names the sibling itself: *"the responder already moved to
`BytesBuilder(copy: false)` and explains why"*.

Lens RPC-25, the plainest form it has: two sides of one wire format, one of them
fixed, and the fixed one carries the reasoning in a field comment.

## Hypothesis

A `List<int>` holds a word-sized slot per byte on the VM, so the buffer costs
several times the body, and `fromList` adds a copy on top.

## Before

```
LIBRARY   32 MiB payload   the buffer's own  +205 MiB
LIST      32 MiB payload   +165 MiB
BUILDER   32 MiB payload     +1 MiB
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b148_what_a_buffered_request_costs.dart`.

**The two bare arms are there to bracket the library's**, which is the only way a
single allocation number means anything: before the fix the library sits with
`List<int>`. The library arm reads RSS three times — before the payload, after it,
after the buffer takes it — so the buffer is not charged for bytes the caller had
already allocated.

## Mechanism

```dart
final List<int> bodyBuffer = [];
...
call.bodyBuffer.addAll(data);
...
request.bodyBytes = Uint8List.fromList(call.bodyBuffer);
```

Over HTTP/1.1 the whole body is buffered by construction — the wire cannot flush
before the end — so this is not a corner case: every unary call, and every client
stream in full, goes through it at a size the application chooses.

## After

```
LIBRARY   32 MiB payload   the buffer's own  +0 MiB
```

`BytesBuilder(copy: false)` with `add` and `takeBytes()`. A single-chunk body —
every unary call — reaches `bodyBytes` as the caller's own `Uint8List` with no copy
at all, because `takeBytes()` returns the one chunk it holds.

## Canary

```
the final copy restored, `Uint8List.fromList(call.bodyBuffer.takeBytes())`
  WITNESS a single-chunk body reaches the wire uncopied
    Expected: true
      Actual: <false>
```

**The witness is IDENTITY, not RSS.** It is the same fact stated deterministically:
a copy anywhere on the path from `sendMessage` to `bodyBytes` breaks
`identical(sent, payload)`, and a test that measured bytes resident would be a
test that fails on a busy machine. The canary ablates only the second copy, which
is the half an identity assertion can see; the first — the list's own slots — is
the probe's.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http +205
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2220 / 2220, REUSE compliant
```

`+205` against `+201`, nothing else in the package changed.

## Not fixed

**No arm reads TIME.** `Uint8List.fromList` over a 32 MiB list of word-sized
elements has a CPU cost as well as a memory one, and the lead filed the memory
claim. What the round establishes is residency.

**The multi-chunk path still copies once at fire time**, because `takeBytes()`
concatenates when it holds more than one chunk. That is one copy instead of two
plus the list, and a client stream of N messages is the only shape that pays it.
Not worth a lead: the remedy would be to hand `package:http` a stream, which is a
different request shape and would lose the content-length this transport sets.

**The hand-over is a new requirement on callers** and nothing enforces it: a caller
that mutates its `Uint8List` after `sendMessage` now changes what goes on the wire.
Stated in the field comment, and it is the contract the channel transports already
have (rounds 575-576); no test pins it, because a test that mutated the payload
would be asserting the hazard rather than the guarantee.

## Links

Lead `../backlog/B-148-the-http1-request-body-is-a-list-of-int.md` — CLOSED.
Bench `../probes/P-205-what-one-buffered-request-body-costs.md` — new.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [585]`.
Round `575` — where the same hand-over-by-reference contract was written down for
the channel transports.
Lesson: none. The candidate — "a bare reference arm brackets a number that alone
means nothing" — is `measurement.md` item 3's own rule (a probe has a control) with
the control picked from outside the library, and the probe record carries it.
