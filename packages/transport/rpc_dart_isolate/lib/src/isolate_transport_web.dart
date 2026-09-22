// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller/web_platform/isolate_contactor_controller_web_worker.dart';
import 'package:isolate_manager/src/isolate_manager_controller/web.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:web/web.dart';

import 'web_bridge.dart';
import 'worker_policy.dart';

typedef RpcIsolateEntrypoint =
    void Function(IRpcTransport transport, Map<String, dynamic> customParams);

const bool _kIsWasm = bool.fromEnvironment('dart.tool.dart2wasm');
const String _defaultWorkerName = 'rpcIsolateWorker';

/// How long to wait for the worker's post-entrypoint `ready` ack before
/// assuming it is a worker built before that ack existed and proceeding anyway.
///
/// Deliberately NOT `startupTimeout`: this bound is a compatibility fallback
/// whose expiry is a SUCCESS path, whereas `startupTimeout` bounds failures.
/// Tying them together would mean a generous startup budget also made every
/// legacy worker wait that long before its first call.
const Duration _readyGracePeriod = Duration(seconds: 5);

@JS('self')
external DedicatedWorkerGlobalScope get _workerSelf;

// The wire format and the channel live in `web_bridge.dart`, which imports no
// JS library. Keeping them here made them untestable: this file cannot be
// loaded off the web at all, so neither could they.

// -- Public API ---------------------------------------------------------------

/// Web implementation backed by isolate_manager Worker controllers.
abstract interface class RpcIsolateTransport {
  static Future<({IRpcTransport transport, void Function() kill})> spawn({
    required RpcIsolateEntrypoint entrypoint,
    Map<String, dynamic>? customParams,
    String isolateId = 'default',
    String? debugName,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Uri? workerUri,
    Duration startupTimeout = const Duration(seconds: 30),
  }) async {
    // On web we cannot transfer the entrypoint function; user must expose it
    // in a worker. Keeping the parameter for API parity.
    final _ = entrypoint;

    // The policy rides on the URL: a Worker has no argument list, and the VM
    // sibling ships it as args[4]. See [_policyQueryParam].
    final uri = withWorkerPolicy(_resolveWorkerUri(workerUri), policy);
    final workerOptions = _buildWorkerOptions(debugName);
    final worker = workerOptions == null
        ? Worker(uri.toString().toJS)
        : Worker(uri.toString().toJS, workerOptions);

    final controller = IsolateContactorControllerImplWorker<Object?, Object?>(
      worker,
      workerConverter: (value) => (value as Map).cast<String, Object?>(),
      onDispose: null,
      debugMode: false,
    );

    final channel = WebMultiplexedChannel(
      messageStream: controller.onMessage,
      send: controller.sendIsolate,
      onClose: controller.close,
    );
    final transport = RpcChannelTransport(
      channel: channel,
      isClient: true,
      policy: policy,
    );

    // A worker that fails to LOAD -- a 404 on the script, or a parse error --
    // fires an `error` event on the Worker object and then does nothing else.
    // With nobody listening, the two waits below just expire and spawn() hands
    // back a transport wired to a worker that does not exist: isClosed false,
    // health "ready", and every call hangs forever. The VM sibling wires
    // onError/onExit for exactly this reason.
    final workerFailed = Completer<Object>();
    void reportWorkerError(String what) {
      if (!workerFailed.isCompleted) workerFailed.complete(what);
    }

    final errorListener = (Event event) {
      // `event is ErrorEvent` is meaningless across JS interop (it is always
      // true and checks nothing), so ask the JS type system with isA. The
      // message is empty for a cross-origin or 404 load failure anyway -- the
      // event firing at all is the signal.
      final reported = event.isA<ErrorEvent>()
          ? (event as ErrorEvent).message
          : '';
      reportWorkerError(
        reported.isNotEmpty
            ? reported
            : 'the worker script failed to load or threw during startup',
      );
    }.toJS;
    worker.addEventListener('error', errorListener);
    worker.addEventListener('messageerror', errorListener);

    /// Races [future] against a worker error and the startup budget.
    Future<void> awaitStartup(Future<void> future, String phase) async {
      await Future.any([
        future,
        workerFailed.future.then(
          (reason) => throw RpcStatusException(
            RpcStatus.unavailable,
            'RpcIsolateTransport.spawn: worker "$uri" failed during $phase: '
            '$reason',
          ),
        ),
      ]).timeout(
        startupTimeout,
        onTimeout: () => throw TimeoutException(
          'RpcIsolateTransport.spawn: worker "$uri" did not complete $phase '
          'within $startupTimeout.',
          startupTimeout,
        ),
      );
    }

    /// Releases everything spawn() built, so a failed startup leaves nothing
    /// behind -- the worker itself included.
    Future<void> abandon() async {
      worker.removeEventListener('error', errorListener);
      worker.removeEventListener('messageerror', errorListener);
      await transport.close();
      worker.terminate();
    }

    // Wait for worker init acknowledgment (isolate_manager `initialized()`).
    //
    // This confirms only that the worker SCOPE is wired -- not that the user
    // `entrypoint` has run and subscribed its responder. That needs the
    // worker's own `ready` ack below, or early RPC frames race ahead of the
    // subscription and are dropped, because the bridge streams do not buffer.
    //
    // Failing HERE is fatal, deliberately: it means the worker scope never came
    // up at all, which is not the legacy-protocol case handled below.
    try {
      await awaitStartup(controller.ensureInitialized.future, 'initialization');
    } catch (_) {
      await abandon();
      rethrow;
    }

    // Listen for the worker's post-entrypoint readiness ack before any RPC
    // frames are allowed to flow.
    final ready = Completer<void>();
    final readySub = controller.onMessage.listen((raw) {
      final msg = BridgeMessage.fromMap(raw);
      if (msg != null && msg.type == BridgeType.ready && !ready.isCompleted) {
        ready.complete();
      }
    });

    // Deliver initial parameters to the worker.
    controller.sendIsolate(
      BridgeMessage(
        type: BridgeType.init,
        streamId: 0,
        payload: customParams ?? const <String, Object?>{},
      ).toMap(),
    );

    // Wait for the worker responder to be ready. A MISSING ack is tolerated on
    // purpose -- a worker built before this protocol never sends one, and
    // hanging those would be the worse regression. A worker that ERRORS while
    // we wait is not a legacy worker, so that case fails rather than being
    // swallowed along with it.
    try {
      await Future.any([
        ready.future,
        workerFailed.future.then(
          (reason) => throw RpcStatusException(
            RpcStatus.unavailable,
            'RpcIsolateTransport.spawn: worker "$uri" failed before it was '
            'ready: $reason',
          ),
        ),
      ]).timeout(_readyGracePeriod, onTimeout: () {});
    } catch (_) {
      await readySub.cancel();
      await abandon();
      rethrow;
    }
    await readySub.cancel();

    // Past startup the worker is the peer, and a peer that dies must not look
    // healthy. Without this swap `health()` answers "healthy / Transport ready"
    // for a worker that is gone, and every call hangs. The VM sibling closes
    // its channel from onError/onExit for the same reason.
    worker.removeEventListener('error', errorListener);
    worker.removeEventListener('messageerror', errorListener);
    final deathListener = (Event event) {
      unawaited(transport.close());
    }.toJS;
    worker.addEventListener('error', deathListener);
    worker.addEventListener('messageerror', deathListener);

    void kill() {
      worker.removeEventListener('error', deathListener);
      worker.removeEventListener('messageerror', deathListener);
      unawaited(transport.close());
      worker.terminate();
    }

    return (transport: transport, kill: kill);
  }
}

