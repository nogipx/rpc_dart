// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Public ACP client over any [IAcpConnection]. Protocol version mapping and
/// reverse request handlers live here, on the application side of the wire.
library;

import 'dart:async';

import 'json_rpc.dart';

import 'models.dart';
import 'wire_caller.dart';
import 'permission.dart';
import 'updates.dart';
import 'wire.dart';

/// The ACP protocol versions this package speaks.
///
/// v1 is the ecosystem default; v2 is draft. A client requests the latest
/// version it supports and the agent selects the highest version at or
/// below the request — see [AcpClient.initialize].
const int kAcpProtocolVersionV1 = 1;
const int kAcpProtocolVersionV2 = 2;

/// The latest protocol version [AcpClient] requests by default.
const int kAcpProtocolVersion = kAcpProtocolVersionV1;

/// `initialize` was rejected: the agent supports none of the requested
/// protocol versions. [requested] is what the client asked for, [supported]
/// what the agent has.
final class AcpUnsupportedProtocolVersion implements Exception {
  const AcpUnsupportedProtocolVersion(this.requested, this.supported);

  final int requested;
  final List<int> supported;

  static AcpUnsupportedProtocolVersion? fromRpcError(Object error) {
    if (error is! JsonRpcException ||
        error.code != kUnsupportedProtocolVersion) {
      return null;
    }
    final data = error.data;
    if (data is! Map) {
      return null;
    }
    return AcpUnsupportedProtocolVersion(
      data['requested'] as int? ?? 0,
      (data['supported'] as List?)?.whereType<int>().toList() ?? const [],
    );
  }

  @override
  String toString() =>
      'Unsupported ACP protocol version: requested $requested, '
      'agent supports $supported';
}

/// One block of a user prompt.
final class PromptBlock {
  const PromptBlock.text(this.text)
    : type = 'text',
      uri = null,
      mimeType = null,
      blob = null,
      data = null,
      name = null,
      input = null;

  /// A reference to a resource the agent can fetch. [name] is required by
  /// the schema (human-readable label); [uri] is the resource locator.
  const PromptBlock.resourceLink(String this.uri, {this.name})
    : type = 'resource_link',
      text = '',
      mimeType = null,
      blob = null,
      data = null,
      input = null;

  /// Inline binary content: [data] is base64, [mimeType] required, per
  /// the ContentBlock schema.
  const PromptBlock.image({
    required String data,
    required String this.mimeType,
    this.uri,
  }) : type = 'image',
       text = '',
       blob = data,
       data = null,
       name = null,
       input = null;

  /// Inline audio content: [data] is base64, [mimeType] required.
  const PromptBlock.audio({
    required String data,
    required String this.mimeType,
    this.uri,
  }) : type = 'audio',
       text = '',
       blob = data,
       data = null,
       name = null,
       input = null;

  /// An embedded resource (complete contents inline, avoids a
  /// round-trip; requires the agent's `embeddedContext` capability).
  /// [resource] is the raw {uri, text?|blob?, mimeType?} payload, carried
  /// verbatim (rule 4).
  const PromptBlock.resource(Map<String, dynamic> resource)
    : type = 'resource',
      text = '',
      uri = null,
      mimeType = null,
      blob = null,
      data = resource,
      name = null,
      input = null;

  /// A slash-command invocation. Per the spec, commands are sent as
  /// REGULAR TEXT blocks — "/name input" — not as a separate content
  /// type; the ContentBlock union has no command variant. [name] names
  /// the command from the agent's available_commands_update, [input] is
  /// the raw argument text.
  const PromptBlock.command(String this.name, [this.input])
    : type = 'text',
      text = input == null ? '/$name' : '/$name $input',
      uri = null,
      mimeType = null,
      blob = null,
      data = null;

  /// The wire content type. Always 'text' for [PromptBlock.command] —
  /// commands travel as text per the spec.
  final String type;
  final String text;
  final String? uri;
  final String? mimeType;
  final String? blob;
  final Map<String, dynamic>? data;
  final String? name;
  final String? input;

