// Audit finding 3: server disconnect detection is fragile.
//
// log_server.dart:149-152 does:
//   endpoint.transport.incomingMessages.listen(null, onDone: () { ... });
// AFTER endpoint.start() has already attached the responder pipeline's listener
// (responder_pipeline.dart:80 also does transport.incomingMessages.listen(...)).
//
// The audit hypothesis: attaching a second listener to a stream the endpoint
// already listens to throws "Stream has already been listened to" or steals the
// subscription.
//
// This test reproduces EXACTLY that pattern: start an endpoint, then attach a
// second listener to transport.incomingMessages just like _onEndpointCreated
// does. We assert NO StateError is thrown (i.e. the pattern is safe) and that
// the original responder pipeline still works (no stealing). If a StateError
// IS thrown -> the pattern is broken/fragile as claimed -> CONFIRMED.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('finding 3: attaching a second incomingMessages listener after start() '
      'must not throw or steal', () async {
    final (clientT, serverT) = RpcInMemoryTransport.pair();

    final responder = RpcResponderEndpoint(transport: serverT);
    responder.start();

    // Reproduce the server pattern: second listener on the same stream.
    var sawDone = false;
    StateError? thrown;
    try {
      serverT.incomingMessages.listen(null, onDone: () => sawDone = true);
    } on StateError catch (e) {
      thrown = e;
    }

    expect(
      thrown,
      isNull,
      reason:
          'Server disconnect-detection pattern threw on a single-subscription '
          'stream: "${thrown?.message}". The .listen(null, onDone:) in '
          '_onEndpointCreated would crash endpoint creation.',
    );

    // Now verify the responder pipeline was not "stolen": close client side and
    // confirm the onDone we attached actually fires (broadcast semantics).
    await clientT.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      sawDone,
      isTrue,
      reason: 'onDone never fired; disconnect would not be detected',
    );

    await responder.close();
    await serverT.close();
  });
}
