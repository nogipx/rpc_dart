---
round: 457
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-15
bench: P-108 — reused
commit: yes
---

# Round 457 — my own premise was false

## Target

B-91, filed one round earlier as "gzip does not round trip", with question 1:
which side fails, compress or decompress.

**It is not a pre-existing defect. Round 455 caused it**, and this round is that
correction.

## Hypothesis

Round 455 removed `ensureGrpcFrame`'s heuristic on the premise that
`RpcMessageParser` always emits de-framed bodies, so whether the input is framed
is known. If that premise is false anywhere, the unconditional framing double-wraps
and loses the compressed bit.

## Before

B-91's question 1, in process, no transport:

```
registered: [identity, gzip]
gzip  compress 4096 -> 43, decompress 43 -> 4096  IDENTICAL
GZIP  same
```

So the codec is fine and the failure is wiring. Second arm, the same call over a
channel pair:

```
absent / identity / gzip, payload 4 and 4096   all OK
```

Fine there too. So it is **http2-specific**, which is where round 455 changed
something.

Then the read that settles it — `parser.dart:212-218`:

```dart
if (_state.isCompressed) {
  final decompressor = _decompressor;
  if (decompressor == null) {
    // No decompressor at this layer: reconstruct the complete gRPC frame
    // (with compression bit set) and pass it through so the application
    // layer can decompress it.
    payload = RpcMessageFrame.encode(payload, compressed: true);
```

**The http2 transports build their parser with no decompressor.** So for a
compressed message the parser emits a COMPLETE FRAME, deliberately. Round 455 read
`result.add(payload)` two dozen lines below and concluded "always de-framed"
without reading the branch above it.

Confirmed by restoring the heuristic:

```
                        grpc-encoding: gzip
unconditional framing   status=13 INTERNAL
the heuristic           OK
```

## Mechanism

Framing an already-framed compressed message again puts an outer header saying
`compressed: false` around it. The layer above reads the outer header, hands the
inner frame to the codec as a body, and the codec meets gzip bytes. `wireStatusFor`
redacts whatever that throws to INTERNAL, which is why B-91 looked like an
undiagnosable "Internal server error".

## After

The heuristic is back, with a comment that states why it is load-bearing and what
the real fix is. `gzip` and `GZIP` read OK.

## Canary

Round 455's unconditional framing, restored in place, against the new guard:

    Expected: 'saw:yyyy…'  (4096 chars)
      Actual: 'status=13'
    http2 parses with no decompressor, so the parser hands up an already-framed
    compressed message; framing it again drops the compressed bit and the codec
    then reads gzip bytes

The identity arms stay green under it, so the guard is specific to compression.

## Gate

`melos run analyze` SUCCESS. `format:check` and `license:check` SUCCESS.
`rpc_dart_http2` 249 passed, 0 failures. `test:unit` SUCCESS over 14 packages on
re-run.

**One websocket test failed once** in the first full-workspace run and passed both
in isolation (183/183) and on a second workspace run at lower load (3.48 against
6.43). It is in the keepalive/reclaim family, which is wall-clock dependent.
**I did not capture its name**, which the config asks for before calling anything a
flake — so it is recorded as unnamed rather than dismissed.

## Not fixed

**B-78 is RE-OPENED, and the guess is still there.** The right fix is for the
parser to tell its caller which branch it took, instead of the caller re-deriving
it from bytes the peer chose. That is a core API change and not this round's
business; until then the heuristic stays, because the alternative corrupts every
compressed message.

**Two tests I wrote in round 455 asserted the wrong contract** and had to be
inverted: `grpc_wire_compliance_test`'s "frames a body that LOOKS framed" is back
to "does not double-wrap", and `a_self_framing_body_is_still_framed_test` now
CHARACTERISES B-78's hole instead of claiming it fixed. **That file's NAME is now
wrong and I cannot change it** — `mv` is outside the allowlist — so it says so at
the top.

## What let this ship, which is the part worth keeping

**Nothing in 249 http2 tests exercised a genuinely compressed message.** Round 455
ran the full suite green, twice, and the gate cannot see a path nobody drives. The
guard added here is that test; it is the reason B-91 took one round to find rather
than a user.

The reading error is smaller and sharper: I quoted `result.add(payload)` as
evidence for "always de-framed" without reading the twenty lines above it that
reassign `payload`. **A quote is evidence for what the quoted line does, not for
what the variable holds.**

## Links

- RPC-15 — re-measure the loop's own record; this time the record was two rounds
  old and mine
- P-108 — reused, its own-caller arms are what showed gzip failing
- B-91 — closed as "not pre-existing: round 455 caused it"
- B-78 — RE-OPENED with the corrected reading
- Round 455 — the round this corrects
- L-15 — and its cousin: a suite with no arm for a path cannot protect it
