---
round: 723
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-18
bench: P-238 — new
commit: yes
release: none
---

# Round 723 — the h2 responder stops a deaf reader's handler

## Target

`rpc_dart_grpc_reflection` is reachable by any peer and answers each tiny
request with a larger response (the service list or descriptors plus an echo
of the request). Whether that amplification is bounded is a property of the
h2 responder path under it, which P-62 measured on a channel transport only.
The question went to that layer: a raw h2 peer keeps sending requests, reads
its socket, and grants no h2 credit for responses.

## Hypothesis

package:http2 queues outgoing DATA past the stream window, and if the
responder does not pause the handler, the server queues every response.

## Before

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/r723_deaf_reader_bidi.dart`.
A bidi handler yields 1 KiB per request. A raw `package:http2` client sends
100 000 gRPC frames and pauses its response stream after 200 ms.

```
  arm                                        handler produced
  CONTROL client reads                       100000 (98 MiB)
  deaf reader                                    66
  deaf reader, pump's pause wait ablated     100000 (98 MiB)
```

A first version stopped reading at the TCP level, through a proxy. It is
blind: the client then also loses the server's WINDOW_UPDATEs and stops
sending after 7452 requests.

## Mechanism

`RpcHttp2OutgoingPump.add` waits while package:http2 has paused the stream.
The bidi pump stops pulling the handler, so the handler is held at one
stream window (64 KiB, 66 messages).

## After

n/a — nothing to fix.

## Canary

n/a — no fix. The ablation is above: the pump's `while (_paused)` disabled.

## The verdict questions

1. Yes: the client reading or not, and one ablated loop condition.
2. Yes: 66 against 100000.
3. In the server handler's own generator.
4. Not zero: the ablation reaches 100000.
5. No fix, so no witness.
6. n/a.
7. CLEAN, with a valid control.
8. None. The blind TCP-level arm is recorded above.
A1. The raw client has no policy; the server uses the default.
A2. Volume.
L1. n/a — no refusal fires. The handler is paused, not refused.

## Gate

No library change. The ablation was reverted and `git status` showed only
the owner's `config.md`.

## Not fixed

Nothing found. The request side of the same call is bounded by round 719's
weighing; this round did not measure it.

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md` — `applied: [..., 723]`.
New bench `../probes/P-238-a-deaf-reader-against-an-h2-bidi-handler.md`.
Related bench `../probes/P-62-does-the-handler-run-ahead-of-the-wire.md`
(channel transport).
