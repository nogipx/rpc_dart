---
status: open
round: (not re-measured) — a READ sweep handed in by the owner; every item below was re-read against ff930001, but nothing here was MEASURED
commit: ff930001
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**]
probe: none — READ at the addresses named, never run
reason: cost — 24 confirmed copies that did not each justify a number; the ones that clear RPC-25's bar are called out at the end and a round takes those first
---

# B-70 — the tail of the duplication sweep, all of it re-read

A sweep of `rpc_dart` and the five transports reported 36 numbered duplication
items. All 36 are routed, and all 36 were re-read against `ff930001`:

```
  9   own number, with evidence                       B-64 .. B-69
        1, 3, 4, 8 -> B-64      2 -> B-65       27 -> B-66
        12 -> B-67              33 -> B-68      35 -> B-69
  3   already owned before this intake
        15, 16 -> B-63 (the 'Transport is closed' literal; the stale
                        _ensureUsable justification)
        32     -> SPLIT: its _inFlightCalls and _notify copies are B-63's,
                  its markDraining and stop() halves are B-68's
  24  here
```

Item 32 is the only one counted twice, and it is the only one that genuinely has
two owners.

**READ is still all this is.** No probe was run for any item. A line below has
been seen at the address it names; it has not been made to fail.

## Six of the sweep's claims did not survive the re-read

Written down so nobody re-derives them from the original text.

- **25 is STALE, not open.** The sweep said core sees only the
  `IRpcAdvisoryChannelError` marker, so an enveloped stream error is redacted to
  INTERNAL. True before round 413, false now: `RpcHttp2StreamError`
  `extends RpcStatusException` (`rpc_http2_common.dart:193`) and derives its
  status through `wireStatusFor`. **B-62 closed it.** What survives is the
  unconsumed `filterStreamEvents`, which B-62's closing note already records as
  costing precision rather than correctness. Do not re-file.
- **34's headline is WRONG.** The isolate envelope does not lose
  `metadata.methodPath` on web: `isolate_transport_web.dart:68` writes it and
  `:93` reads it back. Its policy half IS a defect — see below.
- **23's proxy claim is WRONG.** Both `createConnection()` closures dispatch to
  `_connectH2ViaProxy` and then pass `drainSignal: drainSignal` from the SAME
  closure (`:322/:347/:364`, `:435/:454`). GOAWAY is visible through a proxy.
  Its other two halves are confirmed.
- **24's counts are wrong** — 3 caller blocks and 4 responder blocks, not 5 and
  3. The shape is confirmed; the arithmetic was not.
- **7's count is 11, not ~12.**
- **19's HTTP/1.1 half is unproven.** Confirmed for the http2 HEADERS path;
  see the entry.
- **14 is already one of B-56's nine.** Round 415 counted `CallScope.track`.
  Whoever takes B-56 gets it free.

## Core — caller and responder pipelines

