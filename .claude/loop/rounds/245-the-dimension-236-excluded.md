---
round: 245
verdict: FIXED
packages: [rpc_dart]
lens: RPC-05
bench: P-21 — new
commit: yes
---

# Round 245 — the dimension round 236 excluded

## Target

RPC-05, `swept here (round 215, d0612f96)`, four files moved since. Its detector
is "for every `RpcSecurityPolicy` field, where exactly it is charged", and
`security_policy.dart` has not changed since the sweep — no new field, so that
half of the detector had nothing to look at.

What HAD changed is a limit that is not a policy field: round 236 added
`maxPendingBytes` to `BufferedBroadcastController`, and round 240 put that
controller at a second hop. The lens's shape is "a new limit charges the
resource at the wrong point", and a bound that excludes a dimension is the same
question asked about WHAT is charged rather than WHEN.

## Hypothesis

`bufferedBytes` weighs the serialized payload only. Metadata is excluded
deliberately, on the stated rationale that it "is small and bounded by the
policy's header limits". If that rationale holds per frame but not in aggregate,
round 236's hole is still open in the excluded dimension.

## Before

`maxMetadataBytes` defaults to 64 KiB and the event bound is 4096. Measured on
the controller every transport uses, with its real config, one variable — the
same 64 KiB in `payload` or in `metadata`:

```
arm        admitted  retained    bound that stopped it
payload      256      16.0 MiB   the byte bound
metadata    4096     256.0 MiB   the EVENT count
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/metadata_escapes_the_byte_bound.dart`
(P-21).

## Mechanism

The rationale was true per frame and false in aggregate. One metadata frame is
small; 4096 of them at the policy's own ceiling are 256 MiB, against a class
whose documentation promises the queue "never grows past maxPendingBytes". The
byte bound simply never fires, because every metadata-only frame weighs zero.

This is exactly the defect round 236 closed for payloads — "the count alone was
the bug" — surviving in the dimension that fix excluded, and round 240 gave it a
second hop by putting the same controller on the reconnect proxy.

## After

```
arm        admitted  retained    bound that stopped it
payload      256      16.0 MiB   the byte bound
metadata     255      15.9 MiB   the byte bound
```

Same probe. `bufferedBytes` now adds each header's name and value length.

## Canary

`metadata_counts_against_the_bound_test.dart`, with `bufferedBytes` reverted to
payload-only in place:

    Expected: a value less than <4096>        Actual: <4096>
      the event count stopped it, so the byte bound never applied:
      4096 frames of 65536 bytes is 256 MiB retained
    Expected: a value less than or equal to <2>   Actual: <3840>

The payload test — the same drive with bytes in the payload instead — passed on
BOTH sides. It is the guard: it proves the harness measures the bound rather
than "the controller stops accepting things".

## Gate

`melos run analyze` SUCCESS (21 members + wasm) · `melos run test:unit
--no-select` SUCCESS · `melos run format:check` SUCCESS · `melos run
license:check` REUSE compliant. In the package: analyze clean, 1420 passed / 1
skipped.

## Not fixed

**The cost of the new accounting is not measured.** `bufferedBytes` now walks
the header list on every enqueue while unlistened. That is O(headers) on a path
that only runs before the first listener, so it is almost certainly free — but
"almost certainly" is not a number, and this round did not take one.

`dart test -p node` still cannot run in this environment (`read ENETDOWN` at
load, reproduced on untouched files), so the dart2js side is unmeasured for the
sixth round running.

## Links

Lens RPC-05, applied and confirmed again · bench P-21 (new) · the fix it
completes is round 236's, and the second hop it protects is round 240's ·
catalog U-07 is the shape.
