// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-2 -- a message up to the limit is delivered.
//
// Under the default policy, any message up to `maxMessageSize` is delivered
// in both directions on every transport, whether the receiver is reading or
// paused.
//
// Every message here is EXACTLY `maxMessageLengthBytes` serialized bytes, the
// largest the default policy admits, in both directions. "Paused" is a
// receiver that does not read for a while after the call starts: the handler
// (client-stream, bidi) or the caller's subscription (server-stream, bidi).
// A unary call has nothing to pause on either side, so it has one row.
//
// The paired refusal -- one byte more is RESOURCE_EXHAUSTED -- is I-7.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/matrix.dart';

final _limit = const RpcSecurityPolicy().maxMessageLengthBytes;
const _pause = Duration(milliseconds: 200);
const _deadline = Duration(seconds: 20);

const _knownFailing = <String, String>{};

/// (shape, paused) rows.
const _rows = [
  (CallShape.unary, false),
  (CallShape.clientStream, false),
  (CallShape.clientStream, true),
  (CallShape.serverStream, false),
  (CallShape.serverStream, true),
  (CallShape.bidi, false),
  (CallShape.bidi, true),
];

void main() {
  group('I-2 a message at the limit is delivered both ways:', () {
    for (final member in members) {
      for (final (shape, paused) in _rows) {
        cell(
          member,
          '${shape.name} receiver ${paused ? 'paused' : 'reading'}',
          knownFailing: _knownFailing,
          timeout: const Duration(seconds: 30),
          () async {
            final rig = await member.serve();
            addTearDown(rig.close);
            final caller = await rig.caller();
            final id = nextCallId();

            final call = Call.start(
              caller,
              shape,
              Blob.request(id: id, size: _limit, responseSize: _limit),
              deadline: _deadline,
              headers: paused
                  ? {pauseReadHeader: '${_pause.inMilliseconds}'}
                  : {},
              pauseResponses: paused ? _pause : null,
            );
            final outcome = await call.outcome;

            expect(outcome.ok, isTrue, reason: '$outcome');
            expect(
              rig.probe.maxN('received', id),
              _limit,
              reason: 'the request reached the handler whole',
            );
            expect(outcome.responses, hasLength(1));
            expect(
              outcome.responses.single.length,
              _limit,
              reason: 'the response reached the caller whole',
            );
          },
        );
      }
    }
  });
}
