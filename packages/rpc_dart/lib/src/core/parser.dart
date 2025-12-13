// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'errors.dart';
import '../logs/_logs.dart';
import 'protocol.dart';

/// Состояние процесса парсинга входящих данных потока gRPC.
///
/// Управляет буферизацией и состоянием парсинга при обработке
/// фрагментированных сообщений gRPC. Сообщения могут приходить
/// по частям или несколько сообщений в одном фрагменте.
final class _MessageParserState {
  /// Текущий накопительный буфер данных
  List<int> buffer = [];

  /// Ожидаемая длина текущего сообщения (null, если заголовок еще не прочитан)
  int? expectedMessageLength;

  /// Флаг сжатия для текущего обрабатываемого сообщения
  bool isCompressed = false;

  /// Сбрасывает состояние для обработки следующего сообщения.
  ///
  /// Вызывается после успешного извлечения полного сообщения
  /// для подготовки к обработке следующего.
  void reset() {
    expectedMessageLength = null;
    isCompressed = false;
  }
}

/// Парсер для обработки фрагментированных сообщений gRPC.
///
/// Отвечает за правильную сборку полных сообщений из фрагментированных
/// потоков данных, поступающих через HTTP/2 DATA фреймы. Решает проблему
/// несовпадения границ HTTP/2 фреймов и сообщений gRPC.
final class RpcMessageParser {
  final RpcLogger? _logger;
  final int _maxMessageLength;
  final int _maxBufferedBytes;
  final Uint8List Function(Uint8List payload)? _decompressor;
  final int _maxMessagesPerChunk;

  RpcMessageParser({
    RpcLogger? logger,
    int maxMessageLength = 64 * 1024 * 1024,
    int? maxBufferedBytes,
    Uint8List Function(Uint8List payload)? decompressor,
    int maxMessagesPerChunk = 1024,
  })  : _logger = logger,
        _maxMessageLength = maxMessageLength,
        _maxBufferedBytes = maxBufferedBytes ??
            (maxMessageLength + RpcConstants.messagePrefixSize),
        _decompressor = decompressor,
        _maxMessagesPerChunk = maxMessagesPerChunk;

  /// Внутреннее состояние парсера
  final _MessageParserState _state = _MessageParserState();

  /// Обрабатывает входящий фрагмент данных и извлекает полные сообщения.
  ///
  /// Накапливает входящие данные в буфере и извлекает из него полные сообщения,
  /// используя информацию о длине из 5-байтного префикса. Может извлечь
  /// несколько сообщений из одного фрагмента или продолжить накопление
  /// для получения полного сообщения.
  ///
  /// [data] Новый фрагмент входящих данных
  /// Возвращает список полных сообщений, извлеченных из данных
  List<Uint8List> call(Uint8List data) {
    try {
      return _call(data);
    } catch (e, trace) {
      _logger?.error(
        'Ошибка при парсинге данных: $e',
        error: e,
        stackTrace: trace,
      );
      rethrow;
    }
  }

  List<Uint8List> _call(Uint8List data) {
    final result = <Uint8List>[];

    // Добавляем данные в буфер
    _state.buffer.addAll(data);
    if (_state.buffer.length > _maxBufferedBytes) {
      final buffered = _state.buffer.length;
      _state.buffer.clear();
      _state.reset();
      throw RpcException(
        'gRPC frame buffer overflow: $buffered bytes (max: $_maxBufferedBytes)',
      );
    }

    // Обрабатываем буфер, пока можем извлекать сообщения
    while (_state.buffer.length >= RpcConstants.messagePrefixSize) {
      // Если мы еще не знаем длину сообщения, извлекаем ее из заголовка
      if (_state.expectedMessageLength == null) {
        try {
          final header = RpcMessageFrame.parseHeader(
            Uint8List.fromList(
              _state.buffer.sublist(0, RpcConstants.messagePrefixSize),
            ),
          );
          _state.isCompressed = header.isCompressed;
          _state.expectedMessageLength = header.messageLength;

          if (_state.expectedMessageLength! > _maxMessageLength) {
            final length = _state.expectedMessageLength!;
            _state.buffer.clear();
            _state.reset();
            throw RpcException(
              'gRPC frame payload is too large: $length bytes (max: $_maxMessageLength)',
            );
          }

          // Удаляем заголовок из буфера
          _state.buffer = _state.buffer.sublist(
            RpcConstants.messagePrefixSize,
          );
        } catch (e, trace) {
          _logger?.error(
            'Ошибка при парсинге заголовка: $e',
            error: e,
            stackTrace: trace,
          );
          _state.buffer.clear();
          _state.reset();
          rethrow;
        }
      }

      // Если у нас достаточно данных для полного сообщения
      if (_state.buffer.length >= _state.expectedMessageLength!) {
        // Извлекаем сообщение
        final messageBytes = _state.buffer.sublist(
          0,
          _state.expectedMessageLength!,
        );
        var payload = Uint8List.fromList(messageBytes);
        if (_state.isCompressed) {
          final decompressor = _decompressor;
          if (decompressor == null) {
            _state.buffer.clear();
            _state.reset();
            throw RpcException(
              'Compressed gRPC frame received but no decompressor configured',
            );
          }
          payload = decompressor(payload);
          if (payload.length > _maxMessageLength) {
            final length = payload.length;
            _state.buffer.clear();
            _state.reset();
            throw RpcException(
              'Decompressed gRPC payload is too large: $length bytes (max: $_maxMessageLength)',
            );
          }
        }
        result.add(payload);
        if (result.length > _maxMessagesPerChunk) {
          _state.buffer.clear();
          _state.reset();
          throw RpcException(
            'Too many gRPC messages in a single chunk: ${result.length} (max: $_maxMessagesPerChunk)',
          );
        }

        // Обновляем буфер, удаляя обработанное сообщение
        _state.buffer = _state.buffer.sublist(_state.expectedMessageLength!);

        // Сбрасываем состояние для следующего сообщения
        _state.reset();
      } else {
        // Недостаточно данных для полного сообщения, нужно ждать
        break;
      }
    }

    _logger?.internal(
      'Обработка завершена, извлечено сообщений: ${result.length}',
    );
    return result;
  }
}
