---
round: 789
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2]
lens: RPC-10
bench: P-283 — new
commit: yes
release: none
---

# Round 789 — the empty unary class stops at the channel

## Target

Round 787's breadth, which it measured on the channel transports only:
the unary responder is shared, so its class may reach every path that feeds
a unary call (RPC-10, shared-layer blast radius). Three questions: do the
HTTP/1.1 and HTTP/2 responders show it; does the unary CALLER have the
mirror (U-14, compare siblings); and does the fuzz that found it, widened
with the frame kinds the gate's fuzz never sends, find anything else once it
is fixed. `loop.py find "empty request body unary http POST content-length
0"` and `find "unary caller response empty data frame ..."` named rounds
627 and 649 (the server-stream and the empty-chunk wait) and B-64 (what ends
a caller), none on these paths.

## Hypothesis

At least one of: an empty unary request over HTTP/1.1 or HTTP/2 holds its
call; a unary caller handed an empty response hangs where a complete one
would not; the widened fuzz, after round 787, still finds a responder held
on an open connection.

## Before

C-71 and P-283:

```
  path                         empty     truncated   complete   none
  HTTP/1.1 RpcHttpServer       3         3           0          -
  HTTP/2   RpcHttp2Server      3 (50/50) 3 (50/50)   0 (50/50)  3 (50/50)
  HTTP/2, round 787 fix OFF    3 (50/50) 3 (50/50)   0 (50/50)  3 (50/50)

  caller, + grpc-status 0      13        13          ok         13
  caller, no trailer           waits     waits       waits      waits

  widened fuzz, 120 sessions   seeds 7 11 23 42 99, noControl and full: 0 failures
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/fuzz_control_frames.dart`

## Mechanism

None found. HTTP/1.1 turns an empty body into no data message, which the
pipeline's own refusal answers; HTTP/2 brings the half-close with the empty
DATA frame, so the end-of-stream branch sees the request already settled.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. HTTP/2: the fix on against the fix off, nothing else varied. Caller:
   `complete` against `empty`, payload only. Fuzz: the same seed before and
   after round 787.
2. The fuzz saw the defect on seed 7 before round 787 (2 of 60); the HTTP/2
   bench answers every arm, so its sameness with the fix off is a result,
   which C-71 says; the caller bench separates trailer from payload.
3. Library side: grpc-status from the server's own frames and headers,
   `activeResponderCount` from the responders, the caller's own result.
4. Each zero has a run where the same oracle fired (round 787's seed 7) or
   an arm that answers differently (caller without trailer).
5. n/a.
6. n/a.
7. CLEAN: every arm of the hypothesis failed against a control that could
   differ.
8. Nothing dismissed by a record: rounds 627/649 and B-64 were pointers, and
   each path was measured today.
9. None.
A1. HTTP/1.1 and HTTP/2: raw clients in the same process as the server,
    separate configuration. Caller: a hand-built server channel.
A2. Volume (calls per connection).
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

Nothing. The caller's wait without a trailer is gRPC's contract; a deadline
bounds it.

## Links

Lens `../lenses/RPC-10-shared-layer-blast-radius.md`.
Probe `../probes/P-283-the-widened-hostile-peer-fuzz.md`.
Negative `../checked/C-71-an-empty-unary-payload-on-every-other-path.md`.
Round `787-an-empty-unary-payload-was-never-answered.md`.
