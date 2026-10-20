// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:js_interop';

import 'package:isolate_manager/src/base/contactor/isolate_contactor_controller/web_platform/isolate_contactor_controller_web_worker.dart';
import 'package:isolate_manager/src/isolate_manager_controller/web.dart';
import 'package:rpc_dart/transport.dart';
import 'package:web/web.dart';

import 'port_channel.dart';
import 'web_bridge.dart';
import 'worker_policy.dart';

export 'port_channel.dart' show RpcIsolateEntrypoint;

const bool _kIsWasm = bool.fromEnvironment('dart.tool.dart2wasm');
const String _defaultWorkerName = 'rpcIsolateWorker';

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
    LogScope? logger,
  }) async {
    // Unused on the web, as is `isolateId`: a function cannot cross into a
    // Worker, so the worker script passes its own entrypoint to
    // runRpcIsolateManagerWorker. Both stay for parity with the VM signature.
    final _ = entrypoint;

    // The policy rides on the URL: a Worker has no argument list, and the VM
    // sibling ships it as args[3]. See kWorkerPolicyQueryParam.
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
      holdUntilReleased: true,
    );
    final transport = RpcChannelTransport(
      channel: channel,
      isClient: true,
      policy: policy,
      logger: logger,
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
    // The worker is listening now; what the transport sent before -- the
    // connection-window grant -- goes out.
    channel.release();

    // Listen for the worker's post-entrypoint readiness ack, which carries its
    // protocol version, before any RPC frames are allowed to flow.
    final ready = Completer<int?>();
    final readySub = controller.onMessage.listen((raw) {
      final frame = bridgeFrameOf(raw);
      if (frame != null &&
          frame.type == PortFrameType.ready &&
          !ready.isCompleted) {
        ready.complete(bridgeVersionOf(raw));
      }
    });

    // Deliver the protocol version and the initial parameters to the worker.
    controller.sendIsolate(
      bridgeHandshakeOf(
        PortFrameType.init,
        body: customParams ?? const <String, Object?>{},
      ),
    );

    int? workerVersion;
    try {
      await awaitStartup(
        ready.future.then((version) => workerVersion = version),
        'its ready handshake',
      );
    } catch (_) {
      await readySub.cancel();
      await abandon();
      rethrow;
    }
    await readySub.cancel();

    final mismatch = workerVersionMismatch(workerVersion);
    if (mismatch != null) {
      await abandon();
      throw RpcStatusException(
        RpcStatus.failedPrecondition,
        'RpcIsolateTransport.spawn: worker "$uri": $mismatch.',
      );
    }

    // Past startup the worker is the peer, and a peer that dies must not look
    // healthy. Without this swap `health()` answers "healthy / Transport ready"
    // for a worker that is gone, and every call hangs. The VM sibling closes
    // its channel from onError/onExit for the same reason.
    worker.removeEventListener('error', errorListener);
    worker.removeEventListener('messageerror', errorListener);
    //
    // An uncaught error is treated as the worker's death, as on the VM, where
    // the isolate is spawned with errorsAreFatal and really does die. A
    // browser keeps a worker running past one, so it is terminated here too:
    // closing only the transport left a worker with nobody to talk to running
    // for the life of the page.
    final deathListener = (Event event) {
      worker.terminate();
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
/// [policy] OVERRIDES what the spawner sent; null inherits it, so both ends run
/// at the limits `spawn(policy:)` was given. The spawner's policy arrives on
/// the worker URL — see [kWorkerPolicyQueryParam]. A worker spawned without
/// one runs at `const RpcSecurityPolicy()`.
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
    controller.sendResult(bridgeHandshakeOf(PortFrameType.ready));
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

  void start(Map<String, dynamic> params, int? hostVersion) {
    if (started) return;
    started = true;
    unawaited(initSub.cancel());
    // A host of another release: answer with this worker's version, which the
    // host refuses, and run no user code against frames neither side can read.
    if (hostVersion != kWorkerProtocolVersion) {
      signalReady();
      return;
    }
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
      final frame = bridgeFrameOf(raw);
      if (frame != null &&
          frame.type == PortFrameType.init &&
          frame.body is Map) {
        start(
          (frame.body as Map).cast<String, dynamic>(),
          bridgeVersionOf(raw),
        );
      }
    },
    // No fallback on onDone: the stream ends only when the channel is gone,
    // and starting the entrypoint then would run user code on a dead channel
    // and send `ready` into it. RpcIsolateTransport.spawn always sends init.
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
