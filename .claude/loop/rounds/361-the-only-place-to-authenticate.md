---
round: 361
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-22
bench: P-52 — new
commit: yes
---

# Round 361 — the only place to authenticate

## Target

The owner's 6.0.0 review list, P2 item 13: `connect()` needs `headers` and
`connectTimeout`.

Filed as P2 hygiene, and the headers half is not hygiene. A websocket client can
authenticate in exactly ONE place — the upgrade request — because there is no
second round trip to attach a token to. So `connect()` could not be used against
an authenticating server at all, which is most of them.

RPC-22 is the lens: its subject is what a peer reaches without being accepted,
and this is the same boundary from the client's side. Its round-274/275 work
established that a connection-oriented peer has a stage BEFORE the protocol
starts and that the stage needs a deadline; `connectTimeout` is that deadline
for the side doing the connecting.

**Scope counted before the fix.** Both parameters have to reach three places or
they are decoration:

```
layer                                headers    connectTimeout
connect() signature                  added      added
openWebSocket, dart:io               added      added
openWebSocket, web stub              ignored*   added
the RECONNECT factory inside connect added      added
```

`*` the browser WebSocket API takes no request headers at all — a hard platform
limit, not a gap. Ignored rather than rejected, so one piece of cross-platform
code can pass a token the VM honours without branching on the platform; stated
in the doc comment per parameter.

## Hypothesis

If `openWebSocket` never forwards a header, no caller can authenticate through
this API; and if `connect()` bounds nothing, a peer that accepts TCP and never
completes the upgrade holds the caller until the OS gives up. Both are claims
about what CROSSES the wire, so both are measured at the peer.

## Before

```
a) route                        authorization
   connect(), no headers        ABSENT              control
   by hand, WebSocket.connect   [Bearer t0ken]      control
   connect(headers: ...)        ABSENT

b) arm                          elapsed   outcome
   no connectTimeout            10016ms   STILL HANGING at the probe bound
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/connect_headers_and_timeout.dart`.

The by-hand control matters: it is what a caller has to do today, and doing it
also means rebuilding the reconnect factory that carries the keepalive and the
compression choice — so the workaround costs two security defaults to buy one.

## Mechanism

`openWebSocket` has two implementations and neither took a header; the dart:io
one calls `WebSocket.connect`, which accepts `headers:` and was simply not
passed any. Nothing anywhere bounded the open: `connect()` awaits
`WebSocket.connect` and then `channel.ready`, both unbounded.

## After

```
a) route                        authorization
   connect(), no headers        ABSENT              control, unchanged
   connect(headers: ...)        [Bearer t0ken]
   after reconnect()            [Bearer t0ken]

b) arm                          elapsed   outcome
   no connectTimeout            10016ms   STILL HANGING at the probe bound
   connectTimeout: 800ms        806ms     TimeoutException
```

Null stays the default for both, so nobody's existing behaviour changed under
them.

**`Future.timeout` abandons the AWAIT, not the WORK**, which core learned on
`RpcClientConnection.connectTimeout` — an abandoned connect that later succeeds
is a live socket nothing holds. So the dart:io path closes the late arrival
instead of dropping it.

## Canary

Three, and what they show is not all the same.

```
the opener drops headers  (headers: (1 > 1) ? headers : null)
  a header reaches the server        Expected: ['Bearer t0ken']  Actual: <null>
  the header is sent again after...  Expected: ['Bearer t0ken']  Actual: <null>

connect() drops headers into the factory
  the same two, identically

the timeout bound removed  (if (1 > 0 || connectTimeout == null))
  a black hole is given up on
    Expected: 'bounded'
      Actual: 'STILL HANGING: connectTimeout was not applied'
```

**The two header canaries fail IDENTICALLY, and that is the finding rather than
a flaw in them**: `connect()` builds one `openChannel` closure and uses it for
both the first open and the reconnect, so there is a single path and no second
source to get right. Reporting them as if they isolated two halves would be a
claim the measurement does not support.

The timeout witness is raced against a 3 s probe bound rather than awaited, so
the unbounded state fails with a real message naming the cause instead of
hanging into the runner's 30 s timeout — which reports nothing about what went
wrong. The first version did exactly that and was rewritten.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
rpc_dart_websocket `All tests passed`; `melos run test:unit --no-select` SUCCESS;
`melos run format:check` SUCCESS; `melos run license:check` compliant;
**`melos run test:web` all passed** — run because `ws_open_stub.dart` IS the web
implementation, so this round changes code the VM gate never executes.

## Not fixed

**`headers` cannot work on the web, and that is a platform limit rather than a
deferral.** The browser WebSocket API takes no request headers; a web client
authenticates with a cookie, a `Sec-WebSocket-Protocol` value or a query
parameter. The parameter is accepted and ignored there so cross-platform code
need not branch, and every doc comment says which platforms honour which
parameter. `connectTimeout` IS honoured on both.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`, tenth
application — first from the CLIENT's side of the pre-protocol stage.
Bench `../probes/P-52-connect-headers-and-timeout.md`, new.
Round `../rounds/275-a-deadline-on-saying-nothing.md`, the server-side mirror:
same stage, same answer, other direction.
Catalog shape U-10 — a new option means new combinations, which is why the
reconnect row exists.
