// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  print('=== RPC Dart Logger Demo ===\n');

  // ---------------------------------------------------------------------------
  // 1. Basic setup: LogController + ConsoleOutput
  // ---------------------------------------------------------------------------
  print('--- 1. Basic logging ---\n');

  final log = LogController(
    minLevel: RpcLogLevel.debug,
    outputs: [ConsoleOutput()],
  );

  final scope = log.scope('app');
  scope.info('Application started');
  scope.debug('Loading configuration', data: {'env': 'production'});
  scope.warning('Cache miss for key "user_123"');

  // ---------------------------------------------------------------------------
  // 2. Scoped loggers: child scopes, tags, bound data
  // ---------------------------------------------------------------------------
  print('\n--- 2. Scoped loggers ---\n');

  final dbScope = scope.child('database');
  dbScope.info('Connected to PostgreSQL');
  dbScope.debug('Pool size: 10');

  final reqScope = scope.child('handler').withData({
    'userId': 'u_42',
    'orderId': 'ord_789',
  });
  reqScope.info('Processing order');
  reqScope.debug('Validating payment');
  reqScope.info('Order shipped');

  // ---------------------------------------------------------------------------
  // 3. Per-scope level filtering
  // ---------------------------------------------------------------------------
  print('\n--- 3. Per-scope filtering ---\n');

  log.minLevel = RpcLogLevel.warning; // suppress debug/info globally
  scope.info('This will NOT appear (below warning)');
  scope.warning('This WILL appear');

  log.setScopeLevel(
      'app.database', RpcLogLevel.debug); // but enable debug for DB
  dbScope.debug('This WILL appear (scope override)');

  log.minLevel = RpcLogLevel.debug; // restore
  log.clearScopeLevel('app.database');

  // ---------------------------------------------------------------------------
  // 4. Spans: operations with duration
  // ---------------------------------------------------------------------------
  print('\n--- 4. Spans ---\n');

  final apiScope = log.scope('api');

  // Callback-based (auto-close on return/throw)
  await apiScope.withSpan('handleRequest', (span) async {
    span.event('Parsing request body');
    await Future.delayed(Duration(milliseconds: 10));

    // Nested sub-span
    await apiScope.withSpan('db.query', (dbSpan) async {
      dbSpan.event('SELECT * FROM orders WHERE id = 789');
      await Future.delayed(Duration(milliseconds: 25));
    });

    span.event('Serializing response');
    await Future.delayed(Duration(milliseconds: 5));
  });

  // Manual span (explicit start/end)
  final span = apiScope.startSpan('backgroundJob');
  span.event('Step 1: fetching data');
  await Future.delayed(Duration(milliseconds: 15));
  span.event('Step 2: processing');
  await Future.delayed(Duration(milliseconds: 20));
  span.end(status: SpanStatus.ok);

  // Error span
  try {
    await apiScope.withSpan('failingOperation', (span) async {
      span.event('Starting risky work');
      await Future.delayed(Duration(milliseconds: 5));
      throw Exception('Something went wrong');
    });
  } catch (_) {
    // withSpan auto-ends with SpanStatus.error
  }

  // ---------------------------------------------------------------------------
  // 5. Spans bypass level filter (telemetry, not logs)
  // ---------------------------------------------------------------------------
  print('\n--- 5. Spans bypass level filter ---\n');

  log.minLevel = RpcLogLevel.fatal; // suppress ALL events
  scope.info('This event will NOT appear');

  await apiScope.withSpan('spanInSilentMode', (span) async {
    span.event('This event inside span will NOT appear either');
    await Future.delayed(Duration(milliseconds: 10));
  });
  // But the span summary WILL appear (spans bypass level filter)

  log.minLevel = RpcLogLevel.debug; // restore

  // ---------------------------------------------------------------------------
  // 6. RingBuffer: query log history
  // ---------------------------------------------------------------------------
  print('\n--- 6. RingBuffer history ---\n');

  final buffer = RingBufferOutput(maxEntries: 100);
  final logWithBuffer = LogController(
    minLevel: RpcLogLevel.debug,
    outputs: [ConsoleOutput(), buffer],
  );

  final svc = logWithBuffer.scope('service');
  svc.info('Request A');
  svc.warning('Slow query');
  svc.error('Connection lost', error: 'ECONNRESET');
  svc.info('Request B');

  final warnings = buffer.query(
    LogFilter(minLevel: RpcLogLevel.warning),
  );
  print('  Buffered warnings+: ${warnings.length}');

  logWithBuffer.dispose();

  // ---------------------------------------------------------------------------
  // 7. Enrichment and Redaction
  // ---------------------------------------------------------------------------
  print('\n--- 7. Enrichment + Redaction ---\n');

  final prodLog = LogController(
    minLevel: RpcLogLevel.info,
    enrichers: [_HostEnricher()],
    redactFields: ['password', 'token', 'secret'],
    outputs: [ConsoleOutput(format: ConsoleFormat.json)],
  );

  final auth = prodLog.scope('auth');
  auth.info('Login attempt', data: {
    'username': 'john',
    'password': 'hunter2',
    'token': 'eyJhbGciOiJIUzI...',
  });

  prodLog.dispose();

  // ---------------------------------------------------------------------------
  // 8. Sampling (production highload)
  // ---------------------------------------------------------------------------
  print('\n--- 8. Sampling ---\n');

  final sampledLog = LogController(
    minLevel: RpcLogLevel.debug,
    sampling: SamplingConfig(
      interval: Duration(seconds: 1),
      maxPerInterval: {
        RpcLogLevel.debug: 3, // max 3 debug/sec
      },
    ),
    outputs: [ConsoleOutput(format: ConsoleFormat.compact)],
  );

  final hot = sampledLog.scope('hotpath');
  for (var i = 0; i < 10; i++) {
    hot.debug('Debug message #$i');
  }
  hot.info('Info is not sampled (unlimited)');

  sampledLog.dispose();

  // ---------------------------------------------------------------------------
  // 9. Noop: zero-cost when no logger
  // ---------------------------------------------------------------------------
  print('\n--- 9. Noop (zero cost) ---\n');

  final noop = LogScope.noop;
  noop.info('This goes nowhere');
  noop.error('This too');
  final noopSpan = noop.startSpan('nothing');
  noopSpan.event('invisible');
  noopSpan.end();
  print('  LogScope.noop: all calls are empty, zero allocation');

  // ---------------------------------------------------------------------------
  // 10. With RPC endpoint — context.log has traceId automatically
  // ---------------------------------------------------------------------------
  print('\n--- 10. Logger with RPC endpoint (auto traceId) ---\n');

  final rpcLog = LogController(
    minLevel: RpcLogLevel.debug,
    outputs: [ConsoleOutput()],
  );

  final (client, server) = RpcInMemoryTransport.pair();
  final responder = RpcResponderEndpoint(transport: server, logger: rpcLog);
  final caller = RpcCallerEndpoint(transport: client, logger: rpcLog);

  responder.registerServiceContract(CalculatorResponder());
  responder.start();

  final calculator = CalculatorCaller(caller);

  // context.log inside the responder has traceId/requestId attached automatically
  final result = await calculator.calculate(Request(10, 5, 'add'));
  print('  10 + 5 = ${result.result}');

  final result2 = await calculator.calculate(Request(7, 3, 'multiply'));
  print('  7 * 3 = ${result2.result}');

  await server.close();
  await client.close();
  rpcLog.dispose();
  log.dispose();

  print('\n=== Done ===');
  exit(0);
}

// --- Enricher example ---

class _HostEnricher implements LogEnricher {
  @override
  Map<String, Object> enrich(LogRecord record) => {'host': 'prod-server-01'};
}

// --- RPC contract (from the original example, simplified) ---

abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodCalculate = 'calculate';
}

class Request {
  final double a, b;
  final String op;
  Request(this.a, this.b, this.op);
}

class Response {
  final double result;
  Response(this.result);
}

final class CalculatorResponder extends RpcResponderContract
    implements ICalculatorContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
    addUnaryMethod<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      handler: calculate,
    );
  }

  Future<Response> calculate(Request req, {RpcContext? context}) async {
    context?.log.info('Calculating ${req.a} ${req.op} ${req.b}');
    final result = switch (req.op) {
      'add' => req.a + req.b,
      'multiply' => req.a * req.b,
      'divide' => req.a / req.b,
      'subtract' => req.a - req.b,
      _ => 0.0,
    };
    context?.log.info('Result: $result');
    return Response(result);
  }
}

final class CalculatorCaller extends RpcCallerContract
    implements ICalculatorContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
      : super(ICalculatorContract.name, endpoint);

  Future<Response> calculate(Request request) {
    return callUnary<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      request: request,
    );
  }
}
