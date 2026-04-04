import 'package:rpc_dart/rpc_dart.dart';

/// Base sealed class for all GitLab webhook events.
sealed class GitlabEvent implements IRpcSerializable {
  const GitlabEvent();

  /// GitLab project numeric ID.
  int get projectId;

  /// GitLab project path (e.g. 'mygroup/myrepo').
  String get projectPath;

  /// Raw event type string as sent in X-Gitlab-Event header.
  String get eventType;

  factory GitlabEvent.fromJson(Map<String, dynamic> json) {
    final kind = json['event_type'] as String? ?? json['object_kind'] as String? ?? '';
    return switch (kind) {
      'push' || 'tag_push' => GitlabPushEvent.fromJson(json),
      'merge_request' => GitlabMergeRequestEvent.fromJson(json),
      'pipeline' => GitlabPipelineEvent.fromJson(json),
      'issue' => GitlabIssueEvent.fromJson(json),
      'note' || 'confidential_note' => GitlabNoteEvent.fromJson(json),
      'build' => GitlabJobEvent.fromJson(json),
      'release' => GitlabReleaseEvent.fromJson(json),
      'deployment' => GitlabDeploymentEvent.fromJson(json),
      _ => GitlabUnknownEvent.fromJson(json),
    };
  }

  static RpcCodec<GitlabEvent> get codec => RpcCodec(GitlabEvent.fromJson);
}

// ============================================================
// Push Event
// ============================================================

final class GitlabPushEvent extends GitlabEvent {
  final String ref;
  final String before;
  final String after;
  final String userName;
  final int commitCount;
  @override
  final int projectId;
  @override
  final String projectPath;

  const GitlabPushEvent({
    required this.ref,
    required this.before,
    required this.after,
    required this.userName,
    required this.commitCount,
    required this.projectId,
    required this.projectPath,
  });

  @override
  String get eventType => 'push';

