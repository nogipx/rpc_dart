---
round: 858
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-326 — new
commit: yes
release: none
---

# Round 858 — the http2 caller agrees with the channel caller

## Target

Rounds 853-857 kept finding the same failure handled differently by the
http2 transport, which parses frames itself, and by the core processor
the channel family shares. P-317 lists what a channel caller accepts from
a hostile server; the http2 caller had never been put through it. I-7
(one failure, one status) holds across the transport group. RPC-25.

Taken off first: the http2 responder's flow-control refusal
(`_fcRefuseOverrun`) for round 856's race. Read: it emits the cancel
synchronously, ahead of any end of stream, so the race cannot occur there.

## Hypothesis

The http2 caller ends every hostile sequence the way the channel caller
does, per shape. Fails if any row's outcome or status code differs.

## Before

```
P-326 (http2) beside P-317 (channel), 13 shared sequences x 4 shapes:
  valid (control)                      OK on all four, both transports
  every other shared row               the same outcome and code on both
  text only: no status                 "Response ended ..." / "Stream ended ...", both 13

  OK without END, then 13 with END     unary OK, client OK, stream 13, bidi 13 — on BOTH
  13 without END, then OK with END     13 on all four — on both
```

## Mechanism

None at the transport: the http2 caller hands statuses up as the channel
transport does, and the core callers decide. The one split is by shape,
not transport, and it is filed as B-296.

## After

n/a.

## Canary

n/a — no fix. The control is the `valid` row on both transports, and the
probe sees a difference where one exists (the B-296 row splits by shape).

## Gate

No library change. The P-317 probe gained two rows (`.dart_tool`, ignored).

## Siblings

—

## Not fixed

- B-296 (owner): a status without END_STREAM completes unary and
  client-stream, but not a stream; the two options change a documented
  choice.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Benches
`../probes/P-326-what-an-http2-caller-accepts-from-a-hostile-server.md`,
`../probes/P-317-what-a-channel-caller-accepts-from-a-hostile-server.md`.
Negative `../checked/C-89-the-http2-caller-agrees-with-the-channel-caller-on-a-hostile-server.md`.
Lead `../backlog/B-296-a-status-without-end-of-stream-ends-unary-and-not-a-stream.md`.
