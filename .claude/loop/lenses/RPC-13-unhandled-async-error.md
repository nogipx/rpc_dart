---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: there are paths that run user code outside a guarded zone — or inside one that was never meant to catch it
breaks: a process crash.
applied: [222, 225, 242, 330, 346, 347, 356, 358, 368]
status: confirmed (round 368)
---

# RPC-13 — An unhandled async error is fatal to the isolate

Anything added to an accept loop or to a stream's event handler runs in the root
zone — ask what a platform accessor does on malformed input BEFORE putting it
there.

## Shape

A future running user code is abandoned with no error handler; in Dart that
kills the whole isolate.

## Detector

Calls that spawn a future without `await` and without `.catchError`, on paths
that run user code: dispatch, lifecycle callbacks, connection accept loops.

**And `async` callbacks handed to `Stream.listen`** — `onData`, `onDone`,
`onError` alike. Nothing awaits the future such a callback returns, so it is an
`unawaited` that does not look like one and no grep for `unawaited(` finds it.
Round 368 added this arm: `grep -n "async {" ` over the shapes found 11, five
guarded and six not. The `onError` parameter is not a guard for the callback's
own throw; it only receives errors from the stream.

## Ask

If this throws, who catches it? Is there a zone, and is it the right one?

## Evidence

One hole found and closed; a sweep across all five transport packages showed
every other site was already guarded.

Round 222 re-ran it, because the 121 sweep is off-journal and rounds 206-212 had
added new `unawaited(...)` calls to exactly these paths. Roughly 85 sites; every
one on a path the detector names is guarded, including all of the new ones:

    _detached / _detachedDispatch              .catchError
    bidi dispatch (both zero-copy and typed)   try/catch inside
    http2 error trailer, refusal, reset        try/catch or .catchError
    http2 GOAWAY fan-out                       .catchError
    websocket upgrade refusal                  .catchError
    channel_transport grant sends              try/catch in _fcSendGrant

But the ablation found something the reading could not:

    _detached's .catchError removed, core suite   +1395 ~1, all passed

## Round 242 — the re-sweep found the THROWER, not the site

Ten files had moved under these paths since 222. Every `unawaited(...)` was
still guarded, and the defect was one level in: `forceReconnect()` runs
`detach().then((_) { _emit(...); ... })` with no `onError`, and `_emit` called
the user's `onStateChanged` with no guard. Round 235 had made `detach()` unable
to reject, so the call site was safe by a property of a different method — and
that says nothing about what the callback inside it does.

    arm                     unhandled  transports built
    control                     0            2
    onStateChanged throws       1            0     <- before
    onStateChanged throws       0            2     <- after

> **Ask who THROWS on the path, not only who catches.** A site with no handler
> is only a defect if something on it can throw; a site whose thrower is USER
> code is a defect the day the API is published. Bench
> `../probes/P-20-throwing-state-callback.md`.

> **A sweep proves the sites are guarded today; it says nothing about
> tomorrow.** The guard here exists because a client hanging up killed two
> production replicas, and deleting it changes nothing any test can see. Ask of
> every guard this lens confirms: what would notice if somebody removed it?
> `../backlog/B-20-detached-guard-has-no-witness.md`.

## Round 356 — the same lens from the CATCHING side

Every instance above is an error with nowhere to go. This one had somewhere to
go and a zone took it instead. `runZonedGuarded` routes a SYNCHRONOUS throw from
its body to its handler and returns normally, so `RpcWasm.run`'s

```dart
late final RpcPeerEndpoint result;
runZonedGuarded(() => result = _boot(...), (e, s) => _consoleError(...));
return result;
```

failed on its own uninitialised variable whenever `configure` or
`endpoint.start()` threw:

    arm                witness
    before             LateError: LateInitializationError: Local 'result' ...
    after              StateError: Bad state: configure exploded on purpose

> **The measurement checklist already had the rule** — D2, *a guarded zone
> catches only its own side's errors; check whose code threw*. Read it as
> applying to the zone's OWN body too, not only to callbacks: boot errors belong
> to the caller and guest errors belong to the zone, and one `runZonedGuarded`
> was covering both.

> **`runZonedGuarded` appears exactly once in the whole workspace's `lib/`.** A
> one-member class is worth saying out loud: the sweep took a grep, and the
> value was in knowing there was nothing else rather than in what it found.

