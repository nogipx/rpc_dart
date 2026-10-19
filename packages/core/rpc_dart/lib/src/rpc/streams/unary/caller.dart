// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of '../_index.dart';

/// Unary caller: codecs → serialized; no codecs → zero-copy (zero-copy
/// transport only). Sends one request, receives one response.
///
/// A client stream of one request: [ClientStreamCaller] holds the response
/// until the status, maps the deadline, and tells the server when the call is
/// abandoned. The request goes out in the frame that half-closes. Each [call]
/// is its own call on its own stream, so one caller can make many.
final class UnaryCaller<TRequest extends Object, TResponse extends Object> {
  /// Creates a unary caller for `/serviceName/methodName`.
  UnaryCaller({
    required IRpcTransport transport,
    required String serviceName,
    required String methodName,
    IRpcCodec<TRequest>? requestCodec,
    IRpcCodec<TResponse>? responseCodec,
    RpcContext? context,
    LogScope? logger,
  }) : _transport = transport,
       _serviceName = serviceName,
       _methodName = methodName,
       _requestCodec = requestCodec,
       _responseCodec = responseCodec,
       _context = context,
       _logger = logger?.child('UnaryCaller') ?? LogScope.noop;

  final IRpcTransport _transport;
  final String _serviceName;
  final String _methodName;
  final IRpcCodec<TRequest>? _requestCodec;
  final IRpcCodec<TResponse>? _responseCodec;
  final RpcContext? _context;
  final LogScope _logger;

  /// Sends [request] and returns the response.
  ///
  /// The wait is bounded by the context's deadline, which fails the call with
  /// [RpcDeadlineExceededException] and tells the server, and otherwise
  /// unbounded.
  ///
  /// Every failure arrives through the returned future, the ones found before
  /// a stream exists (a cancelled or expired context, a transport at its
  /// stream limit) included. The stream is released before it completes.
  ///
  /// `async`, so a failure the caller's constructor finds -- an expired
  /// context -- is the returned future's, not a synchronous throw.
  Future<TResponse> call(TRequest request) async {
    if (_logger.isInternal) {
      _logger.internal('Unary call /$_serviceName/$_methodName started');
    }
    return ClientStreamCaller<TRequest, TResponse>(
      transport: _transport,
      serviceName: _serviceName,
      methodName: _methodName,
      requestCodec: _requestCodec,
      responseCodec: _responseCodec,
      context: _context,
      logger: _logger,
    )._callOne(request);
  }
}
