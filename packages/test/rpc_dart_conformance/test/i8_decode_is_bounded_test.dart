// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-8 -- pre-auth input costs a bounded multiple of its bytes.
//
// The CBOR half. A message is decoded before any interceptor runs, and one
// byte decodes to an empty map, so the bound is on decoded ITEMS:
// `RpcSecurityPolicy.maxDecodedItems`. A message past it is refused
// RESOURCE_EXHAUSTED before the handler sees it, and one inside it is
// delivered whole -- in both directions, on every shape.
//
// Each row runs on a small budget so it is fast; the last one runs the
// default policy with a message the default must refuse.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/matrix.dart';

const _budget = 1000;
const _small = RpcSecurityPolicy(maxDecodedItems: _budget);

/// Items in the list that make a request decode to exactly [total] items.
int _listFor(int total) => total - Doc.requestOverhead;

/// The same for a response.
int _replyFor(int total) => total - Doc.responseOverhead;

/// Runs one CBOR call, returning its status and responses.
Future<(int, List<Doc>)> _call(
  ConformanceCaller caller,
  CallShape shape,
  Doc request,
) async {
  try {
    return (RpcStatus.ok, await caller.cbor(shape, request));
  } on RpcStatusException catch (e) {
    return (e.statusCode, const <Doc>[]);
  }
}

void main() {
  group(
    'I-8 a request past maxDecodedItems is refused before the handler:',
    () {
      for (final member in members) {
        for (final shape in CallShape.values) {
          cell(member, '${shape.name} request', () async {
            final rig = await member.serve(serverPolicy: _small);
            addTearDown(rig.close);
            final caller = await rig.caller();

            final over = nextCallId();
            final (status, _) = await _call(
              caller,
              shape,
              Doc.request(id: over, items: _listFor(_budget + 1)),
            );
            expect(status, RpcStatus.resourceExhausted);
            expect(
              rig.probe.has('received', over),
              isFalse,
              reason: 'the handler received a request past the budget',
            );

            // The paired valid input: exactly the budget is delivered whole.
            final at = nextCallId();
            final (okStatus, _) = await _call(
              caller,
              shape,
              Doc.request(id: at, items: _listFor(_budget)),
            );
            expect(okStatus, RpcStatus.ok);
            expect(rig.probe.maxN('received', at), _listFor(_budget));
          });
        }
      }
    },
  );

  group('I-8 a response past maxDecodedItems is refused by the caller:', () {
    for (final member in members) {
      for (final shape in CallShape.values) {
        cell(member, '${shape.name} response', () async {
          final rig = await member.serve();
          addTearDown(rig.close);
          final caller = await rig.caller(policy: _small);

          final (status, _) = await _call(
            caller,
            shape,
            Doc.request(
              id: nextCallId(),
              items: 0,
              reply: _replyFor(_budget + 1),
            ),
          );
          expect(status, RpcStatus.resourceExhausted);

          final (okStatus, responses) = await _call(
            caller,
            shape,
            Doc.request(id: nextCallId(), items: 0, reply: _replyFor(_budget)),
          );
          expect(okStatus, RpcStatus.ok);
          expect(responses.single.items, _replyFor(_budget));
        });
      }
    }
  });

  group('I-8 the default policy bounds a decode:', () {
    for (final member in members) {
      cell(member, 'unary request of twice the default', () async {
        final rig = await member.serve();
        addTearDown(rig.close);
        final caller = await rig.caller();

        final id = nextCallId();
        final (status, _) = await _call(
          caller,
          CallShape.unary,
          Doc.request(id: id, items: 2 * CborCodec.defaultMaxItems),
        );
        expect(status, RpcStatus.resourceExhausted);
        expect(rig.probe.has('received', id), isFalse);
      });
    }
  });
}
