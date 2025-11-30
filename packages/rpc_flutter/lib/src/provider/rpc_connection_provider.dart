import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_flutter/rpc_flutter.dart';

/// A handle returned by [RpcConnectionProvider.connect] that carries an
/// already created endpoint and an optional disposer.
class RpcConnectionHandle {
  const RpcConnectionHandle({required this.endpoint, this.dispose});

  final RpcCallerEndpoint endpoint;
  final Future<void> Function()? dispose;
}

/// Wraps a subtree with [RpcConnectionBloc] lifecycle-aware wiring.
///
/// - Creates its own [RpcConnectionBloc].
/// - Calls [connect] to get an active [RpcCallerEndpoint], then starts
///   periodic health checks.
/// - Stops the bloc and disposes the endpoint on app pause/inactive/hidden.
/// - Reconnects on resume.
///
/// This widget is intentionally generic so it can be moved into rpc_flutter.
class RpcConnectionProvider extends StatefulWidget {
  const RpcConnectionProvider({
    required this.connect,
    required this.child,
    super.key,
    this.interval = const Duration(seconds: 8),
    this.timeout = const Duration(seconds: 4),
    this.autoStart = true,
    this.stopOnPause = true,
  });

  /// Called when a connection is needed. Should return a ready endpoint.
  final Future<RpcConnectionHandle> Function() connect;

  /// Interval between health checks.
  final Duration interval;

  /// Timeout for health check calls.
  final Duration timeout;

  /// Automatically start monitoring on initState.
  final bool autoStart;

  /// Whether to stop monitoring when app is paused/inactive/hidden.
  final bool stopOnPause;

  final Widget child;

  @override
  State<RpcConnectionProvider> createState() => _RpcConnectionProviderState();
}

class _RpcConnectionProviderState extends State<RpcConnectionProvider>
    with WidgetsBindingObserver {
  late final RpcConnectionBloc _bloc;
  RpcConnectionHandle? _handle;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bloc = RpcConnectionBloc(
      defaultInterval: widget.interval,
      defaultTimeout: widget.timeout,
    );
    if (widget.autoStart) {
      _startMonitoring();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopMonitoring();
    _bloc.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _startMonitoring();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        if (widget.stopOnPause) {
          _stopMonitoring();
        }
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(value: _bloc, child: widget.child);
  }

  void _startMonitoring() {
    if (_starting) {
      return;
    }
    _starting = true;
    unawaited(() async {
      try {
        final handle = await widget.connect();
        if (!mounted) {
          await handle.dispose?.call();
          return;
        }
        _handle = handle;
        _bloc.add(
          RpcConnectionStart(
            data: RpcConnectionInitialData(endpoint: handle.endpoint),
            interval: widget.interval,
            timeout: widget.timeout,
          ),
        );
      } on Object catch (_) {
        // Let consumers react to bloc status changes on next retry.
      } finally {
        _starting = false;
      }
    }());
  }

  void _stopMonitoring() {
    _bloc.add(const RpcConnectionStop());
    final handle = _handle;
    _handle = null;
    if (handle?.dispose != null) {
      unawaited(handle!.dispose!());
    }
  }
}
