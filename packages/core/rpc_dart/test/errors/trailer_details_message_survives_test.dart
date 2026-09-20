// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Five of seven callers destroyed the peer's error message, and nothing said so.
//
// `RpcStatusException.fromTrailer` reads the message out of
// `grpc-status-details-bin` only when the trailer message is EMPTY:
//
//     message.isNotEmpty ? message : status.message
//
// Two call sites passed `''` and reached that branch. The other five --
// bidirectional/caller, server/caller (twice), ping and caller_pipeline --
// substituted the literal `'Unknown error'` for an absent `grpc-message`.
// Non-empty, so the branch could never fire for them, and `details:` went with
// it: the only other returns carry no details at all.
//
// A peer that puts its detail in `google.rpc.Status` and omits `grpc-message`
// is doing the legal, intended thing -- that is what the field is for -- and it
// arrived intact on a unary or client-streaming call and as `Unknown error` on
// the other five.
//
// The rule now lives in one place. `fromTrailer` owns the precedence (trailer
// message, then details message, then the placeholder) and every caller passes
// the header through empty and all.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _Req implements IRpcSerializable {
  final String value;
  _Req(this.value);
  factory _Req.fromJson(Map<String, dynamic> json) =>
      _Req(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

class _Resp implements IRpcSerializable {
  final String value;
  _Resp(this.value);
  factory _Resp.fromJson(Map<String, dynamic> json) =>
      _Resp(json['value'] as String);
  @override
  Map<String, dynamic> toJson() => {'value': value};
}

/// Answers any call with a FOREIGN peer's trailer: a status and a
/// `grpc-status-details-bin` whose inner message is set, and NO `grpc-message`.
///
/// It has to be hand-built. rpc_dart's own responder derives both from one
/// `RpcStatusException`, so its two messages are always equal and the defect is
/// unobservable with this library on both ends — the loss only shows against a
/// peer that uses `google.rpc.Status` the way the spec intends, which is the
/// entire reason `grpc-status-details-bin` is on the wire.
void _answerWithForeignTrailer(
  IRpcTransport transport, {
  required String innerMessage,
}) {
  transport.incomingMessages.listen((message) {
    if (message.metadata?.methodPath == null) return;
    final bin = RpcStatusException(
      RpcStatus.notFound,
      innerMessage,
      details: [RpcErrorInfo(reason: 'USER_NOT_FOUND', domain: 'myapp.v1')],
    ).statusDetailsBin!;
    transport.sendMetadata(
      message.streamId,
      RpcMetadata.forTrailer(RpcStatus.notFound, statusDetailsBin: bin),
      endStream: true,
    );
  });
}

/// A `google.rpc.Status` carrying a message and one detail, as a peer sends it.
Uint8List _detailsBin({required String message}) => RpcStatusException(
  RpcStatus.notFound,
  message,
  details: [RpcErrorInfo(reason: 'USER_NOT_FOUND', domain: 'myapp.v1')],
).statusDetailsBin!;

void main() {
  group('an absent grpc-message', () {
    test('lets the details message through', () {
      final error = RpcStatusException.fromTrailer(
        RpcStatus.notFound,
        '', // what every caller now passes for an absent header
        detailsBin: _detailsBin(message: 'user 42 not found'),
      );

      expect(error.message, 'user 42 not found');
      expect(error.details, hasLength(1));
      expect(error.statusCode, RpcStatus.notFound);
    });

    test('falls back to the placeholder when there are no details either', () {
      final error = RpcStatusException.fromTrailer(RpcStatus.internal, '');

      expect(
        error.message,
        kAbsentTrailerMessage,
        reason:
            'the placeholder still exists; it just moved to the one place that '
            'can tell "the peer said nothing" from "the peer said this"',
      );
    });

    // This is the defect, stated as the rule it broke. A caller that hands in a
    // placeholder is indistinguishable from a peer that sent one, so the
    // details message is lost for good.
    test('a placeholder passed IN still suppresses the details message', () {
      final error = RpcStatusException.fromTrailer(
        RpcStatus.notFound,
        kAbsentTrailerMessage,
        detailsBin: _detailsBin(message: 'user 42 not found'),
      );

      expect(
        error.message,
        kAbsentTrailerMessage,
        reason:
            'nothing downstream can recover from this, which is why the five '
            'call sites had to stop doing it',
      );
    });
  });

  // CONTROL: a real grpc-message still wins over the details message. The fix
  // must not reverse the precedence, only make the fallback reachable.
  test('CONTROL: a present grpc-message wins over the details message', () {
    final error = RpcStatusException.fromTrailer(
      RpcStatus.notFound,
      'what the trailer said',
      detailsBin: _detailsBin(message: 'what the details said'),
    );

    expect(error.message, 'what the trailer said');
    expect(error.details, hasLength(1), reason: 'details still travel');
  });

  // END TO END, over one of the five shapes that used to lose it. The factory
  // tests above prove the rule; this proves the call site was rewired to obey
  // it, which is the half the placeholder broke.
  test('a server-stream caller receives the details message', () async {
    final pair = RpcInMemoryTransport.pair();
    final caller = RpcCallerEndpoint(transport: pair.$1);
    _answerWithForeignTrailer(pair.$2, innerMessage: 'user 42 not found');
    addTearDown(caller.close);

    Object? caught;
    try {
      await caller
          .serverStream<_Req, _Resp>(
            serviceName: 'DetailOnly',
            methodName: 'Fail',
            request: _Req('x'),
            requestCodec: RpcCodec<_Req>(_Req.fromJson),
            responseCodec: RpcCodec<_Resp>(_Resp.fromJson),
          )
          .toList()
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      caught = e;
    }

    expect(caught, isA<RpcStatusException>());
    final error = caught! as RpcStatusException;
    expect(error.statusCode, RpcStatus.notFound);
    expect(
      error.message,
      'user 42 not found',
      reason:
          'the peer sent its detail in grpc-status-details-bin and no '
          'grpc-message, which is exactly what the placeholder used to erase',
    );
    expect(error.details, isNotEmpty);
  });

  // GUARD: a peer can send anything in that header. An undecodable payload must
  // not lose the status, and must not produce an empty message either.
  test('GUARD: an undecodable details payload keeps code and message', () {
    final error = RpcStatusException.fromTrailer(
      RpcStatus.internal,
      '',
      detailsBin: Uint8List.fromList(const [0xFF, 0xFF, 0xFF]),
    );

    expect(error.statusCode, RpcStatus.internal);
    expect(error.message, kAbsentTrailerMessage);
    expect(error.details, isEmpty);
  });
}
