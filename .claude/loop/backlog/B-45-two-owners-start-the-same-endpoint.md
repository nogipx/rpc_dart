---
status: closed (2026-09-15) — the redundant call is silent, the disagreeing one still warns
round: — (found in a consumer's production logs, 2026-09-15)
commit: bb8548939524ee67a53dcc5339d15f772e3f032e
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/core/rpc_dart_framework/lib/src/rpc_app.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: —
---

# B-45 — the server and the framework both start every endpoint, and say so 700 times a day

`RpcWebSocketServer._handleConnection` hands the fresh endpoint to the
application and then starts it:

```dart
_onEndpointCreated?.call(endpoint);
endpoint.start();                      // rpc_websocket_server.dart:289-290
```

`RpcApp`'s `onEndpoint` callback — which is what gets passed in as
`onEndpointCreated` — registers the contracts and **also** starts it
(`rpc_app.dart:413`). Both run, so every connection takes the second
`startResponderListening()` and gets:

```
WARN rpc.responder  Already listening for incoming requests
```

Measured on a consumer's two sync-server replicas, 24 h:
**704 and 698 of these**, against 6 and 34 lines of real error in the same
window. The one message a reader needs is outnumbered a hundred to one by a
message that means "the framework you shipped called your own API twice".

No functional damage: the second call returns at the guard. The cost is the
log, and the cost of the log is that the incident these numbers came from took
a `grep -v` to read.

## The decision behind the fix

Who owns starting the endpoint. Both spellings are defensible and they are not
both right:

- the server starts it, and `onEndpointCreated` is documented as "register, do
  not start" — but then every application built directly on `RpcWebSocketServer`
  without the framework has to know that;
- the callback owns it, and the server stops starting — a behaviour change for
  anyone passing a callback that does not start.

A third, cheap and not exclusive: `startResponderListening` is idempotent by
design, so the warning could be `internal`-level for the identical-filter case
and stay a warning when the second call disagrees with the first (a different
`messageFilter` IS a real mistake — it silently keeps the first one).

Whatever is chosen should also cover `RpcPeerEndpoint`, which has the same
double call one branch up.

## Fixed — 2026-09-15

The third option, which is not exclusive with either of the other two and needs
no decision about ownership: `startResponderListening` now logs the redundant
call at `internal`, and keeps the WARNING for the case that is a real mistake —
a second call asking for a **different** `messageFilter`, where the first one
silently stays in effect. The pipeline remembers the live filter to tell them
apart.

Nothing about the lifecycle changed, so the ownership question is still open and
now costs nothing to leave open.

Witness: `test/endpoint/second_start_is_not_a_warning_test.dart`, four cases.
Canary (the branch replaced by the old unconditional warning):

```
the ordinary second start does not warn
  Expected: empty  Actual: ['Already listening for incoming requests']
a second start with a different filter still warns
  Expected: length <1>  Actual: []
```

Both GUARDs pass on either side — the endpoint still serves after a redundant
start, and the handler runs exactly ONCE, which is the double-subscription this
branch has always existed to prevent.

Gate: rpc_dart 1474 tests, rpc_dart_websocket 164, analyze clean.

## Owner decision

—
