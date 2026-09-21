---
refines: U-24
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/core/**]
applies: sibling implementations of one interface each hand-roll the same helper
breaks: "wrong result: the copies drift, and the one that drifted is the one nobody compared."
applied: [308, 309, 310, 311, 312, 313, 315, 316, 317, 318, 331, 332, 336, 354, 360, 367, 368, 369, 370, 371, 374, 384, 386, 388, 389, 390, 391, 393, 402, 403, 406, 407, 410, 412, 415, 416, 417, 420, 422, 423, 424]
status: confirmed (round 424)
---

# RPC-25 — The same abstraction, four times

## Shape

Several classes implement the same interface, in different packages, written at
different times. Each needs a helper the interface does not provide, so each
writes one. The copies start identical and then DRIFT — and because no file
imports another, nothing brings the difference to anyone's attention.

This is not "duplicated code" as a tidiness complaint. The defect is the drift,
and the drift is invisible by construction: the four copies are in four
packages, and a reader has all of one of them on screen.

## Detector

1. **Find a field every sibling declares.** The name is usually identical,
   because they were copied:
   `grep -n "_streamControllers" packages/transport/*/lib/**`
2. **Read the METHODS around it in each sibling, side by side.** Not the field —
   the operations. Four copies of a five-line method are cheap; four copies that
   disagree are the finding.
3. **Diff them by behaviour, not by text.** Ask of each copy: what does it do
   that the others do not, and is that a deliberate specialisation or a slip?

## Ask

If these four were one, which copy's behaviour would the shared version have —
and which copies would that CHANGE?

Every copy the answer changes is a drift, and each is either a latent defect or
an undocumented specialisation. There is no third category.

## Evidence

**Round 308, the per-stream router.** `rpc_http_caller_transport`,
`rpc_http_responder_transport`, `rpc_http2_caller_transport` and
`rpc_http2_responder_transport` each carried a `Map<int, StreamController<...>>`
plus its own `getMessagesForStream`, `_emit`, `_emitError` and close loop.

    the four copies                          121 lines
    the shared RpcStreamRouter                57 lines of code
    transports, net                          -64 lines

The drift step 3 asks for found one, and it was a real defect rather than a
style difference. `rpc_http2_caller_transport.getMessagesForStream`:

```dart
final existing = _streamControllers[streamId];
if (existing != null) return existing.stream;          // NOT metered
...
return _fcMetered(streamId, ctl.stream);               // metered
```

A repeat call for the same stream returned the stream WITHOUT flow-control
metering, so that consumer never discharged its budget: `_fcOutstanding` only
climbs, and the call is eventually refused at the window for bytes it did
consume. Its own responder sibling, twenty lines of near-identical code in
another file, meters both paths.

**Nothing could have caught it.** The two files never import each other, the
analyzer sees two correct methods, and every test passes because the second
`getMessagesForStream` call is the uncommon path. It is visible only when the
four are put side by side — which is what the extraction forces.

**Round 309, the drain loop.** Three servers polling a count to zero, 65 lines.
The drift was in the LOGGING, not the logic — the copies agreed on what to do
and disagreed on what to say:

                     start log   success log
    websocket        info        (none)
    http             debug       (none)
    http2            info        info "Drain complete"

An operator watching an HTTP/1.1 deploy at the default level saw nothing, and on
two of three servers the ONLY line a drain ever produced was "budget expired,
closing anyway" — so success was signalled by an absence. **Look at what the
copies SAY, not only at what they compute.**

## "It does not apply here" is a claim, and it needs the grep

Round 309 declared `rpc_dart_isolate` out of scope by REASONING: one transport
in two platform variants, SendPort against Worker, different mechanisms, no
siblings. Round 310 ran step 1 instead and found `_incomingCtl`, `_messageSub`,
`_closed` and `_onClose` declared identically in both — the same
`IRpcMultiplexedChannel` lifecycle twice, with a byte-identical `close()` — and
two drifts in it, one a live defect.

**Different mechanism is not different abstraction.** Two classes can wrap
unrelated transports and still be one lifecycle written twice; the wire format
is a parameter, not the shape. Step 1 asks for a FIELD every sibling declares
because a field name survives that difference where an argument about mechanism
does not.

The lens can legitimately not apply — but only after the grep returns nothing.

## Identical copies can BOTH be wrong

Step 3 compares the siblings to each other, which says nothing when they agree
AND are both mistaken. Round 311: `_fcWindow` was byte-identical in the two
http2 transports, so the drift test cleared it — and reading it against the
POLICY instead of against its twin found a third `??` clause that can never
evaluate, because `RpcSecurityPolicy`'s const default for the field is non-null.
Two copies of dead code, each restating the default as a literal, invisible to
`dead_null_aware_expression` because the FIELD is `int?` even though the const
VALUE never is.

So the diff has a second axis: compare each copy to the thing it READS, not only
to its sibling.

## Same code, different LIFETIME — do not merge

Round 317: `RpcResponderContract` and `RpcCallerContract` open their methods with
the same two calls, line for line. They are not the same thing. The responder
resolves the codec mode once per REGISTRATION, to pick which map a handler lands
in; the caller resolves it once per CALL, to decide what goes on the wire. The
responder's preamble also refuses a duplicate name; the caller stores nothing,
so it has no duplicate to refuse.

Merging them would carry a registration rule onto a call path — dead at best,
refusing a second call at worst.

**Before merging two look-alikes, ask how long each one's result LIVES.** Same
computation over different lifetimes is a coincidence, not a duplication. The
genuinely shared part here was already extracted (`_RpcCodecMode`); what stayed
apart is what differs.

## The exception: a duplicated RULE

A no-drift duplication is normally declined (below). The exception is when what
is duplicated is a RULE rather than a computation, because the risk is not what
the code does now — it is what the next edit does.

Round 315, core's `RpcResponderContract`: `_rejectDuplicate` — "is this method
name already taken" — was called from **eight** places, once per branch in each
of the four `add*Method` registrations. The check reads BOTH registration maps,
so it cannot depend on the branch it sits in. Eight copies are eight chances to
answer it differently later, and the analyzer would say nothing about seven of
them.

Ask: *does this duplicated thing decide something, and would enforcing it on
three of four paths compile?* If yes, merge it even with no drift. If it merely
computes a value the same way everywhere, decline.

## What a no-drift candidate earns

Nothing. Round 309 left `_notify` — eight identical lines in two servers —
unmerged, because step 3 found no divergence and merging would add a public
promise to core to save eight lines. Round 311 left `RpcMessageParser(...)`,
constructed byte-identically in both http2 transports, for the same reason:
extracting it saves six lines and puts an indirection between a transport and
the limits it applies. **The bar is the drift, not the line count.**

**Most step-1 results are NOT findings, and a round that says so is applying the
lens correctly.** Record each declined candidate with its reason, or the next
round reads the silence as oversight and re-opens it.

**Round 310, the isolate channels.** The remedy is NOT always extraction. The
two variants compile on different platforms and speak different wire formats, so
one shared class would be an abstraction over nothing — but the drift was real
and had to go. **Aligning the copies is a legitimate outcome**: the lens is
about finding the divergence, and merging is one of two ways to end it.

The drifts, both in the web copy:

    send() failure   VM: throws, names the stream, channel STAYS OPEN
                     web: catch (_) { await close(); }
    stream 0         VM: filtered on data/finish, NOT on metadata
                     web: not filtered at all

The first is the defect the VM copy was fixed away from, still live on the other
platform — and its comment says why: unsendable payload is one message's
problem, and closing makes it the whole connection's. The second silently
diverged on which frames are legal on the reserved stream.

## "This cannot be tested" needs the API check

The twin of the rule above. Round 312 closed with three fixes it called
unwitnessed and gave each a reason; round 313 checked and **two were wrong**:

    309 log unification   "nothing reads log levels"   LogController.stream is public
    311 dead clause       "no runtime witness"          the FUNCTION's contract has one
    310 isolate web send  "needs a browser"             correct — filed as B-31

The two that dissolved were asserted from the SHAPE of the fix ("logs aren't
testable", "dead code isn't testable") rather than from what the APIs expose. A
log controller with a record stream makes levels assertable; a resolver extracted
into a function makes its contract assertable even when the clause it removed
cannot be.

And note where the real one bit: not the platform, but Dart's per-LIBRARY
privacy. `src/`-importing reaches a public symbol in an internal file (round
307) and does nothing for an underscore. That distinction is worth knowing before
declaring a route closed.

## A drift is TESTABLE, by definition

If two copies diverge, they behave differently — otherwise there would be
nothing to fix. So a drift finding can always be pinned from outside, and a
round that cannot pin it has a claim rather than a finding.

Round 312 wrote the witness round 308 shipped without, and the writing found two
traps worth carrying:

- **The first version passed on broken code.** A flow-control test that yielded
  `'z' * 256 KiB` measured 6060 bytes in 22 frames: the payload is charged AS IT
  APPEARS ON THE WIRE and a run of one character deflates ~900:1, so it never
  reached the bound. Assert the byte count crossed the threshold, or the test
  reports success for the wrong reason. Use incompressible data.
- **`grpc-status 0` with no data is not a passing call.** A test asserting only
  "no error" is green on a call that delivered nothing.

## Where to put the shared version

Beside the siblings' existing shared dependency, not in a new "utils" package.
Here that is `rpc_dart`'s `src/core/`, next to `BufferedBroadcastController` and
`RpcMessageParser`, which RPC-24 established are the transport-authoring API
rather than internals — all four transports already build on them.

**A shared helper is a new public promise** (RPC-24), so it is chosen, not
emitted: `RpcStreamRouter` owns the per-stream half ONLY, and each transport
keeps its own broadcast and decides what goes on it. Extracting the broadcast
too would have forced three different error-envelope policies into one class.

## What NOT to merge

The specialisations that are real. All four transports wrap the router
differently and must:

- http2 wraps the returned stream in `_fcMetered`; the http pair does not.
- the http caller reports `_closedDuringCall()` on close, but only for streams
  in flight — which is why `closeAll` takes `Object? Function(int)` and honours
  a null return, rather than one error for everybody.

A merge that erases these is worse than the duplication: it swaps four honest
copies for one class with four flags.

## The other reason to merge: unequal coverage (round 331)

Rounds 316, 317 and 318 all declined on "no drift, no rule", and that bar is
right. Round 331 found the case it misses.

`caller_pipeline.dart`'s two outer stream bridges were **identical** — 37
non-comment lines each, differing only in a type parameter and a message string.
No divergence, so by the bar above, decline. Then:

```
ablate `if (!finished)` in                suite result
  serverStream's copy                     +1434 ~1 -1   caught
  bidirectionalStream's copy              +1435 ~1      NOTHING CAUGHT IT
```

One test pins that rule — the one that stops a normal completion poisoning a
REUSED context's token — and it has no bidi arm. Two identical guards, one
watched and one not, with nothing in the file recording which.

> **Ask which copy the TESTS reach, not only whether the copies agree.**
> Duplication with no divergence can still be worth removing when the copies are
> unequally covered: after the extraction the existing test guards both call
> shapes, because there is one implementation to guard. That is a measurable
> return where "they might drift later" is not.

**Round 332 pointed that criterion at this lens's own output and it came back
worse.** `RpcStreamRouter` — the class round 308 extracted from the four
routers above — had no test file at all, 24 rounds later. Ablating the rule it
exists to enforce, `operator []` returning the SAME stream on a repeated lookup,
which is exactly what http2's caller had got wrong:

```
rpc_dart_http    ablated     +123   all passed
rpc_dart_http2   ablated     +204   all passed
reuse branch reached         http 0 times, http2 1 time
```

Reachable and watched by nothing — L-04 case 1, settled with one `print` rather
than a rebuilt bench.

> **Extracting shared code moves the code but not the tests.** A class four
> callers depend on inherits their coverage of THEIR behaviour, not coverage of
> the rule it was extracted to hold. After an extraction, ask what test
> exercises the NEW unit. Round 308 created this class; nothing tested it until
> `test/core/stream_router_test.dart` in 332.

### Round 367 — the coverage criterion applied and coming back NEGATIVE

331 and 332 are both cases where the criterion said *merge*. 367 is the first
where it said *leave it*, and recording that is the point — the owner asked for
a flow-control refactor, so the silence would otherwise read as an oversight.

Three copies of flow-control accounting: core's credit-and-grants scheme, and
the un-consumed budget written twice in http2. The same rule ablated in each,
against each package's own suite:

    http2 responder _fcOnDelivered    +218       -> +212 -6
    http2 caller    _fcOnDelivered    +218       -> +217 -1
    core _fcTryConsume                +1485 ~1   -> +1484 ~1 -1

331's bar is one copy watched and one **not**. 6/1/1 is unequal in degree and
not in kind, so the extraction inherits coverage that already exists.

> **"Unequally covered" means one copy at ZERO, not one copy at fewer.** A
> spread of 6 to 1 is what different call shapes and different blast radii
> produce on their own; reading it as a coverage gap would make the criterion
> fire on every duplication that exists, which is the bar this lens spent
> rounds 316-318 refusing to lower.

Step 3 also found real drift and it was declined on 360's rule: `close()` clears
`_fcDeferred` + `_fcOutstanding` on the responder, neither on the caller, all of
them in core — three answers, and nothing reaches any of them, because after
close every write is refused by `isClosed` and a reconnect builds a new
transport rather than reusing this one.

And the extraction the request actually named — `RpcFlowController` out of
`RpcChannelTransport` — is not a candidate for this lens at all: **one** copy of
that mechanism, so there is no sibling to compare it against. A lens that needs
siblings cannot judge a single implementation, and saying so is cheaper than
inventing a second criterion for it. `../checked/C-39-the-flow-control-copies-are-all-watched.md`.

## The siblings can be two branches of one `if` (rounds 334, 336)

The detector says to compare sibling implementations across packages. The
responder and caller pipelines hold a cheaper version of the same thing: a
zero-copy branch and a serialized branch, in one method, for each of four call
shapes. Both rounds that read them found a defect.

Round 336's is the sharper one. The zero-copy unary branch carries a comment
from an earlier fix:

> the three streaming shapes already route their request-stream errors, and this
> one did not

True, and it excluded the fourth shape from its own count — the SERIALIZED unary
branch, which is a different method and the default for every codec-based unary
call. Measured on a request stream that errors before a request arrives:

```
ServerStreamResponder    status 13 sent to the peer
UnaryResponder           NONE
```

The caller waits for a response that never comes. `UnaryResponder`'s own
`onDone`, eight lines above the offending `onError`, already answers with
`invalidArgument` — so the method both knew how and failed to.

> **A comment that says "the others already do this" is a claim about the
> others, and it names them. Re-read it as a CHECKLIST: every shape it does not
> name is a shape nobody checked.**

## Round 354 — the divergence can be a MAP KEY

Every instance above is a method. This one is a dictionary.
`RpcResponderEndpoint` and `RpcPeerEndpoint` are sibling subclasses over the
same `RpcResponderPipelineMixin`, and both override `collectEndpointMetrics`.
The responder's override computed five metrics about responder streams INLINE —
`metadataStreams`, `bufferedMessages`, `clientStreamBuffers`,
`activeResponders`, `contractKeys` — all of them from `_respStreams`, which the
mixin owns and both siblings have. The peer's override called the shared
`collectResponderMetrics()` and stopped.

`RpcWebSocketServer._inFlightCalls()` polls `activeResponders` to decide whether
a graceful drain is done:

    arm         activeResponders  stop waited   the in-flight call
    responder   1                 1746ms        returned "finished"
    peer        null              1ms           status 14            <- before

> **`null`, not `0`, and `?? 0` erased the difference.** A missing key and an
> idle server are not the same fact; the fallback made them indistinguishable at
> the one call site that had to tell them apart. When a consumer reads a map with
> `as int?` and a default, ask which producers publish that key — the type
> system will not.

> **The sibling comparison here is not between two implementations but between
> an override and the mixin it extends.** The detector's "find a field every
> sibling declares, then read the methods around it" still finds it, provided the
> reading includes what each override adds ON TOP of the shared call — that
> addition IS the divergence.

Fixed by moving all five into `collectResponderMetrics()`, so the metrics about
responder streams live with the streams. The canary — removing the key from the
mixin — fails the peer witness AND the responder-mode test that predates it,
which is the evidence that there is one home now rather than two copies.
`../probes/P-46-drain-in-peer-mode.md`,
`../rounds/354-the-drain-that-polled-a-key-nobody-published.md`. The getter half
of the same divergence is a breaking interface change and is
`../backlog/B-37-endpoints-getter-excludes-peers.md`.

## Round 360 — a CONSTRUCTOR and a METHOD are two implementations

The smallest pair yet, and both are on one class. `RpcStreamIdManager` takes a
cursor two ways: `resumeAfter:` in the constructor, and `resumeAfter()` as a
method. The method aligns parity and documents it — *"a value of the wrong
parity for this role is rounded UP"* — and the constructor's initialiser took
the value raw:

    route                       resumeAfter  first three ids
    method resumeAfter(4)       4            7, 9, 11
    constructor resumeAfter: 4  4            6, 8, 10   <- a CLIENT

A client issuing even ids mints the SERVER's half of one shared space, and
everything downstream is keyed on the id alone.

> **Two ways to set the same field are two implementations.** The detector's
> "find a field every sibling declares, then read the methods around it" points
> at classes; point it at FIELDS too. `_lastId` has two writers, one in an
> initialiser list where no method body is there to read.

> **An initialiser list hides the drift especially well.** It cannot call an
> instance method, so the shared rule has to be a static — which is exactly the
> step somebody skips when the expression looks short enough to inline.

Same round, same shape, DECLINED: `_methodPathFromKey` cannot round-trip a
dotted service name that its sibling `_parseMethodPath` explicitly admits — real
drift, in one file, and the ordinary path measured clean, so it is
`../backlog/B-40-method-path-from-key-drops-dots.md` rather than a fix. **Drift
is not automatically a defect; it is a defect where something reaches it.**

`../probes/P-51-three-core-diagnostics.md`,
`../rounds/360-two-routes-into-one-concept.md`.

## Round 415 — five duties in one round, and what a copy costs to REACH

Round 391 asked for this: stop applying the lens one copy per round. Five duties
were taken at once, each read across every implementation, and the answer sat in
a sibling every time — a caller that passed the trailer message through, a
teardown that cancelled the token, a processor that gated its sends, a transport
that bounded its shutdown, a header list written in constants.

**The copy is cheap to fix and can be expensive to REACH, and the estimate is
made on the wrong one.** Two of the five were not the edit the sweep described:

- `ping.dart` was listed as one of seven sites substituting `'Unknown error'`,
  and changing that literal would have made its message strictly worse — the
  site does not call the shared factory AT ALL, so the placeholder was the only
  message it had. Converting it to `fromTrailer` is what the duty required, and
  that is a different edit from the one the sweep named.
- Cancelling the token in `closeResponderResources` made a LATENT race in
  `RpcCallScope.close()` reachable for the first time: the scope self-closes on
  cancellation, so the teardown's own `close()` became the second call, and the
  early return on `_isClosed` left the disposer loop running detached.

> **A duplication sweep costs what the LAST copy costs, and the last copy is
> usually the one that cannot simply be edited to match.** Both surprises here
> were in the same place — the copy that had drifted furthest, which is the one
> whose sibling's clause has nowhere to land.

> **The second surprise is the one worth naming: unifying a duty can make a
> dormant defect live.** The scope race had existed all along and nothing could
> reach it, because nothing cancelled the token before tearing down. Ask what
> the newly-correct copy now DOES that no copy did before, and run the suite
> around it — an existing test caught this one, and no new test would have
> looked for it.

`../rounds/415-five-duties-and-the-sibling-that-answered-each.md`.

## Round 416 — when the copies agree and are all wrong together

The widest application yet: one duty — *what does this library throw?* —
answered 80 times across 17 packages, and the copies did NOT drift. They agreed
on `StateError`, and agreeing is what hid it.

> **A duty answered identically everywhere can still be answered wrongly
> everywhere, and then the detector's own signal — divergence — is absent.**
> What exposed it was not a diff between siblings but a diff between the answer
> and what the SYSTEM does with it: `wireStatusFor` is default-deny, so every
> `StateError` became INTERNAL "Internal server error" on the wire.

The tell is in the catalogue already: "Identical copies can BOTH be wrong" is a
section of this file. Round 416 is its largest instance, and it adds the
question that finds them — **ask what consumes the answer, not only who
produces it.** Two consumers gave it away:

- `wireStatusFor`, which redacts anything outside the hierarchy;
- `_isTransportClosed`, which had to compare message TEXT in two spellings
  because the producers disagreed — and the site that had already drifted
  (`channel_transport.dart:437`) was accommodated by widening the matcher rather
  than by removing the drift.

> **A consumer that matches on a MESSAGE is a contract with no declaration, and
> it is evidence the type is carrying nothing.** Find the string comparison and
> you have found the missing type. Here it became `RpcClosedException`, whose
> `what` field then turned out to be the only way to tell an endpoint's refusal
> from its transport's — which one of this round's canaries needed.

`../rounds/416-every-error-names-its-status.md`.