  /// name goes on the wire only for resource_link (schema-required);
  /// for commands it is local metadata.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    if (type == 'text') 'text': text,
    if (uri != null) 'uri': uri,
    if (mimeType != null) 'mimeType': mimeType,
    if (blob != null) 'data': blob,
    if (type == 'resource' && data != null) 'resource': data,
    if (type == 'resource_link' && name != null) 'name': name,
  };
}

/// Why a turn stopped — the stopReason vocabulary ACP defines. The agent
/// may send strings outside this list; compare against these constants,
/// never exhaust over them.
extension type const StopReason(String name) {
  static const StopReason endTurn = StopReason('end_turn');
  static const StopReason maxTurnRequests = StopReason('max_turn_requests');
  static const StopReason maxTokens = StopReason('max_tokens');

  /// The agent refused to continue; per the spec the prompt and
  /// everything after it won't be in the next context.
  static const StopReason refusal = StopReason('refusal');
  static const StopReason cancelled = StopReason('cancelled');

  /// v2: foreground work ended with a failure; the details ride the idle
  /// state_update's `error` field as the JSON-RPC error object.
  static const StopReason error = StopReason('error');
}

/// One entry of the agent's slash-command surface, from
/// `available_commands_update` — a thin typed view over the raw map
/// (rule 4: the raw stays the source of truth).
final class AvailableCommand {
  AvailableCommand(this.raw);

  final Map<String, dynamic> raw;

  String get name => raw['name'] as String? ?? '';
  String? get description => raw['description'] as String?;
  String? get inputHint => (raw['input'] as Map?)?['hint'] as String?;

  /// True when [buffer] is typing this command's name: either still in
  /// the name prefix ('/sta' matches 'status'), or past the name with
  /// arguments following ('/status now' still IS status).
  bool matches(String buffer) {
    final typed = buffer.startsWith('/') ? buffer.substring(1) : buffer;
    final space = typed.indexOf(' ');
    if (space == -1) return name.startsWith(typed);
    return name == typed.substring(0, space);
  }
}

/// Completion over the agent's command surface: pure string ergonomics
/// over what the protocol already provides — matching and hint plumbing
/// for an editor's input line.
extension AvailableCommandCompletion on List<AvailableCommand> {
  /// Commands [buffer] could be typing, most recently advertised first.
  /// An exact name match wins outright ('/status ' completes to nothing
  /// but status), so arguments don't pollute the list.
  List<AvailableCommand> complete(String buffer) {
    if (!buffer.startsWith('/')) return const [];
    final typed = buffer.substring(1);
    final space = typed.indexOf(' ');
    if (space != -1) {
      final name = typed.substring(0, space);
      return where((c) => c.name == name).toList();
    }
    return where((c) => c.name.startsWith(typed)).toList();
  }

  /// What an input box should show while [buffer] is being typed: the
  /// hint of the single command the buffer resolves to, else null —
  /// ambiguity means no confident placeholder.
  String? hintFor(String buffer) {
    final resolved = complete(buffer);
    if (resolved.length != 1) return null;
    final command = resolved.single;
    if (buffer.startsWith('/')) buffer = buffer.substring(1);
    // Past the name the hint has served its purpose; the user is on
    // arguments now.
    if (buffer.length > command.name.length) return null;
    return command.inputHint;
  }
}

/// One session from `session/list` — a thin typed view (rule 4).
final class SessionInfo {
  SessionInfo(this.raw);

  final Map<String, dynamic> raw;

  String get sessionId => raw['sessionId'] as String? ?? '';
  String get cwd => raw['cwd'] as String? ?? '';
  String? get title => raw['title'] as String?;
  String? get updatedAt => raw['updatedAt'] as String?;
  List<String> get additionalDirectories =>
      (raw['additionalDirectories'] as List?)?.cast<String>() ??
      const <String>[];
}

/// One authentication method from the initialize response — a thin typed
/// view over the union; [type] is 'agent' (also when absent, per the
/// schema default) or 'terminal'.
final class AuthMethod {
  AuthMethod(this.raw);

  final Map<String, dynamic> raw;

  /// v1 names the field `id`, v2 `methodId`; both resolve here.
  String get id => (raw['id'] ?? raw['methodId']) as String? ?? '';
  String get name => raw['name'] as String? ?? '';
  String get type => raw['type'] as String? ?? 'agent';
  String? get description => raw['description'] as String?;
  List<String>? get args => (raw['args'] as List?)?.cast<String>();
}

