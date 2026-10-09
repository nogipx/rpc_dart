---
round: 490
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-23
bench: P-129 — new
commit: yes
severity: S2
---

# Round 490 — the knob that names the thing bounded nothing

## Target

B-99, sixth in the audit's rank and the third HTTP/1.1 one, taken now because
round 489 had just measured the same file's buffers and the context was in hand.

Scope decided before the fix, and it is narrower than the lead's sketch. The
sketch asks for a stream-level budget, chunk-by-chunk parsing and a doc
correction. Measuring first showed **both ceilings are already raisable by
knobs that exist** — so what remains is that one of them was wired to the wrong
knob, and that nothing told a reader either ceiling was there. Adding a third
budget would be new public surface for a problem configuration already solves.

Lens RPC-23, prose that carries something the code does not do — here the
strongest form it names, a doc that promises an outcome the code refuses.

## Hypothesis

A finite server stream fails past two ceilings the class doc does not mention:
the body's byte bound, and `maxMessagesPerChunk` applied to a whole stream
because the body reaches the parser as one chunk. Refuted if the channel
transport failed the same shapes, or if either ceiling turned out not to fire.

## Before

```
                       http                      channel (control)
1500 x 10 B      FAILED after 0 status=8       OK 1500
20 x 1 MiB       FAILED after 0 status=8       OK 20
100 x 10 B       OK 100                        OK 100

client-stream upload, 1500 x 10 B      status=8
client-stream upload, 4 x 1 MiB        got:4
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b99_stream_caps.dart`

Both ceilings confirmed, in both directions, with a control that passes every
shape. The class doc's *"A FINITE stream SUCCEEDS"* is false past either.

## Mechanism

Two different kinds of limit, one cause each:

- **bytes**: all three body sites bounded a whole BODY by
  `maxFramedMessageBytes` — one message plus its prefix. On this transport a
  body is a whole stream, so the knob named for this case,
  `maxBufferedBytes` ("max buffered bytes for reassembly/parsing"), bounded
  nothing. Raising it did not move the ceiling.
- **count**: `maxMessagesPerChunk` bounds one parse call's result list. The body
  arrives as a single chunk, so a per-chunk guard bounds the whole stream at
  1024 messages.

## After

```
each knob raised alone, http           before      after
+maxBufferedBytes      20 x 1 MiB      FAILED      OK 20
+maxMessagesPerChunk   1500 x 10 B     OK 1500     OK 1500
```

The three body sites now use `effectiveMaxBufferedBytes`. **The default is
unchanged by construction** — it falls back to `maxMessageLengthBytes + 5`,
which is the same number `maxFramedMessageBytes` gives, and that identity is
what preserves round 458's property that a message at exactly the configured
limit is accepted.

The class doc now states both ceilings, names the knob for each, and carries the
measured shapes.

## Canary

The caller's limit put back to `maxFramedMessageBytes` — the WITNESS fails with
`RpcStatusException(8): HTTP response body exceeds the configured limit of
4194304 bytes ... Raise RpcSecurityPolicy.maxBufferedBytes if this is expected`.
Both CONTROLs and both GUARDs stay green, including the one that pins the
DEFAULT still failing.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant. Round 458's
`a_message_at_exactly_the_limit_test.dart` is in that run and is the test that
would have caught a default shifted by five bytes.

## Not fixed

**The DEFAULTS are deliberately unchanged**, and a finite stream past them still
fails rather than degrades. Changing them is a capacity decision: raising either
raises what one call may buffer, on a transport that must hold the whole thing.
What the round changes is that the ceilings are now visible in the doc and
reachable by configuration.

**Chunk-by-chunk parsing is not done.** It would make `maxMessagesPerChunk` mean
what its name says here, and it is the only route to lifting the count ceiling
without raising a global knob — but it is a change to how the transport emits,
not a limit being read from the wrong field, and it needs its own bench.

**The ping-pong bidi is unmeasured.** The lead says it blocks until its deadline
because nothing is sent before `finishSending`. Plausible from the wire format
and not witnessed; nothing in this bench would see a hang. Left in the lead.

Round 489's response ceiling, shipped one round ago, used the same wrong knob
and is corrected here — which is why `+maxBufferedBytes` still read FAILED on
the first attempt at this round's own measurement.

## Links

Lens RPC-23. Bench P-129 (new). Lead B-99 (closed, with two questions left in
it). Round 458 (B-80) chose `maxFramedMessageBytes` for these sites and its
property is preserved; round 489 is the site corrected in passing.
