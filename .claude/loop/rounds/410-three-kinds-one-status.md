---
round: 410
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the evidence is a complete enumeration of eleven construction sites plus the status each now carries, asserted in the canary
commit: yes
---

# Round 410 — three kinds, one status

## Target

The last core type on the wrong base, named in round 408's `## Not fixed`:
`RpcFrameException extends RpcException`, not `RpcStatusException`. So
`wireStatusFor`'s second branch — which hardcodes INTERNAL — answered every
frame failure the same way.

## Hypothesis

All frame failures are one kind, so one status is right.

## Before

Refuted by enumerating every construction site. There are eleven, and they are
three kinds:

```
kind                     sites  where
a limit, correctable         4  channel_frame.dart:105, :127
                                frame_multiplexed_channel.dart:383, :423
malformed framing            6  channel_frame.dart:267, :274, :278, :285,
                                :295, :304
a policy violation           1  channel_transport.dart:680
```

All eleven reached a peer as INTERNAL. **For the four limits that is the wrong
answer twice over**: grpc-go and grpc-java both answer RESOURCE_EXHAUSTED, and
`RpcRetryInterceptor` treats RESOURCE_EXHAUSTED as transient and INTERNAL as
final — so a sender that could have corrected itself by sending less was told to
never try again.

**The split is not invented here.** It is the one `_answerFramingViolation`
already makes on http2 — *"every RpcException RpcMessageParser raises is a
RESOURCE LIMIT … anything else reaching here is malformed framing, which is
INTERNAL"* — and the policy status is the one
`RpcChannelTransport._validateInbound` already sends as a trailer
(`forTrailer(RpcStatus.invalidArgument)`). The type was the only place that did
not know.

## After

`RpcFrameException extends RpcStatusException`, with a named constructor per
kind:

```
RpcFrameException(msg)          RpcStatus.internal            6 sites, the default
RpcFrameException.limit(msg)    RpcStatus.resourceExhausted   4 sites
RpcFrameException.policy(msg)   RpcStatus.invalidArgument     1 site
```

The default stays INTERNAL deliberately: the six malformed sites are unchanged,
and `platform_error_redaction_test` pins that a frame exception's message is
forwarded rather than redacted — which still holds, because this is still
library-authored and still in the hierarchy.

## Mechanism

`wireStatusFor` was not touched. Before, `RpcFrameException` took its
`error is RpcException` branch, which forwards the message under a hardcoded
INTERNAL. Now it takes the `RpcStatusException` branch above it, which forwards
the status the type carries. Same function, different branch, because the type
moved.

## Canary

Two tests added to `test/errors/one_hierarchy_test.dart`, nine in that file now:

- each kind carries its own status, including the assertion that the DEFAULT is
  still INTERNAL — the regression that would silently re-flatten the six
  malformed sites
- a frame failure still forwards its diagnostic (`contains('max: 4')`, and
  explicitly `isNot(kInternalErrorWireMessage)`), because that text is what lets
  a sender correct itself and is the whole reason these types are in the
  hierarchy

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant.

**The workspace suite needs reporting honestly: 2 of 8 runs went red and neither
was reproducible or nameable.** One came from a shell line that chained three
melos commands; the other reported `rpc_dart_websocket +176 -1` with no test
named in the aggregated output. Against that: **six greens, four of them
back-to-back**, and the websocket suite alone is 3/3. Every targeted attempt to
capture the failure text produced a green run instead.

L-14 says the tell for a real defect is that it survives the remedy a flake
would respond to. This one did not survive reduced load. But L-14 also says name
it, and I could not — so it is recorded as unnamed rather than dismissed. The
change touches `channel_transport.dart`, which the websocket transport uses, so
that is not a free assumption.

## Not fixed

The goal's last piece: the **83 raw `StateError` / `ArgumentError` sites**.
Most are correct as-is — `ArgumentError` for a programming mistake is idiomatic
Dart — so they need the reachability split first: a programmer error, versus a
runtime condition a peer can cause. That is the next round's job, and it is a
classification pass before it is an edit.

B-58 is untouched and remains the owner's: whether a framing violation should
COUNT toward the connection-kill backstop is a different question from which
status it carries, and this round answers only the second.

## Links

- Round 408 — which named this in its `## Not fixed`
- B-58 — the neighbouring question, deliberately not decided here
- RPC-25 — the split copied from the sibling that already made it
