// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A binding is keyed `'$service.$method'` and split again on the LAST dot. That
// is only injective if exactly one of the two halves may contain a dot, and
// `rpcMethodPathFromKey`'s doc has always said which: "a service name may contain
// them, a method name may not". One pattern was used for both halves, so it
// wasn't enforced, and two different paths produced one key.
//
// Nothing unusual has to be registered — an ordinary package-qualified service
// with ordinary method names is enough, and only the REQUEST is crafted. So the
// registration below is held fixed and the PATH is what varies.
//
// The responder half is checked separately with a hand-built frame, because the
// caller transport validates outbound metadata against the same policy — an
// ordinary call is refused locally and proves nothing about a peer that is not
// this library.
//
// The measurements are in `.claude/loop/rounds/504`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _PackageQualified extends RpcResponderContract {
  _PackageQualified() : super('a.b');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'c',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'reached a.b/c'.rpc,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'secret',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'reached a.b/secret'.rpc,
    );
  }
}

void main() {
  group('WITNESS: two paths may not reach one method', () {
    late RpcCallerEndpoint caller;
    late RpcResponderEndpoint responder;

    setUp(() {
      final (client, server) = RpcChannelTransport.pair();
      responder = RpcResponderEndpoint(transport: server)
        ..registerServiceContract(_PackageQualified())
        ..start();
      caller = RpcCallerEndpoint(transport: client);
    });

    tearDown(() async {
      await caller.close();
      await responder.close();
    });

    Future<String> call(String service, String method) async {
      try {
        final r = await caller.unaryRequest<RpcString, RpcString>(
          serviceName: service,
          methodName: method,
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.empty().withTimeout(const Duration(seconds: 5)),
        );
        return r.value;
      } on RpcStatusException catch (e) {
        return 'status ${e.statusCode}';
      }
    }

    test('/a/b.c does not reach a.b/c', () async {
      expect(
        await call('a', 'b.c'),
        'status ${RpcStatus.invalidArgument}',
        reason:
            'the caller named service "a"; reaching service "a.b" means the '
            'key is not injective',
      );
    });

    test('/a/b.secret does not reach a.b/secret', () async {
      expect(
        await call('a', 'b.secret'),
        'status ${RpcStatus.invalidArgument}',
      );
    });

    test('GUARD: the honest path still works', () async {
      expect(
        await call('a.b', 'c'),
        'reached a.b/c',
        reason:
            'a dotted SERVICE name is the ordinary protobuf spelling and '
            'must keep working',
      );
      expect(await call('a.b', 'secret'), 'reached a.b/secret');
    });

    test('GUARD: an absent method is still UNIMPLEMENTED, not malformed', () {
      // If everything came back INVALID_ARGUMENT the witnesses above would be
      // satisfied by a responder that refuses everything.
      expect(call('a', 'c'), completion('status ${RpcStatus.unimplemented}'));
    });
  });

  group('the grammar itself', () {
    test('WITNESS: a dotted method name is refused', () {
      expect(parseRpcMethodPath('/a/b.c'), isNull);
      expect(parseRpcMethodPath('/myapp.v1.Svc/Get.Inner'), isNull);
    });

    test('GUARD: a dotted service name is still accepted', () {
      expect(parseRpcMethodPath('/a.b/c'), ('a.b', 'c'));
      expect(parseRpcMethodPath('/myapp.v1.UserService/Get'), (
        'myapp.v1.UserService',
        'Get',
      ));
    });

    test('GUARD: the key round-trips through the formatter', () {
      // This is the invariant the whole fix exists to restore: parse then format
      // must be the identity, which it cannot be if both halves admit dots.
      for (final path in [
        '/a.b/c',
        '/myapp.v1.UserService/Get',
        '/Svc/method_name-2',
      ]) {
        final parsed = parseRpcMethodPath(path)!;
        expect(rpcMethodPathFromKey('${parsed.$1}.${parsed.$2}'), path);
      }
    });
  });

  test(
    'WITNESS: the RESPONDER refuses a hand-built frame, not just the caller',
    () async {
      // RpcChannelTransport.sendMetadata validates outbound metadata against the
      // same policy, so an ordinary call never leaves the caller — which says
      // nothing about a peer that is not this library. Build the frame with the
      // unvalidated RpcMetadata constructor and write it straight into the channel.
      Future<String> rawSend(String methodPath) async {
        final (clientCh, serverCh) = RpcDirectMultiplexedChannel.pair();
        final responder =
            RpcResponderEndpoint(
                transport: RpcChannelTransport(
                  channel: serverCh,
                  isClient: false,
                  policy: const RpcSecurityPolicy(),
                ),
              )
              ..registerServiceContract(_PackageQualified())
              ..start();

        final answers = <String>[];
        final sub = clientCh.incoming.listen((m) {
          final status = m.metadata?.headers
              .where((h) => h.name == RpcHeaders.grpcStatus)
              .map((h) => h.value)
              .join();
          if (status != null && status.isNotEmpty) answers.add(status);
        });

        await clientCh.send(
          RpcTransportMessage.withMetadata(
            metadata: RpcMetadata([
              const RpcHeader(
                RpcHeaders.contentType,
                RpcHeaders.contentTypeGrpc,
              ),
            ], methodPath: methodPath),
            streamId: 1,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));

        await sub.cancel();
        await responder.close();
        return answers.isEmpty ? 'accepted' : answers.join(',');
      }

      // CONTROL first: a unary call needs a payload this frame does not send, so an
      // ACCEPTED path answers nothing and waits. Without a path known to be
      // accepted, "nothing came back" is indistinguishable from "ignored".
      expect(
        await rawSend('/a.b/secret'),
        'accepted',
        reason: 'the honest path must still be accepted by the responder',
      );
      expect(
        await rawSend('/a/b.secret'),
        '${RpcStatus.invalidArgument}',
        reason:
            'before the fix this read "accepted" too — the responder could not '
            'tell the two paths apart',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
