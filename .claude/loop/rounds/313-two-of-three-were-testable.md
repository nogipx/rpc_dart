---
round: 313
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-25
bench: none
commit: yes
---

# Round 313 — two of the three were testable

## Target

Round 312's own "Not fixed" list, which named three fixes still without
witnesses and gave each a reason:

> - **309's log unification** — nothing automated reads log levels.
> - **310's isolate web `send`** — needs a browser.
> - **311's dead clause** — dead code has no runtime witness by definition.

Two of those three are wrong. This round is the correction, and the pattern is
the one round 310 already paid for: **a claim that something cannot be tested is
a claim, and it needs the check.**

## Hypothesis

"Untestable" was asserted from the shape of each fix rather than from the APIs
available. Looking at the APIs changes at least one answer.

## Before

```
fix                    claimed          actual
309 log unification    untestable       LogController.stream is public
311 dead clause        untestable       unconsumedWindowFor is a callable function
310 isolate web send   platform-blocked  platform-blocked
```

**309.** `LogController` exposes `Stream<LogRecord> get stream` and
`LogScope scope(String)`. Levels and messages are readable; `LogRecord` is
sealed over events and spans, and `LogEvent` carries `level` and `message`.
Nothing about log assertions is impossible — I had simply not looked.

**311.** The DELETED clause has no runtime witness, which is what made the claim
feel true. The FUNCTION's contract does, and that is what needed pinning:
`unconsumedWindowFor` is a plain function reachable from tests by the route
round 307 established.

## Mechanism

**`drain_until_idle_test.dart`, four tests in core.** The witness is placed on
`drainUntilIdle` rather than on three servers, because all three now call it —
one implementation, one set of assertions, and every server inherits them:

- an idle drain returns in under 200 ms and logs NOTHING (a drain with nothing
  to do is not an event, and it must not pay the 25 ms tick);
- a converging drain logs the start line at INFO — the level http used to emit
  at DEBUG, so an operator at the default level saw no drain at all — and the
  "Drain complete" line, which two of the three servers never had, so success
  was signalled by an absence;
- an expiring drain warns with the count and "closing anyway", and RETURNS
  rather than waiting on a number that never falls;
- `unit` names what is counted, so "3 in flight" is readable.

**`unconsumed_window_test.dart`, four tests in http2.** The valuable one is the
surprising clause: `RpcSecurityPolicy.flowControlWindowBytes` documents null as
"disable" and its own doc advises HTTP/2 to set it, and setting it does NOT
disable this bound. That is deliberate — the two mechanisms differ — and until
311 it was written nowhere and checked by nothing.

The last test asserts `const RpcSecurityPolicy().flowControlWindowBytes` is
non-null, which is the thing `unconsumedWindowFor`'s `!` leans on. If the policy
default ever becomes null, that test fails first and names the reason instead of
the transport throwing at runtime.

Neither assertion restates 4 MiB as a literal: both read the policy, so moving
the default moves the test with it. Two copies of the transport used to restate
it, and that is what 311 removed.

## After

```
                 before   after
rpc_dart          1429     1433
rpc_dart_http2     200      204
```

## Canary

These are witnesses rather than fixes, so the canary question is whether they
can FAIL. Both were written against code that already passes, which is the weak
case — so each carries an assertion that is false on the pre-fix behaviour and
not merely true today:

- the INFO/`Drain complete` assertions fail on http's old DEBUG start and on
  websocket's missing success line;
- `null does NOT disable` fails if the middle `??` is dropped, which is the edit
  a reader who believes the policy doc would make.

`drainUntilIdle` also has its own guard against a vacuous pass: the idle test
asserts a TIME bound, so a version that polled once regardless would be caught.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, 0 failures; core 1429 -> 1433,
http2 200 -> 204.
`melos run format:check` — SUCCESS after formatting the new core test, which the
gate caught.
`melos run license:check` — compliant, 1316/1316.

## Not fixed

**310's isolate web `send` remains genuinely unwitnessed, and this is the
determination rather than a repeat of the assertion.** Three routes were
considered:

1. **Through the public API** — `RpcIsolateTransport.spawn` needs a real
   `Worker`, so it needs a browser. `test:unit` cannot; `test:wasm` is a
   different package with its own harness.
2. **Directly on the channel** — `_WebMultiplexedChannel` takes its `send` as a
   constructor parameter, so a throwing stub would reach the defect in one line.
   It is library-private, and Dart privacy is per-library: no test can name it.
3. **Making it visible** — `@visibleForTesting` on the class, or a factory. That
   changes production code shape to admit a test.

(3) is the only one that works, and it is a real trade rather than an oversight:
it widens a transport's surface for a platform the ordinary gate does not run.
**Filed as B-31 for the owner** rather than decided here.

## Links

RPC-25 (`applied:` gains 313). B-31 (new).

The lens gains the counterpart to what 310 taught it: "the lens does not apply"
needed the grep, and **"this cannot be tested" needs the API check**. Both are
claims that feel like conclusions. Two of the three here dissolved on one look
at what the logger and the function actually expose.
