---
round: 573
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-21
bench: P-194 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 573 — the 503 written to a dead socket

## Target

`B-151` item 2, the last substantive one on that lead, and round 561 had already named exactly what
it needed: "a request in flight when the budget runs out, and an observation of whether the peer gets
a reset or a 503". Taken over another http2 lead deliberately — six consecutive rounds in one
transport, and this package's lifecycle items were measured but this one was not.

Lens RPC-21: drive the lifecycle twice — here the two branches of one `stop()`.

## Hypothesis

`stop()` force-closes the connections and only then closes the transport that promises the 503, so
the promised answer is written to a socket that is already gone.

## Before

```
WITNESS  drainTimeout 200ms, the handler takes 30s
    while running   STILL WAITING
    after stop()    ClientException: Connection closed before full header was
                    received, uri=http://127.0.0.1:56821/Svc/slow

ARM      no drainTimeout, so the cut is immediate and documented
    after stop()    ClientException: ... same

CONTROL  the handler finishes inside a 3s budget
    while running   HTTP 200
    after stop()    HTTP 200
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b151_drain_then_force.dart`, with a raw
`package:http` POST so the reading is the HTTP outcome rather than whatever the rpc_dart caller makes
of it.

**The CONTROL is what makes the two resets mean something** — the rig does complete requests and read
statuses.

## Mechanism

```
1. httpServer.close()                 stop accepting
2. _drainRequests(transport, budget)  wait for what is running
3. httpServer.close(force: true)      CUT the connections
4. endpoint.close() -> transport.close()
     "Complete any pending responses with 503."
```

The 503s are made at step 4 over sockets step 3 destroyed. **Both branches had it**: the no-drain one
force-closes and reaches the same step 4 afterwards.

## After

```
WITNESS  after stop()  HTTP 503
ARM      after stop()  HTTP 503
CONTROL  after stop()  HTTP 200    unchanged
```

`_answerStragglers` before each force close: close the transport, then yield one turn.

**The yield is the part worth knowing, and it was measured rather than guessed.** Completing the
completer only hands the response to shelf, which still has to WRITE it, and there is nothing to
await for that — round 561 established that `HttpServer.close()` completes on port release, not on
response flush. Reordering alone still read `ClientException`; `Duration.zero` reads `HTTP 503`. One
event-loop turn, not a wall-clock sleep — which matters because `B-187` is a lead about this
package's sibling sleeping a fixed 50 ms.

## Canary

```
`|| 1 > 0` on the straggler answer

  a request still running when the drain budget expires gets 503
    Expected: 'HTTP 503'
      Actual: 'ClientException'
    the transport promises a 503 to everything still pending, and a reset
    instead tells the peer nothing it can act on

  the no-drain witness fails the same way; the CONTROL passes
```

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http +181
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2183 / 2183, REUSE compliant
```

## Not fixed

**A large pending body can still be cut.** One turn is enough for a 503, which `_reject` builds
small by construction; a response whose body does not fit the socket buffer in one turn is not
covered, and nothing here measures that. The honest claim is about the 503 the transport promises.

**`B-151`'s item 4 remains and is not a defect**: the drain polls
`health().details['pendingRequests']` every 25 ms, a string-keyed metric `drain.dart` itself
criticises. A typed pending count is a design change with no failure to measure, which is why three
rounds have now left it.

**Still unmeasured on that lead**: no TLS arm on the http2 sibling, and `shelf_io.serve` is passed
neither TLS nor `shared`.

**What the peer makes of the 503 is not driven.** The arm reads the HTTP status; whether the rpc_dart
caller turns it into UNAVAILABLE rather than something unclassifiable is a different question on a
different path.

## Links

Lead `../backlog/B-151-http1-server-lifecycle-defects.md` — item 2 CLOSED; the lead stays open for
item 4 and the TLS/`shared` remainder.
Lead `../backlog/B-187-http2-close-sleeps-fifty-ms.md` — why the yield here is a turn and not a
sleep.
Round `561-two-comments-about-one-call-disagreed.md` — which established that
`HttpServer.close()` completes on port release, the fact this round's yield rests on.
Bench `../probes/P-194-reset-or-503-at-the-end-of-a-drain.md` — new.
Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [573]`.
Lesson: none. The reorder-then-measure step is `measurement.md`'s ordinary discipline, and what it
caught — that the fix was incomplete until the write got a turn — is recorded in the method's own
doc comment rather than as a rule.
