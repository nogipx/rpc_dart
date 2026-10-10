// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-7 -- one failure, one status.
//
// The same failure gives the same status code on every transport:
// deadline -> DEADLINE_EXCEEDED, oversize -> RESOURCE_EXHAUSTED,
// dead peer -> UNAVAILABLE.
//
// Oversize is tested in both directions, and each time only the RECEIVING
// side has the small limit; the sender keeps the default, so its own check
// cannot fire first (L1). The isolate transport applies one policy to both
// sides, so there the sender has the small limit too -- the status must still
// be the same.
//
// The paired "a message at the limit is accepted" is I-2.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/matrix.dart';

const _small = 64 * 1024;
const _smallPolicy = RpcSecurityPolicy(maxMessageLengthBytes: _small);

enum _Failure {
  deadline(RpcStatus.deadlineExceeded),
  oversizeRequest(RpcStatus.resourceExhausted),
  oversizeResponse(RpcStatus.resourceExhausted),
  deadPeer(RpcStatus.unavailable);

  const _Failure(this.status);
  final int status;
}

/// A server frame channel closes the connection on an oversized request, and
/// only a channel with a close code (`IRpcChannelOversizeClose`, websocket)
/// can say why. Over any other byte channel -- the core's own `pair()`
/// included, measured -- the caller sees the connection end and reports
/// UNAVAILABLE, which is also retryable.
const _channelOversize =
    'status 14 "The stream closed before the peer sent a status", expected 8';

const _knownFailing = <String, String>{
  'channel | unary oversizeRequest': _channelOversize,
  'channel | clientStream oversizeRequest': _channelOversize,
  'channel | serverStream oversizeRequest': _channelOversize,
  'channel | bidi oversizeRequest': _channelOversize,
};

void main() {
  for (final failure in _Failure.values) {
    group('I-7 ${failure.name} is status ${failure.status}:', () {
      for (final member in members) {
        for (final shape in CallShape.values) {
          cell(
            member,
            '${shape.name} ${failure.name}',
            knownFailing: _knownFailing,
            () async {
              final rig = await member.serve(
                serverPolicy: failure == _Failure.oversizeRequest
                    ? _smallPolicy
                    : const RpcSecurityPolicy(),
              );
              addTearDown(rig.close);
              final caller = await rig.caller(
                policy: failure == _Failure.oversizeResponse
                    ? _smallPolicy
                    : const RpcSecurityPolicy(),
              );
              final id = nextCallId();

              final request = switch (failure) {
                _Failure.deadline ||
                _Failure.deadPeer => Blob.request(id: id, mode: Mode.hang),
                _Failure.oversizeRequest => Blob.request(
                  id: id,
                  size: _small + 1,
                ),
                _Failure.oversizeResponse => Blob.request(
                  id: id,
                  responseSize: _small + 1,
                ),
              };
              final call = Call.start(
                caller,
                shape,
                request,
                deadline: failure == _Failure.deadline
                    ? const Duration(milliseconds: 300)
                    : const Duration(seconds: 5),
              );
              if (failure == _Failure.deadPeer) {
                await rig.probe.waitFor('enter', id);
                await rig.killPeer();
              }

              final outcome = await endsWithin(
                call,
                const Duration(seconds: 6),
                failure.name,
              );
              expect(
                outcome.status,
                failure.status,
                reason: '${failure.name} on ${member.name}: $outcome',
              );
            },
          );
        }
      }
    });
  }
}
