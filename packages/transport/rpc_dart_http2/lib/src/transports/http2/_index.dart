// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

export 'rpc_http2_caller_transport.dart';
export 'rpc_http2_responder_transport.dart';
export 'rpc_http2_server.dart';

// `rpc_http2_common.dart` is NOT re-exported wholesale. It is HTTP/2 wire
// machinery -- header conversion, frame checks, the outgoing pump, Nagle --
// used by this package's own transports and nothing else in the repo. Exported
// as a file, every helper in it became a compatibility promise because nobody
// wrote an underscore.
//
// `RpcHttp2StreamError` is the exception and genuinely public: it is the
// envelope a stream-scoped error arrives in on `incomingMessages`, so anyone
// subscribing to that stream can receive one and needs the type to match on it.
//
// Code inside this package imports the file directly; so do the tests that
// exercise the machinery.
export 'rpc_http2_common.dart' show RpcHttp2StreamError;
