// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-6 -- a cancel reaches the other side.
//
// A caller's cancel ends the responder handler's token within 1 s on every
// transport.
//
// The handler hangs until its token fires, and reports that firing itself:
// the assertion is an event at the peer (L-11). The call carries no deadline,
// so nothing but the cancel can fire the token. Each shape is cancelled the
// way an application cancels it: the context's token for unary and
// client-stream, the subscription for server-stream and bidi.

@TestOn('vm')
library;

import 'package:test/test.dart';

import 'support/matrix.dart';

const _within = Duration(seconds: 1);

/// The http caller aborts its own request and the responder is never told:
/// its handler runs until it ends or its deadline passes. rpc_dart_http's
/// README states this as the transport's behaviour; the invariant says it is
/// not allowed.
const _httpNeverTold =
    'the handler never reported "cancelled" within 1000 ms; the http '
    'responder is not told of a caller cancel';

const _knownFailing = <String, String>{
  'http | unary': _httpNeverTold,
  'http | clientStream': _httpNeverTold,
  'http | serverStream': _httpNeverTold,
  'http | bidi': _httpNeverTold,
  'http | 20 calls on one connection, all cancelled': _httpNeverTold,
};

void main() {
  group('I-6 a cancel reaches the responder:', () {
    for (final member in members) {
      for (final shape in CallShape.values) {
        cell(member, shape.name, knownFailing: _knownFailing, () async {
          final rig = await member.serve();
          addTearDown(rig.close);
          final caller = await rig.caller();
          final id = nextCallId();

          final call = Call.start(
            caller,
            shape,
            Blob.request(id: id, mode: Mode.hang),
          );
          await rig.probe.waitFor('enter', id);
          expect(
            rig.probe.has('cancelled', id),
            isFalse,
            reason: 'GUARD: nothing fired the token before the cancel',
          );

          await call.cancel();
          await rig.probe.waitFor(
            'cancelled',
            id,
            within: _within,
            because: 'the caller cancelled',
          );
        });
      }

      cell(
        member,
        '20 calls on one connection, all cancelled',
        knownFailing: _knownFailing,
        () async {
          final rig = await member.serve();
          addTearDown(rig.close);
          final caller = await rig.caller();

          final calls = <({int id, Call call})>[];
          for (var i = 0; i < 5; i++) {
            for (final shape in CallShape.values) {
              final id = nextCallId();
              final request = Blob.request(id: id, mode: Mode.hang);
              calls.add((id: id, call: Call.start(caller, shape, request)));
            }
          }
          await rig.probe.waitForCount('enter', calls.length);

          for (final c in calls) {
            await c.call.cancel();
          }
          for (final c in calls) {
            await rig.probe.waitFor(
              'cancelled',
              c.id,
              within: _within,
              because: 'the caller cancelled ${c.call.shape.name}',
            );
          }
        },
      );
    }
  });
}
