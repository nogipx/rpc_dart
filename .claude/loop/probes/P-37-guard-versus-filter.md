---
file: packages/core/rpc_dart/.dart_tool/probe/guard_vs_filter.dart
round: 338 — the validating round
commit: 8b25cc98c006a39e3d054a89f33faa7b2e6a30c6
paths: [packages/core/rpc_dart/lib/src/logger/**]
status: valid
---

# P-37 — does the level guard predict the filter it stands in for

For each logger configuration, emits one `internal()` and prints three things:
what `isInternal` said, whether the record actually reached the controller's
stream, and whether those two agree. Needs no instrumentation — the controller's
own `stream` is the observation point, so the number is the library's.

Add a row by adding a `configure` callback. The second half walks
`child().child()` to show how far a tag reaches.

## Measures

Agreement between the guard and the delivery, per configuration. The direction
matters and the probe labels it: `guard true, delivered false` is a string built
and dropped — where the code was before the guards existed. `guard false,
delivered true` is a **mute**: the logger was configured to accept the record
and the guard stopped it ever being offered.

## Control

The mechanism is the tag argument the guard passes to `accepts`. Removing it —
`accepts(RpcLogLevel.internal, name)`, the form every guard used up to round 338
— against the fixed form:

```
                                          guard dropping tag    guard passing tag
no tag, no overrides                      false / false         false / false
scope override -> internal                true  / true          true  / true
TAG override -> internal, scope tagged    false / true  MUTE    true  / true
TAG override -> error, scope internal     true  / false         false / false
```

Two of four configurations disagreed, one of them in the muting direction. The
bench sees it because it never asks the guard what happened — it asks the
controller.

## Reach

`child()` carries the tag (`tag: tag ?? this.tag`) and every guarded class builds
its scope with `logger?.child(...)`, so the same disagreement holds at any depth:

```
root        rpc                                    guard: false  delivered: true
child       rpc.ServerResponder                    guard: false  delivered: true
grandchild  rpc.ServerResponder.StreamProcessor    guard: false  delivered: true
```