```
  5   CONFIRMED. The reserved-header filter is unary/caller.dart:418 and
      base_processor.dart:1266, both `if (RpcHeaders.isReserved(k)) continue`.
      Ping has no such line: caller_pipeline.dart:346 is a bare
      headerMap.addAll(routingContext.headers) over the base metadata, so a
      context header overrides ping's own. RpcContext._sanitizeHeaders drops
      only keys starting with ':', so content-type and grpc-* get through

  6   CONFIRMED, and sharper than reported: BOTH orderings carry a comment
      justifying themselves, and one of them describes the other's bug.
      base_processor.dart:1377 sends the notice `unawaited` because "Awaiting
      the notice first meant a send that never completed took the local error
      with it -- and the `try` below catches a throw, not a hang".
      unary/caller.dart:615 does `await cancellationNotice` in `finally` before
      releaseStreamId, defending itself with "_notifyPeerOfCancellation never
      throws" -- which is not the same as never hangs. The sibling's comment
      names the exact transport class that hangs that way

  7   CONFIRMED, and the count is 11. RpcGrpcCompression normalises with
      trim().toLowerCase() (compression.dart:118) and compares the NORMALISED
      value at :124, :131, :150. Eleven sites outside the registry compare a
      raw header value against the lower-case constant: metadata.dart:98,
      unary/caller.dart:114/499/513, base_processor.dart:37/269/564/972/1135,
      unary/responder.dart:87/287. Plus compression.dart:166 itself, on a token
      out of grpc-accept-encoding. `Identity` is a real codec to all eleven

  9   CONFIRMED. Four sites cancel the context token before tearing down --
      responder_pipeline.dart:441 (all streams), :523 ('server draining'),
      :1114, :1975. closeResponderResources (:452-465) goes straight to
      _cleanupStream with no token cancel, so a handler polling the token is
      never told during endpoint.close()

  10  CONFIRMED, and the class boundary is the whole point. base_processor.dart
      holds StreamProcessor (:188) and CallProcessor (:905).
      _setupDeadlineMonitoring exists ONCE, at :1331, inside CallProcessor, and
      is wired at :1013. StreamProcessor has _setupCancellationMonitoring
      (:848) and NO deadline disposer. Its own doc says why that matters: "a
      bare close is indistinguishable from the server having finished: a
      server-stream call then ends *normally* on expiry, handing the consumer a
      truncated stream". That reasoning is not implemented on the responder side

  11  CONFIRMED. The drain refusal (unavailable) is at responder_pipeline.dart
      ~613 and tests `_respIsDraining && _respStreams[id] == null`, i.e. BEFORE
      the closed-stream guard ~658. The ceiling refusal (resourceExhausted)
      ~681 sits after it and carries a comment explaining that it must. The
      drain branch has no such comment and gets the opposite order

  13  CONFIRMED, and worse than "a second home". RpcContext holds its own four
      constants -- _maxHeaderCount 128, _maxHeaderNameLength 128,
      _maxHeaderValueLength 8*1024, _maxTotalHeaderBytes 64*1024
      (contracts/context.dart:11-14) -- NUMERICALLY EQUAL to the policy's
      defaults today and wired to nothing. _sanitizeHeaders (:238) `continue`s
      past an over-long header and `break`s out at the count or byte ceiling,
      discarding the remainder with no signal. A raised maxHeaders never reaches it

  14  CONFIRMED. Eight relay sites forward pause/resume (caller_pipeline:284/
      724/752, responder_pipeline:1645/1901, server/responder:169,
      bidirectional/caller:175, circuit_breaker_interceptor:243).
      CallScope.track (call_scope.dart:133-164) builds its controller with
      onCancel only -- no onPause, no onResume -- so demand stops there.
      ALREADY B-56's

  20  CONFIRMED as an asymmetry. Core charges bufferedBytes, metadata included,
      in five places and says so at responder_pipeline.dart:934 and
      responder_streams.dart:282 ("NOT payload.length"). `bufferedBytes` does
      not appear anywhere in rpc_dart_http2/lib

  21  CONFIRMED. Four send paths in channel_transport.dart: sendMetadata (:442),
      sendMessage (:461), sendDirectObject (:509), finishSending (:532). Only
      finishSending consults _finishedStreams (:537) and awaits a credit-parked
      send (:550), under a comment explaining that an end-of-stream carries no
      payload so nothing meters it. sendMetadata with endStream: true goes
      straight to _channel.send and calls _markFinished AFTER -- so a trailer
      does overtake a parked DATA frame
```

## Transports — the contract, and http2

