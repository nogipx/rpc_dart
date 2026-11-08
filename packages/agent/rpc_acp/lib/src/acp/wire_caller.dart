// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'json_rpc.dart';
import 'wire.dart';

/// ACP semantics on the application side of any [IAcpConnection].
final class AcpWireCaller {
  AcpWireCaller(this._wire, this._app, {this.onMcpMessage}) {
    _wire.onAgentRequest = _handleAgentRequest;
    _wire.onAgentNotification = (method, params) {
      if (method == 'elicitation/complete') {
        unawaited(
          _app.onCompleteElicitation(
            CompleteElicitationRequest.fromJson(params),
          ),
        );
      }
    };
  }

  final JsonRpcWire _wire;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  onMcpMessage;

  void notifyMcpMessage(Map<String, dynamic> params) =>
      _wire.notify('mcp/message', params);

  /// The protocol version negotiated on this connection. Every request
  /// after `initialize` is translated into this version's wire shape;
  /// one connection speaks exactly one version (ACP v2, version
  /// negotiation).
  int get protocolVersion => _protocolVersion;
  int _protocolVersion = 1;

  /// Application handlers for agent-originated requests.
  final AcpAppService _app;

  /// Every `session/update` the agent sends, including updates outside a
  /// prompt window.
  Stream<(String, Map<String, dynamic>)> get updates => _wire.allUpdates;

  Future<InitializeResult> initialize(InitializeRequest request) async {
    // v2 renamed the identity fields: the client sends `info` +
    // `capabilities`, the agent answers `capabilities` + required `info`.
    // The typed result is version-neutral; the wire shape is not.
    final result = request.protocolVersion >= 2
        ? await _wire.request('initialize', <String, dynamic>{
            'protocolVersion': request.protocolVersion,
            'info': ?request.clientInfo,
            'capabilities': request.clientCapabilities,
          })
        : await _wire.request('initialize', <String, dynamic>{
            'protocolVersion': request.protocolVersion,
            'clientCapabilities': request.clientCapabilities,
            'clientInfo': ?request.clientInfo,
          });
    final parsed = InitializeResult.fromJson(result);
    _protocolVersion = parsed.protocolVersion;
    return parsed;
  }

  Future<NewSessionResult> newSession(NewSessionRequest request) async {
    final result = await _wire.request(
      'session/new',
      _normalizeSetupParams(request.toJson()),
    );
    return NewSessionResult.fromJson(result);
  }

  /// v2 requires a `type` discriminator on every MCP server config (v1
  /// stdio configs had none; the sse transport is gone). Entries the
  /// caller typed for v1 get `stdio` — the only transport whose v1 form
  /// lacked the field.
  Map<String, dynamic> _normalizeSetupParams(Map<String, dynamic> params) {
    if (_protocolVersion < 2) return params;
    final servers = params['mcpServers'];
    if (servers is! List) return params;
    params['mcpServers'] = <Map<String, dynamic>>[
      for (final server in servers.whereType<Map<String, dynamic>>())
        if (server.containsKey('type'))
          server
        else
          <String, dynamic>{'type': 'stdio', ...server},
    ];
    return params;
  }

  Stream<SessionUpdateEvent> prompt(PromptRequest request) async* {
    if (_protocolVersion >= 2) {
      yield* _promptV2(request);
      return;
    }
    final updates = _wire.sessionUpdates(request.sessionId);
    final response = _wire.request('session/prompt', <String, dynamic>{
      'sessionId': request.sessionId,
      'prompt': request.blocks,
    });
    // The response, not the notification stream, is what ends the turn:
    // close the session window when it arrives. Events already queued are
    // delivered first.
    unawaited(
      response.then<void>(
        (_) => _wire.endSession(request.sessionId),
        onError: (Object _, StackTrace stackTrace) =>
            _wire.endSession(request.sessionId),
      ),
    );

    try {
      await for (final raw in updates) {
        yield SessionUpdateEvent(raw);
      }
      final result = await response;
      // A stop reason is a fact about the stream, not about this response:
      // default it rather than throw when the agent omitted it.
      yield SessionUpdateEvent(
        const <String, dynamic>{},
        stopReason: result['stopReason'] as String? ?? 'end_turn',
      );
    } finally {
      _wire.endSession(request.sessionId);
    }
  }

