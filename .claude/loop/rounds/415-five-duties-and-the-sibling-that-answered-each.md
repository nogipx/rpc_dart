---
round: 415
verdict: FIXED
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2]
lens: RPC-25
bench: none — the evidence is seven ablations, one per half of each fix; no
  quantity exists here. Every finding is "two implementations of one duty
  disagree", whose control is the sibling that already answers it correctly and
  whose confirmation is switching the fix off and watching a named witness fail
commit: yes
---

# Round 415 — five duties, and the sibling that answered each

## Target

The intake the owner handed in at `ff930001` — a 36-item duplication sweep,
filed at that commit as B-64 to B-70 with nothing executed. `next` listed 17
owner decisions and nine open leads and named no order.

Taken: **the intake's confirmed defects**, not a lead. B-63 and B-64 to B-70 are
all one shape, and RPC-25's own record says what to do with it — *"when a lens
has paid five times running, the detector to keep is not the shape but the
QUESTION: pick the duty, then read every implementation of it side by side"*,
and round 391 adds that the answer is to stop applying it one copy per round.
So the scope is the duty, and five of them were taken:

```
duty                                                    copies      wrong
what a caller owes the app when a trailer says error          7          5
what a teardown owes a handler still running                  5          1
what a unary responder owes a call that ended under it   2 branches      2
how long a graceful HTTP/2 shutdown may run                   2          1
which headers this library sends, per the CORS policy         2          1
```

Not taken, and why: B-56 is ranked first by the owner and is a five-call-site
refactor with its own two constraints — it is a round, not a passenger on this
one. B-66, B-67 and B-68 are owner decisions and stay so.

## Hypothesis

Each of these is a copy that drifted, so each fix is transcription: make the
odd one out match its sibling.

It held for three and failed for two, both times by being **smaller than the
sweep said**. The ping site could not be made to match by editing the line the
sweep pointed at, and `closeResponderResources` could not be fixed without
fixing something else the fix itself made reachable.

## Before

No probe: there is no quantity here. What each defect is, read out of the code:

```
duty                        the copy that was wrong          what it did instead
trailer -> exception        5 of 7 caller sites              substituted 'Unknown error',
                                                             so fromTrailer's details
                                                             fallback could never fire
teardown -> handler         closeResponderResources          tore the stream down without
                                                             cancelling the token
call ended -> unary answer  UnaryResponder, both branches    sent DATA + grpc-status: 0
                                                             on an abandoned stream
graceful shutdown bound     http2 responder                  await _connection.finish(),
                                                             unbounded
what we send -> CORS        _requiredGrpcAllowedHeaders      3 headers against the 7 core
                                                             actually sends
```

## Mechanism

**The trailer one is the only silent one, and the sweep did not see its cause.**
`RpcStatusException.fromTrailer` reads the message out of
`grpc-status-details-bin` only when the trailer message is EMPTY
(`errors.dart:123`, `message.isNotEmpty ? message : status.message`). Two
callers passed `''` and reached that branch; five substituted `'Unknown error'`
first, which is non-empty, so the branch was unreachable for them and `details:`
went with it. A peer that puts its detail in `google.rpc.Status` and omits
`grpc-message` — legal, and what the field is for — arrived intact on unary and
client-streaming and as `Unknown error` everywhere else.

The other four are one implementation having a clause its sibling lacks:
`_abortActiveStreams` cancels the token and `closeResponderResources` did not;
`StreamProcessor` gates every send on `_isActive` and `UnaryResponder` is not on
that path; the http2 CALLER bounds `finish()` and terminates, the responder did
neither; core sends seven headers and the CORS policy's list names three.

## After

The rule now has one home per duty, and the odd one out was moved to it rather
than the rule copied again:

- `fromTrailer` owns the precedence — trailer message, then the details message,
  then `kAbsentTrailerMessage` — and all seven callers pass the header through
  empty and all. `grep -rn "Unknown error" packages --include="*.dart"` returns
  the constant's declaration and doc prose, and no production call site.
- `closeResponderResources` cancels the tokens before tearing streams down, so
  all five teardown paths in `responder_pipeline.dart` (`:442`, `:465`, `:1126`,
  `:1988`) now do.
- `UnaryResponder` checks `_callIsOver` after `await _handler(...)` on both
  branches and answers CANCELLED instead of a payload.
- `kGracefulCloseTimeout` lives in `rpc_http2_common.dart` and both transports
  bound `finish()` against it with a `terminate()` fallback.
- The two CORS lists are written in `RpcHeaders` constants and cover everything
  core sends and writes, including `grpc-status-details-bin`.

### The two places the hypothesis broke

**`ping.dart` does not call `fromTrailer` at all.** The staged edit changed its
`?? 'Unknown error'` to `?? ''` with a comment saying the factory would pick the
message up — it builds `RpcStatusException` directly, so the only effect would
have been `'Ping failed with status 14: '`, a message made worse with nothing
gained. Converted to `fromTrailer` instead, which is what the site needed; the
composed prefix went, because the status it names is already on the exception.

**The token cancel made a latent `RpcCallScope` race reachable.** The scope
self-closes on cancellation (`call_scope.dart:289`), so cancelling before
teardown means `_cleanupStream`'s own `scope.close()` is now the SECOND call —
and `close()` returned early on `_isClosed`, leaving the disposer loop running
detached behind it. `close()` now joins the first call instead. Caught by an
existing test rather than a new one, which is the only reason it was caught:
`call_scope_disposer_timeout_test.dart`'s *"the disposers around it still run"*
went to `['third', 'hang-start']` against the expected `['third', 'hang-start',
'first']`.