  factory GitlabPushEvent.fromJson(Map<String, dynamic> json) {
    final project = json['project'] as Map<String, dynamic>? ?? {};
    return GitlabPushEvent(
      ref: json['ref'] as String? ?? '',
      before: json['before'] as String? ?? '',
      after: json['after'] as String? ?? '',
      userName: json['user_name'] as String? ?? '',
      commitCount: json['total_commits_count'] as int? ?? 0,
      projectId: project['id'] as int? ?? 0,
      projectPath: project['path_with_namespace'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'ref': ref,
        'before': before,
        'after': after,
        'user_name': userName,
        'total_commits_count': commitCount,
        'project': {'id': projectId, 'path_with_namespace': projectPath},
      };
}

// ============================================================
// Merge Request Event
// ============================================================

final class GitlabMergeRequestEvent extends GitlabEvent {
  final int mrIid;
  final String title;
  final String action;
  final String sourceBranch;
  final String targetBranch;
  final String authorName;
  final String state;
  final String url;
  @override
  final int projectId;
  @override
  final String projectPath;

  const GitlabMergeRequestEvent({
    required this.mrIid,
    required this.title,
    required this.action,
    required this.sourceBranch,
    required this.targetBranch,
    required this.authorName,
    required this.state,
    required this.url,
    required this.projectId,
    required this.projectPath,
  });

  @override
  String get eventType => 'merge_request';

  factory GitlabMergeRequestEvent.fromJson(Map<String, dynamic> json) {
    final attrs = json['object_attributes'] as Map<String, dynamic>? ?? {};
    final project = json['project'] as Map<String, dynamic>? ?? {};
    return GitlabMergeRequestEvent(
      mrIid: attrs['iid'] as int? ?? 0,
      title: attrs['title'] as String? ?? '',
      action: attrs['action'] as String? ?? '',
      sourceBranch: attrs['source_branch'] as String? ?? '',
      targetBranch: attrs['target_branch'] as String? ?? '',
      authorName: (json['user'] as Map<String, dynamic>?)?['name'] as String? ?? '',
      state: attrs['state'] as String? ?? '',
      url: attrs['url'] as String? ?? '',
      projectId: project['id'] as int? ?? 0,
      projectPath: project['path_with_namespace'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'object_attributes': {
          'iid': mrIid,
          'title': title,
          'action': action,
          'source_branch': sourceBranch,
          'target_branch': targetBranch,
          'state': state,
          'url': url,
        },
        'user': {'name': authorName},
        'project': {'id': projectId, 'path_with_namespace': projectPath},
      };
}

// ============================================================
// Pipeline Event
// ============================================================

final class GitlabPipelineEvent extends GitlabEvent {
  final int pipelineId;
  final String ref;
  final String status;
  final String source;
  final String sha;
  @override
  final int projectId;
  @override
  final String projectPath;

  const GitlabPipelineEvent({
    required this.pipelineId,
    required this.ref,
    required this.status,
    required this.source,
    required this.sha,
    required this.projectId,
    required this.projectPath,
  });

  @override
  String get eventType => 'pipeline';

  factory GitlabPipelineEvent.fromJson(Map<String, dynamic> json) {
    final attrs = json['object_attributes'] as Map<String, dynamic>? ?? {};
    final project = json['project'] as Map<String, dynamic>? ?? {};
    return GitlabPipelineEvent(
      pipelineId: attrs['id'] as int? ?? 0,
      ref: attrs['ref'] as String? ?? '',
      status: attrs['status'] as String? ?? '',
      source: attrs['source'] as String? ?? '',
      sha: attrs['sha'] as String? ?? '',
      projectId: project['id'] as int? ?? 0,
      projectPath: project['path_with_namespace'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'object_attributes': {
          'id': pipelineId,
          'ref': ref,
          'status': status,
          'source': source,
          'sha': sha,
        },
        'project': {'id': projectId, 'path_with_namespace': projectPath},
      };
}

// ============================================================
// Issue Event
// ============================================================

final class GitlabIssueEvent extends GitlabEvent {
  final int issueIid;
  final String title;
  final String action;
  final String authorName;
  final String state;
  final String url;
  @override
  final int projectId;
  @override
  final String projectPath;

  const GitlabIssueEvent({
    required this.issueIid,
    required this.title,
    required this.action,
    required this.authorName,
    required this.state,
    required this.url,
    required this.projectId,
    required this.projectPath,
  });

  @override
  String get eventType => 'issue';

  factory GitlabIssueEvent.fromJson(Map<String, dynamic> json) {
    final attrs = json['object_attributes'] as Map<String, dynamic>? ?? {};
    final project = json['project'] as Map<String, dynamic>? ?? {};
    return GitlabIssueEvent(
      issueIid: attrs['iid'] as int? ?? 0,
      title: attrs['title'] as String? ?? '',
      action: attrs['action'] as String? ?? '',
      authorName: (json['user'] as Map<String, dynamic>?)?['name'] as String? ?? '',
      state: attrs['state'] as String? ?? '',
      url: attrs['url'] as String? ?? '',
      projectId: project['id'] as int? ?? 0,
      projectPath: project['path_with_namespace'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'object_attributes': {
          'iid': issueIid,
          'title': title,
          'action': action,
          'state': state,
          'url': url,
        },
        'user': {'name': authorName},
        'project': {'id': projectId, 'path_with_namespace': projectPath},
      };
}

// ============================================================
// Note (Comment) Event
// ============================================================

final class GitlabNoteEvent extends GitlabEvent {
  final int noteId;
  final String note;
  final String noteableType;
  final String authorName;
  final String url;
  @override
  final int projectId;
  @override
  final String projectPath;

  const GitlabNoteEvent({
    required this.noteId,
    required this.note,
    required this.noteableType,
    required this.authorName,
    required this.url,
    required this.projectId,
    required this.projectPath,
  });

  @override
  String get eventType => 'note';

  factory GitlabNoteEvent.fromJson(Map<String, dynamic> json) {
    final attrs = json['object_attributes'] as Map<String, dynamic>? ?? {};
    final project = json['project'] as Map<String, dynamic>? ?? {};
    return GitlabNoteEvent(
      noteId: attrs['id'] as int? ?? 0,
      note: attrs['note'] as String? ?? '',
      noteableType: attrs['noteable_type'] as String? ?? '',
      authorName: (json['user'] as Map<String, dynamic>?)?['name'] as String? ?? '',
      url: attrs['url'] as String? ?? '',
      projectId: project['id'] as int? ?? 0,
      projectPath: project['path_with_namespace'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'object_attributes': {
          'id': noteId,
          'note': note,
          'noteable_type': noteableType,
          'url': url,
        },
        'user': {'name': authorName},
        'project': {'id': projectId, 'path_with_namespace': projectPath},
      };
}

// ============================================================
// Job Event
// ============================================================

final class GitlabJobEvent extends GitlabEvent {
  final int buildId;
  final String buildName;
  final String buildStatus;
  final String ref;
  @override
  final int projectId;
  @override
  final String projectPath;

  const GitlabJobEvent({
    required this.buildId,
    required this.buildName,
    required this.buildStatus,
    required this.ref,
    required this.projectId,
    required this.projectPath,
  });

  @override
  String get eventType => 'build';

  factory GitlabJobEvent.fromJson(Map<String, dynamic> json) {
    return GitlabJobEvent(
      buildId: json['build_id'] as int? ?? 0,
      buildName: json['build_name'] as String? ?? '',
      buildStatus: json['build_status'] as String? ?? '',
      ref: json['ref'] as String? ?? '',
      projectId: json['project_id'] as int? ?? 0,
      projectPath: json['project_path_with_namespace'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'build_id': buildId,
        'build_name': buildName,
        'build_status': buildStatus,
        'ref': ref,
        'project_id': projectId,
        'project_path_with_namespace': projectPath,
      };
}

// ============================================================
// Release Event
// ============================================================

final class GitlabReleaseEvent extends GitlabEvent {
  final String tagName;
  final String name;
  final String description;
  final String action;
  @override
  final int projectId;
  @override
  final String projectPath;

  const GitlabReleaseEvent({
    required this.tagName,
    required this.name,
    required this.description,
    required this.action,
    required this.projectId,
    required this.projectPath,
  });

  @override
  String get eventType => 'release';

  factory GitlabReleaseEvent.fromJson(Map<String, dynamic> json) {
    final project = json['project'] as Map<String, dynamic>? ?? {};
    return GitlabReleaseEvent(
      tagName: json['tag'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      action: json['action'] as String? ?? '',
      projectId: project['id'] as int? ?? 0,
      projectPath: project['path_with_namespace'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'tag': tagName,
        'name': name,
        'description': description,
        'action': action,
        'project': {'id': projectId, 'path_with_namespace': projectPath},
      };
}

// ============================================================
// Deployment Event
// ============================================================

final class GitlabDeploymentEvent extends GitlabEvent {
  final int deploymentId;
  final String status;
  final String environment;
  final String ref;
  @override
  final int projectId;
  @override
  final String projectPath;

  const GitlabDeploymentEvent({
    required this.deploymentId,
    required this.status,
    required this.environment,
    required this.ref,
    required this.projectId,
    required this.projectPath,
  });

  @override
  String get eventType => 'deployment';

  factory GitlabDeploymentEvent.fromJson(Map<String, dynamic> json) {
    final project = json['project'] as Map<String, dynamic>? ?? {};
    return GitlabDeploymentEvent(
      deploymentId: json['deployment_id'] as int? ?? 0,
      status: json['status'] as String? ?? '',
      environment: json['environment'] as String? ?? '',
      ref: json['ref'] as String? ?? '',
      projectId: project['id'] as int? ?? 0,
      projectPath: project['path_with_namespace'] as String? ?? '',
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'deployment_id': deploymentId,
        'status': status,
        'environment': environment,
        'ref': ref,
        'project': {'id': projectId, 'path_with_namespace': projectPath},
      };
}

// ============================================================
// Unknown Event (fallback)
// ============================================================

final class GitlabUnknownEvent extends GitlabEvent {
  final Map<String, dynamic> raw;

  const GitlabUnknownEvent({required this.raw});

  @override
  String get eventType => raw['event_type'] as String? ?? raw['object_kind'] as String? ?? 'unknown';

  @override
  int get projectId =>
      (raw['project'] as Map<String, dynamic>?)?['id'] as int? ?? 0;

  @override
  String get projectPath =>
      (raw['project'] as Map<String, dynamic>?)?['path_with_namespace'] as String? ?? '';

  factory GitlabUnknownEvent.fromJson(Map<String, dynamic> json) {
    return GitlabUnknownEvent(raw: json);
  }

  @override
  Map<String, dynamic> toJson() => raw;
}