```
  17  CONFIRMED, three machines with three different answers.
      websocket_caller_transport.dart, rpc_http2_caller_transport.dart and
      _ReconnectingTransportProxy (client_connection.dart:78) each solve the
      SAME id-reuse problem differently: a Set of live ids
      (_idsOnThisConnection, websocket only), never resetting _nextStreamId
      (http2, :1783-1800), and an _idWatermark (the proxy, :113-132/:163/:342).
      The _disconnected-during-the-factory-await fix exists in ONE of them:
      websocket sets it at :416 BEFORE `await _reconnectFactory()`, above a
      comment describing what the other shape costs -- "Set only in the catch
      below, it was false for the whole factory await ... so `_ensureUsable`
      passed and work went into the CLOSED inner: sends accepted and dropped
      silently". http2 sets it only in the catch (:1827). ADJACENT TO B-21,
      NOT COVERED BY IT: B-21 is about making the capability a compile-time
      type, not about the three machines disagreeing

  18  CONFIRMED, and the sharpest half is the simplest. rpc_http_caller_
      transport.dart has NO maxActiveStreams check at all -- zero references.
      Core bounds _activeStreams (channel_transport.dart:395) and removes at
      :408 and :800; http2 bounds _reservedStreams (:732) and removes at :791,
      :936, :1184, then applies a SECOND ceiling to _streamParsers at :1362.
      CHECK RPC-05 AND C-29 FIRST -- the charge point may already be written up

  19  CONFIRMED for http2's HEADERS path, UNPROVEN for HTTP/1.1. The DATA path
      gates the end flag on the status: `isEndOfStream: message.endStream && i
      == messages.length - 1 && statusKnown` (:1418), above a comment naming
      the silent data loss it prevents and the commit that added _statusReceived.
      The HEADERS path (:1346) is a bare `isEndOfStream: message.endStream`.
      For HTTP/1.1 the caller always emits a terminal message -- a synthesised
      grpc-status from the HTTP code (:380) or the parsed trailer set (:449) --
      and only grpc-status/grpc-message reach that set (:420), so an empty
      trailer would end the stream with no status. Whether that is REACHABLE
      was not established

  22  CONFIRMED, and it is the dangerous half. The caller bounds the shutdown --
      `await _connection.finish().timeout(_gracefulCloseTimeout)` with a
      terminate() fallback (:1943) -- above a comment saying finish() on a dead
      connection "throws from package:http2 into the root zone". The responder
      does a bare `await _connection.finish()`
      (rpc_http2_responder_transport.dart:1114), so it is exposed to exactly
      the throw the sibling documents. Same process-death class as B-63 #3

  23  SPLIT. The drainSignal claim is WRONG (see above). CONFIRMED:
      `viaSocket` (:377-409) is the one factory that never calls disableNagle,
      which the TLS (:340) and h2c (:447) paths both do -- and :337 records
      that the direct path once lacked it. ALSO CONFIRMED and worse:
      `reconnect()` cancels every subscription, disposes every pump and clears
      _streamParsers, _activeStreams, _initialHeadersReceived, _halfClosedLocal,
      _reservedStreams and _statusReceived (:1735-1750) and only THEN calls
      `await _connectionFactory()`. viaSocket's factory is
      `() => throw StateError('does not support reconnect')` (:399), so one
      reconnect() call destroys a working connection's entire stream state to
      discover a fact known at construction time

  24  CONFIRMED as a shape; the counts were 5 and 3 and are 3 and 4. The three
      caller blocks list DIFFERENT subsets: :788 adds _fcForget, :933 adds
      _streams.remove, :1180 adds _streamSubscriptions.remove, over a shared
      core of _streamParsers / _initialHeadersReceived / _halfClosedLocal /
      _reservedStreams / _statusReceived

  26  CONFIRMED. ensureGrpcFrame (rpc_http2_common.dart:517) decides whether
      data is already framed by PARSING the first five bytes and checking the
      declared length matches; a payload that happens to satisfy that is
      returned unchanged and its first five bytes are then read as a header.
      http2 only
```

## HTTP/1.1, and the platform pairs

```
  28  CONFIRMED. _requiredGrpcExposedHeaders (rpc_http_cors_policy.dart:12) is
      grpc-encoding, grpc-accept-encoding, grpc-status, grpc-message --
      NO grpc-status-details-bin, which RpcMetadata.forTrailer writes. Compounds
      B-64 #1: two independent paths drop the same field

  29  CONFIRMED, three behaviours for one header. HTTP/1.1 reads
      `request.headers[contentType] ?? ''` and rejects anything not starting
      with application/grpc (rpc_http_responder_transport.dart:231-237), so
      ABSENT is rejected. responder_pipeline.dart:778 guards on
      `contentType != null`, so absent is accepted and only a wrong value is
      refused. The http2 responder validates it nowhere -- its only mentions
      are two comments and the response header it writes at :867

  30  CONFIRMED, and it is browser-facing. caller_pipeline.dart:176 and :330
      send `x-route-service` on EVERY call and every ping.
      _requiredGrpcAllowedHeaders (rpc_http_cors_policy.dart:20) is
      grpc-timeout, grpc-encoding, grpc-accept-encoding. A cross-origin browser
      call therefore sends a header the preflight does not allow unless the
      operator adds it by hand, and nothing server-side looks wrong

  31  CONFIRMED. The "+5 bytes of prefix" rule exists twice, both in core --
      security_policy.dart:297 (effectiveMaxBufferedBytes) and
      frame_multiplexed_channel.dart:157, the latter under a comment explaining
      that without it the effective limit "becomes maxMessageLengthBytes - 5,
      rejecting a message at exactly the limit". Neither rpc_dart_http nor
      rpc_dart_http2 references maxMessageLengthBytes at all outside one doc
      line, so no HTTP body gets the rule

  34  CONFIRMED for the policy half, and it fails SILENTLY. The VM ships the
      spawner's policy into the worker -- `policy.toMap()` as args[4]
      (isolate_transport.dart:318), rebuilt with RpcSecurityPolicy.fromMap at
      :230. Web does not: `runRpcIsolateManagerWorker` takes
      `RpcSecurityPolicy policy = const RpcSecurityPolicy()`
      (isolate_transport_web.dart:429-431) as a DEFAULT PARAMETER of the
      worker-side function, and spawn() applies the caller's policy only to the
      host-side transport (:288). So on web a raised limit holds on the host
      and the worker runs at the default, with no error anywhere

  36  CONFIRMED, both halves. Every policy default is written twice --
      security_policy.dart:195-208 in the constructor and :255-270 in fromMap --
      with the literal repeated each time (128, 128, 8*1024, 1024, 64*1024,
      false, 60s, the flow-control windows), so a changed default makes fromMap
      silently disagree with the constructor. The wasm JS shim is carried as
      strings in both ios/Classes/RpcDartWasmPlugin.swift and
      android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt --
      two languages, and per config.md's native note a fix to one is never a
      fix to the other
```

