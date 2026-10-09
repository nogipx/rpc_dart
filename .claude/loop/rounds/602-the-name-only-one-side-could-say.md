---
round: 602
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-160 — reused
budget: probes 0/5, canaries 0/5
commit: yes
release: changelog
severity: S2
---

# Round 602 — the name only one side could say

## Target

B-198, confirmed in round 525 and open since: the caller refuses service names the
server routes. In the rpc_dart scope, a reachable interop failure, and the remedy
already existed one constructor over — `forClientRequestWithPath` dropped its own
cap in favour of `parseRpcMethodPath`, and its comment records the third limit it
replaced.

## Hypothesis

`RpcMetadata.forClientRequest` caps each name at 128 characters while the responder
routes any `/Service/Method` up to `maxMethodPathLength` (1024 by default).

## Before

```
   32 chars  routable       builds
  128 chars  routable       builds
  129 chars  routable       REFUSED by the caller     <- the band starts
  600 chars  routable       REFUSED by the caller
 1020 chars  not routable   REFUSED by the caller
CONTROL 1206  not routable   REFUSED by the caller
```

Reading the same constructor found a SECOND disagreement: it checked both names
with one pattern that admits a dot, while the responder's grammar forbids a dot in
the METHOD name (the binding key splits on the last dot). So `/a/b.c` was built by
the caller and refused by the server.

## Mechanism

`forClientRequest` had its own grammar — a 128 cap per name and one pattern for
both — instead of the one `parseRpcMethodPath` implements for the responder.

## After

```
   32 .. 600 chars  routable       builds
 1020 chars         not routable   REFUSED by the caller
CONTROL 1206        not routable   REFUSED by the caller
```

Each name is checked against the responder's own pattern (`kServiceTokenPattern`,
`kMethodTokenPattern`) and the whole path against `parseRpcMethodPath`, the limit
`forClientRequestWithPath` already uses. A 600-character package-qualified service
is called end to end.

## Canary

1. The 128 cap back: `a service name the server routes is one the caller can call`
   fails, `Invalid argument (serviceName): Invalid name ... "myapp.segment...
   .UserService"`.
2. The method name checked with the dot-admitting pattern AND the path check off:
   `a dotted method name is refused where the server would refuse it` fails,
   `Expected: throws ArgumentError, Actual: returned <Instance of 'RpcMetadata'>`,
   and the `CONTROL: a path past the default limit` fails the same way. The dot
   rule is enforced twice (token, then path grammar); the token check gives the
   better message.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages, rpc_dart +1897,
websocket +250), `melos run format:check`, `melos run license:check` — green. Both
changed test files pass on `-p node`.

One existing file changed its expectation, not its property:
`a_method_name_may_not_contain_a_dot_test` asserted `/a/b.c` "does not reach a.b/c"
via the server's status 3; it is now refused by the caller before sending
(`ArgumentError`). The server's own refusal stays witnessed by the hand-built-frame
test in the same file.

## Not fixed

`forClientRequest` still checks against the DEFAULT 1024, not a configured
`maxMethodPathLength`, because it has no policy in scope — the same as
`forClientRequestWithPath`. A server configured above 1024 routes names this caller
refuses; the transport validates outbound metadata against its own policy anyway.

## Links

Lead `../backlog/B-198-the-caller-refuses-names-the-server-routes.md` — closed.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [602]`.
Test `packages/core/rpc_dart/test/core/the_caller_builds_what_the_server_routes_test.dart`.