> **A recovery path nobody had ever taken.** `_boot`'s catch sets
> `_initialized = false`, which invites a retry — and the retry was broken:
> `endpoint.close()` reaches the bridge only after several awaits, while the
> retry installs its own `rpcWasmReceiveBytes` synchronously, so the late close
> deleted the LIVE handler. Found only because the witness had to boot twice.
> U-15's "drive the lifecycle twice", arrived at by necessity rather than by
> choice.

Bench `../probes/P-48-boot-failure-on-a-real-guest.md` — the only bench in the
journal that can see `rpc_wasm.dart` at all, since it is `dart:js_interop` and
runs on no VM. `../rounds/356-the-zone-ate-the-reason.md`.

## Round 358 — where a `catch` cannot reach, and how to find out cheaply

`RpcWebSocketChannel.send` calls `_ws.sink.add` unguarded, in a file whose two
close paths are both `try`/`catch`. The obvious fix is a third `try`/`catch`,
and **it was applied, re-run, and changed nothing** — the refusal is not on that
stack:

```
_StreamSinkImpl.add            <- throws Bad state: StreamSink is closed
IOWebSocket.sendBytes
AdapterWebSocketChannel.<fn>
_RootZone.runUnaryGuarded      <- the zone the CONTROLLER was built in
_GuaranteeSink.add
RpcWebSocketChannel.send
```

> **A sink's `add` is a queue, not a call.** Anything that forwards through a
> StreamController runs the real work a microtask later, in the zone the
> controller was constructed in — so a `catch` at the call site, and even a
> `runZonedGuarded` at the call site, both see nothing. Read the sink's
> implementation before writing the guard; the give-away in the stack is a
> `runUnaryGuarded` frame BETWEEN your call and the throw.

> **The construction zone is the lever, and it is testable.** Building the same
> `WebSocketChannel` inside `runZonedGuarded` moved the error from fatal to
> delivered — one arm, and it turns "unfixable" into a scoped decision, because
> the library constructs the socket at its own entry points and the user
> constructs it everywhere else.

> **Ask which close it is.** A PEER close does not reach this at all — the sink
> keeps accepting until it learns. Only our OWN raw socket, closed in the same
> turn, does. The item as filed said "the peer closed"; the table said otherwise,
> and that changed both the severity and the reachability.

DEFERRED to `../backlog/B-39-websocket-send-throws-into-the-root-zone.md`, the
sibling of B-35 one dependency over. Bench
`../probes/P-49-send-into-a-dead-socket.md`.

## Round 368 — the callback that is an `unawaited` without saying so

Rounds 222 and 242 swept `unawaited(...)` and concluded the paths were guarded.
They were, and the sweep missed a whole syntactic form: an `async` callback
passed to `Stream.listen` returns a future nobody holds. Across the four call
shapes, **11 of them, 5 with a try/catch and 6 without**.

The reachable one needs no misbehaving peer. `CallProcessor.send` throws
`RpcStatusException(14)` by design once a call is inactive (round 330, so a
caller cannot be told a request went out when it did not), and
`BidirectionalStreamCaller.requestSink` awaited that throw in an unguarded
`async` callback. A cancelled call whose producer has not noticed — the sink is
still open, so the push is legal — reaches it:

    arm                                   uncaught
    bidi requestSink, before                  1
    bidi requestSink, after                   0
    ClientStreamCaller.call(Stream)           0    <- the sibling, already guarded
    control: listen((_) async { throw })       1

> **The sibling IS the control when the same job is written twice.** Two APIs
> that both let the library drive an application's producer; one wraps its send
> in `.catchError` and one did not. Nothing else had to be arranged.

> **A zero needs its own control here**, because the observable is "how many
> errors reached a zone handler" and a 0 reads the same whether nothing threw or
> nothing was watching. The probe ends with a deliberate throw that must report
> 1, and it still reported 1 after the fix.

Bench `../probes/P-59-the-four-shapes-under-the-same-edge-case.md`, whose other
four cells came back identical on all four shapes — `../checked/C-40-the-four-shapes-agree-on-the-ordinary-edge-cases.md`.
`../rounds/368-the-callback-that-could-kill-the-process.md`.