## Canary

Nine, one per half, each switching off exactly ONE mechanism. Two were split
after the fact because the first run varied more than one thing, and a run that
varies two answers the verdict check's first question with a caveat instead of a
fact: the two CORS lists were re-ablated separately (each fails only its own
tests), and the http2 bound was separated from its `terminate()` fallback. Every
ablation restored with `Edit` and re-run green.

```
fix switched off                       witness failed with
fromTrailer's _orAbsent                Expected: 'Unknown error'  Actual: ''
a caller site's placeholder            Expected: 'user 42 not found'
                                       Actual: 'Unknown error'
closeResponderResources' token cancel  "the handler was never told: close() tore
                                       the stream down without cancelling the
                                       token, so a handler awaiting `cancelled`
                                       parks forever"
RpcCallScope.close() joining           Expected: ['third','hang-start','first']
                                       Actual: ['third','hang-start']
UnaryResponder._callIsOver             Expected: not 'done anyway'
                                       Actual: 'done anyway'
the CORS expose list                   Expected: contains 'grpc-status-details-bin'
                                       Actual: Set:['grpc-encoding',
                                       'grpc-accept-encoding','grpc-status',
                                       'grpc-message']
the CORS allow list                    content-type / x-route-service /
                                       x-request-id+x-trace-id all refused
                                       under an operator override
the http2 responder's bound            "close() did not return: the bare `await
                                       finish()` is unbounded, so a half-open
                                       peer holds server shutdown open
                                       indefinitely"
its terminate() fallback, alone        Expected: true  Actual: <false>
                                       "a timeout abandons the await, not the
                                       work" — close() DID return, in 2 s, and
                                       the connection was still alive
```

Every CONTROL stayed green under its own ablation — a present `grpc-message`
still wins, `drain()` still cancels, an undisturbed call is still answered, a
healthy connection is still finished and never terminated, the three original
CORS headers are still allowed.

**Two things the canaries changed, which is the reason to run them rather than
trust the tests.**

*The first attempt at the caller-site canary PASSED.* It ablated
`server/caller.dart:199` (`_grpcStatusErrorTransformer`) and every test stayed
green — that site is changed and has no witness. The witness runs through
`ServerStreamCaller:142`, which the second attempt ablated and which failed as
quoted. Recorded rather than papered over: see `## Not fixed`.

*One CORS test passed on both sides and has been rewritten.* `x-request-id and
x-trace-id are allowed` asserted against the DEFAULT policy, whose default
`allowedHeaders` already contains both — so it held with the fix absent. The
claim the fix actually makes is that they are REQUIRED, so it now asserts
against a policy whose `allowedHeaders` the operator has replaced, like the
`content-type` case beside it.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS  (rpc_dart 1593, http2 237, websocket 178, ...)
melos run format:check   SUCCESS
melos run license:check  compliant, 1562/1562 files
melos run test:web       SUCCESS — dart2js, core is involved
```

## Not fixed

**B-64 is closed on its first item only.** What remains in it, unmeasured
by this round and still true in the code:

- `client/caller.dart:111` compares the status as a STRING (`!= '0'`) where six
  siblings parse an int;
- "OK with no payload" is UNAVAILABLE on unary and INTERNAL on client-streaming
   — retried and not retried for the same wire event;
- the completion rule is a fourth copy (status vs first payload);
- four caller sites use a bare `Future.timeout` where `RpcLongTimer` exists
  because a dart2js timer past ~24.8 days fires immediately
  (`unary/caller.dart:479,570`, `client/caller.dart:249`, `ping.dart:238`);
- the `Endpoint is closed` pre-flight covers three of the five call shapes.

**Six of the seven trailer call sites have no end-to-end witness.** The factory
unit tests pin the rule and a grep pins the sweep, but only the server-stream
path is driven against a foreign peer. `server/caller.dart:199` is the one
proven to be uncovered — its ablation changed nothing.

**B-70 keeps its number.** Five of its confirmed items are fixed here (9, 22,
28, 30, and the header-constant half of the drift); the rest — 5, 6, 7, 10, 11,
13, 14, 17, 18, 19, 20, 21, 23, 24, 26, 29, 31, 34, 36 — are untouched, and
`34` (a web worker silently running at the default security policy) and `23`
(one `reconnect()` on a `viaSocket` transport destroying a working connection)
are the two worth taking next.

**B-63 is untouched**, including its largest item — eleven production sites
throwing `'Transport is closed'` consumed by literal string comparison.

`ping.dart`'s error message changed shape: `'Ping failed with status 14: x'`
becomes `'x'`, with the status carried on the exception as before. No test
pinned it.

## Links

- B-64 — item 1 closed here; the lead stays open on the five items above
- B-65 — closed here
- B-70 — items 9, 22, 28 and 30 closed here; 19 remain
- RPC-25 — sixth consecutive application of the duty form; five duties in one
  round rather than one copy per round, which is what round 391 asked for
- RPC-14 — the http2 half is its shape: `Future.timeout` abandons the await and
  not the work, so `terminate()` is what releases the connection
- L-16 — the unawaited-cancel rule; `_dropLateResponse` is awaited instead,
  because it is a send and not a cancel
