// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// `forward` drops the credentials of the call it is made on behalf of, and
/// keeps the ones the downstream call is given.
void main() {
  final incoming = RpcContext.empty()
      .withBearerAuth('caller-token')
      .withAdditionalHeaders({'proxy-authorization': 'Basic cHJveHk='})
      .withApiKey('caller-key', headerName: 'X-Service-Key')
      .withAdditionalHeaders({'x-tenant': 'acme'});

  test('the inherited credentials do not go downstream', () {
    final downstream = incoming.forward();

    expect(downstream.getHeader('authorization'), isNull);
    expect(downstream.getHeader('proxy-authorization'), isNull);
    expect(downstream.getHeader('x-service-key'), isNull);
    expect(downstream.getHeader('x-tenant'), 'acme');
  });

  test('credentials passed to forward are the downstream call\'s own', () {
    final downstream = incoming.forward(
      headers: {'authorization': 'Bearer service-token'},
    );

    expect(downstream.getHeader('authorization'), 'Bearer service-token');
    expect(downstream.getHeader('x-service-key'), isNull);
  });

  test('sanitized drops an api key under its own name', () {
    final logged = incoming.sanitized();

    expect(logged.getHeader('x-service-key'), isNull);
    expect(logged.getHeader('proxy-authorization'), isNull);
    expect(logged.getHeader('x-tenant'), 'acme');
  });
}
