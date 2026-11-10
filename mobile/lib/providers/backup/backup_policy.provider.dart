import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_policy.repository.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:logging/logging.dart';

final _backupServerUrlProvider = StreamProvider<String?>((ref) {
  return ref.watch(storeServiceProvider).watch(StoreKey.serverUrl);
});

final _backupStoredUserProvider = StreamProvider((ref) {
  return ref.watch(storeServiceProvider).watch(StoreKey.currentUser);
});

final backupScopeProvider = Provider<String?>((ref) {
  if (!CurrentPlatform.isAndroid) {
    return null;
  }
  ref.watch(_backupServerUrlProvider);
  ref.watch(_backupStoredUserProvider);
  ref.watch(currentUserProvider);
  final store = ref.watch(storeServiceProvider);
  final user = store.tryGet(StoreKey.currentUser);
  final serverUrl = store.tryGet(StoreKey.serverUrl);
  if (user == null || serverUrl == null || serverUrl.isEmpty) {
    return null;
  }
  return backupScope(serverUrl, user.id);
});

final backupPolicyProvider = StreamProvider<BackupPolicy>((ref) {
  final scope = ref.watch(backupScopeProvider);
  if (scope == null) {
    return Stream.value(const BackupPolicy(scope: '', status: BackupPolicyStatus.legacy));
  }
  return ref.watch(driftProvider).backupPolicyRepository.watchPolicy(scope);
});

final backupHistoryCountsProvider = StreamProvider<({int ignored, int uploaded, int matched})>((ref) {
  final scope = ref.watch(backupScopeProvider);
  final user = ref.watch(currentUserProvider);
  if (scope == null || user == null) {
    return Stream.value((ignored: 0, uploaded: 0, matched: 0));
  }
  return ref.watch(driftProvider).backupPolicyRepository.watchHistoryCounts(scope, user.id);
});

final backupPolicyControllerProvider = Provider<BackupPolicyController>((ref) {
  String? currentScope() {
    final user = Store.tryGet(StoreKey.currentUser);
    final serverUrl = Store.tryGet(StoreKey.serverUrl);
    if (!CurrentPlatform.isAndroid || user == null || serverUrl == null || serverUrl.isEmpty) {
      return null;
    }
    return backupScope(serverUrl, user.id);
  }

  Future<void> refresh() async {
    ref.invalidate(backupPolicyProvider);
    ref.invalidate(backupHistoryCountsProvider);
    ref.invalidate(backupCandidateProvider);
    final user = ref.read(currentUserProvider);
    if (user != null) {
      await ref.read(backupProvider.notifier).getBackupStatus(user.id);
    }
  }

  return BackupPolicyController(
    repository: ref.watch(driftProvider).backupPolicyRepository,
    getScope: currentScope,
    stopBackups: () async {
      ref.read(backupProvider.notifier).stopForegroundBackup(reason: 'upload policy changed');
      await ref.read(foregroundUploadServiceProvider).cancelAndWait();
      await ref.read(backgroundWorkerLockServiceProvider).lock();
      await ref.read(backgroundSyncProvider).cancelResumeSyncs();
    },
    scan: () => ref.read(localSyncServiceProvider).sync(full: true, throwOnError: true, skipMediaManagement: true),
    getMediaStoreVersion: () => ref.read(nativeSyncApiProvider).getMediaStoreVersion(),
    onChanged: refresh,
    resume: () async {
      final user = ref.read(currentUserProvider);
      if (user != null && ref.read(appConfigProvider).backup.enabled) {
        unawaited(
          ref.read(backupProvider.notifier).startForegroundBackup(user.id).catchError((Object error, StackTrace stack) {
            Logger('BackupPolicyController').warning('Could not resume backup after changing policy', error, stack);
          }),
        );
      }
    },
  );
});

class BackupPolicyController {
  final BackupPolicyRepository _repository;
  final String? Function() _getScope;
  final Future<void> Function() _stopBackups;
  final Future<void> Function() _scan;
  final Future<String> Function() _getMediaStoreVersion;
  final Future<void> Function() _onChanged;
  final Future<void> Function() _resume;
  bool _busy = false;

  BackupPolicyController({
    required this._repository,
    required this._getScope,
    required this._stopBackups,
    required this._scan,
    required this._getMediaStoreVersion,
    required this._onChanged,
    required this._resume,
  });

  bool get busy => _busy;

  Future<void> enableOnlyNew({bool resetBaseline = false}) async {
    final scope = _startChange();
    try {
      final previous = await _repository.getPolicy(scope);
      if (previous.status == BackupPolicyStatus.active && !resetBaseline) {
        try {
          final version = await _getMediaStoreVersion();
          _ensureScope(scope);
          if (version != previous.mediaStoreVersion) {
            throw StateError('The media library changed; rebuild the baseline');
          }
          await _onChanged();
          _ensureScope(scope);
          await _resume();
        } catch (_) {
          await _pauseAfterFailure(scope);
          rethrow;
        }
        return;
      }
      if (previous.isPaused && !resetBaseline) {
        throw StateError('Rebuilding a paused baseline requires an explicit choice');
      }
      final restoreExisting = previous.mediaStoreVersion != null && !resetBaseline;
      await _repository.beginInitialization(scope);
      try {
        await _stopBackups();
        _ensureScope(scope);
        final version = await _getMediaStoreVersion();
        if (version.isEmpty) {
          throw StateError('The media library identity is unavailable');
        }
        if (restoreExisting && version != previous.mediaStoreVersion) {
          throw StateError('The media library changed; rebuild the baseline');
        }
        await _scan();
        final versionAfterScan = await _getMediaStoreVersion();
        _ensureScope(scope);
        if (version != versionAfterScan) {
          throw StateError('The media library changed during initialization');
        }
        if (restoreExisting) {
          await _repository.resume(scope, version);
        } else {
          await _repository.completeInitialization(scope, version);
        }
        await _onChanged();
        _ensureScope(scope);
        await _resume();
      } catch (_) {
        await _pauseAfterFailure(scope);
        rethrow;
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> useLegacy() async {
    final scope = _startChange();
    try {
      await _repository.beginInitialization(scope);
      try {
        await _stopBackups();
        _ensureScope(scope);
        await _repository.useLegacy(scope);
        await _onChanged();
        _ensureScope(scope);
        await _resume();
      } catch (_) {
        await _pauseAfterFailure(scope);
        rethrow;
      }
    } finally {
      _busy = false;
    }
  }

  String _startChange() {
    if (_busy) {
      throw StateError('The upload policy is already changing');
    }
    final scope = _getScope();
    if (scope == null) {
      throw StateError('An Android account is required');
    }
    _busy = true;
    return scope;
  }

  void _ensureScope(String expected) {
    if (_getScope() != expected) {
      throw StateError('The account or server changed during initialization');
    }
  }

  Future<void> _pauseAfterFailure(String scope) async {
    await _repository.pause(scope);
    try {
      await _onChanged();
    } catch (error, stack) {
      Logger('BackupPolicyController').warning('Could not refresh a paused upload policy', error, stack);
    }
  }
}
