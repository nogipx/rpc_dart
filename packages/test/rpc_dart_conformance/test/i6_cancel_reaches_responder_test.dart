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

import 'dart:io';

import 'package:test/test.dart';

import 'support/matrix.dart';

const _within = Duration(seconds: 1);

/// HTTP/1.1 has no cancel frame: the server learns of a cancel from the TCP
/// close. On macOS a Dart server sees a peer's close about 2.1 s after it,
/// and the harness's proxy adds a second hop; on Linux it is a few ms and
/// these cells pass (B-284).
const _httpLateOnMacOS =
    'macOS only: the handler reports "cancelled" about 4.2 s after the '
    'cancel, past the 1 s bound: a TCP close reaches a Dart server about '
    '2.1 s late there, twice through the proxy';

final _knownFailing = <String, String>{
  if (Platform.isMacOS) ...{
    'http | unary': _httpLateOnMacOS,
    'http | clientStream': _httpLateOnMacOS,
    'http | serverStream': _httpLateOnMacOS,
    'http | bidi': _httpLateOnMacOS,
    'http | 20 calls on one connection, all cancelled': _httpLateOnMacOS,
  },
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
