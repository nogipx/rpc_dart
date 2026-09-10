---
round: 312
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: none
commit: yes
---

# Round 312 — the witness 308 shipped without

## Target

Round 308's own canary section, which said outright:

> The test suite is not the witness here — it passed before and after, which is
> the whole reason the drift survived.

The fix shipped on a code-reading argument. The owner has now asked for the
refactor to be verified by tests, and this is the round that owes one: a
regression test for the metering drift, with a canary proving it can SEE the
defect.

## Hypothesis

The drift is reachable from outside the transport, so a test can pin it. If it
cannot be reached without touching privates, the fix is unfalsifiable and that
is worth knowing too.

## Before

No test in the repository calls `getMessagesForStream` twice for one stream:

```
grep -rln "getMessagesForStream" .../rpc_dart_http2/test  ->  5 files
  none of them asks twice for the same id
```

The endpoint pipeline asks exactly once, which is why 199 tests passed over the
defect.

## Mechanism

The test drives the CALLER TRANSPORT directly, because the endpoint cannot
reach the second-call path at all. It asks twice, listens to the second view —
both calls return the same controller's stream, so whichever call the consumer
takes is the only listen there is — and reads 30 chunks of 256 KiB past the
4 MiB window.

**Two things the writing of it found, and both are the reason it is a real
test.**

1. **The first version passed on broken code.** It yielded `'z' * 256 KiB`, and
   the guard fired: 6060 bytes in 22 frames, ~300 per frame. The payload is
   charged against the window AS IT APPEARS ON THE WIRE, and a run of one
   character deflates about 900:1 — so thirty of those never approach 4 MiB and
   the test never reached the mechanism. The body is now pseudo-random base-62,
   which does not compress.

   That guard is the byte-count assertion, and it exists precisely because a
   flow-control test that never crosses its bound reports success for the wrong
   reason.

2. **`grpc-status 0` with almost no data is not a passing call.** The
   diagnostic that found the compression was recording the trailer status, which
   read OK throughout. A test asserting only "no error" would have been green on
   6060 bytes.

## After

```
                       before   after
http2 suite              199      200
```

Canary run, the pre-308 two-branch form restored:

```
RpcStatusException(8): Response exceeds the un-consumed window
                       (4298316 > 4194304 bytes)
consuming 4102938 bytes never discharged the un-consumed window
```

RESOURCE_EXHAUSTED for 4.1 MB the consumer had **actually read**. Reverted, the
test is green again.

## Canary

Above, and it is a real failing witness rather than a timeout: a status code, a
byte count, and the window it crossed. `methods/canary.md`'s bar — the fix can be
switched off and shown to break something — is met for the first time on this
finding.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, 0 failures; http2 199 -> 200.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1313/1313.

## Not fixed

The sibling fixes from 309-311 are still witnessed only by their siblings and
the analyzer:

- **309's log unification** — nothing automated reads log levels.
- **310's isolate web `send`** — needs a browser; `test:unit` cannot run the web
  variant, and `test:wasm` is a different package.
- **311's dead clause** — dead code has no runtime witness by definition; the
  `!` converts a future null default into a throw, which is the best available.

310's is the one worth a test if the platform gate ever grows to cover it, and
it is recorded here rather than left implicit.

## Links

RPC-25 (`applied:` gains 312), and L-10 — the test builds its request with
`_codec.serialize`, the library's own serializer, because the wire format is
CBOR and nothing in the request shape says so.

What this round adds to the lens: a drift found by comparing siblings is
**testable from outside**, because the divergence is in observable behaviour by
definition — if it were not, the two copies would be indistinguishable and there
would be nothing to fix. A drift with no reachable witness is a claim, not a
finding.
