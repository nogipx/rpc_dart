---
round: 404
verdict: CLEAN
packages: [rpc_dart_framework, rpc_dart_websocket, rpc_dart_http2]
lens: RPC-23
bench: P-89 — new
commit: yes
---

# Round 404 — what the messages promise

## Target

The class round 401 found one member of. Its detector: a `throw` whose message
PRESCRIBES an action is an API surface nothing type-checks, read by someone
already in trouble. L-12 is the rule that makes this a round rather than a
second anecdote — **count the class before concluding anything from one
instance**, because 333/334 fixed a sample and reported "~20 remain" against a
real surface of ~200.

## The count

228 `throw` sites across the 22 packages' `lib/`. Filtering to messages that
tell the reader to DO something — an imperative naming an API, not a
description — leaves **about 20**:

```
site                                                     prescribes
rpc_websocket_server.dart:144   (round 401)              a broadcast stream, or a new server
rpc_app.dart:113                                         create a new RpcApp
websocket_caller_transport.dart:81                       call reconnect()
rpc_http2_caller_transport.dart:199                      call reconnect()
codec.dart:35                                            RpcCodec.withDecoder, or pass fromJson
rpc_container.dart:74                                    registerSingleton / registerFactory first
client/caller.dart:208                                   call finishSending()
rpc_http_caller_transport.dart:312                       call sendMetadata first
transport.dart:290, channel_transport.dart:517           use sendMessage()
unary/caller.dart:504, base_processor.dart:1141          register a cross-platform codec
rpc_http2_common.dart:552                                use a "-bin" key
rpc_http_cors_policy.dart:98                             list explicit origins instead
isolate_transport_stub.dart:28                           use a different transport
models.dart:25, migration_plan.dart:48                   call moveNext() / initial() first
plus ~5 "Provide codecs for network transports."
```

## Hypothesis

401's was not a one-off: the highest-risk members — the ones that name an OBJECT
to rebuild — share its shape, and at least one more cannot work.

## Before

P-89, new, driving the three highest-risk members literally.

**`rpc_app.dart:113` was the closest match to 401** — "create a new RpcApp to
restart", the same "build a new X" that failed one package over. It works:

```
after stop, same modules   restart ok   server starts 2   module: starts 2 stops 2
after stop, new modules    restart ok   server starts 2
after a FAILED start       restart ok   server starts 2
```

Including the literal reading, where only the App is new and the module
instances are reused — they are configured, started and stopped a second time
and the app comes up. `RpcApp.server` takes a server BUILDER rather than a
server, which is exactly the difference from the websocket case: the thing that
cannot be re-listened is rebuilt by the closure.

**The two `call reconnect()` copies** carry two claims in one sentence, so each
was split into two arms — "recoverable, not closed" buys nothing if it only
means `isClosed == false`, so the failed arm goes on to try a LATER reconnect:

```
                              refused with          reconnect    isClosed  after
websocket, server back up     StateError            healthy      false     served
websocket, server still gone  StateError            unhealthy    false     LATER healthy -> served
http2,     server back up     RpcStatusException    healthy      false     served
http2,     server still gone  RpcStatusException    unhealthy    false     LATER healthy -> served
```

Both claims hold, on both transports.

## Mechanism

n/a — nothing is broken among the three driven. 401's remains the only member of
this class known to be wrong, and the reason is visible in the comparison:
**it named an object whose obstacle lived elsewhere.** `RpcApp` prescribes
rebuilding the thing that actually holds the single-shot state; the websocket
server prescribed rebuilding the server when the obstacle was the stream.

> The tell is not "a message that prescribes". It is a message that prescribes
> rebuilding **A** when the state that blocks you is held by **B**.

## After

n/a — no change.

## Canary

n/a — no fix. The load-bearing control is each arm's pre-state column
(`first call: served`, `first started, stopped`), so an arm that never reached
the state it names cannot read as clean — P-84's `grpc-status` lesson in another
currency.

## Gate

Not run: no library code changed. The round's artefacts are three probes,
outside analysis and the suite by design.

## Not fixed

Nothing found. Two things left open rather than pursued:

- **~16 members of the class are undriven.** Most are `call X first` guards on
  an object's own API, where the shape above cannot arise — the obstacle and the
  named object are the same thing. Ranked lowest for that reason, not checked.
- **A drift the arms were not looking for**: the same DISCONNECTED state refuses
  with `StateError` on websocket and `RpcStatusException` on http2. One
  sentence, two copies, two types a caller must catch differently. B-08 settled
  this for the CLOSED state in round 201; nothing has measured the disconnected
  one. Recorded in P-89 rather than filed, because no caller-visible failure has
  been produced from it yet.

## Links

- RPC-23 — the lens; its round-401 form is what this counts
- L-12 — count the class, and put the count in `## Target`
- P-89 — new
- B-08 — closed for the CLOSED state; the drift noted here is the disconnected one
