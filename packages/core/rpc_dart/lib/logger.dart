// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Structured logging and spans. Re-exported by `rpc_dart.dart`.
library;

export 'src/logger/_index.dart'
    show
        RpcLogLevel,
        LogScope,
        LogController,
        LogConfig,
        LogRecord,
        LogEvent,
        LogSpan,
        LogSpanStart,
        LogSpanHandle,
        SpanStatus,
        SpanStartCallback,
        SpanEventCallback,
        SpanCompleteCallback,
        LogOutput,
        ConsoleOutput,
        ConsoleFormat,
        RingBufferOutput,
        LogFilter,
        LogEnricher,
        LogRedactor,
        SamplingConfig;
