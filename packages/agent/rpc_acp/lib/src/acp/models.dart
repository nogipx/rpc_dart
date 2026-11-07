// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Typed ACP protocol values used by the client convenience API.
/// The RPC tunnel carries complete JSON-RPC maps and does not encode these
/// values as a second contract.
library;

/// `initialize` request.
final class InitializeRequest {
  const InitializeRequest({
    required this.protocolVersion,
    required this.clientCapabilities,
    this.clientInfo,
  });

  final int protocolVersion;
  final Map<String, dynamic> clientCapabilities;
  final Map<String, dynamic>? clientInfo;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'protocolVersion': protocolVersion,
    'clientCapabilities': clientCapabilities,
    'clientInfo': ?clientInfo,
  };

  factory InitializeRequest.fromJson(Map<String, dynamic> json) =>
      InitializeRequest(
        protocolVersion: json['protocolVersion'] as int? ?? 1,
        clientCapabilities:
            (json['clientCapabilities'] as Map?)?.cast<String, dynamic>() ??
            const {},
        clientInfo: (json['clientInfo'] as Map?)?.cast<String, dynamic>(),
      );
}

/// `initialize` result.
///
/// The Dart shape is version-neutral; the wire shape is not. [toJson] emits
/// the v2 field names (`capabilities`/`info`) when [protocolVersion] is 2
/// and the v1 names (`agentCapabilities`/`agentInfo`) otherwise;
/// [InitializeResult.fromJson] reads whichever the peer sent, so a caller
/// always gets a populated object no matter which version was negotiated.
final class InitializeResult {
  const InitializeResult({
    required this.protocolVersion,
    required this.agentCapabilities,
    this.agentInfo,
    this.authMethods = const [],
  });

  final int protocolVersion;
  final Map<String, dynamic> agentCapabilities;
  final Map<String, dynamic>? agentInfo;
  final List<Map<String, dynamic>> authMethods;

  bool get canLoadSession => agentCapabilities['loadSession'] == true;

  bool get isV2 => protocolVersion >= 2;

  Map<String, dynamic> toJson() => isV2
      ? <String, dynamic>{
          'protocolVersion': protocolVersion,
          'capabilities': agentCapabilities,
          'info': ?agentInfo,
          'authMethods': authMethods,
        }
      : <String, dynamic>{
          'protocolVersion': protocolVersion,
          'agentCapabilities': agentCapabilities,
          'agentInfo': ?agentInfo,
          'authMethods': authMethods,
        };

