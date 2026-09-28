---
round: 488
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-04
bench: P-127 — new
commit: yes
---

# Round 488 — a frame that names no method cannot open a call

## Target

B-97, fourth in the audit's rank and the first HTTP/1.1 one.

Scope decided before the fix, because the lead's sketch has two halves and only
one is this defect: **the phantom request is in, real cancellation is not.**
Making a cancel actually stop the server's handler means aborting the in-flight
request, which is B-140's subject and which the sketch itself points at. This
round removes what the cancel PUTS ON THE WIRE and says plainly that the handler
still runs.

Lens RPC-04 — a capability dropped or routed to something that cannot honour
it. `IRpcStreamReset` is the capability; this transport does not implement it,
and core's fallback was routed into a method that could only mis-serve it.

## Hypothesis

`sendMetadata` treats every metadata frame as a call-opening one, defaulting a
missing path to `/Unknown/Unknown`. The cancellation notice carries no path, so
every cancel fires a second POST. Refuted if some layer above filtered it, or if
`_pending` being empty made it a no-op.

## Before

```
                       requests reaching the server
after the request fires
  cancel               2  [/Svc/slow, /Unknown/Unknown]
  no cancel            1  [/Svc/slow]

before the request fires
  cancel               1  [/Unknown/Unknown]  body 0 bytes
  no cancel            1  [/Svc/slow]         body 16 bytes
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b97_phantom_post.dart`

**The second table is not in the lead and is the worse half.** The assignment to
`_pending[streamId]` is unconditional, so a notice arriving before the request
fires REPLACES the pending call: the method path and the whole buffered body go
with it, and the real request is never sent at all.

## Mechanism

One request IS the call on this wire format. A metadata frame that names no
method therefore has nothing it can be — there is no open request to add headers
to, because by cancellation time `_fireRequest` has already removed the entry.
`metadata.methodPath ?? '/Unknown/Unknown'` turned that impossibility into a
plausible-looking request.

## After

```
after the request fires    cancel     1  [/Svc/slow]
before the request fires   cancel     1  [/Svc/slow]  body 16 bytes
```

A frame with no method path returns without touching `_pending`.

## Canary

`if (methodPath == null && 1 < 0)` with the old fallback restored — the two
WITNESSES fail with `Expected: ['/Svc/slow'] / Actual: ['/Svc/slow',
'/Unknown/Unknown']` and `Expected: ['/Svc/slow'] / Actual:
['/Unknown/Unknown']`. The CONTROL and the GUARD — an opening frame still fires
its request — stay green.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` 1938/1938, REUSE 3.3.

**One existing test failed and it was passing for the wrong reason.**
`server_receives_custom_request_headers` builds its metadata as
`RpcMetadata([...forClientRequest('Svc', 'Method').headers, custom])` — and
`methodPath` is NOT a header, it is a separate field, so the spread drops it.
The test's own request was going to `/Unknown/Unknown` while it asserted only on
headers. Repaired by passing `methodPath:` explicitly; the situation it measures
is unchanged.

## Not fixed

**Cancelling still does not stop the server's handler.** It runs to completion
in every arm, before and after. That needs `IRpcStreamReset` implemented over
`package:http` 1.6's `AbortableRequest` (present in the lockfile, checked), which
is B-140's scope — and B-140 is about the same abort from the other side, an
abandoned call that keeps downloading. One change should close both; doing it
here would fix a lead this round did not bench.

The browser half of the lead — `x-client-cancelled` and `x-cancellation-reason`
failing CORS preflight — is moot rather than fixed: the request carrying them is
no longer sent.

## Links

Lens RPC-04. Bench P-127 (new). Lead B-97 (closed). B-140 inherits the abort.
