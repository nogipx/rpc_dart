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

/// HTTP/1.1 has no cancel frame: the server learns of a cancel from the TCP
/// close, which dart:io here reports about 2.1 s after it happens, and the
/// harness's proxy adds a second such hop. The cancel does arrive (about
/// 4.2 s here; rpc_dart_http's a_cancel_reaches_the_handler_test, no
/// proxy, about 2.1 s). B-284 asks the owner about the bound.
const _httpLate =
    'the handler reports "cancelled" about 4.2 s after the cancel, past the '
    '1 s bound: a TCP close reaches dart:io about 2.1 s late, twice here';

const _knownFailing = <String, String>{
  'http | unary': _httpLate,
  'http | clientStream': _httpLate,
  'http | serverStream': _httpLate,
  'http | bidi': _httpLate,
  'http | 20 calls on one connection, all cancelled': _httpLate,
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