  /// v2 prompt: the response acknowledges user-message INSERTION
  /// (`{messageId}`), it does not end the turn. Foreground progress and
  /// completion arrive as `state_update` notifications; the idle state
  /// carries the stop reason, including `error` with the JSON-RPC error
  /// object. The client stream ends with a stop reason, normalized here: the terminal event is synthesized from the idle
  /// update, an error stop reason becomes the stream's error.
  Stream<SessionUpdateEvent> _promptV2(PromptRequest request) {
    late final StreamController<SessionUpdateEvent> controller;
    late final StreamSubscription<Map<String, dynamic>> subscription;
    late final Future<Map<String, dynamic>> response;
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      _wire.endSession(request.sessionId);
      unawaited(subscription.cancel());
      unawaited(controller.close());
    }

    void fail(Object error, [StackTrace? stackTrace]) {
      if (finished) return;
      controller.addError(error, stackTrace);
      finish();
    }

    controller = StreamController<SessionUpdateEvent>(
      onListen: () {
        subscription = _wire
            .sessionUpdates(request.sessionId)
            .listen(
              (raw) {
                if (finished) return;
                final isIdle =
                    raw['sessionUpdate'] == 'state_update' &&
                    raw['state'] == 'idle';
                if (!isIdle) {
                  controller.add(SessionUpdateEvent(raw));
                  return;
                }
                unawaited(
                  response.then<void>(
                    (_) {
                      if (finished) return;
                      controller.add(SessionUpdateEvent(raw));
                      final stopReason =
                          raw['stopReason'] as String? ?? 'end_turn';
                      if (stopReason == 'error') {
                        final error = (raw['error'] as Map?)
                            ?.cast<String, dynamic>();
                        if (error != null) {
                          fail(
                            JsonRpcException(
                              error['code'] as int? ?? -32603,
                              error['message'] as String? ?? 'prompt failed',
                              error['data'],
                            ),
                          );
                          return;
                        }
                      }
                      controller.add(
                        SessionUpdateEvent(
                          const <String, dynamic>{},
                          stopReason: stopReason,
                        ),
                      );
                      finish();
                    },
                    onError: (Object error, StackTrace stackTrace) {
                      fail(error, stackTrace);
                    },
                  ),
                );
              },
              onError: fail,
              onDone: () {
                if (!finished) {
                  fail(
                    StateError(
                      'prompt stream ended without an idle state_update',
                    ),
                  );
                }
              },
            );
        response = _wire.request('session/prompt', <String, dynamic>{
          'sessionId': request.sessionId,
          'prompt': request.blocks,
        });
        unawaited(
          response.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              fail(error, stackTrace);
            },
          ),
        );
      },
      onCancel: () async {
        if (finished) return;
        finished = true;
        await subscription.cancel();
        _wire.endSession(request.sessionId);
      },
    );
    return controller.stream;
  }

  Stream<SessionUpdateEvent> loadSession(LoadSessionRequest request) async* {
    // History replays as ordinary session/update notifications on the
    // session's stream; the response, as with prompt, is what ends the
    // window. v2 removed session/load: the same behavior is session/resume
    // with a replayFrom cursor asking for the full history.
    final updates = _wire.sessionUpdates(request.sessionId);
    final Map<String, dynamic> params = _protocolVersion >= 2
        ? _normalizeSetupParams(<String, dynamic>{
            'sessionId': request.sessionId,
            'cwd': request.cwd,
            'additionalDirectories': ?request.additionalDirectories,
            'mcpServers': ?request.mcpServers,
            'replayFrom': const <String, dynamic>{'type': 'start'},
          })
        : request.toJson();
    final method = _protocolVersion >= 2 ? 'session/resume' : 'session/load';
    final response = _wire.request(method, params);
    unawaited(
      response.then<void>(
        (_) => _wire.endSession(request.sessionId),
        onError: (Object _, StackTrace stackTrace) =>
            _wire.endSession(request.sessionId),
      ),
    );
    try {
      await for (final raw in updates) {
        yield SessionUpdateEvent(raw);
      }
      await response;
    } finally {
      _wire.endSession(request.sessionId);
    }
  }

  Future<ResumeSessionResult> resumeSession(
    ResumeSessionRequest request,
  ) async {
    final result = await _wire.request(
      'session/resume',
      _normalizeSetupParams(request.toJson()),
    );
    return ResumeSessionResult.fromJson(result);
  }

  Future<ListSessionsResult> listSessions(ListSessionsRequest request) async {
    final result = await _wire.request('session/list', request.toJson());
    return ListSessionsResult.fromJson(result);
  }

  Future<void> deleteSession(DeleteSessionRequest request) async {
    await _wire.request('session/delete', request.toJson());
  }

  Future<void> closeSession(CloseSessionRequest request) async {
    await _wire.request('session/close', request.toJson());
  }

  Future<void> cancel(CancelRequest request) async {
    // ACP models cancel as a notification: sent, never answered. The unary
    // contract method completes immediately; confirmation that the turn
    // actually stopped only exists as the prompt stream ending.
    _wire.notify('session/cancel', <String, dynamic>{
      'sessionId': request.sessionId,
    });
  }

  Future<void> authenticate(AuthenticateRequest request) async {
    // v2 renamed the auth methods to the auth/ prefix; params unchanged.
    await _wire.request(
      _protocolVersion >= 2 ? 'auth/login' : 'authenticate',
      request.toJson(),
    );
  }

  Future<SetSessionModeResult> setSessionMode(
    SetSessionModeRequest request,
  ) async {
    if (_protocolVersion >= 2) {
      throw StateError('session/set_mode was removed in ACP v2');
    }
    await _wire.request('session/set_mode', request.toJson());
    return const SetSessionModeResult();
  }

  Future<SetSessionConfigOptionResult> setSessionConfigOption(
    SetSessionConfigOptionRequest request,
  ) async {
    // v2 requires a `type` discriminator on the value union: 'boolean'
    // carries a bool, 'id' a string option id. v1 agents accept the value
    // without one; inject it only for v2 connections.
    final params = request.toJson();
    if (_protocolVersion >= 2 && params['type'] == null) {
      final value = params['value'];
      params['type'] = value is bool ? 'boolean' : 'id';
    }
    final result = await _wire.request('session/set_config_option', params);
    return SetSessionConfigOptionResult.fromJson(result);
  }

  Future<void> cancelToolCall(CancelToolCallRequest request) async {
    _requireV2('tool_call/cancel');
    await _wire.request('tool_call/cancel', request.toJson());
  }

  Future<void> cancelTerminal(CancelTerminalRequest request) async {
    _requireV2('terminal/cancel');
    await _wire.request('terminal/cancel', request.toJson());
  }

  void _requireV2(String method) {
    if (_protocolVersion < 2) {
      throw StateError(
        '$method requires ACP v2; this connection negotiated v$_protocolVersion',
      );
    }
  }

  Future<LogoutResult> logout(LogoutRequest request) async {
    final result = await _wire.request(
      _protocolVersion >= 2 ? 'auth/logout' : 'logout',
      request.toJson(),
    );
    return LogoutResult.fromJson(result);
  }

  Future<Object?> _handleAgentRequest(
    String method,
    Map<String, dynamic> params,
  ) => _dispatchAgentRequest(method, params);

  Future<Object?> _dispatchAgentRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case 'mcp/message':
        final handler = onMcpMessage;
        if (handler == null) {
          throw const JsonRpcException(-32601, 'MCP over ACP is not enabled');
        }
        return handler(params);
      case 'session/request_permission':
        // fromJson reads both wire shapes: v1's bare `toolCall` and v2's
        // required title + subject union.
        final outcome = await _app.onRequestPermission(
          PermissionRequestMsg.fromJson(params),
        );
        // The RequestPermissionOutcome union, spec-shaped: an object with
        // an 'outcome' discriminator, not a bare string.
        return <String, dynamic>{
          'outcome': outcome.cancelled
              ? <String, dynamic>{'outcome': 'cancelled'}
              : <String, dynamic>{
                  'outcome': 'selected',
                  'optionId': outcome.optionId,
                },
        };
      case 'fs/read_text_file':
        final result = await _app.onReadTextFile(
          ReadTextFileRequest.fromJson(params),
        );
        return result.toJson();
      case 'fs/write_text_file':
        await _app.onWriteTextFile(WriteTextFileRequest.fromJson(params));
        return <String, dynamic>{};
      case 'terminal/create':
        final result = await _app.onCreateTerminal(
          CreateTerminalRequest.fromJson(params),
        );
        return result.toJson();
      case 'terminal/output':
        final result = await _app.onTerminalOutput(
          TerminalOutputRequest.fromJson(params),
        );
        return result.toJson();
      case 'terminal/release':
        await _app.onReleaseTerminal(TerminalIdRequest.fromJson(params));
        return <String, dynamic>{};
      case 'terminal/wait_for_exit':
        final result = await _app.onWaitForTerminalExit(
          TerminalOutputRequest.fromJson(params),
        );
        return result.toJson();
      case 'terminal/kill':
        await _app.onKillTerminal(TerminalIdRequest.fromJson(params));
        return <String, dynamic>{};
      case 'elicitation/create':
        final result = await _app.onCreateElicitation(
          ElicitationRequestMsg(params),
        );
        return result.toJson();
      default:
        // A method the client never advertised should not arrive from a
        // well-behaved agent; answering honestly beats hanging.
        throw JsonRpcException(-32601, 'Method not handled: $method');
    }
  }
}
