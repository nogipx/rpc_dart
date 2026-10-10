// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// I-4 -- a peer cannot crash the process.
//
// Nothing a peer sends or omits produces an uncaught async error or ends the
// process.
//
// Every server and client here is started inside the test's zone, so an
// uncaught async error from either fails the cell; an error in the root zone
// would end the test isolate and fail the whole file. The kinds of garbage
// are described in support/hostile.dart. Silent, slow, half-closing and
// mid-message peers are I-1's rows, which run under the same rule.
//
// Each cell ends with the paired valid input (tests item 5): a real call to a
// real server of the same member still succeeds afterwards.
//
// The isolate member has no bytes: messages cross a SendPort whole. Its peer
// is a worker that uses the public transport API to send garbage on streams
// it should not, and a host that does the same to the worker.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/hostile.dart';
import 'support/isolate_worker.dart';
import 'support/matrix.dart';

const _knownFailing = <String, String>{};

const _noBytes =
    'messages cross a SendPort whole and typed: there are no raw bytes to '
    'corrupt or cut';

Future<void> _stillServes(Rig rig) async {
  final caller = await rig.caller();
  final outcome = await Call.start(
    caller,
    CallShape.unary,
    Blob.request(id: nextCallId()),
    deadline: const Duration(seconds: 2),
  ).outcome;
  expect(outcome.ok, isTrue, reason: 'a valid call afterwards: $outcome');
}

void main() {
  group('I-4 a hostile client cannot crash the server:', () {
    for (final member in members) {
      for (final kind in Garbage.values) {
        cell(
          member,
          'server gets ${kind.name}',
          skip: member is IsolateMember && kind != Garbage.framed
              ? _noBytes
              : null,
          knownFailing: _knownFailing,
          () async {
            final rig = await member.serve();
            addTearDown(rig.close);

            if (rig is IsolateRig) {
              await _hostileHost(rig);
              return;
            }
            final recording = kind == Garbage.random || kind == Garbage.framed
                ? null
                : await recordExchange(rig);
            await attackServer(rig, kind, recording);
            await _stillServes(rig);
          },
        );
      }
    }
  });

  group('I-4 a hostile server cannot crash the client:', () {
    for (final member in members) {
      for (final kind in Garbage.values) {
        cell(
          member,
          'client gets ${kind.name}',
          skip: member is IsolateMember && kind != Garbage.framed
              ? _noBytes
              : null,
          knownFailing: _knownFailing,
          () async {
            final rig = await member.serve();
            addTearDown(rig.close);

            final Outcome outcome;
            if (member is IsolateMember) {
              final hostile = await member.serve(
                workerMode: WorkerMode.garbage,
              );
              addTearDown(hostile.close);
              outcome = await endsWithin(
                Call.start(
                  await hostile.caller(),
                  CallShape.unary,
                  Blob.request(id: nextCallId()),
                  deadline: const Duration(seconds: 1),
                ),
                const Duration(seconds: 2),
                'a call to a worker answering garbage',
              );
            } else {
              final recording = kind == Garbage.random || kind == Garbage.framed
                  ? null
                  : await recordExchange(rig);
              outcome = await callAgainstFake(member, kind, recording);
            }
            expect(
              outcome.ok,
              isFalse,
              reason: 'garbage is not a valid answer: $outcome',
            );
            await _stillServes(rig);
          },
        );
      }
    }
  });
}

/// The host sends the worker a request whose payload no codec reads, and
/// payloads on streams it never opened; the worker must keep serving.
Future<void> _hostileHost(IsolateRig rig) async {
  final transport = await rig.connect(const RpcSecurityPolicy());
  final id = transport.createStream();
  await transport.sendMetadata(
    id,
    RpcMetadata.forClientRequest(conformanceService, 'unary'),
  );
  await transport.sendMessage(
    id,
    RpcMessageFrame.encode(garbage(256)),
    endStream: true,
  );
  await transport.sendMessage(
    transport.createStream(),
    garbage(64, seed: 2),
    endStream: true,
  );
  await transport.sendMessage(1001, garbage(64, seed: 3));

  final endpoint = RpcCallerEndpoint(transport: transport);
  addTearDown(endpoint.close);
  final outcome = await Call.start(
    ConformanceCaller(endpoint),
    CallShape.unary,
    Blob.request(id: nextCallId()),
    deadline: const Duration(seconds: 2),
  ).outcome;
  expect(outcome.ok, isTrue, reason: 'the same worker afterwards: $outcome');
}
