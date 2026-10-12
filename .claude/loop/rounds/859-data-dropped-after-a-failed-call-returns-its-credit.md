---
round: 859
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-01
bench: P-319 — reused
commit: yes
release: none
---

# Round 859 — data dropped after a failed call returns its credit

## Target

RPC-01, second by S1 yield (14), asks whether every path that drops bytes
returns their flow-control credit. Round 854 added one: the caller closes a
call at its first undecodable response and drops later DATA for it
undecoded (`_handleResponse`, `_warnedLateResponse`). If those bytes were
never credited, a server repeating it would drain the connection window
and stall every call on the connection.

## Hypothesis

DATA the caller drops after failing the call is credited back to the
connection window like DATA it delivers. Fails if the grants fall short of
the bytes received.

## Before

```
P-319, ten server streams, connection window 256 KiB:
arm          received    granted     short
whole        600210 B    802333 B    -202123 B   (control)
bad-first    600180 B    802306 B    -202126 B   (undecodable first, 60 KB after)
```

The bench's recorded ablation (round 852): `_creditConnection` sending
nothing grants 262144 B for 600 KB, so it sees a shortfall.

## Mechanism

None found: the channel transport counts a DATA message consumed when the
caller processor takes it from the per-stream stream, and the processor
takes it before deciding to drop it.

## After

n/a.

## Canary

n/a — no fix. The control is the `whole` arm and the round-852 ablation.

## Gate

No library change. P-319's probe gained the `bad-first` arm (`.dart_tool`,
ignored).

## Siblings

—

## Not fixed

http2 was not measured: its connection window is kept by package:http2,
and a failed response there is reset (`_dropFailedResponse`); whether a
reset stream's in-flight bytes are credited is a separate question.

## Links

Lens `../lenses/RPC-01-flow-control-credit-on-skip.md`. Bench
`../probes/P-319-connection-credit-after-cut-responses.md`. Negative
`../checked/C-90-data-dropped-after-a-failed-call-returns-its-credit.md`.
Round `854-a-hostile-response-is-logged-once.md`.
