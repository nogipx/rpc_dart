---
round: 340
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-10
bench: P-38 — new
commit: yes
---

# Round 340 — the policy that only faced inward

## Target

B-34, filed measured in round 339 when a CI failure took that round. Finishing a
started thread beats opening a new one, and this is the first time **RPC-10 has
ever been applied** — it has sat `applied: never` since round 150.

## Hypothesis

RPC-10 asks *which packages ACTUALLY go through the class that changed?*
`RpcChannelTransport.sendMetadata` validates outbound metadata against the
policy. The transports that implement `IRpcTransport` themselves get none of
that for free, and have to port it by hand — so check whether they did.

## Before

The map, verified on the current tree rather than taken from the lens:

```
transport                                   outbound sendMetadata validates?
RpcChannelTransport (websocket, wasm,       YES  channel_transport.dart:440
                     isolate)
rpc_dart_http caller / responder            YES  :291 / :416
rpc_dart_http2 caller / responder           NO   its only validateMetadata is
                                                 inbound (:1241, :466)
```

http2 was not unchecked — `rpc_http2_common.dart:540`'s `_headerValue` rejects
non-printable-ASCII, and the probe's first arm confirms both transports refuse a
Cyrillic header value. **But a hardcoded check is not a policy.** P-38, under
`RpcSecurityPolicy(maxHeaders: 32, maxHeaderValueBytes: 64)`:

```
                            shared layer                       http2
64 headers (max 32)         ArgumentError: Too many...         ACCEPTED
value 200 chars (max 64)    ArgumentError: Invalid value...    ACCEPTED
header name with a space    ArgumentError: Invalid name...     ACCEPTED
```

A clean call before and after each violation returns `ok(x)`: the frame goes
out, the peer's inbound check refuses that stream, nothing else is harmed. **One
stream is the blast radius**, which is why this was a lead and not an emergency.

## Mechanism

Two implementations of one interface, written at different times. `rpc_dart_http`
carries the check in both halves; http2's caller has `validateMetadata` at line
1241 and its responder at 466, and both are inbound. Nothing distinguishes an
inbound call site from an outbound one to a reader scanning for "is the policy
applied here" — the method name is the same.

## After

`_policy.validateMetadata(metadata)` at the top of both http2 `sendMetadata`
methods, as `rpc_dart_http` does. All three cases now match the shared layer
character for character, including the error text.

```
rpc_dart_http2   +206  ->  +210
```

The non-ASCII case also changed message, because the policy now fires ahead of
`_headerValue`. That costs the `-bin` hint `_headerValue` gave and buys the same
text on every transport; the trade is stated here rather than hidden.

## Canary

Two, because the fix has two halves and each needed its own:

```
caller line removed      Expected: throws ArgumentError
                         Actual: emitted <null>
                         'too many headers was put on the wire'

responder line removed   Actual: threw StateError
                         'Cannot send metadata on stream 1: not a known
                          incoming stream'
```

The responder ablation also confirms the ordering its test comment claims: with
the check gone the stream lookup runs first, so validation really does precede
it. Both GUARDs stayed green in both ablations — an ordinary call, and a `-bin`
trailer carrying base64.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check`
clean; `test:unit` 14 packages, 0 failures.

## Not fixed

**The behaviour change is real and worth naming.** Outbound validation refuses
against the SENDER's policy; before, the same frame was refused against the
PEER's. For a deployment with different policies at the two ends, a sender can
now refuse something its peer would have accepted. `RpcChannelTransport` and
`rpc_dart_http` already make that choice, so this is consistency rather than new
policy — but it lands on a published transport.

`_headerValue`'s `-bin` exemption is now unreachable for non-ASCII values, since
the policy rejects them first. Nothing is lost: the library base64-encodes
`-bin` values (`metadata.dart:129`) and a raw non-ASCII value died one line later
inside `Header.ascii` anyway — as a `FormatException` naming an encoding rather
than an `ArgumentError` naming the rule. Pinned by a GUARD.

## Links

RPC-10 (`applied:` gains 340 — its first). Its map was re-verified before use
rather than trusted: websocket and wasm go `channel -> RpcFrameMultiplexedChannel
-> RpcChannelTransport`, isolate builds `RpcChannelTransport` over its own
channel, http2 and http reference neither except in comments. Unchanged since
round 150.

> **Two comments in http2 name `RpcChannelTransport` behaviours that had to be
> re-implemented by hand** — `createStream`'s `maxActiveStreams`, `finishSending`'s
> idempotence. Each marks a property someone noticed was missing and ported. The
> lens's question is the generalisation of those comments: what else is on that
> list that nobody has noticed yet.
