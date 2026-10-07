---
refines: U-24
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/core/**]
applies: sibling implementations of one interface each hand-roll the same helper
breaks: "wrong result: the copies drift, and the one that drifted is the one nobody compared."
applied: [308, 309, 310, 311, 312, 313, 315, 316, 317, 318, 331, 332, 336, 354, 360, 367, 368, 369, 370, 371, 374, 384, 386, 388, 389, 390, 391, 393, 402, 403, 406, 407, 410, 412, 415, 416, 417, 420, 422, 423, 424, 425, 426, 444, 446, 447, 448, 449, 451, 452, 453, 454, 455, 456, 458, 459, 460, 461, 462, 464, 465, 468, 478, 496, 498, 582, 583, 585, 587, 603, 605, 606, 609, 614, 631, 632, 637, 641, 642, 649, 650, 652, 654, 658, 666, 679, 680, 681, 690, 692]
status: confirmed (round 587)
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
`../backlog/archive/B-37-endpoints-getter-excludes-peers.md`.

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
`../backlog/archive/B-40-method-path-from-key-drops-dots.md` rather than a fix. **Drift
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

## Round 425 — a table column is a claim about how many mechanisms there are

B-56's sweep lists nine sites of "one mechanic" with three columns. Reading the
nine apart gives **two** mechanics that its columns conflate — six bridges
(mirror a source through a controller we own) and four pumps (pause the
subscription for the duration of each send) — and `_pumpBidirectionalResponses`
is a seventh bridge the sweep does not list at all.

> **Before extracting from a sweep's table, re-derive the table.** A column
> heading that reads the same for two sites ("pause/resume") can name two
> different mechanisms, and the helper you extract will then take a flag for the
> difference — which is the failure mode the lead's own constraint warns about.

The defect the re-derivation found is what one column could not hold. A bridge
has TWO cancel paths, the consumer's (`onCancel`, whose return value
`StreamController` AWAITS) and the owner's (a scope closing, a timer firing).
Round 424 fixed the owner half at two sites; two of the six bridges still
returned the source's cancel from `onCancel`:

    consumer cancel(), source parked, 3000ms cap
    RpcCallScope.track            HUNG
    circuit breaker _wrapStream   HUNG
    CONTROL, await removed        6ms
    site 6, already correct       7ms

> **Count the PATHS into a mechanism, not the sites that have it.** One row per
> site with one "cancel unawaited" column answers a question nobody asked: the
> sites are not where a rule is obeyed or broken, the paths are.

And the extraction's return, measured rather than asserted: ablating
`StreamBridge.onCancel` once turns BOTH witnesses red. Before it, the same
ablation had to be made twice in two files to break two tests — which is the
331 coverage criterion arriving from the other side.

`../rounds/425-the-cancel-path-the-table-had-no-column-for.md`,
`../probes/P-95-bridge-cancel-paths.md`.

## Round 426 — a fix on one twin is a QUESTION about the other

Round 390 fixed a caller-side producer that ran on after its call had ended.
Thirty-six rounds later the mirror was still there, on the sibling that shares
the shape line for line: `responseSink` watched nothing, and a responder that
ended its OWN call — a trailer, an error — kept draining the handler's producer
at +32 and +35 messages per quarter-second, against a +1 control.

The signal existed. `BidirectionalStreamResponder.done` predates this loop.

> **When a round fixes a clause on one copy, the sibling inherits a question,
> not the fix.** Nothing in a diff carries it over, and the round that made the
> fix is the one that knows the clause exists. Ask, in the same round: which
> other copy has this shape, and what would its version of this signal be?

Two further things this pair shows:

- **The lead's own table can be the thing that is wrong.** B-56 described this
  clause twice and contradicted itself — the nine-site sweep marks `responseSink`
  "stop on done: y", the five-site table "n/a, it IS the producer". A record with
  two answers and no measurement is not evidence for either.
- **The worse copy is the quieter one.** The caller's version logged a failure
  per message; the responder's `_processor.send` RETURNS on a finished stream, so
  the same defect produced nothing at all. Severity does not track how loud a
  defect is.

The extraction's return, measured again: one ablation of `SinkPump`'s stop
clause reddens both new witnesses AND round 390's, which was written for the
other copy in another file.

`../rounds/426-the-mirror-nobody-held-up.md`,
`../probes/P-96-response-pump-outlives-its-call.md`.

## Round 444 — the instance can be an ABSENCE, and a sweep's own test says where it looked

Every instance above is two copies that disagree. This one is a copy that is not
there: three sites merge a caller context's headers into outbound metadata, two
filter the protocol-reserved keys, and `ping()` did a bare `addAll`. There is no
drifted line to diff — the detector's step 2, *read the methods side by side*,
finds the defect only if the third site is in the list being read.

> **A missing copy cannot be found by comparing the copies you have.** Enumerate
> the sites by what they DO — grep the operation, not the helper's name — or the
> site that never had the helper is invisible, because it does not contain the
> string you searched for.

Here `grep -rn "isReserved"` returns the two sites that have it. The third came
from grepping the operation instead: every place building a `headerMap` from a
context, `headers.entries` and `.headers)` across core and the transports.

**And the previous sweep left its own record of where it looked.**
`cancellation_header_reserved_test.dart` was written when these keys were
reserved, and one of its cases is named *"the control keys never reach the wire,
ordinary ones do"* — over the unary and streaming shapes. A witness enumerates
the sites its author had in mind, so:

> **Read an existing witness for this class as a list of what was swept, then
> diff that list against the sites that exist today.** The gap is the finding.
> It is cheaper than re-deriving the sweep and it is evidence rather than
> memory — which is what L-12 asks for and what a test can actually supply.

`../rounds/444-the-third-merge-site-nobody-swept.md`,
`../probes/P-98-the-same-context-down-two-call-shapes.md`.

## Round 446 — the copy can be a VALUE, and it can be unreachable

Every application above is a duplicated method or duty. 446 is a duplicated
NUMBER: `RpcContext` held `128 / 128 / 8 KiB / 64 KiB`, equal to
`RpcSecurityPolicy`'s four defaults, in a static method on a value type the user
builds before any transport exists — so it could never read a policy.

The usual detector does not fire. There is no drift to find, because the copies
agree, and they will go on agreeing until somebody edits one. What bites is
something else:

> **A duplicated value whose second home cannot be reached makes its knob
> MONOTONE. Lowering the policy still refuses; raising it changes nothing,
> because the unreachable copy truncates first.** Ask of every limit: raise it
> past the default and measure whether anything moved.

Measured: `maxHeaders` raised to 512, 200 headers set, and the call **SUCCEEDED
with 73 of them missing** — no error or log on either side. The equality is the
camouflage, which is why this is the one variant of the shape that a
copies-disagree detector can never see.

Second, smaller lesson, and it cost this round its cheapest path: when a fix
deletes a limit, the tests pinning it may be a prior round's DECISION rather than
a stale assertion. `f876d602` had made these caps effective on purpose and said
why in its commit. Read that before rewriting the test — and re-measure the
sentence, because the reason it gave had already expired.

`../rounds/446-the-knob-that-only-turned-down.md`,
`../probes/P-100-does-raising-maxheaders-raise-anything.md`.

## Round 447 — the two copies can be two BRANCHES of one method

The copies here are not two classes or two packages. They are the DATA branch and
the HEADERS branch of one `_onMessage`, in one file, forty lines apart. One reads
`_statusReceived` before setting the end flag and the other does not — and the
one that does carries a fifteen-line comment describing the data loss it prevents.

```
(d) END_STREAM on DATA,    no status -> status 14 after 2 items   guarded
(e) END_STREAM on HEADERS, no status -> CLEAN END after 2 items   not guarded
(f) END_STREAM on HEADERS, status 0  -> CLEAN END after 2 items   correct
```

(d) against (e) is the pair: identical malformation, different frame type,
opposite outcomes. And (e)'s transport trace reproduces (d)'s comment verbatim —
the ending closes the consumer, the synthesised status arrives one message later
and is discarded.

> **When a branch carries a long comment explaining a rule, ask which SIBLING
> BRANCH of the same method should carry it too.** The detector for this variant
> is not "find the duplicated helper" but "find the guarded branch and read its
> neighbours". The state was not even missing: the unguarded branch MAINTAINS
> `_statusReceived` two lines above, and only failed to read it back.

`../rounds/447-the-same-loss-on-the-other-frame.md`,
`../probes/P-101-an-ending-with-no-status-per-frame-type.md`.

## Round 448 — the helper was ALREADY shared, and the copies were the CALLS

Every application above looks for a duplicated implementation. Here there was
none to find: `_notifyPeerOfCancellation` is one function. What diverged is how
two callers sequence it — `unawaited` on the streaming side, `await` in the unary
side's `finally` — and each wrote a comment defending its own choice.

> **Extraction does not end the divergence; it MOVES it to the call sites.** When
> a lens says "the copies drift", ask whether the drifting copy is the helper or
> the way it is invoked. The detector is the same question asked one level up:
> find the shared helper, then read every call of it side by side.

The trap in reading them: the unary comment says *"`_notifyPeerOfCancellation`
never throws"*, and that is TRUE — the shared helper wraps both its branches in
try/catch. So the comment survives inspection and the defect is what it does not
mention. A catch does not catch a hang, and the sibling's comment says exactly
that, twelve hundred lines away.

Measured: the unary call NEVER SETTLED on a transport whose end-of-stream send
never completes; the streaming sibling returned over the same transport.

Corollary worth carrying: neither ordering was the one to copy. The unary side
was sequencing something real — the notice must precede the id release, or the
frame lands on the next call to hold that number — and had done it by blocking the
whole call. The fix keeps the ordering and drops the blocking.

`../rounds/448-the-promise-that-was-too-big.md`,
`../probes/P-102-cancel-against-a-send-that-never-completes.md`.

## Round 449 — the lens can be RIGHT about the divergence and WRONG about the harm

The three reconnect machines do diverge, exactly as this lens predicts. What the
round refuted is the HARM the divergence was assumed to cause: the copy without
the guard was supposed to accept and silently drop sends, and it refuses them.

> **A divergence is a lead about where to look, never a finding about what
> happens.** The missing guard was real and redundant: http2 discards the old
> connection before the await, so the send path refuses on its own, and the
> proxy's guard is an ABSENCE (`_inner = null`) rather than a boolean, which no
> flag-timing argument can reach. Both were invisible from the diff that showed
> one machine setting a flag earlier than another.

The divergence that survived is one this lens does not usually look for: not what
the copies DO, but what they TELL the caller. Same state, three answers, and
http2 disagreeing with itself by timing — UNAVAILABLE during the await,
FAILED_PRECONDITION after, under a comment saying the two were aligned on purpose
so one `catch` would cover both.

`../rounds/449-the-window-was-real-the-loss-was-not.md`,
`../checked/C-48-no-machine-drops-a-send-during-its-factory-await.md`.

## Round 451 — the sibling that answers the duty can be in another LAYER

Two rounds in a row now where the divergence was real and the harm was not, and
451 says why in a way that generalises: the detector compares SIBLINGS, and it
finds them by looking sideways. `CallProcessor` and `StreamProcessor` sit in one
file, one is the caller half and one the responder half, and one of them owns
`_setupDeadlineMonitoring`. Read that way the responder is missing it.

It is not. The responder enforces the deadline in `responder_pipeline`, one layer
up — and more thoroughly, because the pipeline owns the stream state and can
therefore arm a RECLAIM backstop that `CallProcessor` has no way to provide.

> **Before filing an absence, ask which layer OWNS the thing the duty needs.** A
> duty lands where its resources are, not where its sibling put it. The pair the
> detector shows you may be the wrong pair, and the tell is that the "missing"
> half would have to reach for state it does not hold.

Round 388 already widened where a sibling may live (into the DEPENDENCY); this
widens it upward, into the caller's own stack.

`../rounds/451-the-disposer-was-in-the-other-layer.md`,
`../checked/C-50-the-responder-bounds-its-deadline-in-the-pipeline.md`.

## Round 452 — the divergence that bites is the one the SWEEP's list omitted

B-84 tabulated three teardown blocks and what each adds. It got the shape right
and the contents short: it listed `_fcForget` as `releaseStreamId`'s extra, and
there were two — the other being `_outgoingPumps.remove(...).dispose()`, which is
the one `resetStream` leaked.

> **Re-derive the sweep's own table before working from it.** L-12 says count the
> class before fixing any of it; this is the smaller sibling — the count may be
> right while the CELLS are incomplete, and a one-item-short cell reads exactly
> like a complete one.

Second half, and it is the reason this sat for 26 rounds inside B-70 without
anyone answering a question it had already written down:

> **A divergence you cannot OBSERVE is not a weak lead, it is an unbuilt
> instrument.** `_outgoingPumps`, `_fcOutstanding` and the stream router were
> private with no getter, so the three blocks could only be compared by reading.
> Three counts in `health()` turned "the weakest of the remainder" into a
> measured leak in one round.

```
releaseStreamId   pumps 1 -> 0
resetStream       pumps 1 -> 1     <- the cancellation path
```

`../rounds/452-the-weakest-lead-had-a-leak-in-it.md`,
`../probes/P-105-what-each-teardown-block-clears.md`.

## Round 454 — the comment was on the RIGHT copy, which is the useful case

U-01 says a comment justifying deliberateness is a lead, not a closed door, and
every earlier application here treated the comment as the thing to doubt. 454 is
the other half: two refusals sat either side of one guard, one carried a comment
explaining its position, and the comment was CORRECT. The copy without it had the
wrong order.

```
draining, late frame on a closed id   status=14 "Server is shutting down"
NOT draining, same frame              NONE (ignored)
```

> **A rule written on one copy is a specification for its siblings.** When two
> near-copies straddle a shared guard and only one says where it belongs, read the
> comment as the intended rule and check the silent one against it — rather than
> asking whether the documented one is right.

Second lesson, from the round's GUARD rather than its witness:

> **Moving a refusal later needs a test that it still refuses.** That guard is
> where the round's second finding came from: the new stream IS refused, and
> refused TWICE, because nothing records the id a refusal just refused (B-90).
> Count the answers, not just their presence — `[14]` and `[14, 14]` read the same
> to a `contains` matcher.

`../rounds/454-the-order-the-sibling-wrote-down.md`,
`../probes/P-106-what-a-late-frame-on-a-closed-stream-is-told.md`.

## Round 455 — the duplicated thing can be a FACT, re-derived instead of passed

Round 446 found a duplicated VALUE whose second home was unreachable. 455 is the
next step down: nothing is duplicated in the code at all. What is duplicated is
KNOWLEDGE — both call sites know their input is de-framed, because both pass
`RpcMessageParser` output, and the callee threw that away and re-derived it from
the bytes.

```
body 13B, first byte 0x00 (valid flag)  -> payload 13B  UNCHANGED
body 13B, first byte 0x99 (not a flag)  -> payload 18B  re-framed
```

A 13-byte message arrived as an 8-byte one, silently.

> **When a callee re-derives something its callers already know, the detector is
> the callee's NAME.** `ensureGrpcFrame` — "ensure" promises a check, so a check
> was written, and the only evidence available to it was the argument itself. Ask
> of any `ensureX`/`maybeX`/`normalizeX`: does every caller already know the
> answer? If so the check is not defensive, it is a guess with the caller's
> knowledge discarded.

The fix was therefore SMALLER than the shape B-62 suggested. B-62 carries a flag
alongside the data; here the fact is a constant at both sites, so it is carried by
the function's contract and its name instead. **Look for the constant before
building the channel to pass the fact down.**

`../rounds/455-the-guess-over-bytes-the-peer-chose.md`,
`../probes/P-107-does-a-body-that-looks-framed-survive-unchanged.md`.

## Round 456 — a LENIENT copy and a strict one both pass, in opposite directions

The usual failure in this lens is two copies giving different answers to the same
question, with one of them wrong. 456 is worse and quieter: three answers, two of
them normalising, and the value satisfied every check — each in the direction that
made the next one harmful.

```
isSupported('Identity')     true       normalises, so nothing is refused
'Identity' != 'identity'    true       so compression is switched ON
compress(enc: 'Identity')   unchanged  normalises, so nothing is compressed
```

Result: the compressed FLAG on bytes nothing compressed.

> **When copies disagree about STRICTNESS rather than about a value, the lenient
> one hides the strict one.** No check refuses, so no error names the
> disagreement; the damage is downstream of all of them. The detector is not "do
> the copies return the same thing" but "does each copy NORMALISE the same input
> before deciding".

Two method notes the round paid for:

> **A witness in the wrong LAYER can pass on both sides of the fix.** Over a
> channel pair, compress and decompress both normalise in one process, so the bug
> round trips harmlessly and the test is green either way. It only bites where the
> two ends are built separately — here, http2's parser against the pipeline's
> reading. Put the witness where the copies are actually independent.

> **Check the lead's claim about REACHABILITY, not just its claim about the code.**
> B-82 said a hand-built peer was required. The opposite was true: a foreign peer
> at flag 0 is inert, and the library's own caller reaches it through a documented
> context header.

`../rounds/456-the-registry-was-lenient-and-nothing-else-was.md`,
`../probes/P-108-what-the-case-of-grpc-encoding-changes.md`.

## Round 458 — the copies agreed on the VALUE and disagreed on the UNIT

Every application so far compares what copies DO. 458's copies do the same thing
with the same number and still disagree, because one of them measures a message
and the other measures a frame.

```
channel, limit = exactly the message   ACCEPTED
http,    limit = exactly the message   REFUSED status=8
both,    limit = message + 5           ACCEPTED   <- the difference is 5 bytes
```

`maxMessageLengthBytes` counts a MESSAGE. An HTTP body is a FRAME. Comparing one
against the other silently lowers the operator's ceiling by the prefix — and only
on the transport that forgot, so the same policy means two things.

> **When a limit crosses a layer, check its UNIT, not just that it is applied.**
> "Is there a bound?" is the question a lead asks; "a bound on WHAT?" is the one
> that finds the defect. The tell is a name that describes the payload being
> compared against a length that includes a header.

Two smaller notes the round paid for:

> **Bound on the wire size, REPORT the configured one.** The first fix made the
> refusal name `max + 5`, a number the operator never typed. An existing test
> caught it, and its own `reason` explained why: the message has to name the knob
> somebody would raise.

> **An off-by-N defect cannot be measured approximately.** Setting the limit to the
> message's own serialized length makes "exactly at the limit" true by
> construction, instead of guessing what the codec does to the payload.

`../rounds/458-a-message-at-exactly-the-limit.md`,
`../probes/P-109-a-message-at-exactly-the-limit.md`.

## Round 459 — an ABSENT copy in one sibling can be the correct answer

This lens has spent fifty rounds finding that a missing copy is a defect. 459 is
the case where it is not, and the distinction is worth having: the duty was in the
shared layer all along, and the window it guards does not exist on the sibling that
lacks it.

```
the parser buffer cap    http2 DOES pass it; the parser's null fallback is the
                         same formula core passes explicitly
the residency charge     lives in core's responder_pipeline, which http2 feeds
the window it guards     cannot open on HTTP/2 -- the method is a `:path`
                         pseudo-header on the frame that opens the stream
```

> **Three questions before filing an absence, and the third is the one usually
> skipped.** Is the duty here? Is it in a layer this sibling shares? And can the
> situation it guards against ARISE here at all? Round 451 stopped at the second;
> this one needed the third, because the honest answer is "correct by
> construction", not "covered elsewhere".

The corollary is about evidence, not code:

> **A grep for a NAME is not evidence about a MECHANISM.** B-79 rested on
> "`bufferedBytes` does not appear anywhere in `rpc_dart_http2/lib`" — and
> `maxBufferedBytes` appears twice, while the thing the lead meant is a property on
> a message class that no transport needs to name. Two different mechanisms shared
> one word, and the word was searched instead of either.

`../rounds/459-the-charge-lives-where-they-meet.md`,
`../checked/C-51-http2-does-charge-the-buffered-bytes.md`.

## Round 460 — the siblings differed in a property the lead never named

B-86 was filed on the shape both transports share: a terminal message whose metadata
is EMPTY. It reasoned that if that reads as a clean end on one, it reads as a clean
end on the other. It does not, and the reason is a property nobody had written down.

```
http2      TWO terminal messages: trailers with no status, then a synthesised 14.
           The first closes the consumer; the second is discarded.
HTTP/1.1   ONE terminal message. Nothing to lose the ordering of.
```

Same empty metadata, opposite outcomes — and the fix on http2 was about ORDER, not
about emptiness at all.

> **When a lead generalises from a shape, ask what else differs between the copies
> before accepting or refuting it.** The shape was identical and the answer still
> depended on a cardinality the lead never mentioned. A shared shape licenses a
> hypothesis about the sibling, never a conclusion — which is the same rule round
> 449 arrived at from the other direction, where the divergence was real and the harm
> was not.

`../rounds/460-one-terminal-message-not-two.md`,
`../checked/C-52-http1-tells-the-consumer-when-a-status-never-came.md`.

## Round 461 — the re-derived fact ends at the PRODUCER, not at the caller

455 found a re-derived fact and located it in the CALLERS: both pass
`RpcMessageParser` output, so the input is always de-framed, so frame
unconditionally. That reading was wrong and the loop paid two rounds for it: the
parser emits a FRAME for a compressed message it cannot de-frame and a BODY
otherwise, so framing unconditionally double-wrapped every compressed message and
lost the compression bit (`grpc-encoding: gzip -> status=13`).

461's fix moved one level upstream. The parser takes `emitFramed`, tracks
`alreadyFramed` for the branch that already framed, and every value it emits is
then the same shape. `frameParsedMessage` is deleted rather than corrected.

> **When a callee re-derives what its callers know, 455's question — "do all
> callers already know?" — has a twin that has to be asked first: does the
> PRODUCER know, and is it the same producer every time?** If one producer feeds
> every call site, the fix belongs in the producer's output shape, and it is
> smaller than any fact carried through the callers: the flag that disambiguates
> turned out to be a local variable eight lines from where the ambiguity is
> created. Nothing had to cross a boundary.

> **The evidence that the boundary is the right one is a SINGLE canary reddening
> both witnesses.** `emitFramed: false` fires P-107's framing witness and P-108's
> compressed-message guards at once. Two defects that one switch controls were
> never two defects; they were one ambiguity, and a fix that addresses one of them
> is by construction in the wrong place.

The same pair also shows what 455's fix cost by being in the wrong layer: the
caller-side version could not even be witnessed against compression, because at
that layer the compressed case is indistinguishable from the framed one — which
is exactly the ambiguity being removed. **A fix placed where the fact is not
available cannot be tested against the case it breaks.**

`../rounds/461-the-parser-answers-so-nobody-guesses.md`, and rounds 455 (the wrong
layer) and 457 (the revert that named this one).

## Round 462 — count the BEHAVIOURS, because that is what this lens is about

The detector says: find a field every sibling declares, read the methods around
it, diff them by behaviour. Step 3's "by behaviour, not by text" is the whole
instruction, and a lead that has already done steps 1 and 2 arrives with a table
of IMPLEMENTATIONS — which is a different number.

B-77 tabulated three, with three verdicts. Measured, four inputs against each:

```
                          HTTP/1.1      HTTP/2        core (channel)
(absent)                  415 REFUSED   OK            OK
application/grpc          200           OK            OK
text/plain                415 REFUSED   status=3      status=3
```

Two behaviours. The row the lead read as "http2 validates NOWHERE" is http2
INHERITING core's copy, because its metadata goes up to the shared pipeline — and
a fix sized to three implementations would have added a call http2 already makes.

> **A count of implementations is not a count of behaviours, and this lens wants
> the second one.** Sibling files are where you look; the wire is where you count.
> The cost of getting it backwards is not wasted effort but a WRONG FIX: the
> owner's decision here was "the three collapse to one function, and http2 starts
> calling it", and on a surface of two that instruction makes a live check looser.

Second half, and it is the one the three-way comparison could never produce: the
count was also SHORT. A fourth site judges a content-type — the http2 caller, on
the RESPONSE — and reading the four together is what showed the HTTP/1.1 caller
has no such check at all. Round 444's rule applies again: a missing copy cannot be
found by comparing the copies you have, and here the missing one was on the
opposite side of the call from everything the lead listed.

```
HTTP/1.1 caller, a 200 + text/html   status=13 "Invalid compression flag ... : 60"
HTTP/2 caller, same answer           status=13 "Invalid content-type ... "text/html""
```

> **When a duty has two directions, enumerate both before believing a count.** The
> lead's three sites were all inbound. "Who validates X" asked of the caller side
> as well doubles the surface and, here, is where the only unguarded site was.

Third, on merging: the unified rule takes the divergent part as a PARAMETER, and
the site with a reason of its own states it rather than reading the shared
default. The HTTP/1.1 responder keeps refusing an absent header because a
cross-origin `fetch` with a typeless body sends none and needs no preflight —
which is the argument its own POST-only check is built on, thirty lines above.
That is "What NOT to merge" applied to a DEFAULT rather than to code: one
implementation, and one call site that names a different argument to it.

`../rounds/462-three-implementations-two-behaviours.md`,
`../probes/P-111-content-type-across-the-layers.md`.

## Round 464 — unify the DUTY, and take the flag from what each copy already has

Round 416 unified what this library THROWS; 464 unified what it throws for one
state, and the interesting part is the second half.

Three reconnect machines answered the disconnected state three ways, and the
owner's `## Ask` — *whose behaviour would the shared version have?* — has no
answer as posed:

```
                          websocket   http2     health
during the factory await     9          14      degraded
after a FAILED reconnect     9           9      unhealthy
```

> **When the Ask has no winner, check whether the copies are answering ONE
> question.** They were not: a reconnect in flight and a reconnect that failed
> want opposite advice, and every copy gave one answer to both. `health()`
> already distinguished them, which is the tell — a fact the system computes
> somewhere and the shape under test does not carry.

The shared version became a TYPE, `RpcNoConnectionException(what, reconnecting:)`,
the same remedy round 416 reached for. What it needed was a flag at each site,
and this is where the shape is easy to get wrong:

> **Do not add a flag for the unified duty; find the one each copy already
> keeps.** A fresh `bool _reconnecting` would have needed clearing at three exits
> in one machine, three in another and SEVEN in the third's connect loop — and an
> uncleared one leaves callers retrying into a loop that gave up. All three
> already had a field meaning "an attempt is in flight", each cleared in exactly
> one place: two single-flight `Future`s and a `Completer` guard. The proxy takes
> it as a CALLBACK rather than a copy, so there is still one source.

The first attempt here did add the bool — and the compiler refused it, because
the name `_reconnecting` was already taken by the single-flight future in BOTH
transports. A collision is a weak signal and it was the right one.

Third note, on the sibling that was right by accident: http2 answered the correct
status during its window and not from its guard — it discards the connection
first, so the send path threw on its own. **A copy that produces the right value
for the wrong reason is still a copy that will drift**, and the type made it
visible: same code, different exception class, for one state.

`../rounds/464-two-states-wearing-one-word.md`,
`../probes/P-113-what-one-state-tells-a-caller.md`.

## Round 465 — the ablation aimed at one copy answered for another

The same lead's other half, and it is the third time it has ended "the divergence
is real and the harm is not". Three mechanisms for stream-id reuse across a
reconnect, and the outcome is identical:

```
             before  after  collision  late finishSending
websocket      1       3       no      no -- different id
http2          1       3       no      no -- different id
proxy          1       3       no      no -- different id
```

The section above — *"What a no-drift candidate earns: nothing"* — applies, and
451's question settles the merge: the proxy REPLACES the transport, so its duty
crosses an object boundary the other two never lose. One shared class would be
one class with three flags.

What is worth carrying is where the round's only new fact came from:

> **An ablation aimed at one copy is a live test of every copy built on it.** The
> control here restored `_nextStreamId = 1` in http2 — the reset its own comment
> says is deliberately absent — to prove the bench could see a collision. It did,
> AND the proxy arm, which runs over that same transport, stayed clean: its
> `_idWatermark` carried the sequence across a transport that had rewound. That
> is what its doc comment claims and what nothing had ever exercised. Read every
> row of a control run, not only the row you aimed at.

`../rounds/465-three-mechanisms-one-outcome.md`,
`../probes/P-115-does-an-id-come-back-after-a-reconnect.md`,
`../checked/C-53-three-id-mechanisms-one-correct-outcome.md`.

## Round 468 — one of the "copies" had no entry point at all

The detector's step 1 is *find a field every sibling declares*, and a field name
survives differences in mechanism — which is what makes it a good detector and
also what makes this case slip through. B-89 listed three implementations of the
stream-id parity rule by pointing at three counters. One of them is not an
implementation:

```
RpcHttp2ResponderTransport implements
    IRpcTransport, IRpcSecurityPolicyAware, IRpcFlowControlled
```

No `IRpcStreamIdSequence`, so no `resumeStreamIdsAfter` and no
`lastIssuedStreamId`. `_nextStreamId = 2` is written once and incremented; nothing
can hand it a value of any parity.

> **A field is a copy of a RULE only if something can drive it.** Step 1 finds
> declarations, and a bare initialiser declares the same thing a rule does. Before
> counting a site as an instance, ask what its ENTRY POINT is — the `implements`
> clause answers it in one line, and answered it here after the lead had carried
> the site for eighteen rounds.

The same round's second half is the one worth pairing with 465's: the control —
the caller's alignment deleted — turned three direct rows red and left the PROXY
arm clean. Two rounds running, an ablation aimed at one arm has answered a
question about another.

> **A clean arm under an ablation is not a weaker result than a red one.** Red
> says the rule works; clean says the rule is never asked on that path. Both are
> findings, and only the second tells you whether a duplication can bite.

`../rounds/468-the-third-home-has-no-door.md`,
`../probes/P-117-where-the-parity-rules-meet.md`,
`../checked/C-54-the-parity-rules-never-meet.md`.

## Round 478 — a matrix read off a LEAD is not a matrix

The lens's whole method is step 3: diff the copies by behaviour. 478 is what
happens when the diff is taken from prose instead of from code.

B-33 said two adapters disagreed. Round 471 recorded FOUR answers. Both were
written before round 416 converted this library's `StateError`s, and round 471 —
mine — read `minio` and `sqlite` with a grep and took `in_memory` and `webdav`
from the lead's text. Read against the tree:

```
blob MISSING, expectedVersion != null   in_memory ABORTED   sqlite ABORTED
                                        webdav    false     minio  false
blob EXISTS at another version          all four  ABORTED    <- already unified
```

> **One axis had already been fixed by a round that never mentioned this lead.**
> Round 416 swept `StateError` out of 17 packages; two of these four adapters
> were in that sweep, and B-33 went on describing the pre-416 world for
> twenty-five rounds. A lens that compares copies has to re-read the copies —
> including when a previous round of the SAME lens claims to have done it.

The choice between the two surviving answers is worth recording too, because it
is not "pick the majority":

> **Between two defensible unifications, prefer the one that cannot break a
> working caller.** `false` and ABORTED each had two adapters and a real
> argument. `false` is what the contract sentence already promised, and choosing
> it makes two adapters STOP throwing; choosing ABORTED would have added a new
> throw to two published packages for a case that returns quietly today.

And the implementation asymmetry the sweep exposed:

> **A unified answer can cost one adapter a query.** `sqlite` could not
> distinguish "gone" from "wrong version" at all — a conditional
> `DELETE … AND version = ?` reports `changes() == 0` for both — so the two
> outcomes having different answers forced a read before the write. The other
> three needed a line or nothing. Count the cost per copy, not per class.

`../rounds/478-one-contract-for-a-conditional-delete.md`.

## Round 496 — one copy had been OPTIMISED and the other had not

The duty: accumulate bytes until a declared length arrives. Two implementations,
one layer apart — `RpcFrameMultiplexedChannel` for channel frames,
`RpcMessageParser` for gRPC messages. The channel's had been made amortized, with
a comment saying so; the parser's still reallocated and copied the unconsumed tail
on every chunk:

    16 MiB in 1025 chunks of 16 KiB    1515 ms  92.47 us/KiB   ->  8 ms  0.49 us/KiB
     1 MiB in 65 chunks                   7 ms   6.84 us/KiB   ->  0 ms  0.00 us/KiB

> **The divergence this lens looks for can be PERFORMANCE, with both copies
> correct.** Every earlier application found one copy answering a question
> differently — a status, a duty, a limit. Here both reassemble correctly and one
> is quadratic. A copies-disagree detector reading behaviour finds nothing; the
> tell is a comment on one copy (*"amortized O(1) via _appendToBuffer"*) with no
> counterpart on the other.

> **And the sibling's SECOND rule is the one worth crossing the boundary for.**
> The channel's comment says its size limit is *"checked BEFORE the append, which
> is the whole point"* — because geometric growth lets a peer past the bound make
> you allocate twice it first. Copying the growth without that ordering would have
> traded a CPU bug for a memory one. When taking an optimisation from a sibling,
> take the invariants written around it.

`../probes/P-134-what-reassembling-one-large-message-costs.md`,
`../rounds/496-the-sibling-had-solved-it-one-layer-up.md`, B-105.

## Round 498 — the duty was already named in a doc comment

Rounds 384, 386, 389 and 390 each found a duty one copy had forgotten. Round 498
found one where the SIBLING'S DOC SAYS SO IN ADVANCE.

The duty: *what does a caller owe the server when it stops waiting?*
`BaseProcessor.notifyPeerOfAbort` exists for it, and its comment reads:

> *"`_sendCancellationToServer` is reachable only through a cancellation token, so
> a call that ends because its local REQUEST STREAM failed has no way to reach
> it."*

That sentence enumerates one such ending. TIMEOUT is another, and neither
`UnaryCaller` nor `ClientStreamCaller` reached the notice from it:

    no deadline, a handler that never answers     cancelled=0  ->  1
    the same with a 500 ms deadline (control)     cancelled=1      1

> **A doc that says "X is reachable only through Y" is a list with one entry and
> an invitation to find the others.** Grep the imperative and the exclusive —
> "only through", "the only path", "nothing else calls" — and then enumerate the
> endings yourself. The fix is usually the existing method, called from one more
> place.

And the round's own mistake is the one to carry forward: **the second half's
canary passed.** Its witness reached `onTimeout` through a short deadline, the only
fast route — and the deadline path already cancels the handler through the call
scope, so the test measured machinery that already worked. It is a GUARD now, and
the half it was meant to witness has only the 60-second probe behind it.

> **When two copies share a duty but not a trigger, a witness for one may be
> unreachable for the other.** Check that the ablation kills each witness, not
> just that the suite is green.

`../probes/P-136-what-bounds-a-call-with-no-deadline.md`,
`../rounds/498-giving-up-without-telling-anyone.md`, B-107.

## Round 582 — the two homes both wrote, and the merge made it visible

Round 446's variant is a duplicated VALUE whose copies agree. 582 is the same
variant with the copies DISAGREEING and both reaching the wire.

The duty: *who sets the response `content-type`?* Two answers on HTTP/1.1 —
`_completeResponse` seeds `application/grpc+proto`, and
`RpcMetadata.forServerInitialResponse()` adds `application/grpc`, which core's
unary responder sends on every call. HTTP/2 has one answer: it converts the
metadata and seeds nothing. That sibling is the control, and it has no second
home to collide with.

```
HANDLER  application/grpc+json   2  [application/grpc+proto, application/grpc]
WIRE     application/grpc+json   1  [application/grpc]
```

> **A second home for a value is normally silent; what made this one visible is
> that the surrounding code MERGES rather than overwrites.** The branch turning a
> repeated header name into a list exists so a repeated custom key survives
> (round 545) — a correct feature, which promoted an invisible duplicate into two
> values in the output. Where a collection accumulates by key, ask which keys have
> two writers; an overwrite would have hidden this for as long as nobody compared
> the two literals.

And the detector's answer here is not "share the helper" but **pick an owner**.
`content-type` is a wire concern the transport knows and core cannot — core has no
request in hand and emits the bare form — so the transport resolves it and skips
any copy in the metadata. Extracting a shared helper for one caller would have
been RPC-08's defect instead.

`../probes/P-202-which-content-type-a-grpc-over-http1-response-carries.md`,
`../rounds/582-two-answers-to-one-question.md`, B-146.

## Round 583 — the list to complete was the doc's own exception clause

Round 498 found a duty a doc had named ("X is reachable only through Y" is a list
with one entry). 583 is the same move on a doc that enumerates its own
EXCEPTIONS.

`grpcStatusFromHttpStatus` is grpc-go's table plus whatever this library really
produces, and its doc says exactly that:

> *"Two rows are kept beyond grpc-go's, each because something really produces
> it."*

So enumerate what this library really produces. `_reject`'s call sites give six
statuses, three of which had no row — 405, 408, 415 — all falling to
`_ => unknown`:

```
405    2  attempts 1    not a POST                              correct
415    2  attempts 1    content-type is not application/grpc    correct
408    2  attempts 1    the body did not arrive in time      ->  14, attempts 3
```

> **An exception clause with N entries is a list to complete, and the completion
> is decided by one property rather than by taste.** Here it is RETRYABILITY: a
> missing row makes a status `unknown`, which is final, so a row changes behaviour
> only where the condition is transient. That test keeps 405 and 415 out and lets
> 408 in — and it is why "add rows for all three to improve the diagnostic" is the
> wrong answer rather than a harmless one.

The round's other half is the lens looked at from behind. The comment that filed
the lead argues from the table and gets the status wrong, and its CONCLUSION is
right anyway, because the two statuses it confuses have the same retryability.
**A copy that disagrees with its source is not automatically a defect — ask which
property the argument depended on.**

`../probes/P-203-what-each-http1-rejection-becomes-at-the-caller.md`,
`../rounds/583-the-row-the-table-was-missing.md`, B-147, B-222.

## Round 585 — the fixed copy carried the reasoning in a field comment

The cheapest application this lens has had. Two sides of one wire format in one
package; the responder's body buffer is a `BytesBuilder(copy: false)` with a
comment saying why, and the caller's was still a growable `List<int>` finished off
with `Uint8List.fromList`.

```
LIBRARY   32 MiB payload   the buffer's own  +205 MiB  ->  +0
LIST      +165 MiB
BUILDER     +1 MiB
```

> **When a lens finds a divergence that is a COST rather than a wrong answer, the
> number needs a bracket and the bracket belongs OUTSIDE the library.** A bare
> `List<int>` and a bare `BytesBuilder` fed the same bytes say which of the two the
> library is; the library's own figure says nothing on its own. And read the
> bracket as a bracket: the `LIST` arm varied `+165` to `+528` across runs on
> identical input.

> **A performance fix with a deterministic consequence should be pinned by the
> consequence, not by the measurement.** `takeBytes()` on a single chunk returns
> that chunk, so `identical(sent, payload)` is the memory claim stated as an
> assertion — and unlike an RSS threshold it does not fail on a busy machine.

Round 496 found the divergence-as-performance variant first (one reassembly
amortized, its sibling quadratic). 585 adds that the sibling's comment can be the
whole diff: nothing here had to be designed.

`../probes/P-205-what-one-buffered-request-body-costs.md`,
`../rounds/585-the-buffer-the-sibling-had-already-replaced.md`, B-148.

## Round 587 — the sibling was fifteen lines up, in the same `try`

Every earlier application looked for the sibling in another class, package or layer.
Here it is the PREVIOUS CATCH CLAUSE.

The duty: *what does this transport log when a call ends for a reason this side
caused?* `http.RequestAbortedException` answers it at `internal` and says why —
*"logging it at error would make every ordinary cancellation look like a failure"*.
The generic catch below it answered the same question at `error`, so an orderly
`close()` produced one record per in-flight call:

```
8 calls in flight   errors 8  ->  0, internal 16
1 call              errors 1  ->  0
0 calls             errors 0      0
```

> **Two `catch` clauses on one `try` are two copies of a decision, and a diff never
> shows them side by side because nothing was duplicated — the second one simply
> never asked.** Detector: for each `try` with more than one handler, state the
> question every clause is answering and check they agree. Cheaper than any
> cross-package sweep this lens has run.

> **When a claim says "each", the arm must SCALE.** `8 / 1 / 0` is the measurement;
> a single run showing one error reads as a message rather than as a defect, and the
> 0-call arm is what says the records come from the calls and not from the close.

> **And when a fix MOVES a log rather than removing one, the instrument has to admit
> the lower level.** With the default `minLevel` the guarded `internal` call is
> filtered, so `errors 0` is the same reading for "moved" and for "deleted".

`../probes/P-207-what-an-orderly-close-logs-per-in-flight-call.md`,
`../rounds/587-eight-calls-eight-errors.md`, B-143.
