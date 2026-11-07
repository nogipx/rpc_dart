// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// The agent's permission request and the decision a client returns.
library;

/// One option the agent offers for a permission request.
final class PermissionOption {
  const PermissionOption(this.optionId, this.name, this.kind);

  final String optionId;
  final String name;
  final String? kind;

  factory PermissionOption.fromJson(Map<String, dynamic> json) =>
      PermissionOption(
        json['optionId'] as String,
        json['name'] as String? ?? '',
        json['kind'] as String?,
      );
}

/// A request from the agent to authorize a tool call.
///
/// v1 agents stuff prompt copy into the tool call's title; v2 separates
/// them: [title] (required there) is the prompt text, [subject] the
/// structured `tool_call`/`command` union. Both are optional here because
/// a v1 request has neither.
final class PermissionRequest {
  const PermissionRequest(
    this.sessionId,
    this.toolCall,
    this.options, {
    this.title,
    this.subject,
  });

  final String sessionId;

  /// The tool call awaiting authorization, exactly as the agent sent it.
  /// For a v2 `command` subject this is empty — read [subject] instead.
  final Map<String, dynamic> toolCall;

  /// Options the agent offers; the decision must name one of these ids
  /// (or be [PermissionCancelled]).
  final List<PermissionOption> options;

  /// v2: the permission prompt's headline text.
  final String? title;

  /// v2: the subject union ({type: tool_call|command, ...}), verbatim.
  final Map<String, dynamic>? subject;
}

/// The client's answer to a [PermissionRequest].
sealed class PermissionDecision {
  const PermissionDecision();

  Object? toJson();
}

/// The user selected one of the offered options.
final class SelectOption extends PermissionDecision {
  const SelectOption(this.optionId);

  final String optionId;

  @override
  Object toJson() => <String, dynamic>{'optionId': optionId};
}

/// The turn was cancelled before the user responded.
final class PermissionCancelled extends PermissionDecision {
  const PermissionCancelled();

  @override
  Object toJson() => 'cancelled';
}
