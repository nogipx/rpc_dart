---
round: 311
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: none
commit: yes
---

# Round 311 — a fallback that could never fire

## Target

The owner asked whether more refactoring remains. RPC-25's step 1 was run across
the transports rather than reasoned about — the correction round 310 paid for.

Three sibling pairs came back. Two are reported here as NOT findings, which is
the point of recording them.

## Hypothesis

After 308-310 the obvious duplications are gone, so what step 1 returns now will
mostly be legitimate: identical code that is identical because it is correct. A
round that cannot say "no finding" about most of its candidates is not applying
the lens, it is looking for work.

## Before

Step 1, and step 3 on each result:

```
candidate                       copies   drift        verdict
_fcWindow  (http2 pair)              2   see below    FINDING
RpcMessageParser(...)  (http2)       2   none         not a finding
_notify  (ws + http2, from 309)      2   none         not a finding
```

`RpcMessageParser(...)` is constructed byte-identically in both http2
transports: same four policy fields, same `Parser-$streamId` logger label.
Extracting it would save six lines and add an indirection between a transport
and the limits it applies. **No drift, no finding** — the bar RPC-25 set with
`_notify` in 309.

## Mechanism

`_fcWindow` was byte-identical in both http2 transports too, so by that bar it
should also have been left alone. Reading it against the POLICY rather than
against its twin is what made it a finding:

```dart
int get _fcWindow =>
    _policy.flowControlWindowBytes ??
    const RpcSecurityPolicy().flowControlWindowBytes ??
    4 * 1024 * 1024;                                    // <- unreachable
```

`RpcSecurityPolicy`'s const constructor declares
`flowControlWindowBytes = 4 * 1024 * 1024`, so
`const RpcSecurityPolicy().flowControlWindowBytes` is never null and **the third
clause can never evaluate**. Two copies of dead code, each restating the
policy's default as a literal.

The analyzer cannot see it, and that is why it survived: the field is typed
`int?`, so `dead_null_aware_expression` has nothing to fire on — only the const
VALUE is non-null, which requires reading the constructor.

It is not merely dead. It is a second place claiming to know the default, so
changing `RpcSecurityPolicy`'s default leaves two transports quietly asserting
the old number as a floor.

**The middle clause is the one worth documenting, and it is deliberate.**
`RpcSecurityPolicy.flowControlWindowBytes` documents null as "disable", and its
own doc advises transports with native flow control — HTTP/2 — to do exactly
that. So an operator following that advice sets null and HTTP/2 applies 4 MiB
anyway. Correct, because the two mechanisms are not the same one: disabling the
rpc-level GRANTS is right for HTTP/2, leaving the un-consumed bound off is not,
since the bytes still arrive and still have to go somewhere. Nowhere said so.

`unconsumedWindowFor(policy)` in `rpc_http2_common.dart` now holds the
resolution once, with that explanation, and ends in `!` rather than a literal —
so if the policy default ever becomes null this fails loudly instead of silently
substituting a number the transport invented.

The helper went into the file round 307 made properly internal, which is where a
package-private shared helper belongs: no new public promise.

## After

```
_fcWindow copies                 2 -> 1 resolver
unreachable clauses              2 -> 0
literals restating the default   2 -> 0
```

## Canary

Switch the fix off and nothing breaks — which is the honest statement about dead
code, and why it needs a different witness than a defect does.

The proof of deadness is the const constructor, read: `flowControlWindowBytes =
4 * 1024 * 1024` at `security_policy.dart:194`. The proof that it now fails
loudly is the `!`: make that default null and `unconsumedWindowFor` throws,
where the old form returned 4 MiB and carried on.

Suite: 14 packages, 0 failures — the extraction changed no behaviour.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1311/1311.

## Not fixed

Scope was checked rather than assumed: `grep -rn "const RpcSecurityPolicy()\."`
returns five more sites, all in core's `responder_pipeline.dart`, and all use a
ternary on `is IRpcSecurityPolicyAware` with no third clause. The dead-fallback
shape was unique to the two http2 copies.

## Links

RPC-25 (`applied:` gains 311). The lens gains its counterweight: **most step-1
results are not findings**, and this round reports two candidates it declined —
`RpcMessageParser` and `_notify` — with the reason. What made `_fcWindow`
different is that the drift was not against its twin but against the POLICY it
reads: identical copies can BOTH be wrong, and comparing them to each other says
nothing about that.
