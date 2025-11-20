import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_data/src/daemon_process_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _TestLogger implements RpcLogger {
  final List<String> entries = [];

  @override
  String get name => 'daemon-test';

  RpcLogger _record(RpcLoggerLevel level, String message) {
    entries.add('$level:$message');
    return this;
  }

  @override
  Future<void> log({
    required RpcLoggerLevel level,
    required String message,
    String? context,
    String? requestId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
    AnsiColor? color,
    RpcContext? rpcContext,
  }) async {
    entries.add('$level:$message');
  }

  @override
  RpcLogger child(String childName, {String? label}) => this;

  @override
  Future<void> internal(String message,
          {String? context,
          String? requestId,
          String? traceId,
          Map<String, dynamic>? data,
          AnsiColor? color,
          RpcContext? rpcContext}) async =>
      log(level: RpcLoggerLevel.internal, message: message);

  @override
  Future<void> debug(String message,
          {String? context,
          String? requestId,
          String? traceId,
          Map<String, dynamic>? data,
          AnsiColor? color,
          RpcContext? rpcContext}) async =>
      log(level: RpcLoggerLevel.debug, message: message);

  @override
  Future<void> info(String message,
          {String? context,
          String? requestId,
          String? traceId,
          Map<String, dynamic>? data,
          AnsiColor? color,
          RpcContext? rpcContext}) async =>
      log(level: RpcLoggerLevel.info, message: message);

  @override
  Future<void> warning(String message,
          {String? context,
          String? requestId,
          String? traceId,
          Map<String, dynamic>? data,
          AnsiColor? color,
          RpcContext? rpcContext}) async =>
      log(level: RpcLoggerLevel.warning, message: message);

  @override
  Future<void> error(String message,
          {String? context,
          String? requestId,
          String? traceId,
          Object? error,
          StackTrace? stackTrace,
          Map<String, dynamic>? data,
          AnsiColor? color,
          RpcContext? rpcContext}) async =>
      log(level: RpcLoggerLevel.error, message: message);

  @override
  Future<void> critical(String message,
          {String? context,
          String? requestId,
          String? traceId,
          Object? error,
          StackTrace? stackTrace,
          Map<String, dynamic>? data,
          AnsiColor? color,
          RpcContext? rpcContext}) async =>
      log(level: RpcLoggerLevel.critical, message: message);
}

void main() {
  group('DaemonProcessManager resource management', () {
    late Directory tempDir;
    late _TestLogger logger;
    late DaemonProcessManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rpc-daemon-test');
      logger = _TestLogger();
      final pidFile = p.join(tempDir.path, 'daemon.pid');
      manager = DaemonProcessManager(
        logger: logger,
        pidFilePath: pidFile,
      );
    });

    tearDown(() async {
      await manager.releasePidFile();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('maybeLaunchDaemon returns null when daemonization not requested',
        () async {
      final process = await manager.maybeLaunchDaemon(
        daemonizeRequested: false,
        isDaemonChild: false,
        cliArguments: const [],
      );
      expect(process, isNull);
    });

    test('createPidFile writes PID and releasePidFile removes it', () async {
      await manager.createPidFile();
      final content = await File(manager.pidFilePath).readAsString();
      expect(content.trim(), equals('$pid'));

      await manager.releasePidFile();
      expect(await File(manager.pidFilePath).exists(), isFalse);
      expect(logger.entries.any((entry) => entry.contains('PID файл создан')),
          isTrue);
    });
  });
}
