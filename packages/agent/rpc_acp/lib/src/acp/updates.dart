// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Typed surface over ACP `session/update` notifications.
///
/// Rule 4 of the design: every variant keeps the original update map in
/// [SessionUpdate.raw]. Typed fields exist only for what a consumer routes
/// on; anything the schema adds later still arrives intact.
library;

/// One `session/update` notification body (the `update` object).
sealed class SessionUpdate {
  const SessionUpdate(this.raw);

  /// The update exactly as the agent sent it.
  final Map<String, dynamic> raw;
}

/// A chunk of the user's message being echoed back.
final class UserMessageChunk extends SessionUpdate {
  UserMessageChunk(super.raw, this.text, this.messageId);

  final String text;
  final String? messageId;
}

/// A chunk of the agent's response being streamed.
final class AgentMessageChunk extends SessionUpdate {
  AgentMessageChunk(super.raw, this.text, this.messageId);

  final String text;
  final String? messageId;
}

/// A chunk of the agent's internal reasoning being streamed.
final class AgentThoughtChunk extends SessionUpdate {
  AgentThoughtChunk(super.raw, this.text, this.messageId);

  final String text;
  final String? messageId;
}

/// A new tool call has been initiated.
final class ToolCallStart extends SessionUpdate {
  ToolCallStart(super.raw, this.toolCallId, this.title, this.kind, this.name);

  final String toolCallId;
  final String title;
  final String? kind;
  final String? name;
}

/// Status or results of a tool call changed.
final class ToolCallChange extends SessionUpdate {
  ToolCallChange(
    super.raw,
    this.toolCallId,
    this.status,
    this.title,
    this.kind,
  );

  final String toolCallId;

  /// pending | running | completed | failed (v2 adds cancelled; the raw
  /// value is carried, so values outside this list still arrive).
  final String? status;
  final String? title;
  final String? kind;

  /// True when the agent advertised this tool call as client-cancellable
  /// (v2 `tool_call_update.capabilities.cancel`). Cancelling is a
  /// [AcpClient.cancelToolCall] request; it must not be sent otherwise.
  bool get canCancel =>
      ((raw['capabilities'] as Map?)?.cast<String, dynamic>())?['cancel']
          is Map;
}

/// The agent's execution plan for a complex task.
final class PlanUpdate extends SessionUpdate {
  PlanUpdate(super.raw, this.entries);

  final List<Map<String, dynamic>> entries;
}

/// Available commands (agent's slash-command surface) have changed.
final class AvailableCommandsUpdate extends SessionUpdate {
  AvailableCommandsUpdate(super.raw, this.commands);

  final List<Map<String, dynamic>> commands;
}

/// The current session mode has changed (e.g. plan vs. act).
final class CurrentModeUpdate extends SessionUpdate {
  CurrentModeUpdate(super.raw, this.modeId);

  final String modeId;
}

/// Session configuration options have changed.
final class ConfigOptionsUpdate extends SessionUpdate {
  ConfigOptionsUpdate(super.raw, this.options);

  final List<Map<String, dynamic>> options;
}

/// Session metadata (title, timestamps) has changed.
final class SessionInfoUpdate extends SessionUpdate {
  SessionInfoUpdate(super.raw, this.title);

  final String? title;
}

/// Context window and cost update — the only usage truth ACP provides.
final class UsageUpdate extends SessionUpdate {
  UsageUpdate(super.raw, this.used, this.size, this.cost);

  /// Tokens currently in context.
  final int used;

  /// Total context window size in tokens.
  final int size;

  /// Cumulative session cost, if the agent reports one — the schema's
  /// Cost object {amount, currency}, carried verbatim (rule 4).
  final Map<String, dynamic>? cost;

  double? get costAmount => (cost?['amount'] as num?)?.toDouble();
  String? get costCurrency => cost?['currency'] as String?;
}

/// Information for the user that is not part of session history.
final class NoticeUpdate extends SessionUpdate {
  NoticeUpdate(super.raw, this.severity, this.title, this.description);

  final String? severity;
  final String title;
  final String? description;
}

/// A context compaction has been created or updated.
final class CompactionUpdate extends SessionUpdate {
  CompactionUpdate(super.raw, this.compactionId, this.status, this.error);

  final String compactionId;
  final String? status;
  final String? error;
}

/// A chunk appended to a compaction's retained summary.
final class CompactionSummaryChunk extends SessionUpdate {
  CompactionSummaryChunk(super.raw, this.compactionId, this.text);

  final String compactionId;
  final String text;
}

/// Foreground lifecycle of a v2 session: running, requires_action, or idle.
///
/// v2 moved turn completion here from the `session/prompt` response: the
/// idle state carries the stop reason, including `error` with the JSON-RPC
/// error object in [error].
final class StateUpdate extends SessionUpdate {
  StateUpdate(super.raw, this.state, this.stopReason, this.error);

  /// running | idle | requires_action (extensible; unknown values arrive
  /// verbatim and should be treated as informational).
  final String state;

