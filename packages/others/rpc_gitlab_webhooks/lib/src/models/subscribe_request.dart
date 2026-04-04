import 'package:rpc_dart/rpc_dart.dart';

/// Subscription filter sent by client when opening a webhook event stream.
///
/// All fields are optional — omitting them means "no filter" (receive everything).
final class GitlabSubscribeRequest implements IRpcSerializable {
  /// Only deliver events from projects with these numeric IDs.
  /// Empty list = all projects.
  final List<int> projectIds;

  /// Only deliver events from these projects (path_with_namespace).
  /// Empty list = all projects.
  final List<String> projectPaths;

  /// Only deliver push/pipeline events matching these refs (branch or tag names).
  /// Empty list = all refs.
  final List<String> refs;

  const GitlabSubscribeRequest({
    this.projectIds = const [],
    this.projectPaths = const [],
    this.refs = const [],
  });

  /// Receive all events without filtering.
  const GitlabSubscribeRequest.all()
      : projectIds = const [],
        projectPaths = const [],
        refs = const [];

  bool get hasProjectFilter => projectIds.isNotEmpty || projectPaths.isNotEmpty;
  bool get hasRefFilter => refs.isNotEmpty;

  /// Returns true if [event] passes the filter criteria.
  ///
  /// Project filter matches if either [projectId] or [projectPath] is in the
  /// respective list. Both lists are OR-combined, then AND-ed with ref filter.
  bool matches(int projectId, String projectPath, {String? ref}) {
    if (hasProjectFilter) {
      final idMatch = projectIds.isNotEmpty && projectIds.contains(projectId);
      final pathMatch = projectPaths.isNotEmpty && projectPaths.contains(projectPath);
      if (!idMatch && !pathMatch) return false;
    }
    if (hasRefFilter && ref != null && !refs.contains(ref)) return false;
    return true;
  }

  factory GitlabSubscribeRequest.fromJson(Map<String, dynamic> json) {
    return GitlabSubscribeRequest(
      projectIds: List<int>.from(json['project_ids'] as List? ?? []),
      projectPaths: List<String>.from(json['project_paths'] as List? ?? []),
      refs: List<String>.from(json['refs'] as List? ?? []),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'project_ids': projectIds,
        'project_paths': projectPaths,
        'refs': refs,
      };

  static RpcCodec<GitlabSubscribeRequest> get codec =>
      RpcCodec(GitlabSubscribeRequest.fromJson);
}