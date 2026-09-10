---
round: 290
verdict: INCONCLUSIVE
packages: [rpc_dart]
lens: RPC-04
bench: none
commit: yes
---

# Round 290 — the boundary cannot be drawn yet

## Target

Step 1 of round 289's plan: take the pipeline machinery off the public barrel.
289 had scoped it — `RpcMessageParser`, `RpcMessageHeader` and
`BufferedBroadcastController` stay (all four transports build on them), thirteen
other types are used only by core's own tests — and expected the edit to touch
fourteen files.

## Hypothesis

`hide` on `export 'src/_index.dart'` in `lib/rpc_dart.dart` narrows the surface
without touching a line of implementation, because a `hide` on a re-export
affects consumers only.

## Before

The `hide` was applied and the analyzer run. It does not affect consumers only:

```
analyzer errors                   78
  inside lib/                      7   call_scope.dart, caller_pipeline.dart x2,
                                       responder_pipeline.dart x2,
                                       responder_streams.dart x2
  inside test/                    71
```

**Core's own implementation imports core's own public barrel.** Eleven files
under `lib/` do it:

```
src/endpoint/_index.dart          src/resilience/client_connection.dart
src/contracts/_index.dart         src/resilience/circuit_breaker_interceptor.dart
src/primitives/_index.dart        src/resilience/rate_limiter.dart
src/rpc/streams/_index.dart       src/resilience/retry_interceptor.dart
src/codec/special_cbor.dart       src/integration/rpc_server_interface.dart
```

So `package:rpc_dart/rpc_dart.dart` is not a surface over the implementation, it
is a dependency OF the implementation. Narrowing it removes names the library
needs from itself.

## Mechanism

A barrel that the implementation imports is load-bearing in both directions.
`hide` there is not an export-visibility change, it is a deletion from the
internal namespace of every file that imports it — which is why seven errors
landed in `lib/` and not one of them in a file I edited.

Reverted; the tree is green (`No issues found!`).

## After

n/a — the change was withdrawn.

## Canary

n/a. The 78 errors ARE the measurement: the hypothesis said "consumers only",
and 7 of them were inside `lib/`.

## Gate

`fvm dart analyze --fatal-infos --fatal-warnings lib test` on `rpc_dart`, after
the revert: `No issues found!`. `loop.py lint` green.

## Not fixed

The boundary. **The prerequisite is now known and it was not in 289's plan**:
the eleven `lib/` files above have to stop importing `package:rpc_dart/rpc_dart.dart`
and import the specific barrels they need instead. Only then does `hide` mean
what 289 assumed.

That is a mechanical edit with a real risk of import cycles — `src/endpoint/_index.dart`
importing `src/rpc/_index.dart` directly may close a loop that going through the
public barrel currently hides — so it needs the cycle checked per file, not a
blanket replace.

Order for the mandate is therefore: **re-point the eleven internal imports →
then `hide` → then `dart:typed_data` → then the doc comments.** Step 0 is new
and this round is what found it.

A one-line comment now sits on the export in `lib/rpc_dart.dart` saying why it
cannot be narrowed, so the next attempt does not rediscover this by breaking the
build.

## Links

RPC-04 (`applied:` gains 290). Round 289 is the plan this corrects.