  /// Why foreground work ended; non-null on the idle transition that ends
  /// a turn. May be null, unknown, or malformed per the spec — a client
  /// cannot infer success or failure without a recognized value.
  final String? stopReason;

  /// The JSON-RPC error object, present when [stopReason] is `error`.
  final Map<String, dynamic>? error;
}

/// v2 whole-message upsert: full content of a user message keyed by the
/// agent-owned [messageId]. Omitted content means unchanged, null/[] clears,
/// a concrete array replaces (including content accumulated from chunks).
final class UserMessageUpsert extends SessionUpdate {
  UserMessageUpsert(super.raw, this.messageId, this.content);

  final String messageId;
  final List<Map<String, dynamic>> content;
}

/// v2 whole-message upsert for an agent message. See [UserMessageUpsert].
final class AgentMessageUpsert extends SessionUpdate {
  AgentMessageUpsert(super.raw, this.messageId, this.content);

  final String messageId;
  final List<Map<String, dynamic>> content;
}

/// v2 whole-message upsert for an agent thought. See [UserMessageUpsert].
final class AgentThoughtUpsert extends SessionUpdate {
  AgentThoughtUpsert(super.raw, this.messageId, this.content);

  final String messageId;
  final List<Map<String, dynamic>> content;
}

/// v2: appends one content item to a tool call's accumulated content.
final class ToolCallContentChunkUpdate extends SessionUpdate {
  ToolCallContentChunkUpdate(super.raw, this.toolCallId, this.content);

  final String toolCallId;

  /// The ToolCallContent item, carried verbatim (rule 4).
  final Map<String, dynamic> content;
}

/// One structured file change of a v2 diff content item.
///
/// [operation] is add | delete | modify | move | copy (extensible; unknown
/// values arrive verbatim and render generically with [path]/[oldPath]).
/// [oldPath] is set for move and copy. All values come from the raw map the
/// agent sent — this is a view, not a parse that can reject (rule 4).
final class DiffChange {
  DiffChange(this.raw);

  final Map<String, dynamic> raw;

  String get operation => raw['operation'] as String? ?? '';
  String get path => raw['path'] as String? ?? '';
  String? get oldPath => raw['oldPath'] as String?;
  String? get fileType => raw['fileType'] as String?;
  String? get mimeType => raw['mimeType'] as String?;
}

/// A v2 diff content item: [changes] is the authoritative list of
/// file-level operations; [patchText], when present, is renderable text in
/// [patchFormat] (`git_patch` is the one ACP-defined format, with absolute
/// paths and no commit metadata). Clients must render from [changes] when
/// the patch is absent, null, or of an unknown format.
final class DiffContent {
  DiffContent(this.raw, this.changes, this.patchFormat, this.patchText);

  final Map<String, dynamic> raw;
  final List<DiffChange> changes;
  final String? patchFormat;
  final String? patchText;

  /// True when [patchText] is present AND in the one format this view
  /// knows how to render. Unknown formats (including `_`-prefixed custom
  /// ones) render from [changes], per the spec.
  bool get hasRenderablePatch =>
      patchText != null && patchFormat == 'git_patch';
}

/// Views a tool-call content item as a v2 diff, or null when [item] is not
/// a diff item. Use on items of `tool_call_update.content` and
/// [ToolCallContentChunkUpdate.content].
DiffContent? diffContentOf(Map<String, dynamic> item) {
  if (item['type'] != 'diff') return null;
  final patch = (item['patch'] as Map?)?.cast<String, dynamic>();
  return DiffContent(
    item,
    <DiffChange>[
      for (final change
          in (item['changes'] as List?)?.whereType<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[])
        DiffChange(change),
    ],
    patch?['format'] as String?,
    patch?['text'] as String?,
  );
}

/// v2: Agent-owned display terminal state, an upsert keyed by [terminalId].
///
/// Patch semantics per the spec: omitted fields are unchanged, null clears,
/// a concrete value replaces. [output], when present, is an authoritative
/// replacement snapshot (base64 in `output.data`), not a merge. All patch
/// fields are nullable here; the raw map is the source of truth (rule 4).
final class TerminalUpdate extends SessionUpdate {
  TerminalUpdate(
    super.raw,
    this.terminalId,
    this.command,
    this.cwd,
    this.size,
    this.output,
    this.exitStatus,
  );

  final String terminalId;
  final String? command;
  final String? cwd;
  final Map<String, dynamic>? size;
  final Map<String, dynamic>? output;
  final Map<String, dynamic>? exitStatus;

  bool get hasExited => exitStatus != null;

  /// True when the agent advertised this terminal as client-cancellable
  /// (v2 `terminal_update.capabilities.cancel`). Cancelling is a
  /// [AcpClient.cancelTerminal] request; it must not be sent otherwise.
  bool get canCancel =>
      ((raw['capabilities'] as Map?)?.cast<String, dynamic>())?['cancel']
          is Map;
}

/// v2: appends live output bytes to a display terminal. [data] is base64,
/// independently encoded per chunk — decode each chunk separately and append
/// the bytes in received order.
final class TerminalOutputChunkUpdate extends SessionUpdate {
  TerminalOutputChunkUpdate(super.raw, this.terminalId, this.data);

