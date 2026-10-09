---
round: 538
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-23
bench: P-171 — new
commit: yes
release: changelog
severity: S1
---

# Round 538 — the documented composition never worked

## Target

B-142: the HTTP/1.1 responder routes by the full request path.

Lens RPC-23 — the narrative beside the code. The class says three separate times that its handler
"mounts on any shelf server or router", and one line down the file reads the path that a mount is
defined to change.

## Hypothesis

`methodPath = request.requestedUri.path`, so mounted under `/rpc/` the path is `/rpc/Svc/M` and the
call is refused.

## Before

```
  arm                    methodPath the transport saw   the caller got
  mounted at /rpc        /rpc/Echo/echo           status 3: Invalid method path: /rpc/Echo/echo
  CONTROL not mounted    /Echo/echo               ok: echo:hi
```

Bench `../probes/P-171-does-a-mounted-handler-route.md`.

CONFIRMED exactly as filed. Two readings from one run, because a wrong path and a missing service give
the same status from different causes: the `methodPath` column names the cause, the outcome column says
it matters.

**The mount is built from shelf's own primitive**, `Request.change(path: 'rpc')` — which is what
`shelf_router.mount` does — so the composition under test is the real one and no dependency was added
to measure it.

## Mechanism

Shelf splits a request into `handlerPath` and `url`: `url` is the path RELATIVE to wherever the handler
was mounted, and `requestedUri.path` is the whole thing. Unmounted the two are identical, which is why
every existing test agreed with the broken reading.

## After

`'/${request.url.path}'`. The leading slash is added back because `url` never carries one and
`parseRpcMethodPath` requires it. Both arms now read `/Echo/echo`.

## Canary

`requestedUri.path` restored: the witness fails `Expected: '/Echo/echo' / Actual: '/rpc/Echo/echo'`, and
the two-level control fails with `/api/v1/Echo/echo`. The unmounted control passes in that state — which
is precisely the reason the defect survived.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. rpc_dart_http: 170 passed.

## Not fixed

**`shelf_router` itself was not used.** The mount is emulated through the primitive that package mounts
with; if it ever changes how, this rig would not notice.

**No CHANGELOG line is owed for the unmounted case and one IS owed for the mounted one.** Nothing changes
for a handler served at the root — the two path forms are identical there — but a deployment that had
worked around this by registering services under a prefixed name would now break. Worth a line as a
fix, not as a break.

**The caller side of a prefix was never in question.** `RpcHttpCallerTransport` takes it as part of
`baseUrl` and worked in both arms.

**The sibling was not checked.** Whether `rpc_dart_http2`'s responder has the same shape — it does not
use shelf, so probably not — was not looked at. RPC-08's question, unasked.

## Links

Lens RPC-23. Bench P-171 (new). Lead B-142 closed. The third round in a row where the lead's own fix
sketch was right (`'/${request.url.path}'`, exactly), after two where it was not.
