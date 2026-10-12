---
round: 842
verdict: CLEAN
packages: [rpc_dart_http]
lens: RPC-05
bench: P-313 — new
commit: yes
release: none
---

# Round 842 — an http connection returns its slot when the client leaves

## Target

Round 839's http sibling line left a gap: its "answered, client destroys"
arms read REFUSED at cap 1 with the server still holding the socket, and the
record blamed a dart:io client trap. RPC-05, ranked third in the curate pass
after round 839, asks the same question of `RpcHttpServer`'s
`maxConnections`: does every way a client leaves return the slot?

Read off current code and not taken, so not negatives: RPC-28 on the
compressed websocket open (one timer over the whole open, an owned client);
the metadata frame's JSON decode (bounded by the frame's metadata cap, every
field type-checked); network-audit §13's stream collectors (`toList`, `fold`,
`join`) found none on a peer stream in core or the transports.

## Hypothesis

A kept-alive or silent http connection whose client leaves returns its
`maxConnections` slot. Fails if a fresh client is refused after the cap's
worth of clients have gone.

## Before

```
arm                               cap 1     no cap   ablated, cap 1
answered, client process exits    served    served   REFUSED
connected, client process exits   served    served   REFUSED
```

The server held no socket on the port in any arm; the kernel showed only
TIME_WAIT. The ablation (`_onEnded()` off in `_WatchedSocket._ended`) shows
the bench can see a slot that is not returned.

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/r842_exit_slot.dart`.

The first runs read REFUSED at cap 1 in both arms. That was the bench: on
this macOS a peer's close reaches the server about 2.1 s late (P-295), and
the probe looked at 500 ms. A plain `ServerSocket` against nc saw the close
at 2.5 s (`r842_plain_server.dart`). With a 3.5 s settle the arms read as
above (L-25).

## Mechanism

None to fix: `_WatchedSocket` keeps its read handlers (no upgrade detaches
the socket in `rpc_dart_http`), and `_open` is a map keyed by the remote
address, so a second end of one connection removes nothing extra.

## After

n/a — nothing to fix.

## Canary

n/a — no fix. The ablation column is the bench's control.

## Gate

No library change; the ablation was reverted (`git status` clean before the
record).

## Siblings

—

## Not fixed

Corrections to round 839 and P-310, which blamed dart:io for what was this
delay: P-310's "Trap" paragraph and round 839's first Not fixed bullet and
http sibling line are rewritten here. Round 839's websocket finding stands:
its ablation read REFUSED with no socket left on the server, after the
keepalive, not the client, ended the connection.

## Links

Lens `../lenses/RPC-05-concurrency-limit-charge-point.md`. Bench
`../probes/P-313-a-client-process-leaves-a-capped-http-server.md`. Lesson
`../lessons/L-25-wait-out-the-fin-delay.md`. Bench
`../probes/P-295-when-a-closed-connection-reaches-the-server.md` (the
delay), `../probes/P-310-connection-slots-per-ending.md` (corrected). Round
`839-maxconnections-counts-open-connections.md` (corrected).
