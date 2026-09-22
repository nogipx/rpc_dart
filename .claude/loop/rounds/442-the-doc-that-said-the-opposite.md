---
round: 442
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-23
bench: none — the evidence is that two doc comments assert the opposite of what
  the lead measured, read against the lead
commit: yes
---

# Round 442 — the doc that said the opposite

## Target

**B-71**, taken on the owner's instruction to witness the web half-open gap.
Also closes **B-30** on the owner's instruction (see `## Also`).

## Hypothesis

That the gap could be pinned with a runnable witness. **It cannot**, and
establishing why is half this round — but looking for the witness found
something worse than an unwitnessed gap: the public documentation asserts the
gap does not exist.

## Before

B-71's body, filed round 422:

> A browser client on a half-open path — the peer gone, the socket still "open"
> to the runtime — has **no liveness signal at all**.
>
> ```
>   websocket (web)      NOTHING
> ```

The public doc a user reads, `websocket_caller_transport.dart:122`:

> Accepted and IGNORED on the web: browsers run ping/pong inside the WebSocket
> implementation and expose no API for it. **A web client is not unprotected**,
> but it cannot be tuned here.

And `ws_open_stub.dart:11`, more strongly:

> so a web client **is not left unprotected — the browser is doing it** — it
> just cannot be tuned from here.

## Mechanism

The lead and the documentation disagree about the same fact, and **the
documentation is the one users read**. It is also wrong.

A browser does run ping/pong internally, which is what the reassurance rests
on. But it exposes neither the interval nor the OUTCOME: a missing pong does
not surface to the page and does not close the socket the way `dart:io` does.
"The browser is doing it" is true of the frames and false of the only thing the
frames are for.

So a caller reads a sentence telling them they are covered, on the one platform
where they are not, and the sentence appears TWICE — in the API doc and in the
implementation — where each copy reads as corroboration of the other. That is
how a wrong claim survives four hundred rounds.

## After

Both copies now state the measured fact, and the API doc carries the lead's own
table so the asymmetry is visible at the call site rather than in a backlog
file:

```
  transport            half-open detected by
  websocket (VM)       WebSocket.pingInterval, native
  websocket (web)      NOTHING
  http2                startHttp2Keepalive, this library's own loop
  isolate              the port closing
```

and the actionable consequence, which neither copy had: **on the web, set a
deadline on every call — it is the only bound there is.**

One code change, in the stub:

```dart
- final _ = (enableCompression, headers);
+ final _ = (pingInterval, enableCompression, headers);
```

That discard exists, by its own comment, "so a reader sees the platform cannot
honour them rather than that somebody forgot". `pingInterval` — the one whose
absence actually costs something — was the one missing from it.

## Canary

**The witness the owner asked for cannot be built with this harness, and the
reason is worth recording so nobody re-attempts it.**

Half-open means the peer is gone with no FIN and no RST. In-process that needs
raw control of the socket AFTER the WebSocket handshake, and neither side
offers it:

- `dart:io`'s `WebSocket` answers ping at the protocol layer, so a server built
  on `WebSocketTransformer.upgrade` cannot be made to go silent;
- hand-rolling the upgrade on a raw `ServerSocket` needs the
  `Sec-WebSocket-Accept` SHA-1, and this package depends only on
  `web_socket_channel` — adding `crypto` as a dev dependency to build a
  negative is a poor trade;
- the web arm needs a browser that can be cut off at the network layer, and
  `test:web` is dart2js against node.

What IS established, and it is the part that matters: the claim was never
unwitnessed for lack of trying — it was **contradicted in writing**, in the two
places a reader looks, and that contradiction is checkable by reading and is
now gone.

Gate includes `test:web`, because the file changed is the one compiled for the
web target.

## Also

**B-30 closed on the owner's instruction.** Round 441 put four options for the
remainder; the owner chose to close. Deliberately left in the repo, and
recorded in the lead so no later round reports it as a discovery:

```
lib/ logs        39 lines   rpc_notify, runtime, user-visible
lib/ comments   277 lines   23 files, dartdoc renders them
rpc_notify test 230 lines   outside the mandate
postgres test    17 lines   outside the mandate
generated        21 lines   rpc_data/*.g.dart
fixtures         18 lines   C-47, must never be translated
```

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run test:web       SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1609/1609
```

## Not fixed

B-71 does NOT close. Its three shapes stand and all need the owner:

1. leave it, document it — **this round did the documenting**, which was option
   1 and is now spent;
2. refuse a non-null `pingInterval` on the web path, making the silent drop
   loud. Breaking for anyone passing it cross-platform today;
3. an application-level heartbeat, with the wire cost the lead describes.

The doc fix does not make the gap smaller. It makes it honest, which is the
most a round can do without a decision.

## Links

- B-71 — its body was right and the shipped docs contradicted it; docs fixed,
  the three fix shapes still need an owner
- B-30 — closed by the owner
- RPC-23 — the strongest instance yet: prose that reassures against the
  measurement
