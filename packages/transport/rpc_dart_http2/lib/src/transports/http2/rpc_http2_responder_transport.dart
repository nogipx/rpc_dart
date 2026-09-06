// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

import 'rpc_http2_common.dart';

/// HTTP/2 серверный транспорт для входящих RPC вызовов
///
/// Реализует IRpcTransport поверх HTTP/2 протокола для серверной стороны.
/// Поддерживает мультиплексирование потоков и gRPC-совместимый протокол.
///
/// Реализует [IRpcSecurityPolicyAware]: слои эндпоинта определяют политику
/// через `is`-проверку, поэтому транспорт, который её не объявляет, получает
/// `const RpcSecurityPolicy()` вместо настроенной приложением. Для сервера это
/// значит, что `maxActiveStreams`, `halfOpenStreamTimeout` и лимит размера
/// сообщения брались по умолчанию, а не из конфигурации.
class RpcHttp2ResponderTransport
    implements IRpcTransport, IRpcSecurityPolicyAware, IRpcFlowControlled {
  @override
  bool get isClient => false;

  @override
  RpcSecurityPolicy get securityPolicy => _policy;

  /// HTTP/2 соединение
  final http2.ServerTransportConnection _connection;

  /// Контроллер для входящих сообщений
  final BufferedBroadcastController<RpcTransportMessage> _messageController =
      BufferedBroadcastController<RpcTransportMessage>();

  /// Per-stream dedicated controllers for [getMessagesForStream]. See the
  /// caller transport for the rationale; the broadcast above is still fed so
  /// the responder pipeline can dispatch new incoming streams.
  final Map<int, StreamController<RpcTransportMessage>> _streamControllers = {};

  /// Счетчик для генерации Stream ID (сервер использует четные)
  int _nextStreamId = 2; // Сервер использует четные ID

  /// Активные HTTP/2 streams (входящие от клиента)
  final Map<int, http2.ServerTransportStream> _incomingStreams = {};

  /// Backpressured writers, one per outgoing stream. See [_OutgoingPump].
  final Map<int, _OutgoingPump> _outgoingPumps = {};

  /// Streams whose inbound crediting the responder pipeline has taken over.
  ///
  /// [IRpcFlowControlled] is how the pipeline says "I will report consumption
  /// myself". This transport did not implement it, so `_flowControlled` in
  /// [RpcHttp2Server] resolved to null and the `deferFlowCredit` /
  /// `returnFlowCredit` calls that `_pipelineFedRequestStream` already makes
  /// were silent no-ops: the demand signal existed and never reached HTTP/2.
  ///
  /// The consequence is the request-direction twin of the slow-reader defect.
  /// A client-stream upload into a handler consuming nothing, paced 4 KiB
  /// messages, measured 24.2 MiB after 12s and still climbing ~400 msg/s
  /// (never plateauing), against 4.4 MiB flat over websocket.
  ///
  /// Note the shape that does NOT work here, since it is the obvious one:
  /// putting `onPause`/`onResume` on [getMessagesForStream]'s controller does
  /// nothing for uploads, because client-stream and bidi requests are fed by
  /// `_pipelineFedRequestStream` from the BROADCAST, not from that per-stream
  /// view. The pipeline's explicit credit calls are the only demand signal on
  /// this path.
  final Set<int> _fcDeferred = {};

  /// Bytes handed to the pipeline but not yet reported consumed, per stream.
  final Map<int, int> _fcOutstanding = {};

  /// How much un-consumed request payload one stream may have in flight.
  ///
  /// `flowControlWindowBytes` is the operator's existing knob for exactly this
  /// question. HTTP/2 carries its own windows, so this is not used to emit
  /// rpc-level grants; it is the threshold at which we stop READING, which is
  /// what makes the peer's own window close.
  int get _fcWindow =>
      _policy.flowControlWindowBytes ??
      const RpcSecurityPolicy().flowControlWindowBytes ??
      4 * 1024 * 1024;

  @override
  void deferFlowCredit(int streamId) => _fcDeferred.add(streamId);

  @override
  void returnFlowCredit(int streamId, int bytes) {
    if (bytes <= 0 || !_fcDeferred.contains(streamId)) return;
    final left = (_fcOutstanding[streamId] ?? 0) - bytes;
    _fcOutstanding[streamId] = left < 0 ? 0 : left;
    if (left <= _fcWindow) {
      final sub = _streamSubscriptions[streamId];
      if (sub != null && sub.isPaused) sub.resume();
    }
  }

  /// Charges [bytes] against [streamId]'s budget and stops reading if it is
  /// over. Only meaningful once the pipeline has claimed the stream.
  void _fcOnDelivered(int streamId, int bytes) {
    if (bytes <= 0 || !_fcDeferred.contains(streamId)) return;
    final now = (_fcOutstanding[streamId] ?? 0) + bytes;
    _fcOutstanding[streamId] = now;
    if (now > _fcWindow) {
      final sub = _streamSubscriptions[streamId];
      if (sub != null && !sub.isPaused) sub.pause();
    }
  }

  void _fcForget(int streamId) {
    _fcDeferred.remove(streamId);
    _fcOutstanding.remove(streamId);
  }

  /// Подписки на входящие сообщения streams
  final Map<int, StreamSubscription> _streamSubscriptions = {};

  /// Парсеры для каждого stream (для фрагментированных сообщений)
  final Map<int, RpcMessageParser> _streamParsers = {};

  /// Tracks streams where initial response headers have been sent.
  /// Used to distinguish trailers (no :status) from Trailers-Only (:status + grpc-status).
  final Set<int> _initialHeadersSent = {};

  /// Флаг закрытия
  bool _isClosed = false;

  /// Логгер
  final LogScope? _logger;

  final RpcSecurityPolicy _policy;

  RpcHttp2ResponderTransport({
    required http2.ServerTransportConnection connection,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    LogScope? logger,
  }) : _connection = connection,
       _logger = logger?.child('Http2ServerTransport'),
       _policy = policy {
    _setupConnectionListener();
  }

  // Удален дублирующий метод bind() - используйте RpcHttp2Server из rpc_http2_server.dart

  /// Настраивает обработчик входящих streams от клиентов
  void _setupConnectionListener() {
    _logger?.internal('Настройка обработчика входящих соединений');

    _connection.incomingStreams.listen(
      (http2.ServerTransportStream stream) {
        _handleIncomingStream(stream);
      },
      onError: (error, stackTrace) {
        _logger?.error(
          'Ошибка в соединении HTTP/2',
          error: error,
          stackTrace: stackTrace,
        );

        if (!_messageController.isClosed) {
          _messageController.addError(error, stackTrace);
        }
      },
      onDone: () {
        // `incomingStreams` completing means NO MORE NEW STREAMS -- it does not
        // mean the connection is closed, and treating it as such killed every
        // call still running.
        //
        // package:http2 completes this stream from `onClosing()`, which fires
        // on GOAWAY (its `_finishing`) as well as on a real teardown. GOAWAY is
        // the ordinary graceful-shutdown signal: a peer draining, a proxy
        // recycling a connection, or a load balancer rotating a backend all
        // send it, and the whole point of GOAWAY is that streams already open
        // are allowed to FINISH. Closing here answered "please stop starting
        // new work" with "everything in flight dies now".
        //
        // Measured against this server's own graceful drain, one 3s call in
        // flight when the peer was sent GOAWAY:
        //
        //   before : the in-flight call failed UNAVAILABLE and stop() returned
        //            in 416ms -- the drain it was supposed to perform never
        //            happened
        //   after  : the in-flight call returns its real answer
        //
        // So: stop accepting, and close only once the last open stream is done.
        // A genuinely dead connection still closes promptly, because its
        // streams end too (and `socket.done` closes the endpoint regardless).
        _logger?.internal(
          'HTTP/2: no further incoming streams (GOAWAY or connection close)',
        );
        _acceptingStreams = false;
        _closeIfDrained();
      },
    );
  }

  /// False once the peer will send no further streams (GOAWAY or teardown).
  bool _acceptingStreams = true;

  /// Closes the transport once no stream is left to serve.
  ///
  /// Only meaningful after [_acceptingStreams] goes false: before that, an
  /// empty stream table is just an idle connection.
  void _closeIfDrained() {
    if (_acceptingStreams || _isClosed) return;
    if (_incomingStreams.isNotEmpty) return;
    _logger?.internal('HTTP/2: last stream drained, closing transport');
    close();
  }

  /// Обрабатывает новый входящий stream от клиента
  void _handleIncomingStream(http2.ServerTransportStream stream) {
    final streamId = stream.id;
    _logger?.internal('Получен новый входящий stream: $streamId');

    _incomingStreams[streamId] = stream;
    _logger?.internal(
      'Сохранен stream $streamId (активных: ${_incomingStreams.length})',
    );

    // Настраиваем обработку сообщений от этого stream
    final subscription = stream.incomingMessages.listen(
      (http2.StreamMessage message) {
        _handleIncomingMessage(streamId, message);
      },
      onError: (error, stackTrace) {
        // A peer RST_STREAM is a cancellation, not a transport fault: the
        // client walked away (a cancelled subscription, a deadline). Reporting
        // it as a stream error pushes an RpcHttp2StreamError at every
        // incomingMessages consumer for what is a routine event. Surface it as
        // a clean end-of-stream instead, which is also what lets the responder
        // tear the call down and stop the handler.
        if (error is http2.StreamTransportException) {
          _logger?.internal('Stream $streamId сброшен пиром: ${error.message}');
          _emit(RpcTransportMessage(streamId: streamId, isEndOfStream: true));
          return;
        }

        _logger?.error(
          'Ошибка в stream $streamId',
          error: error,
          stackTrace: stackTrace,
        );

        _emitStreamError(streamId, error, stackTrace);
      },
      onDone: () {
        _logger?.internal('Входящий stream $streamId завершен');

        // Отправляем сообщение о завершении потока
        _emit(RpcTransportMessage(streamId: streamId, isEndOfStream: true));

        // Не удаляем сразу из _incomingStreams, чтобы можно было отправить ответ
        // Очистка произойдет в releaseStreamId или close
        _streamSubscriptions.remove(streamId);
        _streamParsers.remove(streamId);
      },
    );

    _streamSubscriptions[streamId] = subscription;

    // RST_STREAM after the request side has finished has NOWHERE else to land.
    //
    // The onError branch above catches a reset only while `incomingMessages` is
    // still live. For a server-stream or unary call the client half-closes as
    // soon as its request is out, so `onDone` has already run and the
    // subscription is gone by the time the client cancels -- and package:http2
    // reports the reset only through `onTerminated`, which nothing registered.
    // The call therefore ran to completion with no client: measured with a
    // client that cancelled its subscription and left the connection up, the
    // handler was still producing at +6s (404715 messages, openStreams stuck at
    // 1) and nothing was ever going to stop it. The websocket sibling, whose
    // cancellation travels as ordinary metadata the responder already
    // understands, stopped after 1 further message.
    //
    // Synthesising the same `x-client-cancelled` frame reuses that tested
    // teardown path rather than adding a second one.
    stream.onTerminated = (errorCode) {
      _logger?.internal(
        'Stream $streamId reset by peer (errorCode: $errorCode), '
        'cancelling the call',
      );
      _emit(
        RpcTransportMessage.withMetadata(
          streamId: streamId,
          metadata: RpcMetadata([
            RpcHeader(RpcHeaders.xClientCancelled, 'true'),
            RpcHeader(
              RpcHeaders.xCancellationReason,
              'peer sent RST_STREAM (errorCode: $errorCode)',
            ),
          ]),
        ),
      );
    };
  }

  /// Обрабатывает входящее сообщение от клиента
  void _handleIncomingMessage(int streamId, http2.StreamMessage message) {
    // Убираем избыточное логирование - оставляем только в конкретных обработчиках

    try {
      if (message is http2.HeadersStreamMessage) {
        // Обрабатываем входящие headers (метаданные запроса)
        _handleIncomingHeaders(streamId, message);
      } else if (message is http2.DataStreamMessage) {
        // Обрабатываем входящие данные запроса
        _handleIncomingData(streamId, message);
      }
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при обработке сообщения stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      _emitStreamError(streamId, e, stackTrace);
      _answerRejectedStream(streamId, e);
    }
  }

  /// Answers a request this transport refused before the pipeline ever saw it.
  ///
  /// A header frame that fails [RpcSecurityPolicy.validateMetadata] throws out
  /// of [_handleIncomingHeaders] BEFORE [_emit], so the responder pipeline gets
  /// no state for the stream and never replies. The peer was left waiting, and
  /// the HTTP/2 stream stayed in [_incomingStreams] forever.
  ///
  /// Measured with a `:path` carrying no leading slash -- which the policy
  /// rejects, and which only a foreign peer can send, since rpc_dart's own
  /// caller always builds the path itself:
  ///
  ///   20 requests sent, 0 answered
  ///   server transport : incomingStreams: 20
  ///   responder        : openStreams: 20
  ///
  /// The peer chooses the path, so that is an unauthenticated way to pin
  /// `maxActiveStreams` worth of slots with requests that can never complete.
  /// [_emitStreamError] alone does not help: it reports inward, to a pipeline
  /// with nothing to attach the error to.
  ///
  /// Sent as Trailers-Only (the stream has no initial headers yet), and
  /// detached with its own guard, because this runs on the connection's listen
  /// callback where a throw would reach the root zone.
  void _answerRejectedStream(int streamId, Object error) {
    if (_isClosed) return;
    if (!_incomingStreams.containsKey(streamId)) return;

    final status = error is ArgumentError
        ? RpcStatus.invalidArgument
        : RpcStatus.internal;
    final message = error is ArgumentError
        ? (error.message?.toString() ?? 'Invalid request metadata')
        : 'Request rejected: $error';

    unawaited(() async {
      try {
        await sendMetadata(
          streamId,
          RpcMetadata.forTrailer(status, message: message),
          endStream: true,
        );
      } catch (e) {
        _logger?.warning('Не удалось отклонить stream $streamId: $e');
      } finally {
        releaseStreamId(streamId);
      }
    }());
  }

  /// Обрабатывает входящие HTTP/2 headers от клиента
  void _handleIncomingHeaders(
    int streamId,
    http2.HeadersStreamMessage message,
  ) {
    // gRPC is POST-only. Nothing checked, so EVERY method executed the
    // handler -- measured 7 of 7, GET, HEAD, PUT, DELETE, OPTIONS and even
    // BREW all returning grpc-status=0 with the handler run.
    //
    // GET is the one that matters. A browser can be made to issue a
    // cross-origin GET without a preflight, while a POST carrying
    // `content-type: application/grpc` cannot leave the origin unprompted --
    // so accepting GET turned every unary method into something an attacker's
    // page could trigger. HEAD and the rest are the same hole, less reachable.
    //
    // rpc_dart's own caller hard-codes POST in
    // rpcMetadataToHttp2RequestHeaders, which is exactly why no existing test
    // could reach this: only a foreign peer chooses the method.
    //
    // Absent is left alone rather than rejected, matching the content-type
    // check next door: a request with no `:method` is malformed HTTP/2 and
    // package:http2 refuses it before this point.
    final requestMethod = extractRequestMethod(message.headers);
    if (requestMethod != null && requestMethod.toUpperCase() != 'POST') {
      throw ArgumentError.value(
        requestMethod,
        ':method',
        'gRPC requires POST; this request used a different HTTP method',
      );
    }

    // Извлекаем путь метода из pseudo-headers
    final methodPath = extractMethodPath(message.headers);

    // Конвертируем HTTP/2 headers в RPC метаданные (pseudo-headers отфильтрованы)
    final metadata = http2HeadersToRpcMetadata(
      message.headers,
      methodPath: methodPath,
    );
    _policy.validateMetadata(metadata);

    // Создаем транспортное сообщение
    final transportMessage = RpcTransportMessage(
      streamId: streamId,
      metadata: metadata,
      isEndOfStream: message.endStream,
      methodPath: methodPath,
    );

    _emit(transportMessage);

    _logger?.internal('Headers получены для stream $streamId: $methodPath');
  }

  /// Обрабатывает входящие HTTP/2 данные от клиента
  void _handleIncomingData(int streamId, http2.DataStreamMessage message) {
    try {
      // Получаем или создаем парсер для этого stream
      if (_streamParsers.length >= _policy.maxActiveStreams &&
          !_streamParsers.containsKey(streamId)) {
        throw RpcException(
          'Too many active streams: ${_streamParsers.length} (max: ${_policy.maxActiveStreams})',
        );
      }
      final parser = _streamParsers.putIfAbsent(
        streamId,
        () => RpcMessageParser(
          logger: _logger?.child('Parser-$streamId'),
          maxMessageLength: _policy.maxMessageLengthBytes,
          maxBufferedBytes: _policy.maxBufferedBytes,
          maxMessagesPerChunk: _policy.maxMessagesPerChunk,
        ),
      );

      // Распаковываем gRPC frame(s) используя RpcMessageParser
      final bytes = message.bytes is Uint8List
          ? message.bytes as Uint8List
          : Uint8List.fromList(message.bytes);
      final messages = parser(bytes);

      // Отправляем каждое сообщение отдельно.
      // END_STREAM применяется только к действительно последнему сообщению
      // батча — сравнение по индексу, а не по значению (Uint8List сравнивается
      // по идентичности, что ломается при повторе одной и той же ссылки).
      for (var i = 0; i < messages.length; i++) {
        final framedMessage = ensureGrpcFrame(messages[i]);
        final transportMessage = RpcTransportMessage(
          streamId: streamId,
          payload: framedMessage,
          isEndOfStream: message.endStream && i == messages.length - 1,
        );

        _emit(transportMessage);
      }

      _logger?.internal(
        'Обработано ${messages.length} входящих сообщений для stream $streamId',
      );
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при распаковке входящих gRPC данных для stream $streamId',
        error: e,
        stackTrace: stackTrace,
      );

      _emitStreamError(streamId, e, stackTrace);
      _answerFramingViolation(streamId, e);
    }
  }

  /// Answers a peer whose frame this transport refused to decode.
  ///
  /// [_emitStreamError] tells OUR side, and nothing else did: the offending
  /// frame is dropped, so the stream reaches the responder pipeline carrying no
  /// payload, and the peer eventually gets whatever the pipeline makes of an
  /// empty request. Measured against grpcurl with
  /// `maxMessageLengthBytes: 4096`, a 20KB request came back as:
  ///
  ///   Code: InvalidArgument
  ///   Message: Request stream closed without payload for
  ///            shapes.v1.ShapeService.Unary
  ///
  /// Both halves are wrong. gRPC answers an over-limit message with
  /// RESOURCE_EXHAUSTED (grpc-go and grpc-java both do), and INVALID_ARGUMENT
  /// tells the caller its *arguments* were malformed rather than too large --
  /// which also inverts retry semantics, since rpc_dart's own
  /// RpcRetryInterceptor treats RESOURCE_EXHAUSTED as transient and
  /// INVALID_ARGUMENT as final. The message pointed at a symptom (no payload
  /// arrived) instead of the cause.
  ///
  /// Best-effort: if the stream is already gone, or headers cannot be sent,
  /// there is nothing further to do and the local error above still stands.
  void _answerFramingViolation(int streamId, Object error) {
    // Every RpcException RpcMessageParser raises is a RESOURCE LIMIT, and all
    // four read as RESOURCE_EXHAUSTED to a gRPC peer:
    //   'gRPC frame buffer overflow: N (max: M)'
    //   'gRPC frame payload is too large: N (max: M)'
    //   'Decompressed gRPC payload is too large: N (max: M)'
    //   'Too many gRPC messages in a single chunk: N (max: M)'
    // Anything else reaching here is malformed framing, which is INTERNAL.
    //
    // Matching on the type rather than on message text: the first attempt at
    // this looked for 'too large' and missed the buffer-overflow wording, so a
    // 20KB request against a 4KB limit still came back as Internal.
    final status = error is RpcException
        ? RpcStatus.resourceExhausted
        : RpcStatus.internal;

    try {
      final trailers = RpcMetadata.forTrailer(status, message: '$error');
      unawaited(
        sendMetadata(streamId, trailers, endStream: true).catchError((_) {}),
      );
    } catch (_) {
      // The stream may already be closed; the emitted error covers our side.
    }
  }

  @override
  int createStream() {
    if (_isClosed) throw StateError('Transport is closed');

    final streamId = _nextStreamId;
    _nextStreamId += 2; // Сервер использует четные ID (2, 4, 6, ...)

    // NOTE: server-push / server-initiated streams are NOT supported on the
    // HTTP/2 responder. A minted even id is not a real http2 stream, so any
    // subsequent send on it would silently lose data. We hand back the id for
    // API compatibility, but sends will fail fast via [_requireIncomingStream].
    _logger?.internal('Создан исходящий stream: $streamId');
    return streamId;
  }

  /// Returns the backpressured outgoing pump for [streamId], creating it on
  /// first use. Every outgoing frame for a stream MUST go through the same
  /// pump: mixing `sendHeaders`/`sendData` with the pump would reorder headers
  /// against data, which is a protocol error.
  _OutgoingPump _pumpFor(int streamId, http2.TransportStream stream) =>
      _outgoingPumps[streamId] ??= _OutgoingPump(stream);

  /// Resolves the http2 stream that a server-side send must target.
  ///
  /// Responder sends always reply on the client-initiated stream id (which is
  /// in [_incomingStreams]). An unknown id means either a server-initiated
  /// stream from [createStream] (unsupported) or a stale/released id — both are
  /// programming errors that must fail loudly instead of dropping data.
  http2.ServerTransportStream _requireIncomingStream(int streamId, String op) {
    final incomingStream = _incomingStreams[streamId];
    if (incomingStream == null) {
      throw StateError(
        'Cannot $op on stream $streamId: not a known incoming stream. '
        'Server-initiated streams are not supported on the HTTP/2 responder '
        '(server-push is unimplemented); responses must use the '
        'client-initiated stream id.',
      );
    }
    return incomingStream;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_isClosed) return false;

    _logger?.internal('Освобождение stream: $streamId');

    // Закрываем входящий stream мягко если он активен
    final incomingStream = _incomingStreams.remove(streamId);
    final pump = _outgoingPumps.remove(streamId);
    if (incomingStream != null) {
      try {
        // Through the pump when there is one: its addStream owns the sink, so
        // a direct sendData here would throw "cannot add while adding a
        // stream" and the release would fall through to terminate().
        if (pump != null) {
          pump.endStreamNow();
        } else {
          incomingStream.sendData(Uint8List(0), endStream: true);
        }
        _logger?.internal(
          'Отправлен END_STREAM при освобождении входящего stream $streamId',
        );
      } catch (e) {
        _logger?.internal(
          'Используем terminate для входящего stream $streamId: $e',
        );
        pump?.dispose();
        incomingStream.terminate();
      }
    } else {
      pump?.dispose();
    }

    // Отменяем подписку на сообщения
    final subscription = _streamSubscriptions.remove(streamId);
    subscription?.cancel();

    // Удаляем парсер и tracking для этого stream
    _streamParsers.remove(streamId);
    _initialHeadersSent.remove(streamId);
    _fcForget(streamId);

    // If the peer has already said it will send nothing further, this may have
    // been the last call we owed it.
    _closeIfDrained();

    return true;
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw StateError('Transport is closed');

    _logger?.internal('Отправка ответных метаданных для stream $streamId');

    // Для серверных ответов ищем входящий stream. Неизвестный id (server-push)
    // должен падать громко, а не молча терять метаданные.
    final incomingStream = _requireIncomingStream(streamId, 'send metadata');

    try {
      final List<http2.Header> headers;

      if (!endStream) {
        // Initial response headers — includes :status: 200
        headers = rpcMetadataToHttp2ResponseHeaders(metadata);
        _initialHeadersSent.add(streamId);
      } else if (!_initialHeadersSent.contains(streamId)) {
        // Trailers-Only — first and last HEADERS frame.
        // Must include :status: 200 and content-type per gRPC spec.
        headers = rpcMetadataToHttp2TrailersOnly(metadata);
        _initialHeadersSent.add(streamId);
      } else {
        // Trailers after initial headers + data.
        // MUST NOT include :status per HTTP/2 spec (RFC 7540 Section 8.1.2.1).
        headers = rpcMetadataToHttp2Trailers(metadata);
      }

      await _pumpFor(
        streamId,
        incomingStream,
      ).add(http2.HeadersStreamMessage(headers, endStream: endStream));

      _logger?.internal(
        'Метаданные отправлены для stream $streamId '
        '(${endStream ? (_initialHeadersSent.contains(streamId) ? "trailers" : "trailers-only") : "initial headers"})',
      );
    } catch (e) {
      _logger?.error('Ошибка при отправке метаданных для stream $streamId: $e');
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_isClosed) throw StateError('Transport is closed');

    final incomingStream = _requireIncomingStream(streamId, 'send message');

    _logger?.internal(
      'Отправка ответных данных для stream $streamId: ${data.length} байт',
    );

    try {
      assert(
        isGrpcFrame(data),
        'IRpcTransport.sendMessage ожидает gRPC frame с 5-байтовым префиксом',
      );

      // Отправляем данные через HTTP/2 как уже сформированный gRPC frame.
      // Through the pump, so a peer that stops reading stops the handler --
      // `sendData` would enqueue regardless. See [_OutgoingPump].
      await _pumpFor(
        streamId,
        incomingStream,
      ).add(http2.DataStreamMessage(data, endStream: endStream));

      _logger?.internal('Ответные данные отправлены для stream $streamId');
    } catch (e) {
      _logger?.error('Ошибка при отправке данных для stream $streamId: $e');
      rethrow;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_isClosed) return;

    final incomingStream = _incomingStreams[streamId];
    if (incomingStream == null) {
      _logger?.internal(
        'Incoming stream $streamId not found, skipping finish sending',
      );
      return;
    }

    _logger?.internal('Завершение отправки ответа для stream $streamId');

    try {
      // Отправляем END_STREAM с пустыми данными
      await _pumpFor(
        streamId,
        incomingStream,
      ).add(http2.DataStreamMessage(Uint8List(0), endStream: true));

      _logger?.internal('Отправка ответа завершена для stream $streamId');
    } catch (e) {
      _logger?.warning(
        'Ошибка при завершении отправки для stream $streamId: $e',
      );
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages => _messageController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    final existing = _streamControllers[streamId];
    if (existing != null) return existing.stream;
    final ctl = StreamController<RpcTransportMessage>(
      onCancel: () => _streamControllers.remove(streamId),
      // The OTHER half of the request-direction demand chain. Client-stream
      // requests are fed by `_pipelineFedRequestStream`, which reports demand
      // through IRpcFlowControlled above; bidirectional and server-stream ones
      // are fed by `_stateBoundStream`, which subscribes HERE and never calls
      // deferFlowCredit. Without this hop the bidi upload direction stayed
      // unbounded (13.7 MiB on the wire at 12s and climbing) while
      // client-stream was already bounded at 4.4 MiB.
      onPause: () => _streamSubscriptions[streamId]?.pause(),
      onResume: () => _streamSubscriptions[streamId]?.resume(),
    );
    _streamControllers[streamId] = ctl;
    return ctl.stream;
  }

  /// Routes an incoming message to the broadcast and to the stream's dedicated
  /// controller, closing the latter on end-of-stream.
  void _emit(RpcTransportMessage message) {
    // Charge before delivering: the pipeline may consume synchronously and
    // report the credit back, and crediting a charge that has not happened yet
    // would leave the counter permanently negative-then-clamped at zero.
    _fcOnDelivered(message.streamId, message.payload?.length ?? 0);
    if (!_messageController.isClosed) _messageController.add(message);
    final ctl = _streamControllers[message.streamId];
    if (ctl != null && !ctl.isClosed) ctl.add(message);
    if (message.isEndOfStream) {
      final ended = _streamControllers.remove(message.streamId);
      if (ended != null && !ended.isClosed) unawaited(ended.close());
    }
  }

  /// Routes a stream-scoped error: raw on the dedicated controller, enveloped
  /// on the broadcast.
  void _emitStreamError(int streamId, Object error, [StackTrace? stackTrace]) {
    final ctl = _streamControllers[streamId];
    if (ctl != null && !ctl.isClosed) ctl.addError(error, stackTrace);
    if (!_messageController.isClosed) {
      _messageController.addError(
        RpcHttp2StreamError(streamId, error, stackTrace),
      );
    }
  }

  Map<String, Object?> _buildHealthDetails() => {
    'isClosed': _isClosed,
    'incomingStreams': _incomingStreams.length,
    'streamSubscriptions': _streamSubscriptions.length,
    'streamParsers': _streamParsers.length,
    'messageControllerClosed': _messageController.isClosed,
  };

  @override
  Future<RpcHealthStatus> health() async {
    final details = _buildHealthDetails();

    if (_messageController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'HTTP/2 responder transport closed',
        details: details,
      );
    }

    if (_isClosed) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'HTTP/2 responder connection is closed',
        details: details,
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'HTTP/2 responder ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Server-side HTTP/2 transport does not support manual reconnect',
      details: {..._buildHealthDetails(), 'supported': false},
    );
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;

    _logger?.info('Закрытие HTTP/2 серверного транспорта');
    _isClosed = true;

    // Даем время на завершение активных потоков
    final totalStreams = _incomingStreams.length;
    if (totalStreams > 0) {
      _logger?.internal('Ожидание завершения $totalStreams активных потоков');
      await Future.delayed(Duration(milliseconds: 50));
    }

    // Закрываем все входящие streams осторожно
    for (final stream in _incomingStreams.values) {
      try {
        // Пытаемся закрыть stream мягко. Via the pump where one exists: it
        // owns the sink, and it also releases any handler parked on the
        // peer's window so teardown does not wait on a dead reader.
        final pump = _outgoingPumps[stream.id];
        if (pump != null) {
          pump.endStreamNow();
        } else {
          stream.sendData(Uint8List(0), endStream: true);
        }
        _logger?.internal(
          'Отправлен END_STREAM для входящего stream ${stream.id}',
        );
      } catch (e) {
        _logger?.internal(
          'Используем terminate для входящего stream ${stream.id}: $e',
        );
        // В крайнем случае используем terminate
        try {
          stream.terminate();
        } catch (e2) {
          _logger?.warning(
            'Ошибка при terminate входящего stream ${stream.id}: $e2',
          );
        }
      }
    }
    _incomingStreams.clear();

    // Release anything still parked on a peer window, after the soft close
    // above has had its chance to flush.
    for (final pump in _outgoingPumps.values) {
      pump.dispose();
    }
    _outgoingPumps.clear();

    // Отменяем все подписки
    for (final subscription in _streamSubscriptions.values) {
      await subscription.cancel();
    }
    _streamSubscriptions.clear();

    // Очищаем парсеры и tracking
    _streamParsers.clear();
    _initialHeadersSent.clear();
    _fcDeferred.clear();
    _fcOutstanding.clear();

    // Закрываем per-stream контроллеры
    for (final ctl in _streamControllers.values) {
      if (!ctl.isClosed) unawaited(ctl.close());
    }
    _streamControllers.clear();

    // Закрываем HTTP/2 соединение
    await _connection.finish();

    // Закрываем контроллер сообщений
    if (!_messageController.isClosed) {
      await _messageController.close();
    }

    _logger?.info('HTTP/2 серверный транспорт закрыт');
  }

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnimplementedError('Unsupport direct object sending');
  }

  @override
  bool get supportsZeroCopy => false;
}

