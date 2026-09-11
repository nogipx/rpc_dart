---
round: 338
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: P-37 — new
commit: yes
---

# Round 338 — the guard that asked a different question

## Target

Round 337's own mechanism. It put one predicate — `_logger.isInternal` — in
front of 158 new call sites, taking the guard count from 65 to **222**, on the
assumption that the guard predicts what `_log` will do. The round never checked
that assumption, and RPC-15 exists for exactly this: re-measure your own record.

They are two different calls:

```dart
bool get isInternal => _controller.accepts(RpcLogLevel.internal, name);
void _log(...)      => _controller.accepts(level, name, tag)
```

## Hypothesis

`accepts`'s third parameter is optional and positional, so one caller can omit
it silently. If `_resolveLevel` uses it, the guard and the filter can disagree.

## Before

`_resolveLevel(scope, tag)` consults the tag override **first**, ahead of the
scope overrides and ahead of `minLevel`:

```dart
if (tag != null) {
  final tagLevel = _tagLevels[tag];
  if (tagLevel != null) return tagLevel;
}
```

P-37, one `internal()` per row, asking the CONTROLLER what arrived rather than
asking the guard:

```
                                          guard   delivered
no tag, no overrides                      false   false
scope override -> internal                true    true
TAG override -> internal, scope tagged    false   true     <-- DISAGREE, MUTE
TAG override -> error, scope internal     true    false    <-- DISAGREE
```

**Row three is the defect.** The controller was configured to accept the record —
`setTagLevel('verbose', internal)` — and delivers it. The guard says no, so with
the guard in place it is never offered. Every one of the 222 sites loses its
diagnostics, the call still succeeds, and nothing reports anything.

Row four is the same bug in the harmless direction: a string built and dropped.

The tag reaches all of them. `child()` carries it (`tag: tag ?? this.tag`) and
every guarded class builds its scope with `logger?.child(...)`:

```
root        rpc                                    guard: false  delivered: true
child       rpc.ServerResponder                    guard: false  delivered: true
grandchild  rpc.ServerResponder.StreamProcessor    guard: false  delivered: true
```

**Reachable through the public API, and through the ordinary use of it.** The
endpoints build untagged scopes, so a `LogController` handed to
`RpcCallerEndpoint` is safe. But every transport takes a `LogScope?` directly —
`RpcHttp2CallerTransport.connect(logger: ...)`, `RpcHttp2Server(logger: ...)` —
and turning one tag up is how you get verbose output from one subsystem without
drowning in the rest. That configuration silenced all 41 guarded lines in
`rpc_dart_http2`.

## Mechanism

An optional positional parameter that changes the answer. `accepts(level, scope,
[String? tag])` has four callers; three passed the tag and the guards did not.
Omitting it does not read as a decision at the call site — it reads as the
common case.

## After

The guard asks the filter's own question:

```dart
bool get isInternal => _controller.accepts(RpcLogLevel.internal, name, tag);
bool get isTrace    => _controller.accepts(RpcLogLevel.trace,    name, tag);
bool get isDebug    => _controller.accepts(RpcLogLevel.debug,    name, tag);
```

```
                                          guard   delivered
no tag, no overrides                      false   false
scope override -> internal                true    true
TAG override -> internal, scope tagged    true    true
TAG override -> error, scope internal     false   false
```

Four of four agree. Three lines, and they fix all 222 sites at once — the depth
of the fix is one mechanism even though its breadth is the whole tree.

```
rpc_dart          +1445 ~1  ->  +1449 ~1
rpc_dart_http2    +205      ->  +206
```

## Canary

The fix ablated to the pre-338 form, on both witnesses:

```
core   a_guard_must_predict_the_filter_test.dart
       Expected: true  Actual: <false>
       'the guard disagreed with the filter and so MUTED a record the
        logger accepts — every guarded call site loses its diagnostics'
       3 of 4 red

http2  a TAGGED scope still logs when the tag level allows it
       Expected: true  Actual: <false>
       'the tag level says internal, so these must arrive'
```

The guard against a fix that simply logs everything: http2's UNTAGGED test and
core's no-tag rows stayed green in the ablated run — the two configurations that
were already correct must remain correct, and rows one and two of P-37 are
identical in both arms.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check`
clean; `test:unit` 14 packages, 0 failures.

## Not fixed

`LogController.accepts`'s tag stays optional and positional. Making it required
is a breaking change to a public method and would fix nothing currently broken —
all four callers now pass it, verified by grep. Filed as the shape, not as work:
the sweep is one line and cheap to repeat.

## Links

RPC-15 (`applied:` gains 338). The record re-measured is round 337's, one round
old, and the thing it got wrong was not any of its 158 edits — those were right —
but the predicate all of them now depend on.

> **A guard is a PREDICTION about another piece of code, and it is only as good
> as the arguments it makes the prediction with.** Both calls here read
> "consult the filter"; one of them passed three arguments and the other two,
> and the optional one was the one that decides. The witness round 337 wrote
> could not catch it, because it configured the logger the way the guard
> happened to assume.
