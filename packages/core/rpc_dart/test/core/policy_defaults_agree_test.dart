// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcSecurityPolicy` has TWO routes in — the constructor and `fromMap` — and
// every default used to be a literal written out in both. `fromMap` is how a
// policy crosses an isolate or a worker boundary, so a drift would put the two
// ends of one process on different limits, silently.
//
// The literals are now one private constant each. This test is what fails if
// someone writes a literal back in: it compares the two routes field by field,
// which is a claim about the CLASS rather than about any particular number, so it
// keeps holding when a default is deliberately changed.
//
// `toMap` is in the loop as well, because a round trip through it is the actual
// journey a policy makes across a boundary.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Every field, as a map, so a mismatch names the field that drifted instead of
/// failing on an opaque `==`.
Map<String, Object?> _fields(RpcSecurityPolicy p) => {
  'maxMessageLengthBytes': p.maxMessageLengthBytes,
  'maxBufferedBytes': p.maxBufferedBytes,
  'maxMessagesPerChunk': p.maxMessagesPerChunk,
  'maxActiveStreams': p.maxActiveStreams,
  'maxConcurrentHandlers': p.maxConcurrentHandlers,
  'maxMetadataBytes': p.maxMetadataBytes,
  'maxHeaders': p.maxHeaders,
  'maxHeaderNameBytes': p.maxHeaderNameBytes,
  'maxHeaderValueBytes': p.maxHeaderValueBytes,
  'maxMethodPathLength': p.maxMethodPathLength,
  'closeOnProtocolError': p.closeOnProtocolError,
  'halfOpenStreamTimeout': p.halfOpenStreamTimeout,
  'flowControlWindowBytes': p.flowControlWindowBytes,
  'flowControlConnectionWindowBytes': p.flowControlConnectionWindowBytes,
  'initialSendWindowBytes': p.initialSendWindowBytes,
  'initialSendWindowGrace': p.initialSendWindowGrace,
  'contentTypeValidation': p.contentTypeValidation,
};

void main() {
  group('the two routes into RpcSecurityPolicy agree', () {
    // WITNESS. An EMPTY map takes every `fromMap` fallback, so this compares the
    // fallbacks against the constructor defaults and nothing else.
    test('fromMap on an empty map equals the default constructor', () {
      expect(
        _fields(RpcSecurityPolicy.fromMap(const {})),
        _fields(const RpcSecurityPolicy()),
        reason:
            'fromMap is how a policy crosses an isolate or worker boundary, so '
            'a default it does not share with the constructor puts the two ends '
            'of one process on different limits',
      );
    });

    // The journey a policy actually makes: out through toMap, back in through
    // fromMap. Catches a key NAME that only one side knows, which the empty-map
    // test above cannot see.
    test('a default policy survives a toMap/fromMap round trip', () {
      final original = const RpcSecurityPolicy();

      expect(
        _fields(RpcSecurityPolicy.fromMap(original.toMap())),
        _fields(original),
      );
    });

    // CONTROL. A NON-default policy must also survive, or the two tests above
    // would pass on a `fromMap` that ignored its input and always returned the
    // defaults.
    test('CONTROL: a non-default policy survives the round trip too', () {
      final custom = const RpcSecurityPolicy(
        maxMessageLengthBytes: 1234,
        maxBufferedBytes: 4321,
        maxMessagesPerChunk: 7,
        maxActiveStreams: 11,
        maxConcurrentHandlers: 3,
        maxMetadataBytes: 999,
        maxHeaders: 13,
        maxHeaderNameBytes: 17,
        maxHeaderValueBytes: 19,
        maxMethodPathLength: 23,
        closeOnProtocolError: true,
        halfOpenStreamTimeout: Duration(seconds: 29),
        flowControlWindowBytes: 31 * 1024,
        flowControlConnectionWindowBytes: 37 * 1024,
        initialSendWindowBytes: 41 * 1024,
        initialSendWindowGrace: Duration(seconds: 43),
        contentTypeValidation: RpcContentTypeValidation.strict,
      );

      expect(
        _fields(RpcSecurityPolicy.fromMap(custom.toMap())),
        _fields(custom),
      );
    });
  });
}
