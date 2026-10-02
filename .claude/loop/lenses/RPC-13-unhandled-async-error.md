---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: there are paths that run user code outside a guarded zone — or inside one that was never meant to catch it
breaks: a process crash.
applied: [222, 225, 242, 330, 346, 347, 356, 358, 368, 431, 443, 480, 483, 500, 535, 557, 577, 639]
status: confirmed (round 431)
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
> `../backlog/archive/B-20-detached-guard-has-no-witness.md`.

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

DEFERRED to `../backlog/archive/B-39-websocket-send-throws-into-the-root-zone.md`, the
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

## Round 431 — a zone guard has a REACH, and it is the construction site

The crash this lens is about is contained by one thing: the zone the object was
CONSTRUCTED in. That is also its limit, and B-39 spent two owner decisions
without anyone asking where the reach ends.

`RpcWebSocketChannel.send` throws into the root zone when the raw socket is
closed in the same turn — reproduced 73 rounds after it was first measured. The
decided fix was to build the library's own sockets inside `runZonedGuarded`.
Reading the two construction sites says what that buys:

```
who built the socket   raw socket reachable   crash reachable   guard helps
the library            no -- never handed out  NO               nothing to help
the application        yes                     YES              cannot reach it
```

> **A construction-zone guard only protects objects whose construction you own,
> and the throw only happens to whoever can close the thing out from under the
> object. When those are different parties, the guard and the defect are
> disjoint.** Ask who can REACH the resource before deciding where to put the
> zone; the answer here was already in the library's own comments, one of which
> says the socket "is no longer reachable" once wrapped.

What shipped instead is the sentence the one exposed caller needs, on the type
they hand their socket to. The guard is back with the owner.

`../rounds/431-the-guard-that-guards-nobody.md`.

## Round 443 — a lead closed with its detector left in the gate

The owner accepted 431's measurement and B-39 closed with the defect still
live. That is a bounded exception to this lens rather than a fix, and the thing
worth carrying forward is what made closing safe.

The tripwire — `send_after_raw_socket_close_test.dart` — was re-run before the
close (4 tests, green) and **lives in the ordinary suite, not under
`.dart_tool/probe/`**. So it runs on every `melos run test:unit` with nobody
remembering it exists, and the day `package:web_socket_channel` stops throwing,
it goes red.

> **A lead can be closed on a defect that is still live, if it leaves behind a
> detector that runs unattended.** Then the close is a decision about cost, not
> a decision to stop looking — and the question re-opens itself when the world
> moves. A lead closed with its evidence in a probe directory nothing invokes is
> the other thing, and reads identically in the index.

The distinction is worth checking whenever a lead closes UNFIXED: is the
evidence in the gate, or in a file someone has to know to run?

`../rounds/443-a-guard-declined-on-its-own-measurement.md`.

## Round 500 — when the lead's mechanism belongs to the LANGUAGE, ask the language

B-109 claimed that cancelling a `Future.asStream()` subscription leaves the
callback attached, so a reused cancellation token accumulates one per call. That
is a statement about Dart, not about this library, and it is twelve lines to
check:

    100 asStream subscriptions, CANCELLED    callbacks fired =   0
    100 asStream subscriptions, left open    callbacks fired = 100   <- control

> **A lead whose mechanism is a primitive's semantics is the cheapest kind to
> settle, and the most dangerous to settle by reading.** The audit reasoned about
> `Future.asStream` and got it backwards. Twelve lines with a control refuted it;
> a grep over five call sites would have found the shape the lead described and
> confirmed it.

> **Then census anyway, because the primitive is only half the answer.** A site
> observing the token with a bare `.then(` really would retain its callback —
> that is the true version of the concern. Six observers, all using
> `asStream().listen` with a stored subscription, all cancelling it, and
> `cancelled.then(` appears nowhere. The negative is worth as much as the
> refutation: it says the shape cannot creep back in unnoticed.

The round also paid a second instalment on a lesson already bought: its level-2
arm measured RSS across 20 000 calls and produced `+24 MiB` against `-25 MiB`,
with the signs flipping between runs of the same code. P-128 had already
established that RSS across arms is noise.

`../probes/P-138-does-a-cancelled-asstream-detach.md`,
`../rounds/500-ask-the-primitive-first.md`,
`../checked/C-58-a-cancelled-asstream-detaches.md`, B-109.

**Round 535 — the one unguarded close in a file that guards them everywhere.**
`RpcWebSocketServer._handleConnection` runs in the accept loop's event handler, and its
own comments name that as the root zone four separate times. Its FAILURE path ended in a
bare `channel.sink.close()`: unawaited, no error handler. A close rejecting is the state
a failed setup tends to leave a socket in, so the answer to a broken connection was
taking the isolate down.

`../rounds/535-the-grab-bag-graded-itself-backwards.md`, B-139.

> **Grep the file for its own guard before trusting the count.** This one already had
> the correct shape eighty lines above —
> `unawaited(Future.sync(() => channel.sink.close(...)).catchError(...))` — on the
> refusal path. The defect is not an unknown idiom; it is one site the idiom did not
> reach. A file that is careful in nine places is where the tenth hides.

> **`Future.sync` is part of the idiom, not decoration.** `unawaited(x.close())` does
> not catch a SYNCHRONOUS throw from `close`, and a sink in a bad state is as likely to
> throw as to reject.

> **The witness has to require the server to still WORK.** "Still running" is a flag an
> isolate that is about to die still reports. The arm that matters answers a real call
> after the failure, which is what says the accept loop and the isolate both survived.
> And the canary's failure names the SINK as the unhandled source rather than any
> expectation — that is how you tell a root-zone death from a failed assertion.

## Round 557 — a dropped future that never carries an error, and a comment that said otherwise

A reported instance of this lens that is not one. `_discardConnection` drops the future
`terminate()` returns, and `TransportConnection.terminate` really is declared to return one — so
the shape is exactly what this lens looks for. Measured, it never errors: four arms (healthy or
socket destroyed, dropped or awaited) all silent, against a POSITIVE CONTROL where `finish()`
escapes with `Bad state: Cannot add event after closing`.

> **A dropped future is a SHAPE, not a defect; the defect is a dropped future that completes with
> an error.** This lens can be read off a signature, which makes it cheap to report and cheap to be
> wrong about. The distinguishing arm is a call in the same rig that is KNOWN to escape — without
> one, "nothing escaped" and "the rig could not produce it" are the same reading. The first version
> of this probe had no working control: its peer was a bare TCP listener, against which `finish()`
> never completed at all.

> **A comment can attach a true fact to the wrong call.** The doc here described `finish()`'s
> zone-only throw — accurately, and the journal already held it — above a method that calls
> `terminate()` precisely to avoid it. The prose read as a warning about the line below it, and
> round 347 had already lost a round to the same confusion. Where two neighbouring calls differ in
> exactly this property, the comment has to name WHICH one it is about.

`../rounds/557-the-comment-named-a-zone-that-was-not-there.md`,
`../probes/P-182-where-terminate-s-error-lands.md`, B-178.
