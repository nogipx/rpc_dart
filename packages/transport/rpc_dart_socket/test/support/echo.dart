// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A four-shape echo contract and the helpers every test in this package uses.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_socket/rpc_dart_socket.dart';
import 'package:test/test.dart';

const callTimeout = Duration(seconds: 5);

final _codec = RpcCodec(RpcString.fromJson);

/// Header asking the unary handler to wait this many milliseconds.
const delayHeader = 'x-delay-ms';

final class EchoResponder extends RpcResponderContract {
  EchoResponder() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'unary',
      handler: (r, {RpcContext? context}) async {
        final ms = int.tryParse(context?.getHeader(delayHeader) ?? '') ?? 0;
        if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'serverStream',
      handler: (r, {RpcContext? context}) =>
          Stream.fromIterable([for (var i = 0; i < 3; i++) '${r.value}$i'.rpc]),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'clientStream',
      handler: (requests, {RpcContext? context}) async =>
          (await requests.map((r) => r.value).join()).rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      handler: (requests, {RpcContext? context}) =>
          requests.map((r) => r.value.toUpperCase().rpc),
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

final class EchoCaller extends RpcCallerContract {
  EchoCaller(RpcCallerEndpoint endpoint) : super('Echo', endpoint);

  Future<String> unary(String value, {int delayMs = 0}) => callUnary(
    methodName: 'unary',
    request: value.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
    context: delayMs > 0
        ? RpcContext.withHeaders({delayHeader: '$delayMs'})
        : null,
  ).then((r) => r.value).timeout(callTimeout);

  Future<List<String>> serverStream(String value) => callServerStream(
    methodName: 'serverStream',
    request: value.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  ).map((r) => r.value).toList().timeout(callTimeout);

  Future<String> clientStream(List<String> values) => callClientStream(
    methodName: 'clientStream',
    requests: Stream.fromIterable(values.map((v) => v.rpc)),
    requestCodec: _codec,
    responseCodec: _codec,
  ).then((r) => r.value).timeout(callTimeout);

  Future<List<String>> bidi(List<String> values) => callBidirectionalStream(
    methodName: 'bidi',
    requests: Stream.fromIterable(values.map((v) => v.rpc)),
    requestCodec: _codec,
    responseCodec: _codec,
  ).map((r) => r.value).toList().timeout(callTimeout);
}

/// A socket path in a fresh directory, removed after the test.
///
/// Short on purpose: the OS caps a Unix socket path at 104 bytes on macOS.
String tempSocketPath() {
  final dir = Directory.systemTemp.createTempSync('rds');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return '${dir.path}/s.sock';
}

/// A started echo server on [address], stopped after the test.
Future<RpcSocketServer> serveEcho(
  RpcSocketAddress address, {
  int? maxConnections,
  void Function(RpcSocketChannel)? onConnectionOpened,
  void Function(RpcSocketChannel)? onConnectionClosed,
}) async {
  final server = RpcSocketServer(
    address: address,
    maxConnections: maxConnections,
    onEndpointCreated: (e) => e.registerServiceContract(EchoResponder()),
    onConnectionOpened: onConnectionOpened,
    onConnectionClosed: onConnectionClosed,
  );
  await server.start();
  addTearDown(server.stop);
  return server;
}

/// A caller over a new connection to [address], closed after the test.
Future<EchoCaller> dialEcho(RpcSocketAddress address) async {
  final endpoint = RpcCallerEndpoint(
    transport: await connectRpcSocket(
      address,
      connectTimeout: const Duration(seconds: 2),
    ),
  );
  addTearDown(endpoint.close);
  return EchoCaller(endpoint);
}

/// The status a failed [body] ends with, or `ok`.
Future<String> statusOf(Future<Object?> Function() body) async {
  try {
    await body();
    return 'ok';
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}';
  } catch (e) {
    return '${e.runtimeType}';
  }
}
