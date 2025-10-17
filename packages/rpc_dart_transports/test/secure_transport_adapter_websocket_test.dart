// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:licensify/licensify.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Тест SecureTransportAdapter поверх WebSocket транспорта с инициализацией
/// по аналогии с example/transports/websocket_example.dart
class _WsSecureContext {
  _WsSecureContext({
    required this.server,
    required this.connectionsController,
    required this.callerTransport,
    required this.responderTransport,
    required this.caller,
    required this.responder,
    required this.callerKeys,
    required this.responderKeys,
  });

  final HttpServer server;
  final StreamController<WebSocketChannel> connectionsController;
  final RpcWebSocketCallerTransport callerTransport;
  final RpcWebSocketResponderTransport responderTransport;
  final SecureTransportAdapter caller;
  final SecureTransportAdapter responder;
  final LicensifyKeyPair callerKeys;
  final LicensifyKeyPair responderKeys;

  // Расширения для перехваченных кадров
  late List<dynamic> _clientOutboundRaw;

  static Future<_WsSecureContext> create() async {
    // Контроллер подключений (как в примере)
    final connections = StreamController<WebSocketChannel>.broadcast();

    final serverInboundRaw =
        <dynamic>[]; // сырые входящие на сервер (от клиента)
    final serverOutboundRaw =
        <dynamic>[]; // сырые исходящие с сервера (к клиенту)

    // Shelf WebSocket handler: добавляет каждый канал в контроллер
    final wsHandler = webSocketHandler((ch, protocol) {
      // Оборачиваем серверный канал в рекордер
      final recording = RecordingWebSocketChannel(
        ch,
        onSend: (d) => serverOutboundRaw.add(d),
        onReceive: (d) => serverInboundRaw.add(d),
        label: 'server',
      );
      connections.add(recording);
    });

    final handler = const Pipeline().addHandler(wsHandler);

    final server = await shelf_io.serve(handler, '127.0.0.1', 21212);

    final uri = Uri.parse('ws://127.0.0.1:${server.port}');

    // Клиентский транспорт по фабрике (как в примере runClient())
    final clientBaseChannel = WebSocketChannel.connect(uri);
    final clientOutboundRaw = <dynamic>[]; // исходящие от клиента
    final clientInboundRaw = <dynamic>[]; // входящие клиенту
    final callerWrapped = RecordingWebSocketChannel(
      clientBaseChannel,
      onSend: (d) => clientOutboundRaw.add(d),
      onReceive: (d) => clientInboundRaw.add(d),
      label: 'client',
    );
    final callerTransport = RpcWebSocketCallerTransport(callerWrapped);

    // Ждём первое входящее соединение
    final serverChannel = await connections.stream.first
        .timeout(const Duration(seconds: 5), onTimeout: () {
      throw StateError('Не дождались серверного WebSocket соединения');
    });

    final responderTransport = RpcWebSocketResponderTransport(serverChannel);

    // Генерируем ключи
    final callerKeys = await Licensify.generateSigningKeys();
    final responderKeys = await Licensify.generateSigningKeys();

    // Оборачиваем в secure адаптеры
    final caller = SecureTransportAdapter.wrap(
      callerTransport,
      keyStore: SecureTransportKeyStore(
        transportId: 'ws-secure-caller',
        privateKey: callerKeys.privateKey,
        peerPublicKey: responderKeys.publicKey,
      ),
      logger: RpcLogger('ws-secure-caller'),
    );

    final responder = SecureTransportAdapter.wrap(
      responderTransport,
      keyStore: SecureTransportKeyStore(
        transportId: 'ws-secure-responder',
        privateKey: responderKeys.privateKey,
        peerPublicKey: callerKeys.publicKey,
      ),
      logger: RpcLogger('ws-secure-responder'),
    );

    await Future.wait([caller.ready, responder.ready]);

    return _WsSecureContext(
      server: server,
      connectionsController: connections,
      callerTransport: callerTransport,
      responderTransport: responderTransport,
      caller: caller,
      responder: responder,
      callerKeys: callerKeys,
      responderKeys: responderKeys,
    )
      // Сохраняем списки в расширениях через cascade, чтобы тесты могли получить доступ
      .._clientOutboundRaw = clientOutboundRaw;
  }