  factory InitializeResult.fromJson(Map<String, dynamic> json) {
    final version = json['protocolVersion'] as int? ?? 0;
    return InitializeResult(
      protocolVersion: version,
      agentCapabilities:
          (json['agentCapabilities'] as Map?)?.cast<String, dynamic>() ??
          (json['capabilities'] as Map?)?.cast<String, dynamic>() ??
          const {},
      agentInfo:
          (json['agentInfo'] as Map?)?.cast<String, dynamic>() ??
          (json['info'] as Map?)?.cast<String, dynamic>(),
      authMethods:
          (json['authMethods'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
    );
  }
}

/// `session/new` request.
final class NewSessionRequest {
  const NewSessionRequest({
    this.cwd,
    this.additionalDirectories,
    this.mcpServers,
  });

  final String? cwd;
  final List<String>? additionalDirectories;

  /// MCP servers for the agent to connect to.
  ///
  /// Never omitted on the wire: the ACP schema marks it optional, but at
  /// least one major agent (Kimi Code CLI) validates it as required and
  /// answers -32602 when it is absent.
  final List<Map<String, dynamic>>? mcpServers;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cwd': ?cwd,
    'additionalDirectories': ?additionalDirectories,
    'mcpServers': mcpServers ?? const <Map<String, dynamic>>[],
  };

  factory NewSessionRequest.fromJson(Map<String, dynamic> json) =>
      NewSessionRequest(
        cwd: json['cwd'] as String?,
        additionalDirectories: (json['additionalDirectories'] as List?)
            ?.cast<String>(),
        mcpServers: (json['mcpServers'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
      );
}

/// `session/new` result. v2 agents may include the session's initial
/// `configOptions` and `availableCommands`; both are carried verbatim when
/// present (rule 4). `modes` is the v1 mode surface (currentModeId +
/// availableModes) — carried verbatim too, for v1 editors' mode switchers.
final class NewSessionResult {
  const NewSessionResult({
    required this.sessionId,
    this.configOptions,
    this.availableCommands,
    this.modes,
  });

  final String sessionId;
  final List<Map<String, dynamic>>? configOptions;
  final List<Map<String, dynamic>>? availableCommands;

  /// The v1 `modes` payload, verbatim: `{currentModeId, availableModes}`.
  final Map<String, dynamic>? modes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'configOptions': ?configOptions,
    'availableCommands': ?availableCommands,
    'modes': ?modes,
  };

  factory NewSessionResult.fromJson(Map<String, dynamic> json) =>
      NewSessionResult(
        sessionId: json['sessionId'] as String,
        configOptions: (json['configOptions'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
        availableCommands: (json['availableCommands'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
        modes: (json['modes'] as Map?)?.cast<String, dynamic>(),
      );
}

/// `session/prompt` request: one turn into a session.
final class PromptRequest {
  const PromptRequest({required this.sessionId, required this.blocks});

  final String sessionId;

  /// Prompt content blocks, already in ACP JSON shape ({type: text, ...}).
  final List<Map<String, dynamic>> blocks;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'blocks': blocks,
  };

  factory PromptRequest.fromJson(Map<String, dynamic> json) => PromptRequest(
    sessionId: json['sessionId'] as String,
    blocks:
        (json['blocks'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const [],
  );
}

/// `session/cancel` request.
final class CancelRequest {
  const CancelRequest({required this.sessionId});

  final String sessionId;

  Map<String, dynamic> toJson() => <String, dynamic>{'sessionId': sessionId};

  factory CancelRequest.fromJson(Map<String, dynamic> json) =>
      CancelRequest(sessionId: json['sessionId'] as String);
}

/// `session/load` request.
final class LoadSessionRequest {
  const LoadSessionRequest({
    required this.sessionId,
    required this.cwd,
    this.additionalDirectories,
    this.mcpServers,
  });

  final String sessionId;
  final String cwd;
  final List<String>? additionalDirectories;

  /// Never omitted on the wire (see [NewSessionRequest.mcpServers]).
  final List<Map<String, dynamic>>? mcpServers;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'cwd': cwd,
    'additionalDirectories': ?additionalDirectories,
    'mcpServers': mcpServers ?? const <Map<String, dynamic>>[],
  };

  factory LoadSessionRequest.fromJson(Map<String, dynamic> json) =>
      LoadSessionRequest(
        sessionId: json['sessionId'] as String,
        cwd: json['cwd'] as String? ?? '',
        additionalDirectories: (json['additionalDirectories'] as List?)
            ?.cast<String>(),
        mcpServers: (json['mcpServers'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
      );
}

/// `session/resume` request.
final class ResumeSessionRequest {
  const ResumeSessionRequest({
    required this.sessionId,
    required this.cwd,
    this.additionalDirectories,
    this.mcpServers,
  });

  final String sessionId;
  final String cwd;
  final List<String>? additionalDirectories;
  final List<Map<String, dynamic>>? mcpServers;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'cwd': cwd,
    'additionalDirectories': ?additionalDirectories,
    'mcpServers': ?mcpServers,
  };

  factory ResumeSessionRequest.fromJson(Map<String, dynamic> json) =>
      ResumeSessionRequest(
        sessionId: json['sessionId'] as String,
        cwd: json['cwd'] as String? ?? '',
        additionalDirectories: (json['additionalDirectories'] as List?)
            ?.cast<String>(),
        mcpServers: (json['mcpServers'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
      );
}

/// `session/resume` result — initial mode state and config options, both
/// optional in the schema and carried verbatim (rule 4).
final class ResumeSessionResult {
  const ResumeSessionResult({
    this.modes,
    this.configOptions,
    this.availableCommands,
  });

  final Map<String, dynamic>? modes;
  final List<Map<String, dynamic>>? configOptions;

  /// v2 setup responses may carry the session's initial commands.
  final List<Map<String, dynamic>>? availableCommands;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'modes': ?modes,
    'configOptions': ?configOptions,
    'availableCommands': ?availableCommands,
  };

  factory ResumeSessionResult.fromJson(Map<String, dynamic> json) =>
      ResumeSessionResult(
        modes: (json['modes'] as Map?)?.cast<String, dynamic>(),
        configOptions: (json['configOptions'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
        availableCommands: (json['availableCommands'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(),
      );
}

/// `session/list` request.
final class ListSessionsRequest {
  const ListSessionsRequest({this.cursor, this.cwd});

  final String? cursor;
  final String? cwd;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cursor': ?cursor,
    'cwd': ?cwd,
  };

  factory ListSessionsRequest.fromJson(Map<String, dynamic> json) =>
      ListSessionsRequest(
        cursor: json['cursor'] as String?,
        cwd: json['cwd'] as String?,
      );
}

/// `session/list` result. Sessions are raw maps on purpose (rule 4):
/// SessionInfo is metadata the agent owns; what a consumer routes on
/// (sessionId, cwd, title, updatedAt) it can read without this package
/// becoming the schema's keeper.
final class ListSessionsResult {
  const ListSessionsResult({required this.sessions, this.nextCursor});

  final List<Map<String, dynamic>> sessions;
  final String? nextCursor;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessions': sessions,
    'nextCursor': ?nextCursor,
  };

  factory ListSessionsResult.fromJson(Map<String, dynamic> json) =>
      ListSessionsResult(
        sessions:
            (json['sessions'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            const [],
        nextCursor: json['nextCursor'] as String?,
      );
}

/// `session/delete` request.
final class DeleteSessionRequest {
  const DeleteSessionRequest({required this.sessionId});

  final String sessionId;

  Map<String, dynamic> toJson() => <String, dynamic>{'sessionId': sessionId};

  factory DeleteSessionRequest.fromJson(Map<String, dynamic> json) =>
      DeleteSessionRequest(sessionId: json['sessionId'] as String);
}

/// `session/close` request.
final class CloseSessionRequest {
  const CloseSessionRequest({required this.sessionId});

  final String sessionId;

  Map<String, dynamic> toJson() => <String, dynamic>{'sessionId': sessionId};

  factory CloseSessionRequest.fromJson(Map<String, dynamic> json) =>
      CloseSessionRequest(sessionId: json['sessionId'] as String);
}

/// A `session/update` as it travels through the contract.
///
/// [raw] is the update object verbatim (rule 4 of the design); typed access
/// is a view layered on top, not a parse. [stopReason] is non-null only on
/// the terminal event that ends a prompt stream.
final class SessionUpdateEvent {
  const SessionUpdateEvent(this.raw, {this.stopReason});

  final Map<String, dynamic> raw;
  final String? stopReason;

  bool get isTerminal => stopReason != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'raw': raw,
    'stopReason': ?stopReason,
  };

  factory SessionUpdateEvent.fromJson(Map<String, dynamic> json) =>
      SessionUpdateEvent(
        (json['raw'] as Map?)?.cast<String, dynamic>() ?? const {},
        stopReason: json['stopReason'] as String?,
      );
}

/// A permission request as it crosses the contract (agent -> app).
///
/// v1 agents send a bare `toolCall`; v2 restructures the request around a
/// required `title`, optional `description`, and a tagged `subject` union
/// (`tool_call` | `command`). [toolCall] stays the v1 field and is also
/// filled from a v2 `subject: {type: 'tool_call'}` so v1-shaped consumers
/// keep working; v2-only consumers read [title]/[subject].
final class PermissionRequestMsg {
  const PermissionRequestMsg({
    required this.sessionId,
    this.toolCall = const <String, dynamic>{},
    this.options = const [],
    this.title,
    this.description,
    this.subject,
  });

  final String sessionId;
  final Map<String, dynamic> toolCall;
  final List<Map<String, dynamic>> options;
  final String? title;
  final String? description;

  /// The v2 subject union, carried verbatim; null when absent (v1) or when
  /// the request needs no structured context.
  final Map<String, dynamic>? subject;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'toolCall': toolCall,
    'options': options,
    'title': ?title,
    'description': ?description,
    'subject': ?subject,
  };

  factory PermissionRequestMsg.fromJson(Map<String, dynamic> json) {
    final subject = (json['subject'] as Map?)?.cast<String, dynamic>();
    return PermissionRequestMsg(
      sessionId: json['sessionId'] as String,
      toolCall:
          (json['toolCall'] as Map?)?.cast<String, dynamic>() ??
          (subject != null && subject['type'] == 'tool_call'
              ? (subject['toolCall'] as Map?)?.cast<String, dynamic>() ??
                    const <String, dynamic>{}
              : const <String, dynamic>{}),
      options:
          (json['options'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
      title: json['title'] as String?,
      description: json['description'] as String?,
      subject: subject,
    );
  }
}

/// The app's answer to a permission request.
final class PermissionOutcome {
  const PermissionOutcome._({this.optionId, this.cancelled = false});

  factory PermissionOutcome.selected(String optionId) =>
      PermissionOutcome._(optionId: optionId);

  factory PermissionOutcome.cancelled() =>
      const PermissionOutcome._(cancelled: true);

  /// The chosen option id; null when [cancelled].
  final String? optionId;
  final bool cancelled;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'optionId': ?optionId,
    'cancelled': cancelled,
  };

  factory PermissionOutcome.fromJson(Map<String, dynamic> json) =>
      json['cancelled'] == true
      ? PermissionOutcome.cancelled()
      : PermissionOutcome.selected(json['optionId'] as String);
}

// ---------------------------------------------------------------------------
// Client-side messages (agent -> app): fs, terminal, elicitation
// ---------------------------------------------------------------------------

/// `fs/read_text_file` request.
final class ReadTextFileRequest {
  const ReadTextFileRequest({
    required this.sessionId,
    required this.path,
    this.limit,
    this.line,
  });

  final String sessionId;
  final String path;

  /// Maximum number of lines to read.
  final int? limit;

  /// 1-based line to start from.
  final int? line;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'path': path,
    'limit': ?limit,
    'line': ?line,
  };

  factory ReadTextFileRequest.fromJson(Map<String, dynamic> json) =>
      ReadTextFileRequest(
        sessionId: json['sessionId'] as String,
        path: json['path'] as String? ?? '',
        limit: json['limit'] as int?,
        line: json['line'] as int?,
      );
}

/// `fs/read_text_file` response.
final class ReadTextFileResponse {
  const ReadTextFileResponse({required this.content});

  final String content;

  Map<String, dynamic> toJson() => <String, dynamic>{'content': content};

  factory ReadTextFileResponse.fromJson(Map<String, dynamic> json) =>
      ReadTextFileResponse(content: json['content'] as String? ?? '');
}

/// `fs/write_text_file` request.
final class WriteTextFileRequest {
  const WriteTextFileRequest({
    required this.sessionId,
    required this.path,
    required this.content,
  });

  final String sessionId;
  final String path;
  final String content;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'path': path,
    'content': content,
  };

  factory WriteTextFileRequest.fromJson(Map<String, dynamic> json) =>
      WriteTextFileRequest(
        sessionId: json['sessionId'] as String,
        path: json['path'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
}

/// `terminal/create` request.
final class CreateTerminalRequest {
  const CreateTerminalRequest({
    required this.sessionId,
    required this.command,
    this.args,
    this.cwd,
    this.env,
    this.outputByteLimit,
  });

  final String sessionId;
  final String command;
  final List<String>? args;
  final String? cwd;

  /// Environment entries in the schema's {name, value} shape, verbatim.
  final List<Map<String, dynamic>>? env;
  final int? outputByteLimit;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'command': command,
    'args': ?args,
    'cwd': ?cwd,
    'env': ?env,
    'outputByteLimit': ?outputByteLimit,
  };

  factory CreateTerminalRequest.fromJson(Map<String, dynamic> json) =>
      CreateTerminalRequest(
        sessionId: json['sessionId'] as String,
        command: json['command'] as String? ?? '',
        args: (json['args'] as List?)?.cast<String>(),
        cwd: json['cwd'] as String?,
        env: (json['env'] as List?)?.whereType<Map<String, dynamic>>().toList(),
        outputByteLimit: json['outputByteLimit'] as int?,
      );
}

/// `terminal/create` response.
final class CreateTerminalResponse {
  const CreateTerminalResponse({required this.terminalId});

  final String terminalId;

  Map<String, dynamic> toJson() => <String, dynamic>{'terminalId': terminalId};

  factory CreateTerminalResponse.fromJson(Map<String, dynamic> json) =>
      CreateTerminalResponse(terminalId: json['terminalId'] as String);
}

/// `terminal/output` request (also used for `terminal/wait_for_exit`,
/// which carries the same sessionId + terminalId pair).
final class TerminalOutputRequest {
  const TerminalOutputRequest({
    required this.sessionId,
    required this.terminalId,
  });

  final String sessionId;
  final String terminalId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'terminalId': terminalId,
  };

  factory TerminalOutputRequest.fromJson(Map<String, dynamic> json) =>
      TerminalOutputRequest(
        sessionId: json['sessionId'] as String,
        terminalId: json['terminalId'] as String,
      );
}

/// `terminal/output` response.
final class TerminalOutputResponse {
  const TerminalOutputResponse({
    required this.output,
    required this.truncated,
    this.exitStatus,
  });

  final String output;
  final bool truncated;

  /// Verbatim {exitCode, signal} map when the command has completed.
  final Map<String, dynamic>? exitStatus;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'output': output,
    'truncated': truncated,
    'exitStatus': ?exitStatus,
  };

  factory TerminalOutputResponse.fromJson(Map<String, dynamic> json) =>
      TerminalOutputResponse(
        output: json['output'] as String? ?? '',
        truncated: json['truncated'] as bool? ?? false,
        exitStatus: (json['exitStatus'] as Map?)?.cast<String, dynamic>(),
      );
}

/// `terminal/release` / `terminal/kill` request: the session + terminal
/// pair names the terminal to act on.
final class TerminalIdRequest {
  const TerminalIdRequest({required this.sessionId, required this.terminalId});

  final String sessionId;
  final String terminalId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'terminalId': terminalId,
  };

  factory TerminalIdRequest.fromJson(Map<String, dynamic> json) =>
      TerminalIdRequest(
        sessionId: json['sessionId'] as String,
        terminalId: json['terminalId'] as String,
      );
}

/// `terminal/wait_for_exit` response.
final class WaitForTerminalExitResponse {
  const WaitForTerminalExitResponse({this.exitCode, this.signal});

  final int? exitCode;
  final String? signal;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'exitCode': ?exitCode,
    'signal': ?signal,
  };

  factory WaitForTerminalExitResponse.fromJson(Map<String, dynamic> json) =>
      WaitForTerminalExitResponse(
        exitCode: json['exitCode'] as int?,
        signal: json['signal'] as String?,
      );
}

/// `elicitation/create` request, raw on purpose: the schema is a union
/// (form / url / other) tied to a session or a request, and rule 4 says
/// the union grows. The app routes on `mode` and reads what it needs.
final class ElicitationRequestMsg {
  const ElicitationRequestMsg(this.raw);

  final Map<String, dynamic> raw;

  String? get mode => raw['mode'] as String?;
  String? get sessionId => raw['sessionId'] as String?;

  Map<String, dynamic> toJson() => raw;

  factory ElicitationRequestMsg.fromJson(Map<String, dynamic> json) =>
      ElicitationRequestMsg(json);
}

/// `elicitation/create` response, raw for the same reason: accept /
/// decline / cancel / other is the agent's union, not ours.
final class ElicitationResponseMsg {
  const ElicitationResponseMsg(this.raw);

  factory ElicitationResponseMsg.accept([Map<String, dynamic>? content]) =>
      ElicitationResponseMsg(<String, dynamic>{
        'action': 'accept',
        'content': ?content,
      });

  factory ElicitationResponseMsg.decline() =>
      const ElicitationResponseMsg(<String, dynamic>{'action': 'decline'});

  factory ElicitationResponseMsg.cancel() =>
      const ElicitationResponseMsg(<String, dynamic>{'action': 'cancel'});

  final Map<String, dynamic> raw;

  String? get action => raw['action'] as String?;

  Map<String, dynamic> toJson() => raw;

  factory ElicitationResponseMsg.fromJson(Map<String, dynamic> json) =>
      ElicitationResponseMsg(json);
}

/// `authenticate` request.
final class AuthenticateRequest {
  const AuthenticateRequest({required this.methodId});

  final String methodId;

  Map<String, dynamic> toJson() => <String, dynamic>{'methodId': methodId};

  factory AuthenticateRequest.fromJson(Map<String, dynamic> json) =>
      AuthenticateRequest(methodId: json['methodId'] as String);
}

/// `session/set_mode` request.
final class SetSessionModeRequest {
  const SetSessionModeRequest({required this.sessionId, required this.modeId});

  final String sessionId;
  final String modeId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'modeId': modeId,
  };

  factory SetSessionModeRequest.fromJson(Map<String, dynamic> json) =>
      SetSessionModeRequest(
        sessionId: json['sessionId'] as String,
        modeId: json['modeId'] as String,
      );
}

/// `session/set_mode` result — empty in the schema.
final class SetSessionModeResult {
  const SetSessionModeResult();

  Map<String, dynamic> toJson() => const <String, dynamic>{};

  factory SetSessionModeResult.fromJson(Map<String, dynamic> json) =>
      const SetSessionModeResult();
}

/// `session/set_config_option` request. [value] is the raw union payload:
/// {'type': 'boolean', 'value': bool} or {'value': 'someId'} — sent
/// verbatim (rule 4), the default value_id variant included.
final class SetSessionConfigOptionRequest {
  const SetSessionConfigOptionRequest({
    required this.sessionId,
    required this.configId,
    required this.value,
  });

  final String sessionId;
  final String configId;
  final Map<String, dynamic> value;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'configId': configId,
    ...value,
  };

  factory SetSessionConfigOptionRequest.fromJson(Map<String, dynamic> json) {
    final rest = Map<String, dynamic>.of(json)
      ..remove('sessionId')
      ..remove('configId');
    return SetSessionConfigOptionRequest(
      sessionId: json['sessionId'] as String,
      configId: json['configId'] as String,
      value: rest,
    );
  }
}

/// `session/set_config_option` result: the full option set afterwards,
/// raw for the same union reason.
final class SetSessionConfigOptionResult {
  const SetSessionConfigOptionResult({this.configOptions = const []});

  final List<Map<String, dynamic>> configOptions;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'configOptions': configOptions,
  };

  factory SetSessionConfigOptionResult.fromJson(Map<String, dynamic> json) =>
      SetSessionConfigOptionResult(
        configOptions:
            (json['configOptions'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            const [],
      );
}

/// `logout` request — empty; exists because the generator requires a
/// request parameter.
final class LogoutRequest {
  const LogoutRequest();

  Map<String, dynamic> toJson() => const <String, dynamic>{};

  factory LogoutRequest.fromJson(Map<String, dynamic> json) =>
      const LogoutRequest();
}

/// `logout` result.
final class LogoutResult {
  const LogoutResult({this.success = true});

  final bool success;

  Map<String, dynamic> toJson() => <String, dynamic>{'success': success};

  factory LogoutResult.fromJson(Map<String, dynamic> json) =>
      LogoutResult(success: json['success'] as bool? ?? true);
}

/// `elicitation/complete` notification body.
final class CompleteElicitationRequest {
  const CompleteElicitationRequest({required this.elicitationId});

  final String elicitationId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'elicitationId': elicitationId,
  };

  factory CompleteElicitationRequest.fromJson(Map<String, dynamic> json) =>
      CompleteElicitationRequest(
        elicitationId: json['elicitationId'] as String,
      );
}

/// `tool_call/cancel` request (ACP v2).
final class CancelToolCallRequest {
  const CancelToolCallRequest({
    required this.sessionId,
    required this.toolCallId,
  });

  final String sessionId;
  final String toolCallId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'toolCallId': toolCallId,
  };

  factory CancelToolCallRequest.fromJson(Map<String, dynamic> json) =>
      CancelToolCallRequest(
        sessionId: json['sessionId'] as String,
        toolCallId: json['toolCallId'] as String,
      );
}

/// `terminal/cancel` request (ACP v2).
final class CancelTerminalRequest {
  const CancelTerminalRequest({
    required this.sessionId,
    required this.terminalId,
  });

  final String sessionId;
  final String terminalId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sessionId': sessionId,
    'terminalId': terminalId,
  };

  factory CancelTerminalRequest.fromJson(Map<String, dynamic> json) =>
      CancelTerminalRequest(
        sessionId: json['sessionId'] as String,
        terminalId: json['terminalId'] as String,
      );
}
