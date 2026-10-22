---
status: open
round: (not re-measured)
commit: 562fbbb4
paths: [packages/test/rpc_dart_conformance/test/i1_every_call_ends_test.dart, packages/transport/rpc_dart_http/lib/**]
probe:
reason: risk — one failure seen in major-release step 3, not reproduced
rank: 6
---

# B-306 — an http call answered 405 under parallel runs

One run of `melos exec` over socket, websocket, http2 and conformance (four
packages at once) failed conformance I-1 "many calls on one connection: http
| 40 calls, every shape, working peer": `serverStream: status 2: HTTP 405
from /Conformance/serverStream`. The same test file run alone passed, and the
next parallel run did not repeat it. No http code had changed.

405 is what the HTTP/1.1 responder answers a request that is not a POST. An
rpc_dart caller only sends POST, so either the request reached another
process's server on a reused port (a test elsewhere bound, closed and the port
went to a server that answers 405 to POST paths it does not know), or the
caller sent something the responder read as another method.

## Next step

Reproduce: run the conformance I-1 http member in a loop while other packages'
suites run beside it (`melos exec -c 4`), and log the port the member bound and
the port the call connected to. If they differ, it is the test harness; if they
match, capture the request line the responder saw.

## Owner decision

—
