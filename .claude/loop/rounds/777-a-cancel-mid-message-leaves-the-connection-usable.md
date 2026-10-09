---
round: 777
verdict: CLEAN
packages: [rpc_dart_websocket, rpc_dart_http2, rpc_dart_http, rpc_dart_isolate]
lens: RPC-21
bench: P-270 — reused
commit: yes
release: none
---

# Round 777 — a cancel mid message leaves the connection usable

## Target

Rounds 768-770 changed how large messages are credited and refused. A call
cancelled while large messages are in flight is the lifecycle step that
exercises those charges' release: its window, its connection debt and (on
http2) its un-consumed bound must come back, or the next call on the same
connection stalls.

## Hypothesis

After cancelling a server stream of large messages mid-delivery, an upload
of large messages on the same connection stalls or is refused.

## Before

P-270 with `CANCEL=1`: a server stream of 4 x 7 MB, cancelled after the
first message arrives, then a client-stream upload of 4 x 7 MB on the same
connection (http: 2 x 5 MB, inside its 16 MiB body):

```
  websocket  cancel mid-feed, then upload: server got 4/4
  http2      cancel mid-feed, then upload: server got 4/4
  isolate    cancel mid-feed, then upload: server got 4/4
  http       cancel mid-feed, then upload: server got 2/2
```

## Mechanism

The cancel releases what the call held at every layer; nothing to fix.

## After

n/a.

## Canary

n/a. The upload is 28 MB, past one connection window of credit on the
channel transports, so a debt left by the cancel would show as a stall.

## The verdict questions

1. One sequence per transport.
2. The upload needs the credit the cancelled call held; a leak would
   stall it.
3. At the server, as messages received.
4. 28 MB through a 4 MiB stream window and the connection window.
5. n/a.
6. n/a.
7. CLEAN.
8. Nothing dismissed.
9. None.
A1. Default policies.
A2. Volume.
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

Nothing.

## Links

Bench `../probes/P-270-large-messages-across-the-transports.md`.
