---
round: 273
commit: f91dd5d9
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
scope: [http]
---

# C-31 — a `.timeout()` on the body read really does stop the read

B-26's hypothesis, refuted. `RpcHttpResponderTransport` reads the request body
as

```dart
body = await readBody().timeout(bodyReadTimeout!, onTimeout: () => throw ...);
```

and `.timeout` on a future does NOT cancel the `await for` inside the async
function it came from. Round 272 had just paid for that distinction on the
neighbouring `_reject`, where the fix had to cancel the subscription rather than
time the future out, so the same defect on the accepted path looked certain.

It is not there. Measured with P-24 — one socket writing as hard as it can after
the answer arrives, with every flush deadlined:

    arm      bodyReadTimeout  status           the server took
    reading  none             NEVER ANSWERED   16384 of 16384 KiB in 49 ms
    timeout  500ms            408               384 KiB, then a 3s stall

384 KiB is the socket's own buffering, reproduced exactly on two runs. The
`reading` arm is what gives that number meaning: the same bench, same writes,
takes all 16 MiB in 49 ms when the server IS still reading.

**Why the two paths differ.** `_reject` runs BEFORE the response exists, so its
drain is a plain subscription on a live request body and nothing else will ever
end it. `readBody`'s subscription is on a request whose response is completed a
moment later, and dart:io detaches the body from a finished exchange — so the
loop is ended by the layer below rather than by the timeout. The difference is
not in our code at all, which is why reading our code predicted the wrong
answer.

> **Two call sites with the same construct are not the same defect.** The thing
> that ends an abandoned subscription may live under it, not in it. Ask what
> else could close the stream before concluding that nothing does.

Also recorded from the `reading` arm, and consistent with the transport's own
doc comment: with no `bodyReadTimeout` the overflow path keeps consuming after
the cap is hit (memory bounded, the builder is cleared) and one socket held
`pendingRequests: 1` while feeding 16 MiB against a 64 KiB ceiling. That is the
documented slowloris, and `bodyReadTimeout` is its answer on both paths as of
round 272.

## Control

The `reading` arm, above. Without it the timeout arm's stall would be
indistinguishable from a probe that could not write.
