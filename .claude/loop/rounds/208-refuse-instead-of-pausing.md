---
round: 208
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-01
bench: P-02 — reused
budget: probes 0/3, canaries 2/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record, the bench and both canaries; approved 10 of 10
commit: yes
---

# Round 208 — refuse the stalled call instead of pausing the read

## Target

Not the lens `next` named: an OWNER DECISION outranks everything (SKILL.md step
1), and B-12 acquired one at the end of round 207. The owner chose option 2 —
stop pausing, keep reading, and fail a call past its window — and accepted the
cost explicitly. `next` still names RPC-01 by rank, which this is anyway.

## Hypothesis

Round 207 proved the pause is the enabling condition. Removing it must make the
connection survive, and the per-stream budget must still bound memory — the
ablation that proved the first also showed what losing the second costs
(14286 / 15291 KiB on the wire with nothing bounding it).

## Before

```
P-02, reused unchanged from round 207:

UPLOAD (bidi into a deaf handler)     ping before  stalled  ping@stall  after
  control: handler drains it             pong      68 KiB     HUNG      pong
  case:    client cancels it             pong      68 KiB     HUNG      HUNG

DOWNLOAD (server-stream, paused)      ping before  taken    ping@stall  after
  control: consumer resumes               pong     324 msg    HUNG      pong
  case:    consumer cancels               pong     372 msg    HUNG      HUNG
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/aborted_upload_pool.dart`.

Note the `ping@stall` column: even before any cancel, a merely STALLED call
already blocked every other call on the connection. That is the sharper form of
the same fact and became the first witness.

## Mechanism

package:http2 credits the connection window only for messages it can move into a
stream's queue, and will not move them while that stream's consumer is paused.
rpc_dart paused precisely to throttle, so a stalled call parked up to a whole
connection window as pending; `_closeStreamAbnormally` then discarded it through
`removeStreamMessageQueue` with no `dataProcessed`.

So the pause is gone from both transports. `flowControlWindowBytes` stays as the
budget — bytes handed to a consumer and not yet taken — but reading never stops
and a call past it is FAILED:

- responder: a RESOURCE_EXHAUSTED trailer to the peer, then the same synthesized
  `x-client-cancelled` frame the RST_STREAM path already uses, so the handler
  stops instead of serving nobody.
- caller: the error to the consumer FIRST (resetStream records the id and
  `_emitStreamError` suppresses errors for ids we reset ourselves), then
  RST_STREAM, or the server keeps producing for a consumer that is gone.

Consumption is now reported the same way on both sides: `returnFlowCredit` for
pipeline-fed streams, and a lazy `map` over `getMessagesForStream` for the rest.
Charging is restricted to streams that HAVE such a reporter, or a single unary
request larger than the window would refuse itself.

## After

```
same probe, same four runs:

  upload   control : ping@stall pong, after pong,  4174 KiB on the wire
  upload   case    : ping@stall pong, after pong,  4171 KiB on the wire
  download control : ping@stall pong, after pong
  download case    : ping@stall pong, after pong

for comparison, the round-207 ablation with NO bound at all:
  upload control 14286 KiB, upload case 15291 KiB
```

The connection never dies, and 4171 KiB is the 4 MiB default
`flowControlWindowBytes` — the bound still bites.

## Canary

Two halves, two canaries, against
`test/cancel_does_not_kill_the_connection_test.dart`.

- Responder pause restored in `_fcOnDelivered`: both upload witnesses fail,
  `Expected: 'pong' Actual: 'HUNG'` — "a call stalled on a deaf handler blocked
  the whole connection" and "cancelling one stalled upload left the connection
  unusable for every later call". The download witness and the GUARD stayed
  green.
- Caller pause restored: the download witness fails, `Expected: 'pong'
  Actual: 'HUNG'` — "a paused download blocked the whole connection". Both
  upload witnesses and the GUARD stayed green.

Neither half masks the other (the trap L-01 records), and each canary leaves the
other direction green, which is what shows the witnesses isolate their own half.

The BOUND has its own guards, and they are the pre-existing ones:
`upload_backpressure_test` (< 8 MiB on the wire for a non-consuming handler) and
`slow_reader_backpressure_test` (< 2000 messages produced after the client stops
reading) both still pass **on their original numbers** — nothing was weakened to
fit the new behaviour. The first cut of the caller side did fail the second of
those at 23606 messages, because failing the call locally never told the server;
adding the RST_STREAM is what fixed it.

## Gate

`melos run analyze` green; `melos run format:check` green;
`melos exec --scope=rpc_dart_http2 -- fvm dart test` green, 182 tests, every
existing assertion untouched; `melos run test:unit --no-select` green across the
workspace.

## Not fixed

The upstream defect itself. `removeStreamMessageQueue` in package:http2 2.3.1
still discards connection-flow-controlled bytes without accounting for them, and
RFC 9113 6.9.1 requires that accounting. rpc_dart no longer walks into it, but
any other library that throttles by pausing will. Worth reporting upstream —
B-12 keeps the reproduction.

## Links

Lead `../backlog/B-12-http2-cancel-kills-the-connection.md` — closed by this
round, owner decision carried out.
Bench `../probes/P-02-http2-aborted-call-pool.md` — reused unchanged, still
valid; its control now passes on both arms, which is the fix.
Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [206, 207, 208]`.
Round `207-http2-cancel-kills-the-connection.md` — the measurement and the
ablation this implements.
Lesson `../lessons/L-01-half-a-fix-can-mask-the-other-half.md` — applied, not
re-paid: it is why the two canaries were run separately per direction.