/// Decides a permission request. Must be quick: the agent is blocked
/// until the future completes.
typedef PermissionHandler =
    Future<PermissionDecision> Function(PermissionRequest request);

/// One MCP server provided by this client over the ACP connection.
/// This is the unstable ACP transport, not a stdio or HTTP MCP server.
final class AcpMcpServer {
  const AcpMcpServer({
    required this.name,
    required this.serverId,
    required this.handle,
  });

  final String name;
  final String serverId;
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic>? params,
    void Function(String method, Map<String, dynamic>? params) notify,
  )
  handle;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'acp',
    'name': name,
    'serverId': serverId,
  };
}

/// Client-side method handlers: the fs/terminal/elicitation surface the
/// agent may call when the client advertises it. Each is nullable; a null
/// handler means "not supported", and a well-behaved agent never calls
/// what initialize did not advertise (rule 6).
final class AcpClientHandlers {
  const AcpClientHandlers({
    this.onReadTextFile,
    this.onWriteTextFile,
    this.onCreateTerminal,
    this.onTerminalOutput,
    this.onReleaseTerminal,
    this.onWaitForTerminalExit,
    this.onKillTerminal,
    this.onElicitation,
    this.onElicitationComplete,
  });

  final Future<String> Function(ReadTextFileRequest request)? onReadTextFile;
  final Future<void> Function(WriteTextFileRequest request)? onWriteTextFile;

  /// Returns the new terminal's id.
  final Future<String> Function(CreateTerminalRequest request)?
  onCreateTerminal;
  final Future<TerminalOutputResponse> Function(TerminalOutputRequest request)?
  onTerminalOutput;
  final Future<void> Function(TerminalIdRequest request)? onReleaseTerminal;
  final Future<WaitForTerminalExitResponse> Function(
    TerminalOutputRequest request,
  )?
  onWaitForTerminalExit;
  final Future<void> Function(TerminalIdRequest request)? onKillTerminal;
  final Future<ElicitationResponseMsg> Function(ElicitationRequestMsg request)?
  onElicitation;
  final Future<void> Function(CompleteElicitationRequest request)?
  onElicitationComplete;
}

/// What the client advertises at initialize. Defaults advertise nothing —
/// the safe direction, since a capability the client does not honor
/// produces agents calling methods into a client that lied (rule 6).
final class AcpClientCapabilities {
  const AcpClientCapabilities({
    this.readTextFile = false,
    this.writeTextFile = false,
    this.terminal = false,
    this.elicitationForm = false,
    this.elicitationUrl = false,
    this.notices = false,
    this.compaction = false,
    this.configOptions = false,
    this.terminalAuth = false,
  });

  final bool readTextFile;
  final bool writeTextFile;
  final bool terminal;
  final bool elicitationForm;
  final bool elicitationUrl;

  /// `session.notices` — live user-facing `notice` updates.
  final bool notices;

  /// ID-addressed compaction updates.
  final bool compaction;

  /// Config-option extensions.
  final bool configOptions;

  /// Whether the client can run the agent as an interactive process for
  /// terminal-based authentication.
  final bool terminalAuth;

  /// The wire shape of the client capabilities. v1 used role-specific names
  /// (`clientCapabilities` with `fs`/`terminal` groups); v2 renames the
  /// container to `capabilities`, drops the fs/terminal execution surface,
  /// and marks support with objects instead of booleans. The v1-only groups
  /// are silently omitted on a v2 connection — advertising them there would
  /// be a lie the agent is allowed to act on.
  Map<String, dynamic> toJson({int version = kAcpProtocolVersionV1}) {
    if (version >= kAcpProtocolVersionV2) {
      return <String, dynamic>{
        'auth': <String, dynamic>{
          if (terminalAuth) 'terminal': <String, dynamic>{},
        },
        if (elicitationForm || elicitationUrl)
          'elicitation': <String, dynamic>{
            if (elicitationForm) 'form': <String, dynamic>{},
            if (elicitationUrl) 'url': <String, dynamic>{},
          },
      };
    }
    return <String, dynamic>{
      'auth': <String, dynamic>{'terminal': terminalAuth},
      'fs': <String, dynamic>{
        'readTextFile': readTextFile,
        'writeTextFile': writeTextFile,
      },
      'terminal': terminal,
      if (elicitationForm || elicitationUrl)
        'elicitation': <String, dynamic>{
          if (elicitationForm) 'form': <String, dynamic>{},
          if (elicitationUrl) 'url': <String, dynamic>{},
        },
      'session': <String, dynamic>{
        if (notices) 'notices': <String, dynamic>{},
        if (compaction) 'compaction': <String, dynamic>{},
        if (configOptions) 'configOptions': <String, dynamic>{},
      },
    };
  }
}