  Future<void> dispose() async {
    await caller.close();
    await responder.close();
    callerKeys.privateKey.dispose();
    callerKeys.publicKey.dispose();
    responderKeys.privateKey.dispose();
    responderKeys.publicKey.dispose();
    await server.close(force: true);
    await connectionsController.close();
  }
}

/// Обёртка канала для записи исходящих и входящих сырых сообщений
class RecordingWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  RecordingWebSocketChannel(
    this._inner, {
    this.onSend,
    this.onReceive,
    String? label,
  }) : _label = label ?? 'ws';

  final WebSocketChannel _inner;
  final void Function(dynamic data)? onSend;
  final void Function(dynamic data)? onReceive;
  final String _label;

  @override
  Stream get stream => _inner.stream.map((event) {
        onReceive?.call(event);
        if (event is List<int>) {
          String frameInfo;
          String classification = 'unknown';
          String textSnippet = '';
          if (event.length >= 5) {
            final sid = (event[0] << 24) |
                (event[1] << 16) |
                (event[2] << 8) |
                event[3];
            final flags = event[4];
            final isEnd = (flags & 0x01) != 0;
            final isMeta = (flags & 0x02) != 0;
            final payload = event.sublist(5);
            final payloadLen = payload.length;
            // Определяем "текстовость" payload
            bool mostlyPrintable = false;
            if (payloadLen > 0) {
              final printable =
                  payload.where((b) => b >= 0x20 && b < 0x7F).length;
              mostlyPrintable = printable / payloadLen > 0.85;
            }
            if (isMeta) {
              // Пытаемся распарсить JSON
              try {
                final jsonStr = utf8.decode(payload);
                if (jsonStr.contains('"headers"')) {
                  classification = 'metadata-json';
                  textSnippet = jsonStr.length > 120
                      ? '${jsonStr.substring(0, 120)}…'
                      : jsonStr;
                } else {
                  classification =
                      mostlyPrintable ? 'metadata-text' : 'metadata-binary';
                  textSnippet = jsonStr.length > 120
                      ? '${jsonStr.substring(0, 120)}…'
                      : jsonStr;
                }
              } catch (_) {
                classification = 'metadata-binary';
              }
            } else {
              // data frame – может быть шифротокен (чаще всего base64/ASCII) или бинарный gRPC фрейм
              if (mostlyPrintable) {
                // Проверим base64 характер (допускаем = и + /)
                final sampleStr = payload
                    .take(64)
                    .map((c) =>
                        c >= 32 && c < 127 ? String.fromCharCode(c) : '.')
                    .join();
                final base64Regex = RegExp(r'^[A-Za-z0-9+/=\s-]{8,}');
                if (base64Regex.hasMatch(sampleStr.replaceAll('\n', ''))) {
                  classification = 'data-text-token';
                  textSnippet = sampleStr.trim();
                } else {
                  classification = 'data-text';
                  textSnippet = sampleStr.trim();
                }
              } else {
                classification = 'data-binary';
              }
            }
            frameInfo =
                'sid=$sid kind=${isMeta ? 'metadata' : 'data'} cls=$classification end=${isEnd ? 1 : 0} payload=$payloadLen total=${event.length}';
          } else {
            frameInfo = 'too-short total=${event.length}';
          }
          final sampleHex = event
              .take(16)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(' ');
          // ignore: avoid_print
          if (textSnippet.isNotEmpty) {
            print(
                '[RAW:$_label:IN] $frameInfo hex=$sampleHex${event.length > 16 ? '...' : ''} text="${textSnippet.replaceAll('\n', ' ')}"');
          } else {
            print(
                '[RAW:$_label:IN] $frameInfo hex=$sampleHex${event.length > 16 ? '...' : ''}');
          }
        } else {
          final txt = event.toString();
          // ignore: avoid_print
          print(
              '[RAW:$_label:IN] textFrame len=${txt.length} value=${txt.substring(0, txt.length.clamp(0, 80))}');
        }
        return event;
      });

  @override
  WebSocketSink get sink => _RecordingSink(_inner.sink, onSend, _label);

  @override
  int? get closeCode => _inner.closeCode;

  @override
  String? get closeReason => _inner.closeReason;

  @override
  String? get protocol => _inner.protocol;

  @override
  Future<void> get ready => _inner.ready;
}