/// Called from inside the worker entrypoint to wire up the RPC transport.
/// [policy] OVERRIDES what the spawner sent; omit it to inherit.
///
/// Inheriting is the fix: this used to default to `const RpcSecurityPolicy()`
/// with no way for `spawn(policy:)` to reach it, so the host ran at the
/// caller's limits and the worker at the stock ones, silently. The spawner's
/// policy now arrives on the worker URL — see [kWorkerPolicyQueryParam].
void runRpcIsolateManagerWorker(
  RpcIsolateEntrypoint entrypoint, {
  RpcSecurityPolicy? policy,
}) {
  final scope = _workerSelf;
  final effectivePolicy =
      policy ??
      policyFromWorkerUrl(scope.location.href) ??
      const RpcSecurityPolicy();

  final controller = IsolateManagerControllerImpl<Object?, Object?>(
    scope,
    // A CLOSURE, not `scope.close` — `close` is an external extension type
    // interop member and tearing one off is a compile error on the JS targets:
    // "Tear-offs of external extension type interop member 'close' are
    // disallowed". The `onClose` below has always used this form.
    //
    // `unnecessary_lambdas` asks for the tear-off, so the two gates contradict
    // each other on this line and only one of them can be satisfied. The
    // analyzer is the one that is wrong here: its advice does not compile.
    // ignore: unnecessary_lambdas
    onDispose: () => scope.close(),
  );

  final channel = WebMultiplexedChannel(
    messageStream: controller.onIsolateMessage,
    send: controller.sendResult,
    onClose: () {
      controller.close();
      scope.close();
    },
  );
  final transport = RpcChannelTransport(
    channel: channel,
    isClient: false,
    policy: effectivePolicy,
  );

  // Signal ready state.
  controller.initialized();

  void signalReady() {
    controller.sendResult(
      BridgeMessage(type: BridgeType.ready, streamId: 0).toMap(),
    );
  }

  // Wait for the INIT message specifically, NOT for the first message.
  //
  // RpcChannelTransport advertises the connection flow-control window from its
  // own constructor, synchronously, and spawn() builds the transport before it
  // sends init -- so message #1 is a metadata frame. Take `.first` and the init
  // branch never matches, the fallback hands the entrypoint `const {}`, and
  // customParams is silently dropped on every web spawn.
  var started = false;
  late final StreamSubscription<dynamic> initSub;

  void start(Map<String, dynamic> params) {
    if (started) return;
    started = true;
    unawaited(initSub.cancel());
    try {
      entrypoint(transport, params);
      // Ack readiness only AFTER the entrypoint has wired its responder, so
      // the host does not race RPC frames ahead of the subscription.
      signalReady();
    } catch (error, stackTrace) {
      unawaited(transport.close());
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }

  initSub = controller.onIsolateMessage.listen(
    (raw) {
      final msg = BridgeMessage.fromMap(raw);
      if (msg != null && msg.type == BridgeType.init && msg.payload is Map) {
        start((msg.payload as Map).cast<String, dynamic>());
      }
    },
    // A host that never sends init still has to get its entrypoint started.
    onDone: () => start(const <String, dynamic>{}),
  );
}

// -- Helpers ------------------------------------------------------------------

WorkerOptions? _buildWorkerOptions(String? debugName) {
  if (!_kIsWasm && debugName == null) return null;
  if (_kIsWasm && debugName != null) {
    return WorkerOptions(type: 'module', name: debugName);
  }
  if (_kIsWasm) return WorkerOptions(type: 'module');
  return WorkerOptions(name: debugName!);
}

Uri _resolveWorkerUri(Uri? provided) {
  if (provided != null) return provided;
  final defaultPath = Uri.parse('$_defaultWorkerName.js');
  if (defaultPath.isAbsolute) return defaultPath;
  return Uri.base.resolveUri(defaultPath);
}