/// Writes to an HTTP/2 stream's outgoing sink WITH backpressure.
///
/// `TransportStream.sendHeaders`/`sendData` are one-liners over
/// `outgoingMessages.add(...)`, and a `StreamSink.add` never blocks.
/// package:http2 does apply flow control -- `_handleNewOutgoingMessage` pauses
/// the stream's outgoing subscription as soon as its queue `wouldBuffer` -- but
/// an `add` into the controller BEHIND that subscription simply enqueues, so
/// the pause never reaches the producer. The result is that a peer which stops
/// reading does not slow the handler down at all.
///
/// Measured against a server-stream handler, client pausing after 5 items:
///
///   websocket : +1023 items (4.0 MiB), flat for 4s  <- the rpc-level window
///   http2     : +33906 items (132.4 MiB) in 4s, still climbing linearly
///
/// http2 was the odd one out, and not because it lacks flow control: it has
/// native windows and therefore sets the rpc-level one to null, so bypassing
/// the native one left it with nothing. (The rpc-level window is not an option
/// here -- it rides on `x-window-update` metadata frames, which a real gRPC
/// client would read as trailers.)
///
/// Feeding the sink through `addStream` is what reconnects it: a
/// StreamController pauses an active `addStream` source whenever its own
/// consumer is paused, so [add] can wait on that and the handler's `yield`
/// blocks until the peer opens its window.
/// The backpressured writer now lives in `rpc_http2_common.dart` as
/// [RpcHttp2OutgoingPump], because the caller transport needs the same thing
/// for the request direction.
typedef _OutgoingPump = RpcHttp2OutgoingPump;