/// Drives one ACP agent process.
final class AcpClient {
  AcpClient(
    IAcpConnection connection, {
    PermissionHandler? onPermissionRequest,
    AcpClientHandlers handlers = const AcpClientHandlers(),
    this.capabilities = const AcpClientCapabilities(),
    List<AcpMcpServer> mcpServers = const [],
  }) {
    for (final server in mcpServers) {
      if (server.serverId.isEmpty ||
          server.name.isEmpty ||
          _mcpServers.containsKey(server.serverId)) {
        throw ArgumentError.value(
          server.serverId,
          'mcpServers',
          'MCP server names and IDs must be nonempty and IDs unique',
        );
      }
      _mcpServers[server.serverId] = server;
    }
    _wire = JsonRpcWire(connection);
    _agent = AcpWireCaller(
      _wire,
      AcpAppService(onPermissionRequest, handlers),
      onMcpMessage: _handleMcpMessage,
    );
    _commandSub = _wire.allUpdates.listen((record) {
      _trackCommands(parseSessionUpdate(record.$2));
    });
  }

  StreamSubscription<(String, Map<String, dynamic>)>? _commandSub;

  late final JsonRpcWire _wire;
  late final AcpWireCaller _agent;
  final _mcpServers = <String, AcpMcpServer>{};
  final _boundMcpServers = <String>{};
  bool _agentSupportsMcpAcp = false;

  Future<Map<String, dynamic>> _handleMcpMessage(
    Map<String, dynamic> message,
  ) async {
    final serverId = message['serverId'];
    final requestId = message['requestId'];
    final method = message['method'];
    if (serverId is! String ||
        requestId is! String ||
        method is! String ||
        method.isEmpty) {
      throw const JsonRpcException(-32602, 'Invalid MCP message');
    }
    final server = _boundMcpServers.contains(serverId)
        ? _mcpServers[serverId]
        : null;
    if (server == null) {
      throw const JsonRpcException(-32602, 'Unknown MCP server');
    }
    final rawParams = message['params'];
    if (rawParams != null && rawParams is! Map) {
      throw const JsonRpcException(-32602, 'Invalid MCP params');
    }
    var active = true;
    try {
      final outcome = await server.handle(
        method,
        (rawParams as Map?)?.cast<String, dynamic>(),
        (notificationMethod, notificationParams) {
          if (!active) {
            throw StateError('MCP request is no longer active');
          }
          _agent.notifyMcpMessage(<String, dynamic>{
            'serverId': serverId,
            'requestId': requestId,
            'method': notificationMethod,
            'params': ?notificationParams,
          });
        },
      );
      if (outcome.containsKey('result') && !outcome.containsKey('error')) {
        return <String, dynamic>{'result': outcome['result']};
      }
      final error = outcome['error'];
      if (!outcome.containsKey('result') &&
          error is Map &&
          error['code'] is int &&
          error['message'] is String) {
        return <String, dynamic>{'error': error};
      }
      throw const JsonRpcException(-32603, 'Invalid MCP outcome');
    } finally {
      active = false;
    }
  }

  List<Map<String, dynamic>>? _prepareMcpServers(
    List<Map<String, dynamic>>? servers,
  ) {
    if (servers == null) return null;
    final declared = <String>{};
    for (final server in servers) {
      if (server['type'] != 'acp') continue;
      if (!_agentSupportsMcpAcp) {
        throw StateError('Agent does not advertise MCP over ACP');
      }
      final id = server['serverId'];
      if (id is! String || !_mcpServers.containsKey(id)) {
        throw ArgumentError.value(
          id,
          'mcpServers',
          'ACP MCP server is not registered on this client',
        );
      }
      declared.add(id);
    }
    _boundMcpServers.addAll(declared);
    return servers;
  }