## Reported already-shared — NOT verified, the one thing left unchecked

The sweep's own negatives: `grpc-timeout`, percent-encoding of `grpc-message`,
`-bin` base64, the 5-byte frame and its parser, backoff, `wireStatusFor`,
`drainUntilIdle`, `bufferedBytes`, and parity alignment in
`RpcStreamIdManager`. B-63's "Already extracted" list is the checked version of
roughly the same set and should be preferred where the two overlap.

## Where a round starts

RPC-25 declines cosmetic unification and the owner's qualifier on RPC-08 makes a
code-shape difference a lead rather than a defect. By that bar, five of the 24
are defects on their face and would each stand alone:

- **30 + 28** — the CORS header lists are a stale copy of what core sends. A
  cross-origin browser client is broken today and the server logs nothing.
- **22** — a bare `finish()` on the http2 responder, against a sibling whose
  comment says that call throws into the root zone.
- **34** — a web worker silently runs at the default security policy while the
  VM sibling ships the real one.
- **9** — `endpoint.close()` never tells a polling handler to stop.
- **23** — one `reconnect()` on a `viaSocket` transport destroys a working
  connection to learn a fact fixed at construction.

Then 13, 36 and 10, which are the same shape as B-67: a knob that does not reach
the code, a default written twice, and a rule implemented in one of two classes.
The rest is similarity.

## Owner decision

—

## Four items closed — round 415; the lead keeps its number

- **9** — `closeResponderResources` cancels the tokens before tearing streams
  down, so all five teardown paths in `responder_pipeline.dart` do. The fix made
  a latent `RpcCallScope.close()` race REACHABLE: the scope self-closes on
  cancellation, so `_cleanupStream`'s own `close()` became the second call and
  the early return on `_isClosed` left the disposer loop running detached.
  `close()` now joins the first call. Caught by an existing test, not a new one.
- **22** — the http2 responder bounds `finish()` against `kGracefulCloseTimeout`
  with a `terminate()` fallback, the constant now shared with the caller half.
- **28 + 30** — both CORS lists are written in `RpcHeaders` constants and cover
  everything core sends and writes, `grpc-status-details-bin` included. The two
  senders in `caller_pipeline.dart` (`:176`, `:330`) used a raw
  `'x-route-service'` literal where the constant existed; they name the constant
  now, which is the thing that stops the two sides drifting again.

## Two more closed — round 419

**23** — `_connectionFactory` is nullable and null is checked BEFORE the
teardown, so a refusal destroys nothing. Null rather than a throwing closure is
the point: a fact fixed at construction is stored, not discovered by calling
something. An existing suite used the old defect as a TOOL —
`reconnect_failure_is_recoverable_test`'s helper is documented as *"a transport
whose reconnect factory ALWAYS throws, by construction"* — so the answer was a
SPLIT: `viaSocket` takes an `@visibleForTesting connectionFactory`, and "cannot
reconnect" and "the attempt failed" are now covered separately.

**34** — the spawner's policy rides on the worker URL, the one channel a
`Worker` has at construction. `runRpcIsolateManagerWorker`'s `policy` is
nullable and OVERRIDES what arrived; omitting it inherits. The two halves live
outside the `dart:js_interop` file so they can be tested at all; what is NOT
covered is that the two call sites actually call them, which is read by eye. A
worker script built before this change still ignores the parameter.

**17 items remain**: 5, 6, 7, 10, 11, 13, 14, 17, 18, 20, 21, 24, 26, 29, 31,
36, and the sweep's own already-shared list. All of them are duplication whose
copies currently AGREE — the behavioural half of this lead is now spent.

## Round 432 checked here first and found nothing to take

**The BACKLOG index line was stale and pointed at work done 13 rounds earlier**
— it still read *"34 and 23 are the two worth taking next"*, which the section
directly above this one refutes. Corrected there.

Read rather than re-measured, because the code says it plainly: item 23's
`_reconnectOnce` checks `_connectionFactory` for null **before** the teardown,
with a comment stating exactly why (*"BEFORE the teardown ... Answering here
leaves the LIVE connection intact and every in-flight call with it"*), and item
34's `runRpcIsolateManagerWorker` resolves `policy ?? policyFromWorkerUrl(...)
?? const RpcSecurityPolicy()`.

So this lead is what its own last line says: duplication whose copies agree,
below RPC-25's bar, with no defect left in it.
