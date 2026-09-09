---
round: 237
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-18
bench: P-16 — new
budget: probes 1/3, canaries 3/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 7 of 7, with Q4 the one that changed the round (see Canary)
commit: yes
---

# Round 237 — the dependency shared what we copied

## Target

RPC-18, never applied: a dependency accumulates before anything becomes a
message, so every ceiling this side sets is structurally blind to it.

## Hypothesis

The header-block guard added at round 145 bounds what reaches `package:http2`'s
HPACK decoder at `maxMetadataBytes` (64 KiB). HPACK **decompresses**, and
`HPackDecoder.decode()` appends to a `List<Header>` with no cap on count or
size — the only bound is the 4096-byte dynamic table. rpc_dart's `maxHeaders`
runs afterwards. So: prime the table with one large entry, send a block of
one-byte indexed references, and each byte in should emit a whole header out.

## Before

The dependency enumeration first. http2 depends on `package:http2` and
`universal_io`; websocket on `web_socket_channel` over dart:io; http on
`package:http` (caller, bounded at e8c5bc9f) and `shelf`. The accumulation
points already have answers — `FrameDefragmenter` is guarded,
permessage-deflate defaults off, the uncompressed-message residual is 1:1 — and
the one nobody had asked about is what happens AFTER the guard.

```
  refs    wire KiB   headers   logical MiB   RSS +MiB   distinct
  1000           5      1001           3.8          0          1
 10000          14     10001          38.2          1          1
 60000          63     60001         229.3          7          1
```

**The hypothesis was wrong, and the identity column is why.** `distinct: 1` —
package:http2 returns thousands of pointers to ONE shared entry, so Dart's
reference semantics defuse the classic HPACK bomb. 229.3 MiB is what an
implementation that copied would pay, not what this one pays.

rpc_dart is that implementation:

```
 rpc_dart's conversion of those same headers
 10000          14                                  31
 60000          63                                 258      <- ~4100x
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/hpack_expansion.dart`
(bench `../probes/P-16-hpack-reference-flood.md`).

## Mechanism

`http2HeadersToRpcMetadata` calls `String.fromCharCodes(header.value)` per
header, so every shared reference becomes its own String — and it ran one line
BEFORE `_policy.validateMetadata`, which is what holds `maxHeaders: 128`. The
limit that would refuse the request could only refuse a copy already made. One
unauthenticated request, 63 KiB on the wire, under the guard the whole way.

Fixed by enforcing the count DURING the walk, after the pseudo-header filter and
before the value copy, so the set of accepted requests is exactly what it was.
Both call sites — responder and caller — pass their policy; a client is exposed
to the same flood from the server it dialled.

## After

Same probe: both conversion arms `RSS +0 MiB, REFUSED`.

## Canary

`canaries 3/3`, and the budget was spent on the WITNESS, not the fix. The first
two versions asserted RSS and **both passed with the fix removed**: the first
sampled after the 240 MiB was already garbage, and the second still saw nothing
move in the runner even holding the result alive. That is C-29's recorded trap —
*expose a counter, do not infer allocation from memory* — arrived at again from
the other side.

The third version counts what the fix is actually about: a value list that
counts its own reads, so the metric is how many values were materialised.

```
  fix removed : "60001 header values were copied out of 60001 before the
                 policy refused the request it was always going to refuse"
  fix in place: 3 of 7 fail -> 7 of 7 pass
```

The count assertion is deliberately not wrapped in `throwsA`: gated behind the
throw expectation it never ran, so it proved nothing about cost.

## Gate

`melos run analyze` SUCCESS. `melos run test:unit --no-select` SUCCESS
workspace-wide. `melos run format:check` SUCCESS. `melos run license:check`
compliant.

## Not fixed

**The bound is on COUNT, not on total decoded bytes.** 128 headers whose values
are each near the 64 KiB block ceiling is still ~8 MiB, which the wire guard
already bounds, so nothing is unbounded — but no probe established where a
legitimate peer's header block actually sits, and `maxHeaderValueBytes` (8 KiB)
only refuses AFTER the same copy, one layer along.

**Only the http2 converter is guarded.** The websocket and isolate transports
carry metadata as frames rather than a compressed header table, so the
shared-reference shape cannot arise there; that is reading, not measuring.

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md` — `applied:
[237]`, first application in the journal, and its shape gains an inversion: the
dependency was safe and the adapter above it was not.
Bench `../probes/P-16-hpack-reference-flood.md` — new, validated by attributing
each stage separately.
Round `236` — the same dimension question one layer down; RPC-17 and RPC-18 are
siblings and this finding sits between them.
