---
round: 458
verdict: FIXED
packages: [rpc_dart, rpc_dart_http]
lens: RPC-25
bench: P-109 — new
commit: yes
---

# Round 458 — a message at exactly the limit

## Target

B-80, whose decision was to establish FIRST which limit an HTTP body is checked
against, because the missing +5 is moot if there is no bound.

**Both halves of the lead's premise are false, and reading says so before any
bench.**

## Hypothesis

If the HTTP transports bound the body at all, they bound the RAW body — which is
the gRPC-framed message — against a limit expressed in MESSAGE bytes. That is the
failure `frame_multiplexed_channel`'s +5 exists to prevent, in its own words:
without it the effective limit "becomes `maxMessageLengthBytes - 5`, rejecting a
message at exactly the limit".

## Before

The lead says the rule has two homes, both in core, and that "neither
`rpc_dart_http` nor `rpc_dart_http2` references `maxMessageLengthBytes` at all
outside one doc line". Corrected:

```
THREE homes for the +5, not two
  security_policy.dart:339          effectiveMaxBufferedBytes
  frame_multiplexed_channel.dart:157
  parser.dart:113                   <- never counted by the lead

SEVEN references in rpc_dart_http, TWO of them enforcing
  rpc_http_responder_transport.dart:338  builder.length > max -> refuse
  rpc_http_caller_transport.dart:196     builder.length > max -> refuse
```

So there IS a bound, and the question is what it is applied to. With the limit
pinned to one message's EXACT serialized length — so "exactly at the limit" needs
no arithmetic about CBOR:

```
channel, limit = exactly the message   ACCEPTED
http,    limit = exactly the message   REFUSED status=8
channel, limit = message + 5           ACCEPTED
http,    limit = message + 5           ACCEPTED    <- control: it is the 5 bytes
```

Probe:
`packages/transport/rpc_dart_http/.dart_tool/probe/a_message_at_exactly_the_limit.dart`

## Mechanism

Two limits with the same name and different units. `maxMessageLengthBytes` counts
a MESSAGE; an HTTP body is a FRAME. Compare one against the other and the
operator's configured ceiling silently becomes five bytes lower — on HTTP only,
while the channel transports add the prefix and honour it exactly.

## After

One accessor, `RpcSecurityPolicy.maxFramedMessageBytes`, used by both HTTP sites
and by the frame channel, which had the rule inline. HTTP now accepts a message at
exactly the limit.

**Bound on the framed size, REPORT the configured one.** An existing test caught
that distinction: it asserts the refusal names the limit the operator set, and
naming `max + 5` names a number they never configured. Its `reason` says the point
was "the configured one rather than the parser's own ceiling" — still satisfied.

## Canary

The responder bound reverted to the message limit in place:

    Expected: 'ok'
      Actual: 'status=8'
    the limit is in MESSAGE bytes and the body carries the 5-byte gRPC prefix;
    comparing the framed length against it makes the real ceiling max - 5

The GUARD is load-bearing here: widening a bound by five bytes is exactly the
change that can remove it, so one byte of message over must still be refused —
and is, on both transports.

## Gate

`melos run analyze` SUCCESS. `format:check` and `license:check` SUCCESS.
`rpc_dart_http` 140 passed. `rpc_dart` 1676, `rpc_dart_http2` 249,
`rpc_dart_websocket` 183 — each green in its own run.

**`test:unit` over all 14 packages is flaking under load, and here are the names**,
because the config asks for them before anything is called a flake:

```
run 1  rpc_dart_websocket, keepalive/reclaim family   (name not captured)
run 2  rpc_dart_http, caller_response_limit           REAL -- fixed, see above
run 3  rpc_dart_isolate, close_releases_the_isolate
run 4  rpc_dart, response_sink_stops_at_the_ending
```

A DIFFERENT test each run, all wall-clock families, at load average 7.5 to 15.4
after hours of back-to-back suites — which is the batch the config predicts. Each
passes alone, and `rpc_dart_isolate` passes 91/91 through `melos exec` with the
same command. Run 2 was the exception and was a real failure of this round's own
change.

**So the workspace gate has not been seen green end-to-end since run 2's fix.**
Every package is green individually; that is weaker and it is what this round has.

## Not fixed

**`parser.dart:113` keeps its own copy of the formula.** It is the parser's default
for `maxBufferedBytes`, a buffer bound rather than a single-frame bound, so it is
the same arithmetic answering a different question. Left deliberately; folding it
in would make one accessor mean two things.

**http2 was not touched.** Its parsers take `maxMessageLength: maxMessageLengthBytes`
and the parser applies the +5 itself at `:113`, so the message limit reaches it in
the right units. Not measured, which is why B-79 — the neighbouring lead about what
http2 bounds at all — stays open.

**The two transports refuse an oversized message with different statuses**:
RESOURCE_EXHAUSTED on HTTP, UNAVAILABLE on the channel pair, the latter because
`closeOnOversizedFrame` closes the connection on a server. Pre-existing and
explained; not this round's subject.

## Links

- RPC-25 — two limits with one name and different UNITS; the divergence is the
  unit, not the value
- P-109 — a message at exactly the limit, per transport
- B-80 — closed by this round
- B-79 — still open; what http2 bounds was not measured here