  /// What this client advertised at initialize.
  final AcpClientCapabilities capabilities;

  final _updates = StreamController<SessionUpdate>.broadcast();
  final _notices = StreamController<NoticeUpdate>.broadcast();

  /// Session updates streamed during prompt processing.
  Stream<SessionUpdate> get updates => _updates.stream;

  /// Every `session/update` the agent sends on this connection, with its
  /// session id — the feed recorders consume. Wider than [updates]: it
  /// keeps flowing outside prompt windows, and agents DO send updates
  /// there (measured: Kimi reports `usage_update` AFTER the `session/prompt`
  /// response, once the turn-scoped window is already closed).
  Stream<(String, Map<String, dynamic>)> get allUpdates => _wire.allUpdates;

  /// Agent notices (out-of-band information for the user).
  Stream<NoticeUpdate> get notices => _notices.stream;

  final _commands = StreamController<List<AvailableCommand>>.broadcast();
  List<AvailableCommand> _currentCommands = const [];

  /// The agent's slash-command surface, current state. Replaced (not
  /// diffed) on every `available_commands_update` — the spec lets the
  /// agent change the list at any time, and the latest list IS the list.
  List<AvailableCommand> get availableCommands => _currentCommands;

  /// Emits the new full list every time the agent updates it.
  Stream<List<AvailableCommand>> get commandsChanged => _commands.stream;

  /// Negotiates the protocol version and exchanges capabilities.
  /// Must be called before any session method.
  ///
  /// [protocolVersion] is the latest version this client supports; the
  /// agent selects the highest version at or below it. An agent selecting a
  /// higher version, or supporting none of the requested ones, fails with
  /// [AcpUnsupportedProtocolVersion]. All later calls on this client speak
  /// the selected version.
  Future<InitializeResult> initialize({
    int protocolVersion = kAcpProtocolVersion,
  }) async {
    try {
      final result = await _agent.initialize(
        InitializeRequest(
          protocolVersion: protocolVersion,
          clientCapabilities: capabilities.toJson(version: protocolVersion),
          clientInfo: const <String, dynamic>{
            'name': 'rpc_acp',
            'version': '0.1.0',
          },
        ),
      );
      if (result.protocolVersion > protocolVersion) {
        throw AcpUnsupportedProtocolVersion(protocolVersion, <int>[
          result.protocolVersion,
        ]);
      }
      _protocolVersion = result.protocolVersion;
      final advertised = result.agentCapabilities;
      final session = advertised['session'];
      final sessionMcp = session is Map ? session['mcp'] : null;
      final v1Mcp = advertised['mcpCapabilities'];
      _agentSupportsMcpAcp = result.protocolVersion >= 2
          ? sessionMcp is Map && sessionMcp['acp'] != null
          : v1Mcp is Map && v1Mcp['acp'] == true;
      return result;
    } on Object catch (error) {
      final typed = AcpUnsupportedProtocolVersion.fromRpcError(error);
      if (typed != null) throw typed;
      rethrow;
    }
  }

  int _protocolVersion = kAcpProtocolVersionV1;

  /// The protocol version selected on [initialize]. Everything after
  /// initialization speaks exactly this version.
  int get protocolVersion => _protocolVersion;

  /// ACP v2 makes `cwd` a required absolute path on session setup.
  void _requireV2Cwd(String? cwd) {
    if (_protocolVersion < kAcpProtocolVersionV2) return;
    if (cwd == null) {
      throw ArgumentError.value(
        cwd,
        'cwd',
        'ACP v2 requires an absolute working directory',
      );
    }
    if (!cwd.startsWith('/')) {
      throw ArgumentError.value(
        cwd,
        'cwd',
        'ACP v2 requires an absolute working directory',
      );
    }
  }

