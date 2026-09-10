---
round: 294
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none
commit: yes
---

# Round 294 — four copies of one rule

## Target

Second file of the doc audit, taken from RPC-23's ranking rather than by eye:
`core/transport.dart`, 238 doc lines. It holds `IRpcTransport`,
`RpcTransportMessage` and the four capability interfaces — the surface a
third-party transport author reads.

## Hypothesis

RPC-23's detector asks three questions per comment. The third — *could a caller
choose without it* — is the one that bites on an interface, where the reader is
an implementer and the question becomes *could I implement this without it*.

## Before

```
core/transport.dart      238 doc lines / 559 total    43%
```

The four capability interfaces carried the bulk, and one paragraph appeared in
**all four of them, near-verbatim**:

> Kept separate from [IRpcTransport], like [IRpcStreamReset], so adding it does
> not break third-party transports that `implements IRpcTransport`.

## Mechanism

Copy-paste is what a comment does instead of a concept. That rule is about the
capability PATTERN, not about any one capability, so it belongs once — stated on
the first interface, referred to from the other three.

The rest was narrative: how HTTP/2 throws when you send on a half-closed stream,
which rounds fixed the stream-id cursor, a measured reconnect trace. An
implementer needs the CONSTRAINT — *the cursor must survive close* — not the
investigation that discovered it.

## After

```
core/transport.dart      212 doc lines    (-26)
core/lib/src total       4319             (-111 since 293's baseline of 4430)
```

Kept, because deleting them would cost an implementer correctness:

- the cursor must survive `close()`, and why there is no earlier read point
- `returnFlowCredit` MUST follow `deferFlowCredit` or the peer stalls
- not implementing `IRpcSecurityPolicyAware` means defaults, not "no limits"
- the CANCELLED-metadata fallback is illegal once the side is half-closed

Cut: the traces, the round references, the four copies.

## Canary

`public_member_api_docs` is enabled, so a comment DELETED rather than rewritten
goes red rather than silently vanishing. The analyzer is clean, which is what
says these were rewritten.

## Gate

`melos run analyze` — 0 errors across the workspace. `rpc_dart` suite green.
`fvm dart format lib` — 0 changed.

## Not fixed

The queue, still ranked by the detector:

```
responder_pipeline.dart  308     base_processor.dart  227
channel_transport.dart   303     context.dart         176
rate_limiter.dart        161     security_policy.dart 151
```

`responder_pipeline.dart` is now largely INTERNAL — round 291 hid its types — so
its comments answer to a maintainer rather than a caller. RPC-23's third
question changes shape there and the lens does not yet say how; worth settling
before spending a round on 308 lines.

## Links

RPC-23 (`applied:` gains 294). Round 293 derived the lens; this is its second
application and the first where the detector, not instinct, chose the file.
