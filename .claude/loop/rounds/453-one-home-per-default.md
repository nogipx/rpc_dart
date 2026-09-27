---
round: 453
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the copies AGREE today, so there is no quantity to take; the evidence is a canary that reproduces the drift on command
commit: yes
---

# Round 453 — one home per default

## Target

B-85's Dart half, and the owner chose the stronger of the two options offered: one
source for the defaults PLUS the test, rather than a test alone. Their reason,
recorded on the lead: a test detects the drift, it does not prevent it, and a
value with two homes is the shape the lead is filed under.

Scope: the 13 repeated literals in `security_policy.dart`. NOT the native half —
the JS shim carried as strings in both Swift and Kotlin stays a separate,
device-bound job, as the lead says and the owner confirmed.

## Hypothesis

Every default is written twice, constructor against `fromMap`, and `fromMap` is
how a policy crosses an isolate or worker boundary — so a drift puts the two ends
of one process on different limits, silently. **The copies agree today**, so this
is a future edit rather than a present defect, and the evidence has to come from
an ablation instead of a measurement.

## Before

13 literals, each written twice:

```
maxMessageLengthBytes 16 MiB   maxHeaderValueBytes  8 KiB
maxMessagesPerChunk   1024     closeOnProtocolError false
maxActiveStreams      4096     halfOpenStreamTimeout 60 s
maxMetadataBytes      64 KiB   flowControlWindowBytes 4 MiB
maxHeaders            128      flowControlConnectionWindowBytes 64 MiB
maxHeaderNameBytes    128      initialSendWindowBytes 64 KiB
                               initialSendWindowGrace 5 s
```

`bench: none` and the reason is in the frontmatter: there is no quantity to read
while the copies agree.

**The 14th was already right and is the idiom this follows**:
`maxMethodPathLength` used the named `kDefaultMaxMethodPathLength` in both places
already.

## Mechanism

Two independent routes into one class, each carrying its own copy of every
number. Nothing reads one against the other, and `fromMap`'s copies are the ones
a reader never looks at — they are fallbacks, reached only when a key is absent.

## After

One private constant per default, used by both routes. Private rather than public
on purpose: the `public_member_api_docs` lint wanted a doc comment on each, and
13 new documented public members is a real addition to a published surface for
something no caller needs to name. The test does not need them either — it
compares the two ROUTES, not the constants.

## Canary

A literal written back into `fromMap` — `readInt('maxHeaders', 64)` — which is
exactly the future edit this guards against:

    'maxHeaders': 128,
    'maxHeaders': 64,
    Which: at location ['maxHeaders'] is <64> instead of <128>

The field-by-field map is what makes the failure name the drifted field instead
of an opaque `==`, and that was the point of writing it that way.

`+2 -1`, and the split is informative: only the EMPTY-MAP test caught it. The
round-trip tests passed, because `toMap` writes the value explicitly and `fromMap`
then reads it rather than falling back — so the three tests are not redundant,
they cover different journeys.

## Gate

`melos run analyze` SUCCESS. `test:unit` SUCCESS over 14 packages; `rpc_dart`
1669 passed 1 skipped, up three. `format:check` and `license:check` SUCCESS. In
the package: `analyze lib test` clean.

## Not fixed

**The native half of B-85.** The JS shim is carried as strings in both
`RpcDartWasmPlugin.swift` and `RpcDartWasmPlugin.kt`, and per `config.md` a fix to
one is never a fix to the other. It needs `analyze:native` and
`test:wasm:device` on both platforms, so it stays with B-38 and B-03 as the
owner's device-bound work. B-85 therefore does NOT close.

**`toMap` was not made single-source with the field list.** It still writes its own
key names, and the round-trip test is what covers a key only one side knows. A
generated or shared key list would remove that too, and is a bigger change than
this lead asked for.

## Links

- RPC-25 — one value, two routes; the round-446 variant of the same shape, where
  the second home was unreachable rather than merely duplicated
- B-85 — Dart half done, native half still open
- Witness: `test/core/policy_defaults_agree_test.dart`