  final String terminalId;
  final String data;
}

/// v2 plan upsert, keyed by [planId]; each update replaces that plan's
/// entries (an empty list empties the plan). Multiple plans per session are
/// possible; the v1 flat [PlanUpdate] stays for `sessionUpdate: 'plan'`.
final class PlanUpsert extends SessionUpdate {
  PlanUpsert(super.raw, this.planId, this.entries);

  final String planId;
  final List<Map<String, dynamic>> entries;
}

/// An update this package does not model — still carrying its full body.
final class UnknownUpdate extends SessionUpdate {
  const UnknownUpdate(super.raw);
}

/// Parses the `update` object of a `session/update` notification.
SessionUpdate parseSessionUpdate(Map<String, dynamic> raw) {
  switch (raw['sessionUpdate']) {
    case 'user_message_chunk':
      return UserMessageChunk(
        raw,
        _textOf(raw['content']),
        raw['messageId'] as String?,
      );
    case 'agent_message_chunk':
      return AgentMessageChunk(
        raw,
        _textOf(raw['content']),
        raw['messageId'] as String?,
      );
    case 'agent_thought_chunk':
      return AgentThoughtChunk(
        raw,
        _textOf(raw['content']),
        raw['messageId'] as String?,
      );
    case 'tool_call':
      return ToolCallStart(
        raw,
        raw['toolCallId'] as String,
        raw['title'] as String? ?? '',
        raw['kind'] as String?,
        raw['name'] as String?,
      );
    case 'tool_call_update':
      return ToolCallChange(
        raw,
        raw['toolCallId'] as String,
        raw['status'] as String?,
        raw['title'] as String?,
        raw['kind'] as String?,
      );
    case 'plan':
      return PlanUpdate(raw, _mapList(raw['entries']));
    case 'available_commands_update':
      return AvailableCommandsUpdate(raw, _mapList(raw['availableCommands']));
    case 'current_mode_update':
      return CurrentModeUpdate(raw, raw['currentModeId'] as String? ?? '');
    case 'config_option_update':
      return ConfigOptionsUpdate(raw, _mapList(raw['configOptions']));
    case 'session_info_update':
      return SessionInfoUpdate(raw, raw['title'] as String?);
    case 'usage_update':
      return UsageUpdate(
        raw,
        raw['used'] as int? ?? 0,
        raw['size'] as int? ?? 0,
        (raw['cost'] as Map?)?.cast<String, dynamic>(),
      );
    case 'notice':
      return NoticeUpdate(
        raw,
        raw['severity'] as String?,
        raw['title'] as String? ?? '',
        raw['description'] as String?,
      );
    case 'compaction_update':
      return CompactionUpdate(
        raw,
        raw['compactionId'] as String? ?? '',
        raw['status'] as String?,
        raw['error'] as String?,
      );
    case 'compaction_summary_chunk':
      return CompactionSummaryChunk(
        raw,
        raw['compactionId'] as String? ?? '',
        _textOf(raw['content']),
      );
    case 'state_update':
      return StateUpdate(
        raw,
        raw['state'] as String? ?? '',
        raw['stopReason'] as String?,
        (raw['error'] as Map?)?.cast<String, dynamic>(),
      );
    case 'user_message':
      return UserMessageUpsert(
        raw,
        raw['messageId'] as String? ?? '',
        _mapList(raw['content']),
      );
    case 'agent_message':
      return AgentMessageUpsert(
        raw,
        raw['messageId'] as String? ?? '',
        _mapList(raw['content']),
      );
    case 'agent_thought':
      return AgentThoughtUpsert(
        raw,
        raw['messageId'] as String? ?? '',
        _mapList(raw['content']),
      );
    case 'tool_call_content_chunk':
      return ToolCallContentChunkUpdate(
        raw,
        raw['toolCallId'] as String? ?? '',
        (raw['content'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      );
    case 'terminal_update':
      return TerminalUpdate(
        raw,
        raw['terminalId'] as String? ?? '',
        raw['command'] as String?,
        raw['cwd'] as String?,
        (raw['size'] as Map?)?.cast<String, dynamic>(),
        (raw['output'] as Map?)?.cast<String, dynamic>(),
        (raw['exitStatus'] as Map?)?.cast<String, dynamic>(),
      );
    case 'terminal_output_chunk':
      return TerminalOutputChunkUpdate(
        raw,
        raw['terminalId'] as String? ?? '',
        raw['data'] as String? ?? '',
      );
    case 'plan_update':
      final plan = (raw['plan'] as Map?)?.cast<String, dynamic>();
      return PlanUpsert(
        raw,
        plan?['planId'] as String? ?? '',
        _mapList(plan?['entries']),
      );
    default:
      return UnknownUpdate(raw);
  }
}

String _textOf(Object? content) {
  if (content is Map && content['type'] == 'text') {
    return content['text'] as String? ?? '';
  }
  return '';
}

List<Map<String, dynamic>> _mapList(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];
