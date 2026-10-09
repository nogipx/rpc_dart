---
file: packages/core/rpc_dart/.dart_tool/probe/b113_dotted_key_collision.dart
round: 504
commit: 54382ce7
paths: [packages/core/rpc_dart/lib/src/core/metadata.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-142 — which paths reach one method?

## Why it exists

The lead is about a key format, but a key format is not observable. What is
observable is which paths a caller can use to reach a handler, so the rig holds the
REGISTRATION fixed and varies the path — one ordinary package-qualified service,
`a.b`, with ordinary methods `c` and `secret`, and nothing unusual registered
anywhere.

That last part is the point. The lead says the defect needs a dotted METHOD name to
be registered and calls it low-likelihood. Fixing the registration and varying only
the request is what tests that claim, and it is false: the ambiguity is reachable
against a completely ordinary service.

## The harness

Three levels, because the first two do not answer the question a grammar fix has to
answer.

1. **Caller API.** `unaryRequest` with mismatched service/method splits. Enough to
   show the misroute, and NOT enough to show where the refusal lands after a fix —
   `RpcChannelTransport.sendMetadata` validates outbound metadata against the same
   policy, so an ordinary call is refused locally.
2. **An authorising interceptor.** A responder interceptor that denies one service
   by name, to ask whether the ambiguity carries past a guard.
3. **A hand-built frame.** `RpcMetadata`'s plain constructor does not validate, and
   `RpcChannelTransport` takes a channel, so the frame goes straight into
   `RpcDirectMultiplexedChannel.pair()` past the caller transport entirely. This is
   the only level that speaks about a peer which is not this library.

## The numbers (round 504)

Registered: service `a.b`, methods `c` and `secret`.

```
                  before                     after
/a.b/c            reached a.b/c              reached a.b/c        <- control
/a/b.c            reached a.b/c              status 3
/a/b.secret       reached a.b/secret         status 3
/a/c              status 12                  status 12            <- control
/zzz/c            status 12                  status 12            <- control

interceptor denying service "a.b":
/a.b/secret       status 7                   status 7             <- control
/a/b.secret       status 7                   status 3
guard saw         [a.b/secret, a.b/secret]   [a.b/secret]

raw frame into the responder:
/a.b/secret       accepted, awaiting data    accepted, awaiting data  <- control
/a/b.secret       accepted, awaiting data    grpc-status 3
```

## Measures

What the caller gets back: a handler's return value, or a gRPC status. For the raw
level, the status header on the response frame, or its absence.

The last needs care. A unary call requires a payload the hand-built frame does not
send, so a path the responder ACCEPTS produces no answer at all — indistinguishable
from a frame that was ignored. The honest path is therefore sent through the same
code as a control, and it reads "accepted" in both tables; only against that does
the dotted path's `grpc-status 3` mean "refused" rather than "the rig broke".

## Control

**Four, and one of them refuted a hypothesis this round started with.**

`/a.b/c` — the honest path — must keep working, or the fix is just a denial of
service.

`/a/c` and `/zzz/c` must stay UNIMPLEMENTED. Without them the two misroutes are
equally consistent with a responder that dispatches anything to anything.

`/a.b/secret` through the raw level must read "accepted" in both tables, as above.

**The interceptor level was built to confirm an auth bypass and refuted it.** The
guard saw `a.b/secret` for BOTH calls and denied both: the responder resolves the
key before the middleware context is built, so an in-process interceptor sees the
RESOLVED service name, not the caller's split. The escalation was wrong and the
measurement is what said so.

## What it establishes, and what it does not

Establishes: with one token pattern for both halves of the path, `/a/b.c` and
`/a.b/c` produce the key `a.b.c` and the responder dispatches both to the same
handler — against an ordinary package-qualified service, with nothing unusual
registered. After splitting the pattern in two, the crafted paths are refused
INVALID_ARGUMENT at the caller AND at the responder, while the honest path and the
UNIMPLEMENTED cases are unchanged.

Does NOT establish an authorisation bypass inside the process; the interceptor level
shows the opposite. What remains is a routing-correctness defect plus a hazard that
lives OUTSIDE the library: anything filtering on the path string upstream of the
responder — a reverse proxy rule, an access log, a gateway ACL — sees two distinct
strings for one method, and a rule written against one of them does not cover the
other.

Nor does it cover the transports that parse paths themselves; `rpc_dart_http`'s
responder calls `policy.isValidMethodPath`, so it inherits the fix, but that was
not run here.

## Reading

rpc_dart — holds the REGISTRATION fixed and varies the PATH, which is what
refuted the lead's "low likelihood": an ordinary package-qualified service is
enough and only the request is crafted. **Three levels, and the first two
cannot answer what a grammar fix has to answer** — the caller transport
validates outbound metadata against the same policy, so an ordinary call is
refused locally and says nothing about a foreign peer; the third level
hand-builds the frame past it. Its controls include `/a/c` and `/zzz/c`
staying UNIMPLEMENTED, and the honest path through the raw level reading
"accepted" in both tables — a unary call needs a payload the frame omits, so
an accepted path answers nothing and that is otherwise indistinguishable from
being ignored. **The interceptor level was built to confirm an auth bypass and
refuted it.**