  /// Creates a new session and returns the full result: the session id
  /// plus whatever setup payload the agent sent (configOptions, the
  /// availableCommands surface, the v1 modes block) — what an editor
  /// needs to render its model/thinking/mode switchers.
  ///
  /// ACP v2 requires an absolute [cwd]; v1 leaves it optional. The guard
  /// applies to v2 connections only.
  Future<NewSessionResult> newSessionResult({
    String? cwd,
    List<String>? additionalDirectories,
    List<Map<String, dynamic>>? mcpServers,
  }) async {
    _requireV2Cwd(cwd);
    final result = await _agent.newSession(
      NewSessionRequest(
        cwd: cwd,
        additionalDirectories: additionalDirectories,
        mcpServers: _prepareMcpServers(mcpServers),
      ),
    );
    // v2 agents may advertise the initial command surface in the setup
    // response instead of a notification; track it the same way.
    final commands = result.availableCommands;
    if (commands != null) {
      _trackCommands(AvailableCommandsUpdate(const {}, commands));
    }
    return result;
  }

  /// Creates a new session and returns its id.
  Future<String> newSession({
    String? cwd,
    List<String>? additionalDirectories,
    List<Map<String, dynamic>>? mcpServers,
  }) => newSessionResult(
    cwd: cwd,
    additionalDirectories: additionalDirectories,
    mcpServers: mcpServers,
  ).then((result) => result.sessionId);

  Stream<SessionUpdateEvent> loadSessionStream(
    String sessionId, {
    required String cwd,
    List<String>? additionalDirectories,
    List<Map<String, dynamic>>? mcpServers,
  }) => _agent.loadSession(
    LoadSessionRequest(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
      mcpServers: _prepareMcpServers(mcpServers),
    ),
  );

  /// Loads an existing session of this agent process, streaming its
  /// history back as session updates. Only available when the agent
  /// advertised `loadSession`.
  Stream<SessionUpdate> loadSession(
    String sessionId, {
    required String cwd,
    List<String>? additionalDirectories,
    List<Map<String, dynamic>>? mcpServers,
  }) {
    _requireV2Cwd(cwd);
    return _agent
        .loadSession(
          LoadSessionRequest(
            sessionId: sessionId,
            cwd: cwd,
            additionalDirectories: additionalDirectories,
            mcpServers: _prepareMcpServers(mcpServers),
          ),
        )
        .map((event) => parseSessionUpdate(event.raw));
  }

  /// Resumes an existing session without replaying history. Only
  /// available when the agent advertised `sessionCapabilities.resume`.
  Future<ResumeSessionResult> resumeSession(
    String sessionId, {
    required String cwd,
    List<String>? additionalDirectories,
    List<Map<String, dynamic>>? mcpServers,
  }) async {
    _requireV2Cwd(cwd);
    final result = await _agent.resumeSession(
      ResumeSessionRequest(
        sessionId: sessionId,
        cwd: cwd,
        additionalDirectories: additionalDirectories,
        mcpServers: _prepareMcpServers(mcpServers),
      ),
    );
    final commands = result.availableCommands;
    if (commands != null) {
      _trackCommands(AvailableCommandsUpdate(const {}, commands));
    }
    return result;
  }

  /// Lists sessions known to the agent. Only available when the agent
  /// advertised `sessionCapabilities.list`.
  Future<ListSessionsResult> listSessions({String? cursor, String? cwd}) =>
      _agent.listSessions(ListSessionsRequest(cursor: cursor, cwd: cwd));

  /// Deletes a session from the agent's session list. Only available when
  /// the agent advertised `sessionCapabilities.delete`.
  Future<void> deleteSession(String sessionId) =>
      _agent.deleteSession(DeleteSessionRequest(sessionId: sessionId));

  /// Closes an active session and frees its resources. Only available
  /// when the agent advertised `sessionCapabilities.close`.
  Future<void> closeSession(String sessionId) =>
      _agent.closeSession(CloseSessionRequest(sessionId: sessionId));

  /// Authenticates against a method the agent advertised at initialize.
  /// Throws the agent's `auth_required` (-32000) error on failure.
  Future<void> authenticate(String methodId) =>
      _agent.authenticate(AuthenticateRequest(methodId: methodId));

  /// Logs out of the authenticated state; new sessions will require
  /// authentication again.
  Future<bool> logout() =>
      _agent.logout(const LogoutRequest()).then((r) => r.success);

