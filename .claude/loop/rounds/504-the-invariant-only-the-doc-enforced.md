---
round: 504
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-142 — new
commit: yes
---

# Round 504 — the invariant only the doc enforced

## Target

The method-path grammar in `core/metadata.dart` — twentieth in the audit's rank.

Lens RPC-08, shape 1, in the form round 501 generalised it: *N places that make the
same KIND of decision; if one is argued for and the other is a fallthrough, the
fallthrough is the finding.* The two places here are documented inverses of each
other and live twenty lines apart. `rpcMethodPathFromKey` splits a key on the LAST
dot and its doc states the invariant that makes that correct — *"a service name may
contain them, a method name may not"*. `parseRpcMethodPath` applied ONE token
pattern to both halves of the path, and that pattern admits dots.

So the invariant was enforced by a sentence. Reading either function alone, both are
fine.

## Hypothesis

`/a.b/c` and `/a/b.c` produce the same binding key, so a request dispatches to a
method the caller did not name.

## Before

Registered: service `a.b`, methods `c` and `secret` — nothing unusual anywhere.

```
/a.b/c        -> reached a.b/c        <- control, the honest path
/a/b.c        -> reached a.b/c           names service "a", not "a.b"
/a/b.secret   -> reached a.b/secret      names service "a", not "a.b"
/a/c          -> status 12            <- control, must be UNIMPLEMENTED
/zzz/c        -> status 12            <- control
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b113_dotted_key_collision.dart`

**CONFIRMED, and the lead's own severity estimate is wrong.** It says the defect
needs a dotted METHOD name to be registered and calls the likelihood low. It does
not: the registration above is an ordinary package-qualified gRPC service, which
`parseRpcMethodPath`'s comment explicitly supports (`myapp.v1.UserService`), with
ordinary method names. Only the REQUEST is crafted. Holding the registration fixed
and varying the path is what showed that.

The two UNIMPLEMENTED controls are what make the misroutes mean something: without
them, two rows of "reached" are equally consistent with a responder that dispatches
anything.

## Mechanism

```dart
final RegExp kMethodTokenPattern = RegExp(r'^[A-Za-z0-9_.-]+$');
...
if (!kMethodTokenPattern.hasMatch(parts[1]) ||
    !kMethodTokenPattern.hasMatch(parts[2])) return null;
```

One pattern, both halves. A binding is keyed `'$service.$method'` and read back by
splitting on the last dot, which is a bijection only if exactly one half may contain
a dot. With both admitting dots, `('a', 'b.c')` and `('a.b', 'c')` are distinct pairs
with one key, and the registry cannot tell them apart.

The name `kMethodTokenPattern` was already half the bug: it says *method*, and it was
being asked about services too.

## After

```
/a.b/c        -> reached a.b/c        <- control, unchanged
/a/b.c        -> status 3
/a/b.secret   -> status 3
/a/c          -> status 12            <- control, unchanged
/zzz/c        -> status 12            <- control, unchanged
```

Two patterns: `kServiceTokenPattern` keeps the dot, `kMethodTokenPattern` loses it.
Not public API — checked by compiling an external import against the barrel — so the
change is internal. Only one dotted method name existed in the whole repo, in a test
this round's predecessor wrote.

**And the responder refuses it, not only the caller.** That distinction is the
round's main methodological cost. `RpcChannelTransport.sendMetadata` validates
outbound metadata against the same policy, so the first reading of the after-table
was `status 3` produced entirely inside the caller — which says nothing about a peer
that is not this library. A third level was needed: `RpcMetadata`'s plain constructor
does not validate and `RpcChannelTransport` accepts a channel, so a hand-built frame
goes straight in past the caller transport.

```
raw frame into the responder      before                    after
/a.b/secret (honest, control)     accepted, awaiting data   accepted, awaiting data
/a/b.secret                       accepted, awaiting data   grpc-status 3
```

The control is load-bearing there: a unary call needs a payload the frame does not
send, so an ACCEPTED path answers nothing at all, which is indistinguishable from a
frame that was ignored. Only against a path known to be accepted does the other
row's status mean "refused".

Regression: `test/core/a_method_name_may_not_contain_a_dot_test.dart`, 4 WITNESS and
4 GUARD, including a parse-then-format round-trip — the invariant itself, stated as
a test rather than as a sentence.

## Canary

The single permissive pattern restored in place. All four WITNESS tests fail with
the values they name:

```
/a/b.c does not reach a.b/c   Expected: 'status 3'  Actual: 'reached a.b/c'
/a/b.secret                   Expected: 'status 3'  Actual: 'reached a.b/secret'
a dotted method is refused    Expected: null        Actual: (a, b.c)
the RESPONDER refuses         Expected: '3'         Actual: 'accepted'
```

All four GUARDs stay green, including the round-trip — which is the interesting
part: parse-then-format is the identity for every path that is legal under BOTH
grammars, so the round-trip test alone would never have found this. It guards the
fix without being able to witness the defect.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run license:check` compliant.
`format:check` failed once on this round's own new test file and passed after
`fvm dart format`.

## Not fixed

**The escalation this round started with is REFUTED, and that is the most useful
thing in it.** The obvious reading of a service-boundary confusion is an
authorisation bypass, so an arm was built for it: a responder interceptor denying
service `a.b` by name. It denied both paths and the guard saw `a.b/secret` twice.
The responder resolves the binding before the middleware context exists, so an
in-process interceptor sees the RESOLVED service name, never the caller's split.
There is no in-process bypass and the record says so.

**What is left is a hazard OUTSIDE the library, and it is not fixed by this change
for existing deployments.** Anything filtering on the path string upstream of the
responder — a reverse-proxy rule, a gateway ACL, an access log — saw two distinct
strings for one method, so a rule written against `/a.b/` did not cover
`/a/b.`. After this fix the responder refuses the second form, which closes it going
forward; it does nothing about logs already written or rules already trusted.

**`rpc_dart_http`'s responder was not run.** It calls `policy.isValidMethodPath`, so
it inherits the fix by construction, but that is an argument and not a measurement.

**The status is INVALID_ARGUMENT, not UNIMPLEMENTED.** A crafted path is now
malformed rather than absent, which is honest but tells a prober that the grammar
refused it rather than that the method does not exist. Unified with every other
malformed-path refusal, so changing it is a separate question about the whole
refusal path.

## Links

Lens RPC-08 — third distinct KIND of sibling pair it has paid on (transports,
interceptors, and now two documented-inverse functions); worth the curate pass
asking whether that detector has outgrown the parity matrix it was derived from.
Bench P-142 (new). Lead B-113 (closed). Round 503's second failure route existed
only through this ambiguity, and its probe printed this defect in its after-table.
