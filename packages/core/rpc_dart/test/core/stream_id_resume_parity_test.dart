// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// There are two routes into "continue this id sequence" and they disagreed.
//
// The METHOD aligns parity and says so: "a value of the wrong parity for this
// role is rounded UP to the next valid one, so a client manager keeps issuing
// odd ids whatever it is handed". The CONSTRUCTOR parameter took the value raw:
//
//   route                       resumeAfter  first three ids
//   method resumeAfter(4)       4            7, 9, 11
//   constructor resumeAfter: 4  4            6, 8, 10   <- a CLIENT
//   constructor, server         5            7, 9, 11   <- a SERVER
//   method, server              5            8, 10, 12
//
// The two roles own opposite parities of one id space, so a client issuing even
// ids is minting the server's ids: two calls can hold the same id at once, and
// everything downstream -- half-close, release, flow-control credit -- is keyed
// on it alone.
//
// `IRpcStreamIdSequence.resumeStreamIdsAfter` is public and its contract
// demands this: "must leave parity intact". The constructor is reachable
// through `RpcChannelTransport.fromChannel(resumeStreamIdsAfter:)`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

List<int> _firstThree(RpcStreamIdManager m) => [
  m.generateId(),
  m.generateId(),
  m.generateId(),
];

final _odd = predicate<int>((i) => i.isOdd, 'an odd (client) stream id');
final _even = predicate<int>((i) => i.isEven, 'an even (server) stream id');

void main() {
  group('resumeAfter parity, constructor against method', () {
    // WITNESS: a client handed an even cursor must still issue odd ids.
    test('a client given an even cursor keeps issuing odd ids', () {
      final viaCtor = RpcStreamIdManager(isClient: true, resumeAfter: 4);
      expect(
        _firstThree(viaCtor),
        everyElement(_odd),
        reason: 'a client issuing even ids mints the server half of the space',
      );
    });

    // WITNESS: and the mirror, which is the same defect from the other role.
    test('a server given an odd cursor keeps issuing even ids', () {
      final viaCtor = RpcStreamIdManager(isClient: false, resumeAfter: 5);
      expect(_firstThree(viaCtor), everyElement(_even));
    });

    // WITNESS: the two routes are one concept and must not diverge. This is
    // what the round was about -- the method is the control, and it was right.
    test('the constructor agrees with the method, both roles', () {
      for (final isClient in [true, false]) {
        for (final cursor in [1, 2, 3, 4, 5, 40, 41]) {
          final viaCtor = RpcStreamIdManager(
            isClient: isClient,
            resumeAfter: cursor,
          );
          final viaMethod = RpcStreamIdManager(isClient: isClient)
            ..resumeAfter(cursor);
          expect(
            _firstThree(viaCtor),
            _firstThree(viaMethod),
            reason:
                'isClient=$isClient resumeAfter=$cursor: the two routes into '
                'one concept disagree',
          );
        }
      }
    });

    // GUARD: a cursor of the RIGHT parity must be taken as-is, not nudged.
    // Rounding everything up would pass the witnesses and skip an id per
    // reconnect.
    test('GUARD: a correctly-parity cursor is not moved', () {
      expect(_firstThree(RpcStreamIdManager(isClient: true, resumeAfter: 5)), [
        7,
        9,
        11,
      ]);
      expect(_firstThree(RpcStreamIdManager(isClient: false, resumeAfter: 6)), [
        8,
        10,
        12,
      ]);
    });

    // GUARD: the documented "values below the natural start are ignored" still
    // holds, so `resumeAfter: -1` and `null` behave alike.
    test('GUARD: a cursor below the natural start is ignored', () {
      expect(
        _firstThree(RpcStreamIdManager(isClient: true, resumeAfter: -1)),
        _firstThree(RpcStreamIdManager(isClient: true)),
      );
      expect(
        _firstThree(RpcStreamIdManager(isClient: false, resumeAfter: 0)),
        _firstThree(RpcStreamIdManager(isClient: false)),
      );
    });

    // GUARD: the ids a healthy manager mints are unchanged -- the control the
    // whole table is read against.
    test('GUARD: no cursor at all is unaffected', () {
      expect(_firstThree(RpcStreamIdManager(isClient: true)), [1, 3, 5]);
      expect(_firstThree(RpcStreamIdManager(isClient: false)), [2, 4, 6]);
    });
  });
}