  /// Switches the session's mode. Only available when the agent
  /// advertised `availableModes`. Removed in ACP v2 — modes are config
  /// options there; calling this on a v2 connection throws before the wire.
  Future<void> setMode(String sessionId, String modeId) {
    if (_protocolVersion >= kAcpProtocolVersionV2) {
      throw StateError(
        'session/set_mode was removed in ACP v2; use setConfigOption with '
        'a mode-category option',
      );
    }
    return _agent.setSessionMode(
      SetSessionModeRequest(sessionId: sessionId, modeId: modeId),
    );
  }

  /// Sets one session config option; [value] is the raw union payload —
  /// {'type': 'boolean', 'value': bool} or {'value': 'someId'}. Returns
  /// the agent's full option set afterwards.
  Future<List<Map<String, dynamic>>> setConfigOption(
    String sessionId,
    String configId,
    Map<String, dynamic> value,
  ) => _agent
      .setSessionConfigOption(
        SetSessionConfigOptionRequest(
          sessionId: sessionId,
          configId: configId,
          value: value,
        ),
      )
      .then((r) => r.configOptions);

  /// Sends one turn. Completes with the stop reason when the agent ends
  /// the turn; progress arrives on [updates] in the meantime.
  ///
  /// Raw half of [promptStream]: same wire events, but consumed for you.
  Future<String> prompt(String sessionId, List<PromptBlock> blocks) async {
    final stopReason = Completer<String>();
    final subscription =
        promptStream(sessionId, blocks.map((b) => b.toJson()).toList()).listen(
          (event) {
            if (event.isTerminal) {
              if (!stopReason.isCompleted) {
                stopReason.complete(event.stopReason);
              }
              return;
            }
            final update = parseSessionUpdate(event.raw);
            if (update is NoticeUpdate) {
              _notices.add(update);
            }
            _trackCommands(update);
            _updates.add(update);
          },
          onError: stopReason.completeError,
          onDone: () {
            if (!stopReason.isCompleted) {
              stopReason.completeError(
                StateError('prompt stream ended without a stop reason'),
              );
            }
          },
        );

    try {
      return await stopReason.future;
    } finally {
      await subscription.cancel();
    }
  }

  /// Every turn update, followed by a terminal event with the stop reason.
  Stream<SessionUpdateEvent> promptStream(
    String sessionId,
    List<Map<String, dynamic>> blocks,
  ) => _agent.prompt(PromptRequest(sessionId: sessionId, blocks: blocks));

  /// Interrupts the current turn of [sessionId]. Fire-and-forget: the
  /// confirmation that the turn actually stopped only exists as the prompt
  /// stream ending with a stop reason.
  Future<void> cancel(String sessionId) async {
    await _agent.cancel(CancelRequest(sessionId: sessionId));
  }

  /// Cancels one tool call the agent advertised as cancellable (v2
  /// `tool_call_update.capabilities.cancel`). Throws before the wire on a
  /// v1 connection; the agent confirms with a final-status
  /// `tool_call_update`, usually `cancelled`.
  Future<void> cancelToolCall(String sessionId, String toolCallId) {
    if (_protocolVersion < kAcpProtocolVersionV2) {
      throw StateError(
        'tool_call/cancel requires ACP v2; this connection negotiated v'
        '$_protocolVersion',
      );
    }
    return _agent
        .cancelToolCall(
          CancelToolCallRequest(sessionId: sessionId, toolCallId: toolCallId),
        )
        .then((_) {});
  }

  /// Stops one Agent-owned display terminal the agent opted into
  /// cancelling (v2 `terminal/cancel`). Throws before the wire on a v1
  /// connection.
  Future<void> cancelTerminal(String sessionId, String terminalId) {
    if (_protocolVersion < kAcpProtocolVersionV2) {
      throw StateError(
        'terminal/cancel requires ACP v2; this connection negotiated v'
        '$_protocolVersion',
      );
    }
    return _agent
        .cancelTerminal(
          CancelTerminalRequest(sessionId: sessionId, terminalId: terminalId),
        )
        .then((_) {});
  }

