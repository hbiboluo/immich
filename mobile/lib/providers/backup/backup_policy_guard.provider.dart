import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/backup_policy_guard.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';

final backupPolicyGuardProvider = Provider((ref) {
  return BackupPolicyGuard(
    getScope: () {
      if (!CurrentPlatform.isAndroid) {
        return null;
      }
      final user = Store.tryGet(StoreKey.currentUser);
      final serverUrl = Store.tryGet(StoreKey.serverUrl);
      if (user == null || serverUrl == null || serverUrl.isEmpty) {
        return null;
      }
      return backupScope(serverUrl, user.id);
    },
    getUserId: () => Store.tryGet(StoreKey.currentUser)?.id,
    getPolicy: (scope) => ref.read(driftProvider).backupPolicyRepository.getPolicy(scope),
    getMediaStoreVersion: () => ref.read(nativeSyncApiProvider).getMediaStoreVersion(),
    pause: (scope, {expectedRevision}) =>
        ref.read(driftProvider).backupPolicyRepository.pause(scope, expectedRevision: expectedRevision),
  );
});
