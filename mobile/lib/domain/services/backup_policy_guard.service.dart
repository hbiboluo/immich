import 'package:immich_mobile/domain/models/backup_policy.model.dart';

class BackupPolicyGuard {
  final String? Function() getScope;
  final String? Function() getUserId;
  final Future<BackupPolicy> Function(String scope) getPolicy;
  final Future<String> Function() getMediaStoreVersion;
  final Future<void> Function(String scope, {int? expectedRevision}) pause;

  const BackupPolicyGuard({
    required this.getScope,
    required this.getUserId,
    required this.getPolicy,
    required this.getMediaStoreVersion,
    required this.pause,
  });

  bool isCurrentScope(String? scope) => getScope() == scope;

  bool isCurrentUser(String userId) => getUserId() == userId;

  Future<BackupPolicy?> current({bool validateMediaStore = false}) async {
    final scope = getScope();
    if (scope == null) {
      return null;
    }
    final policy = await getPolicy(scope);
    if (!isCurrentScope(scope)) {
      return null;
    }
    if (validateMediaStore && policy.status == BackupPolicyStatus.active) {
      final String version;
      try {
        version = await getMediaStoreVersion();
      } catch (_) {
        await pause(scope, expectedRevision: policy.revision);
        final paused = await getPolicy(scope);
        return isCurrentScope(scope) ? paused : null;
      }
      if (!isCurrentScope(scope)) {
        return null;
      }
      if (version != policy.mediaStoreVersion) {
        await pause(scope, expectedRevision: policy.revision);
        final paused = await getPolicy(scope);
        return isCurrentScope(scope) ? paused : null;
      }
    }
    return policy;
  }

  Future<bool> allowsMediaManagement() async {
    if (getScope() == null) {
      return true;
    }
    final policy = await current();
    return policy != null && !policy.onlyNew;
  }
}