  void _trackCommands(SessionUpdate update) {
    if (update case AvailableCommandsUpdate(:final commands)) {
      _currentCommands = <AvailableCommand>[
        for (final raw in commands) AvailableCommand(raw),
      ];
      if (!_commands.isClosed) _commands.add(_currentCommands);
    }
  }

  /// Closes the protocol connection and its update streams.
  Future<void> dispose() async {
    await _commandSub?.cancel();
    await _wire.dispose();
    if (!_updates.isClosed) await _updates.close();
    if (!_notices.isClosed) await _notices.close();
    if (!_commands.isClosed) await _commands.close();
  }
}

/// Handles agent-originated requests on the application side of ACP.
final class AcpAppService {
  AcpAppService(this._handler, this._handlers);

  final PermissionHandler? _handler;
  final AcpClientHandlers _handlers;

  Future<PermissionOutcome> onRequestPermission(
    PermissionRequestMsg request,
  ) async {
    final handler = _handler ?? _approveFirstOption;
    final decision = await handler(
      PermissionRequest(
        request.sessionId,
        request.toolCall,
        request.options
            .map(
              (o) => PermissionOption(
                o['optionId'] as String? ?? '',
                o['name'] as String? ?? '',
                o['kind'] as String?,
              ),
            )
            .toList(),
        title: request.title,
        subject: request.subject,
      ),
    );

    return switch (decision) {
      SelectOption(:final optionId) => PermissionOutcome.selected(optionId),
      PermissionCancelled() => PermissionOutcome.cancelled(),
    };
  }

  /// A client-side method the client did not advertise is the agent
  /// calling into a client that lied (rule 6). Refuse loudly; a hang
  /// would read to the agent as a slow human.
  Never _notAdvertised(String method) =>
      throw JsonRpcException(-32601, 'client did not advertise $method');

  Future<ReadTextFileResponse> onReadTextFile(
    ReadTextFileRequest request,
  ) async {
    final handler =
        _handlers.onReadTextFile ?? _notAdvertised('fs/read_text_file');
    return ReadTextFileResponse(content: await handler(request));
  }

  Future<void> onWriteTextFile(WriteTextFileRequest request) async {
    final handler =
        _handlers.onWriteTextFile ?? _notAdvertised('fs/write_text_file');
    await handler(request);
  }

  Future<CreateTerminalResponse> onCreateTerminal(
    CreateTerminalRequest request,
  ) async {
    final handler =
        _handlers.onCreateTerminal ?? _notAdvertised('terminal/create');
    return CreateTerminalResponse(terminalId: await handler(request));
  }

  Future<TerminalOutputResponse> onTerminalOutput(
    TerminalOutputRequest request,
  ) {
    final handler =
        _handlers.onTerminalOutput ?? _notAdvertised('terminal/output');
    return handler(request);
  }

  Future<void> onReleaseTerminal(TerminalIdRequest request) async {
    final handler =
        _handlers.onReleaseTerminal ?? _notAdvertised('terminal/release');
    await handler(request);
  }

  Future<WaitForTerminalExitResponse> onWaitForTerminalExit(
    TerminalOutputRequest request,
  ) {
    final handler =
        _handlers.onWaitForTerminalExit ??
        _notAdvertised('terminal/wait_for_exit');
    return handler(request);
  }

  Future<void> onKillTerminal(TerminalIdRequest request) async {
    final handler = _handlers.onKillTerminal ?? _notAdvertised('terminal/kill');
    await handler(request);
  }

  Future<ElicitationResponseMsg> onCreateElicitation(
    ElicitationRequestMsg request,
  ) {
    final handler =
        _handlers.onElicitation ?? _notAdvertised('elicitation/create');
    return handler(request);
  }

  Future<void> onCompleteElicitation(CompleteElicitationRequest request) async {
    final handler = _handlers.onElicitationComplete;
    if (handler == null) _notAdvertised('elicitation/complete');
    await handler(request);
  }

  /// Unsafe default: approves the first offered option. Exists so a
  /// driver without a handler still completes; pass [PermissionHandler]
  /// to decide for real.
  Future<PermissionDecision> _approveFirstOption(
    PermissionRequest request,
  ) async {
    if (request.options.isEmpty) return const PermissionCancelled();
    return SelectOption(request.options.first.optionId);
  }
}
