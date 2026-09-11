---
round: 332
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none
commit: yes
---

# Round 332 — the shared class nobody tested

## Target

Round 331 invented a criterion — *ask which copy the TESTS reach, not only
whether the copies agree* — on one file. A criterion invented on one instance is
a guess about a class, so it is worth one round to point it somewhere else.

`RpcStreamRouter` is the natural target: round 308 extracted it from four
hand-rolled copies precisely because one had drifted where nothing could see it.
If deduplication buys coverage, the class that deduplication produced is where
that should show.

## Hypothesis

The extraction already bought the coverage. Four transports share the class, so
any of their suites should catch a break in it.

## Before

Wrong, and worse than round 331's case. Ablating the rule the class exists to
enforce — `operator []` returning the SAME stream on a repeated lookup, which is
exactly what http2's caller had got wrong before 308:

```
                                        result
rpc_dart_http    ablated                +123   all passed
rpc_dart_http2   ablated                +204   all passed
```

Two suites, 327 tests, neither notices. Then the question round 330 taught —
is the path even reached? — instrumented rather than assumed:

```
reuse branch hit during the suites      rpc_dart_http    0 times
                                        rpc_dart_http2   1 time
```

**Reachable, and watched by nothing.** That is L-04 case 1 (untested), not case
2 (unreachable), and the distinction took one `print` to settle.

`RpcStreamRouter` had no test file at all.

## Mechanism

A shared class inherits its callers' coverage, not the union of it. Four
transports use this router, but each exercises it only through its own
behaviour; no transport test asks the router the question the class is FOR.
Round 308 moved the code into one place and left the testing where it was —
which is to say nowhere.

## After

`test/core/stream_router_test.dart`, four tests against the class rather than
through a transport, because the rule belongs to the class and all four
transports inherit it at once:

```
rpc_dart   +1435 ~1  ->  +1439 ~1
```

Beyond the reuse rule they pin: ids stay separate, end-of-stream closes the
stream AND drops the entry (the leak signal `health()` reports through
`length`), and `addError` reaches one stream rather than every concurrent call —
the last being a defect this project has actually had.

## Canary

The ablation both transport suites called green:

```
operator [] always mints a fresh controller
  rpc_dart_http / rpc_dart_http2      +123 / +204     all passed
  stream_router_test                  Expected: [7]   Actual: []
```

**The first version of the witness was wrong** and the failure said so: it tried
to `listen` twice and got `Bad state: Stream has already been listened to`. The
controllers are single-subscription, so "both lookups can listen" is not the
rule and never was. What the branch protects is the STORED controller — ablated,
the second lookup overwrites the map entry and `add` delivers to a controller
nobody is listening to. The corrected test subscribes once and asks again
without subscribing.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures — `rpc_dart`
`+1439 ~1`, `rpc_dart_http2` `+204`, `rpc_dart_websocket` `+137`, `rpc_dart_http`
`+123`.

## Not fixed

The three remaining `add`/`remove`/`closeAll` paths have no dedicated test
either; the four written here cover the rules with a known failure history. The
transports' own wrappers — http2's `_fcMetered`, the http caller's
`_closedDuringCall()` — stay tested where they are, since those are the
specialisations RPC-25 says not to merge.

## Links

RPC-25 (`applied:` gains 332). The criterion from 331 generalises, and this is
the sharper form of it:

> **Extracting shared code moves the code but not the tests.** A class four
> callers depend on inherits their coverage of their own behaviour, not coverage
> of the rule it was extracted to hold. After an extraction, ask what test
> exercises the NEW unit — round 308 created this class and round 332 found it
> had none, 24 rounds later.

L-04 for the reachable-versus-untested distinction, settled here with one
`print` rather than a rebuilt bench — the lesson round 330 paid for.
