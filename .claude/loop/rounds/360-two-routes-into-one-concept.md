---
round: 360
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-51 — new
commit: yes
---

# Round 360 — two routes into one concept

## Target

The owner's 6.0.0 review list, P2 item 14 — three core defects filed as one
line. They are not arbitrary neighbours: each is a place where the library
produces a WRONG ANSWER rather than failing, and each has a SIBLING beside it
that gets the same question right. That is RPC-25's shape, so the three were
taken as one round with one bench.

**Scope counted before the fix: three sub-items, two fixed, one filed.**

```
sub-item                          sibling that is right        verdict
a  RpcStreamIdManager(resumeAfter:)  the resumeAfter() METHOD   FIXED
b  _methodPathFromKey()              _parseMethodPath()         filed, B-40
c  the parser's decompress catch     what the gzip codec said   FIXED
```

## Hypothesis

Each sub-item is its own, so each is stated where it is measured. The shared one:
where a concept has two implementations, one of them has drifted, and the
drift is invisible because both compile and neither throws.

## Before

```
a) route                       resumeAfter  first three ids
   method resumeAfter(4)       4            7, 9, 11
   constructor resumeAfter: 4  4            6, 8, 10
   constructor, server         5            7, 9, 11
   method, server              5            8, 10, 12

b) service name                answered as
   Calculator                  ok
   myapp.v1.UserService        ok
   google.protobuf.Empty       ok

c) input                       message
   a bomb (valid gzip header)  ...exceeds the configured limit (max: N)
   corrupt / not gzip at all   ...exceeds the configured limit (max: N)
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/three_core_diagnostics.dart`.

**(a)** A CLIENT issuing `6, 8, 10` is minting the SERVER's half of the id
space. The two roles own opposite parities of one space, and everything
downstream — half-close, release, flow-control credit, `_statusSeen` — is keyed
on the id alone, so two calls holding one id are indistinguishable.
`IRpcStreamIdSequence.resumeStreamIdsAfter` states the contract the constructor
broke: *"must leave parity intact"*.

**(b)** CLEAN on the ordinary path, which is the measurement that matters: the
dotted names round-trip. See "Not fixed".

**(c)** Both causes report the same sentence, and one of them is wrong. A peer
with a CORRUPT frame is told its payload exceeds a limit — so it is invited to
send less, which cannot help.

## Mechanism

**(a)** Two routes into "continue this sequence". The method aligns parity and
documents it; the constructor's initialiser took the value raw. Nothing shared
the rule, so the two drifted.

**(c)** The catch rewraps every throw from the decompressor. A decompressor
throws for the bomb it was asked to stop AND for malformed, truncated or
non-compressed input — `rpc_dart_compression`'s gzip codec raises
`FormatException` with a different message for each — and the catch cannot tell
them apart, so it asserted one.

## After

```
a) route                       resumeAfter  first three ids
   method resumeAfter(4)       4            7, 9, 11
   constructor resumeAfter: 4  4            7, 9, 11
   constructor, server         5            8, 10, 12
   method, server              5            8, 10, 12

c) input                       message
   a bomb (valid gzip header)  ...could not be decompressed: it is malformed,
                               or it expands beyond the configured limit
   corrupt / not gzip at all   ...could not be decompressed: it is malformed,
                               or it expands beyond the configured limit
```

(a) is one shared `_alignedStart` helper, so there is one home for the rule.
(c) states the fact and leaves the cause to the two possibilities that produce
it — the limit is still named, because it is the half a peer can act on.

## Canary

Two fixes, two canaries, each failing only its own witnesses.

```
_alignedStart returns resumeAfter raw
  a client given an even cursor keeps issuing odd ids
    Expected: every element(an odd (client) stream id)   Actual: [6, 8, 10]
  a server given an odd cursor keeps issuing even ids
    Expected: every element(an even (server) stream id)  Actual: [7, 9, 11]
  the constructor agrees with the method, both roles
    Expected: [5, 7, 9]  Actual: [4, 6, 8]
  +3 -3, all three GUARDs green

the decompress message reverted
  corrupt input is not reported as exceeding a limit
    Expected: contains 'could not be decompressed'
      Actual: 'RpcException: Decompressed gRPC payload exceeds the configured
               limit (max: 67108864)'
  +2 -2
```

The GUARDs are what keep each fix from overshooting: a correctly-parity cursor
must NOT be nudged (rounding everything up would pass every witness and skip an
id per reconnect), and the decompress message must still NAME the limit — and
the precise `too large: N bytes` message must survive for a decompressor that
ignores the hint, because there the parser genuinely knows.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`fvm dart test -j 8` in rpc_dart, `+1470 ~1`;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` 1358/1358; **`melos run test:web` `+6`**, run because
this round changes core, which the config names as web-relevant.

Two gate runs were re-run rather than accepted, and neither was called a flake
without naming it. `test:unit` failed once at load average **15.01** in
`rpc_notify`'s `stream_distributor_test` — a package this round does not
touch — and passed alone immediately and in the full gate at load 7.34.
`test:web` failed once inside pub's `Entrypoint.ensureUpToDate`, not in any
test, while the device runs' `flutter pub get` was still settling; the re-run
exited 0.

## Not fixed

**Sub-item (b), and the measurement is why.** `_methodPathFromKey` splits a
method key on EVERY dot, so `myapp.v1.UserService.Get` yields four parts and
returns `/UnknownService/UnknownMethod` — while `_parseMethodPath` validates
against `[A-Za-z0-9_.-]+` and admits those names deliberately. Real drift, in
one file.

But the ordinary path is clean, measured: `methodPath` rides on the frame, and
the formatter is consulted only when both retained messages are null while
`methodKey` is set. Reaching that needs a peer with no metadata frame whose
retained payload has already been taken, and round 360 did not build a witness
for it. The damage there is a wrong diagnostic STRING that nothing routes on —
below the config's bar. Filed as **B-40** with the four-line fix written out,
to be applied by any round that touches the method for another reason.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`, fifteenth
application — and the first where the two implementations are a CONSTRUCTOR and
a METHOD on one class.
Bench `../probes/P-51-three-core-diagnostics.md`, new.
Lead `../backlog/B-40-method-path-from-key-drops-dots.md`, new.
Catalog shape U-14.