class _RecordingSink implements WebSocketSink {
  _RecordingSink(this._inner, this._onSend, this._label);
  final WebSocketSink _inner;
  final void Function(dynamic data)? _onSend;
  final String _label;
  @override
  void add(event) {
    _onSend?.call(event);
    if (event is List<int>) {
      String frameInfo;
      String classification = 'unknown';
      String textSnippet = '';
      if (event.length >= 5) {
        final sid =
            (event[0] << 24) | (event[1] << 16) | (event[2] << 8) | event[3];
        final flags = event[4];
        final isEnd = (flags & 0x01) != 0;
        final isMeta = (flags & 0x02) != 0;
        final payload = event.sublist(5);
        final payloadLen = payload.length;
        bool mostlyPrintable = false;
        if (payloadLen > 0) {
          final printable = payload.where((b) => b >= 0x20 && b < 0x7F).length;
          mostlyPrintable = printable / payloadLen > 0.85;
        }
        if (isMeta) {
          try {
            final jsonStr = utf8.decode(payload);
            if (jsonStr.contains('"headers"')) {
              classification = 'metadata-json';
              textSnippet = jsonStr.length > 120
                  ? '${jsonStr.substring(0, 120)}…'
                  : jsonStr;
            } else {
              classification =
                  mostlyPrintable ? 'metadata-text' : 'metadata-binary';
              textSnippet = jsonStr.length > 120
                  ? '${jsonStr.substring(0, 120)}…'
                  : jsonStr;
            }
          } catch (_) {
            classification = 'metadata-binary';
          }
        } else {
          if (mostlyPrintable) {
            final sampleStr = payload
                .take(64)
                .map((c) => c >= 32 && c < 127 ? String.fromCharCode(c) : '.')
                .join();
            final base64Regex = RegExp(r'^[A-Za-z0-9+/=\s-]{8,}');
            if (base64Regex.hasMatch(sampleStr.replaceAll('\n', ''))) {
              classification = 'data-text-token';
              textSnippet = sampleStr.trim();
            } else {
              classification = 'data-text';
              textSnippet = sampleStr.trim();
            }
          } else {
            classification = 'data-binary';
          }
        }
        frameInfo =
            'sid=$sid kind=${isMeta ? 'metadata' : 'data'} cls=$classification end=${isEnd ? 1 : 0} payload=$payloadLen total=${event.length}';
      } else {
        frameInfo = 'too-short total=${event.length}';
      }
      final sampleHex = event
          .take(16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      // ignore: avoid_print
      if (textSnippet.isNotEmpty) {
        print(
            '[RAW:$_label:OUT] $frameInfo hex=$sampleHex${event.length > 16 ? '...' : ''} text="${textSnippet.replaceAll('\n', ' ')}"');
      } else {
        print(
            '[RAW:$_label:OUT] $frameInfo hex=$sampleHex${event.length > 16 ? '...' : ''}');
      }
    } else {
      final txt = event.toString();
      // ignore: avoid_print
      print(
          '[RAW:$_label:OUT] textFrame len=${txt.length} value=${txt.substring(0, txt.length.clamp(0, 80))}');
    }
    _inner.add(event);
  }

  @override
  void addError(error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future addStream(Stream stream) => _inner.addStream(stream);

  @override
  Future close([int? closeCode, String? closeReason]) =>
      _inner.close(closeCode, closeReason);

  @override
  Future get done => _inner.done;
}

// === Utility pretty printers for readable send/receive logs ===
String _hexSample(Uint8List data, {int max = 32}) {
  final take = data.length < max ? data.length : max;
  final hex =
      data.take(take).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  return data.length > max ? '$hex …(+${data.length - max} bytes)' : hex;
}

String _asciiSample(Uint8List data, {int max = 48}) {
  final buf = StringBuffer();
  final take = data.length < max ? data.length : max;
  for (var i = 0; i < take; i++) {
    final b = data[i];
    if (b >= 0x20 && b < 0x7F) {
      buf.writeCharCode(b);
    } else {
      buf.write('.');
    }
  }
  if (data.length > max) buf.write('…');
  return buf.toString();
}

void _printSendMetadata(String who, int streamId, RpcMetadata md) {
  final headers = md.headers.map((h) => '${h.name}=${h.value}').join(', ');
  // ignore: avoid_print
  print(
      '>>> [$who] SEND METADATA sid=$streamId headers=[${headers.isEmpty ? '∅' : headers}]');
}

void _printRecvMetadata(String who, RpcTransportMessage msg) {
  final md = msg.metadata!;
  final headers = md.headers.map((h) => '${h.name}=${h.value}').join(', ');
  // ignore: avoid_print
  print(
      '<<< [$who] RECV METADATA sid=${msg.streamId} headers=[${headers.isEmpty ? '∅' : headers}] end=${msg.isEndOfStream}');
}

void _printSendPayload(String who, int streamId, Uint8List data,
    {bool end = false}) {
  // ignore: avoid_print
  print(
      '>>> [$who] SEND PAYLOAD sid=$streamId bytes=${data.length} hex=[${_hexSample(data)}] ascii="${_asciiSample(data)}" end=$end');
}

void _printRecvPayload(String who, RpcTransportMessage msg) {
  final data = utf8.decode(msg.payload!);
  // ignore: avoid_print
  print(
      '<<< [$who] RECV PAYLOAD data=$data sid=${msg.streamId} end=${msg.isEndOfStream}');
}

void main() {
  group('SecureTransportAdapter/WebSocket (shelf init pattern)', () {
    late _WsSecureContext ctx;

    setUp(() async {
      ctx = await _WsSecureContext.create();
    });

    tearDown(() async {
      await ctx.dispose();
    });

    test('caller -> responder: metadata + payload + encrypted end-of-stream',
        () async {
      // ignore: avoid_print
      print('--- TEST: caller -> responder start');
      final streamId = ctx.caller.createStream();
      // ignore: avoid_print
      print('streamId=$streamId created');
      final metadata = RpcMetadata([
        const RpcHeader(':method', 'POST'),
        const RpcHeader(':path', '/svc.Do/Call'),
        const RpcHeader('x-test', '42'),
      ]);
      // ignore: avoid_print
      print('sending metadata headers=${metadata.headers.length}');
      _printSendMetadata('caller', streamId, metadata);
      final mdFuture = ctx.responder.incomingMessages
          .where((m) => m.streamId == streamId && m.metadata != null)
          .first;
      await ctx.caller.sendMetadata(streamId, metadata);
      final md = await mdFuture;
      _printRecvMetadata('responder', md);

      final payload = Uint8List.fromList(utf8.encode('HELLOWORLD'));
      final dataFuture = ctx.responder.incomingMessages
          .where((m) => m.streamId == streamId && m.payload != null)
          .first;
      _printSendPayload('caller', streamId, payload);
      await ctx.caller.sendMessage(streamId, payload);
      // ignore: avoid_print
      print('payload sent len=${payload.length}');
      final dataMsg = await dataFuture;
      _printRecvPayload('responder', dataMsg);

      final endFuture = ctx.responder.incomingMessages
          .where((m) => m.streamId == streamId && m.isEndOfStream)
          .first;
      await ctx.caller.finishSending(streamId);
      // ignore: avoid_print
      print('finishSending sent');
      final endMsg = await endFuture;
      // ignore: avoid_print
      print('received end-of-stream (caller->responder)');
      expect(endMsg.isEndOfStream, isTrue);
      expect(endMsg.metadata, isNotNull);
      expect(endMsg.metadata!.headers, isEmpty);
    });

    test('responder -> caller: metadata + payload + encrypted end-of-stream',
        () async {
      print('--- TEST: responder -> caller start');
      final streamId = ctx.caller.createStream();
      print('streamId=$streamId created');

      // Создать поток на стороне caller (минимальное metadata)
      await ctx.caller.sendMetadata(streamId, const RpcMetadata([]));

      final mdFuture = ctx.caller.incomingMessages
          .where((m) => m.streamId == streamId && m.metadata != null)
          .first;

      final serverMd = RpcMetadata([
        const RpcHeader(':status', '200'),
        const RpcHeader('grpc-status', '0'),
      ]);
      _printSendMetadata('responder', streamId, serverMd);
      await ctx.responder.sendMetadata(streamId, serverMd);
      final md = await mdFuture;
      _printRecvMetadata('caller', md);

      final dataFuture = ctx.caller.incomingMessages
          .where((m) => m.streamId == streamId && m.payload != null)
          .first;
      final respPayload = Uint8List.fromList(utf8.encode('HELLOWORLD_REPLY'));
      _printSendPayload('responder', streamId, respPayload);
      await ctx.responder.sendMessage(streamId, respPayload);
      print('responder payload sent len=${respPayload.length}');
      final dataMsg = await dataFuture;
      _printRecvPayload('caller', dataMsg);

      final endFuture = ctx.caller.incomingMessages
          .where((m) => m.streamId == streamId && m.isEndOfStream)
          .first;
      await ctx.responder.finishSending(streamId);
      print('responder finishSending sent');
      final endMsg = await endFuture;
      expect(endMsg.isEndOfStream, isTrue);
      expect(endMsg.metadata, isNotNull);
      expect(endMsg.metadata!.headers, isEmpty);
    });

    test(
        'wire confidentiality: raw frames do not leak original headers/payload',
        () async {
      final streamId = ctx.caller.createStream();
      print('streamId=$streamId created');
      final metadata = RpcMetadata([
        const RpcHeader(':method', 'POST'),
        const RpcHeader(':path', '/svc.Secret/Do'),
        const RpcHeader('x-sensitive', 'TOP-SECRET'),
      ]);

      await ctx.caller.sendMetadata(streamId, metadata);
      final payload = Uint8List.fromList(utf8.encode('HELLOWORLD'));
      _printSendPayload('caller', streamId, payload, end: true);
      await ctx.caller.sendMessage(streamId, payload, endStream: true);
      print('sent metadata+payload+endStream');

      // Ждём end-of-stream чтобы всё отправилось
      await ctx.responder.incomingMessages
          .where((m) => m.streamId == streamId && m.isEndOfStream)
          .first
          .timeout(const Duration(seconds: 5));

      // Собираем все бинарные фреймы клиента (исходящие)
      final clientBinary =
          ctx._clientOutboundRaw.whereType<List<int>>().toList(growable: false);
      expect(clientBinary, isNotEmpty,
          reason: 'Нет перехваченных бинарных кадров');

      bool containsPattern(List<int> data, String pattern) {
        final pat = pattern.codeUnits;
        for (var i = 0; i <= data.length - pat.length; i++) {
          var match = true;
          for (var j = 0; j < pat.length; j++) {
            if (data[i + j] != pat[j]) {
              match = false;
              break;
            }
          }
          if (match) return true;
        }
        return false;
      }

      // Проверяем, что исходные значения заголовков и путь не встречаются в сыром виде
      for (final frame in clientBinary) {
        expect(containsPattern(frame, ':method'), isFalse);
        expect(containsPattern(frame, '/svc.Secret/Do'), isFalse);
        expect(containsPattern(frame, 'x-sensitive'), isFalse);
        expect(containsPattern(frame, 'TOP-SECRET'), isFalse);
      }

      // Имя secure-заголовка должно появиться (мы не скрываем сам факт шифрования)
      final hasSecureHeader = clientBinary.any(
        (f) => containsPattern(f, 'x-rpc-secure-metadata'),
      );
      expect(
        hasSecureHeader,
        isTrue,
        reason: 'Не найден x-rpc-secure-metadata в исходящих кадров metadata',
      );

      // Проверяем, что бинарная последовательность payload (строка HELLOWORLD) не встречается как plaintext
      final plain = 'HELLOWORLD';
      final leaksPlain = clientBinary.any((f) => containsPattern(f, plain));
      expect(leaksPlain, isFalse,
          reason: 'Обнаружен plaintext payload (HELLOWORLD) в шифротексте');
    });

    test('encryption produces different tokens for identical metadata+payload',
        () async {
      print('--- TEST: token uniqueness start');
      final streamA = ctx.caller.createStream();
      final streamB = ctx.caller.createStream();
      print('streamA=$streamA streamB=$streamB');

      final metadata = RpcMetadata([
        const RpcHeader(':method', 'POST'),
        const RpcHeader(':path', '/svc.Token/Test'),
      ]);
      final payload = Uint8List.fromList(utf8.encode('HELLOWORLD'));

      // Отправляем одинаковые metadata+payload в два потока
      _printSendMetadata('caller', streamA, metadata);
      await ctx.caller.sendMetadata(streamA, metadata);
      _printSendMetadata('caller', streamB, metadata);
      await ctx.caller.sendMetadata(streamB, metadata);
      _printSendPayload('caller', streamA, payload, end: true);
      await ctx.caller.sendMessage(streamA, payload, endStream: true);
      _printSendPayload('caller', streamB, payload, end: true);
      await ctx.caller.sendMessage(streamB, payload, endStream: true);
      print('sent both streams');

      // Ждём завершения обоих потоков на приёмнике
      await Future.wait([
        ctx.responder.incomingMessages
            .where((m) => m.streamId == streamA && m.isEndOfStream)
            .first,
        ctx.responder.incomingMessages
            .where((m) => m.streamId == streamB && m.isEndOfStream)
            .first,
      ]);

      // Собираем сырые outbound кадры клиента
      final frames = ctx._clientOutboundRaw.whereType<List<int>>().toList();
      // Фильтруем только metadata и data кадры двух потоков (по streamId в первых 4 байтах)
      List<List<int>> framesFor(int sid) => frames
          .where((f) =>
              f.length >= 5 &&
              ((f[0] << 24) | (f[1] << 16) | (f[2] << 8) | f[3]) == sid)
          .toList();

      final aFrames = framesFor(streamA);
      final bFrames = framesFor(streamB);
      expect(aFrames, isNotEmpty);
      expect(bFrames, isNotEmpty);
      print('aFrames=${aFrames.length} bFrames=${bFrames.length}');

      // Сравниваем байтовые последовательности: ни один кадр не должен побайтно совпасть между потоками
      final overlaps = <String>[];
      for (final fa in aFrames) {
        for (final fb in bFrames) {
          if (fa.length == fb.length) {
            var same = true;
            for (var i = 0; i < fa.length; i++) {
              if (fa[i] != fb[i]) {
                same = false;
                break;
              }
            }
            if (same) overlaps.add('match-len=${fa.length}');
          }
        }
      }
      expect(overlaps, isEmpty,
          reason:
              'Обнаружены идентичные шифротекстовые кадры для одинаковых входных данных');
      print('--- TEST: token uniqueness end');
    });
  });
}
