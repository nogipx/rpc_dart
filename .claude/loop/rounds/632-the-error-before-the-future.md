---
round: 632
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness checks where each shape's error arrives
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 632 — the error before the Future

## Target

B-238, from the audit of 2026-10-02: after `close()`, three of the caller's four
call shapes throw at the call site.

## Hypothesis

`unaryRequest`, `serverStream` and `bidirectionalStream` are not `async` and test
`isActive` before building what they return; `clientStream` moved its guard into
its async closure on purpose and is the one that fails through its Future.

## Before

```
after caller.close():
  unary          throws at the call site
  server-stream  throws at the call site
  bidi           throws at the call site
  client-stream  returns a Future that fails (control)
```

## Control

`clientStream` on the same closed caller: the call returns normally and its
Future completes with `RpcClosedException`.

## Mechanism

RPC-25: the four shapes each carry the same guard, and one copy had been moved
to where the error belongs.

## After

The three return `Future.error` / `Stream.error` with the same
`RpcClosedException`. All four now return normally and fail through what they
return; `test/endpoint` 320 green.

## Canary

The before table is the same witness against the throwing guards.

## Gate

`melos run analyze` and `format` green. The first `test:unit` was red on
`one_rule_for_every_caller_shape_test.dart`, whose closed-endpoint group asserted
the refusal with `throwsA` on a closure: that reads a returned Future and passed
for unary, but not a returned Stream. The group asserts WHO refused (`what:
'Endpoint'`, not the transport underneath), and still does; the two streaming
arms now read it with `emitsError`. Second `test:unit` green (exit 0).

## Not fixed

The `ArgumentError`s for a codec/zero-copy mismatch still throw at the call site:
those are programming errors, which Dart reports synchronously by convention.

## Links

Lead `../backlog/B-238-a-closed-caller-throws-before-the-future.md` — closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 632]`.
Test `packages/core/rpc_dart/test/endpoint/a_closed_caller_fails_the_call_not_the_call_site_test.dart`.
