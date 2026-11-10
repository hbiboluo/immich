import 'dart:convert';

enum BackupPolicyStatus { legacy, initializing, active, paused }

enum BackupHistoryReason { baseline, uploaded, remoteMatched }

class BackupPolicy {
  final String scope;
  final BackupPolicyStatus status;
  final String? mediaStoreVersion;
  final int revision;
  final int mediaStoreEpoch;

  const BackupPolicy({
    required this.scope,
    this.status = BackupPolicyStatus.legacy,
    this.mediaStoreVersion,
    this.revision = 0,
    this.mediaStoreEpoch = 0,
  });

  bool get onlyNew => status != BackupPolicyStatus.legacy;

  bool get isPaused => status == BackupPolicyStatus.initializing || status == BackupPolicyStatus.paused;
}

String backupScope(String serverUrl, String userId) {
  final uri = Uri.parse(serverUrl).normalizePath();
  final server = Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
    path: uri.path.replaceAll(RegExp(r'/+$'), ''),
  );
  return jsonEncode([server.toString(), userId]);
}
