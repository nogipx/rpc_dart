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
//
// Each direction is tried just past the limit and far past it. Far past it,
// the sender is still writing when the receiver refuses and closes; a close
// that leaves those bytes unread resets the connection, and the reset can
// discard the RESOURCE_EXHAUSTED answer already on its way.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/matrix.dart';

const _small = 64 * 1024;
const _smallPolicy = RpcSecurityPolicy(maxMessageLengthBytes: _small);

/// Far past [_small]: big enough that the sender is still writing when the
/// receiver closes.
const _far = 8 * 1024 * 1024;

enum _Failure {
  deadline(RpcStatus.deadlineExceeded),
  oversizeRequest(RpcStatus.resourceExhausted),
  oversizeRequestFar(RpcStatus.resourceExhausted),
  oversizeResponse(RpcStatus.resourceExhausted),
  oversizeResponseFar(RpcStatus.resourceExhausted),
  deadPeer(RpcStatus.unavailable);

  const _Failure(this.status);
  final int status;

  bool get smallServer => this == oversizeRequest || this == oversizeRequestFar;
  bool get smallCaller =>
      this == oversizeResponse || this == oversizeResponseFar;
}

const _knownFailing = <String, String>{};

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
                serverPolicy: failure.smallServer
                    ? _smallPolicy
                    : const RpcSecurityPolicy(),
              );
              addTearDown(rig.close);
              final caller = await rig.caller(
                policy: failure.smallCaller
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
                _Failure.oversizeRequestFar => Blob.request(id: id, size: _far),
                _Failure.oversizeResponse => Blob.request(
                  id: id,
                  responseSize: _small + 1,
                ),
                _Failure.oversizeResponseFar => Blob.request(
                  id: id,
                  responseSize: _far,
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
