// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';

/// Turns a status the data service sent with [RpcDataError.toStatusException]
/// back into the [RpcDataError] it was, on every call shape.
///
/// Installed on the caller endpoint by [DataServiceClient], once per
/// endpoint. Errors from other services pass through unchanged: only an
/// `ErrorInfo` in [RpcDataError.wireDomain] is converted.
final class RpcDataErrorInterceptor extends IRpcInterceptor {
  const RpcDataErrorInterceptor();

  static final _installed = Expando<bool>('rpc_data error interceptor');

  /// Adds the interceptor to [endpoint] unless it is already there.
  static void installOn(RpcCallerEndpoint endpoint) {
    if (_installed[endpoint] ?? false) return;
    _installed[endpoint] = true;
    endpoint.addInterceptor(const RpcDataErrorInterceptor());
  }

  static Object _convert(Object error) => error is RpcStatusException
      ? RpcDataError.fromStatusException(error) ?? error
      : error;

  static Never _rethrow(Object error, StackTrace stackTrace) =>
      Error.throwWithStackTrace(_convert(error), stackTrace);

  static Stream<T> _stream<T>(Stream<T> source) => source.handleError(
    _rethrow,
    test: (error) => error is RpcStatusException,
  );

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) => next(call.context, request).catchError(
    _rethrow,
    test: (error) => error is RpcStatusException,
  );

  @override
  Future<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async => _stream(await next(call.context, request));

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) => next(call.context, requests).catchError(
    _rethrow,
    test: (error) => error is RpcStatusException,
  );

  @override
  Future<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async => _stream(await next(call.context, requests));
}
