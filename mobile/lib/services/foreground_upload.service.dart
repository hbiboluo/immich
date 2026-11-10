import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart' hide AssetVisibility;
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/backup_policy_guard.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_policy.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/backup/backup_policy_guard.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/utils/async_mutex.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart' show PMProgressHandler;

/// Callbacks for upload progress and status updates
class UploadCallbacks {
  final void Function(String id, String filename, int bytes, int totalBytes)? onProgress;
  final void Function(String localId, String remoteId)? onSuccess;
  final void Function(String id, String errorMessage)? onError;
  final void Function(String id, double progress)? onICloudProgress;

  const UploadCallbacks({this.onProgress, this.onSuccess, this.onError, this.onICloudProgress});
}

final foregroundUploadServiceProvider = Provider((ref) {
  // ignore: dispose-provided-instances
  return ForegroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    ref.watch(driftProvider).backupRepository,
    ref.watch(connectivityApiProvider),
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(assetServiceProvider),
    backupPolicyRepository: ref.watch(driftProvider).backupPolicyRepository,
    backupPolicyGuard: ref.watch(backupPolicyGuardProvider),
  );
});

/// Service for handling foreground HTTP uploads
///
/// This service handles synchronous uploads using HTTP client with
/// concurrent worker pools. Used for manual backups, auto backups
/// (foreground mode), and share intent uploads.
class ForegroundUploadService {
  ForegroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._backupRepository,
    this._connectivityApi,
    this._assetMediaRepository,
    this._assetService, {
    this._backupPolicyRepository,
    this._backupPolicyGuard,
  });

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final BackupRepository _backupRepository;
  final ConnectivityApi _connectivityApi;
  final AssetMediaRepository _assetMediaRepository;
  final AssetService _assetService;
  final BackupPolicyRepository? _backupPolicyRepository;
  final BackupPolicyGuard? _backupPolicyGuard;
  final Logger _logger = Logger('ForegroundUploadService');

  bool shouldAbortUpload = false;
  final _backupMutex = AsyncMutex();
  Future<void>? _backupTask;
  Completer<void>? _backupCancellation;

  Future<({int total, int remainder, int processing})> getBackupCounts(String userId) async {
    final scope = _backupPolicyGuard?.getScope();
    final policy = await _backupPolicyGuard?.current(validateMediaStore: true);
    if (_backupPolicyGuard != null &&
        (!_backupPolicyGuard.isCurrentUser(userId) ||
            !_backupPolicyGuard.isCurrentScope(scope) ||
            (scope != null && policy == null))) {
      return (total: 0, remainder: 0, processing: 0);
    }
    return policy == null
        ? _backupRepository.getAllCounts(userId)
        : _backupRepository.getAllCounts(userId, scope: policy.scope);
  }

  Future<List<LocalAsset>> getBackupCandidates(String userId, {bool onlyHashed = true}) async {
    final scope = _backupPolicyGuard?.getScope();
    final policy = await _backupPolicyGuard?.current(validateMediaStore: true);
    if (_backupPolicyGuard != null &&
        (!_backupPolicyGuard.isCurrentUser(userId) ||
            !_backupPolicyGuard.isCurrentScope(scope) ||
            (scope != null && policy == null))) {
      return [];
    }
    return policy == null
        ? _backupRepository.getCandidates(userId, onlyHashed: onlyHashed)
        : _backupRepository.getCandidates(userId, onlyHashed: onlyHashed, scope: policy.scope);
  }

  /// Bulk upload of backup candidates from selected albums
  Future<void> uploadCandidates(
    String userId,
    Completer<void> cancelToken, {
    UploadCallbacks callbacks = const UploadCallbacks(),
    bool useSequentialUpload = false,
  }) async {
    final started = await _backupMutex.run(() async {
      final previous = _backupTask;
      if (previous != null) {
        _cancelBackup();
        await previous;
      }
      if (cancelToken.isCompleted) {
        return (task: Future<void>.value());
      }
      final cancellation = Completer<void>();
      _backupCancellation = cancellation;
      unawaited(
        cancelToken.future.then((_) {
          if (!cancellation.isCompleted) {
            cancellation.complete();
          }
        }),
      );
      final task = _runBackup(userId, cancellation, callbacks, useSequentialUpload);
      _backupTask = task;
      return (task: task);
    });
    final task = started.task;
    try {
      await task;
    } finally {
      if (identical(_backupTask, task)) {
        _backupTask = null;
        _backupCancellation = null;
      }
    }
  }

  void _cancelBackup() {
    shouldAbortUpload = true;
    final cancellation = _backupCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  Future<void> cancelAndWait() async {
    final stopped = await _backupMutex.run(() async {
      _cancelBackup();
      return (task: _backupTask);
    });
    await stopped.task;
  }

  Future<void> _runBackup(
    String userId,
    Completer<void> cancelToken,
    UploadCallbacks callbacks,
    bool useSequentialUpload,
  ) async {
    shouldAbortUpload = false;
    final scope = _backupPolicyGuard?.getScope();
    final policy = await _backupPolicyGuard?.current(validateMediaStore: true);
    if (policy?.isPaused == true ||
        (_backupPolicyGuard != null &&
            (!_backupPolicyGuard.isCurrentUser(userId) ||
                !_backupPolicyGuard.isCurrentScope(scope) ||
                (scope != null && policy == null))) ||
        cancelToken.isCompleted) {
      return;
    }
    if (policy != null) {
      await _uploadBatches(userId, policy, cancelToken, callbacks, useSequentialUpload);
      return;
    }
    final candidates = await _backupRepository.getCandidates(userId);
    if (candidates.isEmpty) {
      return;
    }

    final networkCapabilities = await _connectivityApi.getCapabilities();
    final hasWifi = networkCapabilities.isUnmetered;
    _logger.info('Network capabilities: $networkCapabilities, hasWifi/isUnmetered: $hasWifi');

    if (useSequentialUpload) {
      await _uploadSequentially(items: candidates, cancelToken: cancelToken, hasWifi: hasWifi, callbacks: callbacks);
    } else {
      await _executeWithWorkerPool<LocalAsset>(
        items: candidates,
        cancelToken: cancelToken,
        shouldSkip: (asset) {
          final requireWifi = _shouldRequireWiFi(asset);
          return requireWifi && !hasWifi;
        },
        processItem: (asset) => uploadSingleAsset(asset, cancelToken, callbacks: callbacks),
      );
    }
  }

  Future<void> _uploadBatches(
    String userId,
    BackupPolicy policy,
    Completer<void> cancelToken,
    UploadCallbacks callbacks,
    bool useSequentialUpload,
  ) async {
    final guard = _backupPolicyGuard!;
    String? afterId;
    while (!cancelToken.isCompleted && !shouldAbortUpload) {
      final current = await guard.current(validateMediaStore: true);
      if (current == null || current.isPaused || current.scope != policy.scope || current.revision != policy.revision) {
        return;
      }
      final candidates = await _backupRepository.getCandidates(
        userId,
        scope: policy.scope,
        limit: 200,
        afterId: afterId,
      );
      if (candidates.isEmpty || cancelToken.isCompleted) {
        return;
      }
      afterId = candidates.last.id;
      final network = await _connectivityApi.getCapabilities();
      await _executeWithWorkerPool<LocalAsset>(
        items: candidates,
        cancelToken: cancelToken,
        concurrentWorkers: useSequentialUpload ? 1 : 3,
        processItem: (asset) async {
          if (_shouldRequireWiFi(asset) && !network.isUnmetered) {
            return;
          }
          final latest = await guard.current();
          if (latest == null ||
              latest.isPaused ||
              latest.scope != policy.scope ||
              latest.revision != policy.revision ||
              !guard.isCurrentUser(userId) ||
              cancelToken.isCompleted) {
            return;
          }
          if (policy.onlyNew && await _backupPolicyRepository!.hasProcessed(policy.scope, asset.id)) {
            return;
          }
          final refreshed = await _assetService.getLocalAsset(asset.id);
          if (refreshed == null || refreshed.updatedAt != asset.updatedAt || refreshed.checksum != asset.checksum) {
            return;
          }
          await uploadSingleAsset(
            asset,
            cancelToken,
            callbacks: callbacks,
            historyScope: policy.scope,
            historyEpoch: policy.mediaStoreEpoch,
            historyRevision: policy.revision,
          );
        },
      );
    }
  }

  /// Sequential upload - used for background isolate where concurrent HTTP clients may cause issues
  Future<void> _uploadSequentially({
    required List<LocalAsset> items,
    required Completer<void> cancelToken,
    required bool hasWifi,
    required UploadCallbacks callbacks,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    for (final asset in items) {
      if (shouldAbortUpload || cancelToken.isCompleted) {
        break;
      }

      final requireWifi = _shouldRequireWiFi(asset);
      if (requireWifi && !hasWifi) {
        _logger.warning('Skipping upload for ${asset.id} because it requires WiFi');
        continue;
      }

      await uploadSingleAsset(asset, cancelToken, callbacks: callbacks);
    }
  }

  /// Manually upload picked local assets
  Future<void> uploadManual(
    List<LocalAsset> localAssets, {
    Completer<void>? cancelToken,
    UploadCallbacks callbacks = const UploadCallbacks(),
  }) async {
    if (localAssets.isEmpty) {
      return;
    }

    await _executeWithWorkerPool<LocalAsset>(
      items: localAssets,
      cancelToken: cancelToken,
      processItem: (asset) => uploadSingleAsset(asset, cancelToken, callbacks: callbacks),
    );
  }

  /// Upload files from shared intent
  Future<void> uploadShareIntent(
    List<File> files, {
    Completer<void>? cancelToken,
    void Function(String fileId, int bytes, int totalBytes)? onProgress,
    void Function(String fileId, String remoteAssetId)? onSuccess,
    void Function(String fileId, String errorMessage)? onError,
  }) async {
    if (files.isEmpty) {
      return;
    }
    await _executeWithWorkerPool<File>(
      items: files,
      cancelToken: cancelToken,
      processItem: (file) async {
        final fileId = p.hash(file.path).toString();

        final result = await _uploadSingleFile(
          file,
          deviceAssetId: fileId,
          cancelToken: cancelToken,
          onProgress: (bytes, totalBytes) => onProgress?.call(fileId, bytes, totalBytes),
        );

        if (result.isSuccess) {
          onSuccess?.call(fileId, result.remoteAssetId!);
        } else if (!result.isCancelled && result.errorMessage != null) {
          _logger.warning("Error(${result.statusCode}) uploading $fileId", result.error ?? result.errorMessage);
          onError?.call(fileId, result.errorMessage!);
        }
      },
    );
  }

  void cancel() {
    _cancelBackup();
  }

  /// Generic worker pool for concurrent uploads
  ///
  /// [items] - List of items to process
  /// [cancelToken] - Token to cancel the operation
  /// [processItem] - Function to process each item with an HTTP client
  /// [shouldSkip] - Optional function to skip items (e.g., WiFi requirement check)
  /// [concurrentWorkers] - Number of concurrent workers (default: 3)
  Future<void> _executeWithWorkerPool<T>({
    required List<T> items,
    required Completer<void>? cancelToken,
    required Future<void> Function(T item) processItem,
    bool Function(T item)? shouldSkip,
    int concurrentWorkers = 3,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    int currentIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (shouldAbortUpload || (cancelToken != null && cancelToken.isCompleted)) {
          break;
        }

        final index = currentIndex;
        if (index >= items.length) {
          break;
        }
        currentIndex++;

        final item = items[index];

        if (shouldSkip?.call(item) ?? false) {
          continue;
        }

        await processItem(item);
      }
    }

    final workerFutures = <Future<void>>[];
    for (int i = 0; i < concurrentWorkers; i++) {
      workerFutures.add(worker());
    }

    await Future.wait(workerFutures);
  }

  @visibleForTesting
  Future<void> uploadSingleAsset(
    LocalAsset asset,
    Completer<void>? cancelToken, {
    required UploadCallbacks callbacks,
    String? historyScope,
    int? historyEpoch,
    int? historyRevision,
  }) async {
    final t = StaticTranslations.instance;
    final assetNotFoundOnDevice = CurrentPlatform.isAndroid
        ? t.asset_not_found_on_device_android
        : t.asset_not_found_on_device_ios;
    File? file;
    File? livePhotoFile;

    try {
      if (cancelToken?.isCompleted ?? false) {
        return;
      }
      historyScope ??= _backupPolicyGuard?.getScope();
      final historyPolicy = historyScope == null ? null : await _backupPolicyRepository?.getPolicy(historyScope);
      historyEpoch ??= historyPolicy?.mediaStoreEpoch;
      final requireCompleteAsset = historyPolicy?.onlyNew ?? false;
      final remoteId = (await _assetService.getLocalAsset(asset.id))?.remoteId;
      if (remoteId != null) {
        if (!await _canSend(historyScope, historyRevision, asset: asset)) {
          return;
        }
        await _handleUploadSuccess(asset, remoteId, callbacks, historyScope, historyEpoch, uploaded: false);
        return;
      }

      final entity = await _storageRepository.getAssetEntityForAsset(asset);
      if (entity == null) {
        callbacks.onError?.call(asset.localId!, assetNotFoundOnDevice);
        return;
      }

      final isAvailableLocally = await _storageRepository.isAssetAvailableLocally(asset.id);

      if (!isAvailableLocally && CurrentPlatform.isIOS) {
        _logger.info("Loading iCloud asset ${asset.id} - ${asset.name}");

        // Create progress handler for iCloud download
        PMProgressHandler? progressHandler;
        StreamSubscription? progressSubscription;

        progressHandler = PMProgressHandler();
        progressSubscription = progressHandler.stream.listen((event) {
          callbacks.onICloudProgress?.call(asset.localId!, event.progress);
        });

        try {
          file = await _storageRepository.loadFileFromCloud(asset.id, progressHandler: progressHandler);
          if (entity.isLivePhoto) {
            livePhotoFile = await _storageRepository.loadMotionFileFromCloud(
              asset.id,
              progressHandler: progressHandler,
            );
          }
        } finally {
          await progressSubscription.cancel();
        }
      } else {
        // Get files locally
        file = await _storageRepository.getFileForAsset(asset.id);
        if (file == null) {
          _logger.warning("Failed to get file ${asset.id} - ${asset.name}");
          callbacks.onError?.call(asset.localId!, assetNotFoundOnDevice);
          return;
        }

        // For live photos, get the motion video file
        if (entity.isLivePhoto) {
          livePhotoFile = await _storageRepository.getMotionFileForAsset(asset);
          if (livePhotoFile == null) {
            _logger.warning("Failed to obtain motion part of the livePhoto - ${asset.name}");
            callbacks.onError?.call(asset.localId!, assetNotFoundOnDevice);
            if (requireCompleteAsset) {
              return;
            }
          }
        }
      }

      if (requireCompleteAsset && entity.isLivePhoto && livePhotoFile == null) {
        callbacks.onError?.call(asset.localId!, assetNotFoundOnDevice);
        return;
      }
      if (file == null) {
        _logger.warning("Failed to obtain file from iCloud for asset ${asset.id} - ${asset.name}");
        callbacks.onError?.call(asset.localId!, t.asset_not_found_on_icloud);
        return;
      }

      final fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
      // Some apps (e.g. DJI/Fusion) return names without an extension; fall back to the asset name for those.
      final extension = p.extension(file.path).isNotEmpty ? p.extension(file.path) : p.extension(asset.name);
      final originalFileName = p.setExtension(fileName, extension);
      final deviceId = Store.get(StoreKey.deviceId);

      if ((cancelToken?.isCompleted ?? false) || !await _canSend(historyScope, historyRevision, asset: asset)) {
        return;
      }

      final fields = {
        // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
        'deviceAssetId': asset.localId!,
        'deviceId': deviceId,
        'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
        'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
        'isFavorite': asset.isFavorite.toString(),
        'duration': (asset.durationMs ?? 0).toString(),
      };

      // Upload live photo video first if available
      String? livePhotoVideoId;
      if (entity.isLivePhoto && livePhotoFile != null) {
        final livePhotoTitle = p.setExtension(originalFileName, p.extension(livePhotoFile.path));

        final onProgress = callbacks.onProgress;
        final livePhotoResult = await _uploadRepository.uploadFile(
          file: livePhotoFile,
          originalFileName: livePhotoTitle,
          // Visibility hidden on upload to prevent the server from running regular jobs on the live photo asset
          fields: {...fields, 'visibility': AssetVisibility.hidden.toString()},
          cancelToken: cancelToken,
          onProgress: onProgress != null
              ? (bytes, totalBytes) => onProgress(asset.localId!, livePhotoTitle, bytes, totalBytes)
              : null,
          logContext: 'livePhotoVideo[${asset.localId}]',
        );

        if (livePhotoResult.isSuccess && livePhotoResult.remoteAssetId != null) {
          livePhotoVideoId = livePhotoResult.remoteAssetId;
        } else if (requireCompleteAsset) {
          if (livePhotoResult.isCancelled) {
            shouldAbortUpload = true;
          } else {
            callbacks.onError?.call(asset.localId!, livePhotoResult.errorMessage ?? assetNotFoundOnDevice);
          }
          return;
        }
      }

      if (livePhotoVideoId != null) {
        fields['livePhotoVideoId'] = livePhotoVideoId;
      }

      // Add cloudId metadata only to the still image, not the motion video, becasue when the sync id happens, the motion video can get associated with the wrong still image.
      if (CurrentPlatform.isIOS && asset.cloudId != null) {
        fields['metadata'] = jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: asset.cloudId,
              createdAt: asset.createdAt.toIso8601String(),
              adjustmentTime: asset.adjustmentTime?.toIso8601String(),
              latitude: asset.latitude?.toString(),
              longitude: asset.longitude?.toString(),
            ),
          ),
        ]);
      }

      final onProgress = callbacks.onProgress;
      if ((cancelToken?.isCompleted ?? false) || !await _canSend(historyScope, historyRevision, asset: asset)) {
        return;
      }
      final result = await _uploadRepository.uploadFile(
        file: file,
        originalFileName: originalFileName,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress != null
            ? (bytes, totalBytes) => onProgress(asset.localId!, originalFileName, bytes, totalBytes)
            : null,
        logContext: 'asset[${asset.localId}]',
      );

      if (result.isSuccess && result.remoteAssetId != null) {
        await _handleUploadSuccess(asset, result.remoteAssetId!, callbacks, historyScope, historyEpoch);
      } else if (result.isCancelled) {
        shouldAbortUpload = true;
      } else if (result.errorMessage != null) {
        _logger.severe(
          () =>
              "Error(${result.statusCode}) uploading ${asset.localId} | $originalFileName | Created on ${asset.createdAt}",
          result.error ?? result.errorMessage,
        );

        callbacks.onError?.call(asset.localId!, result.errorMessage!);

        if (result.errorMessage == "Quota has been exceeded!") {
          shouldAbortUpload = true;
        }
      }
    } catch (error, stackTrace) {
      _logger.severe(() => "Error backup asset: $error", stackTrace);
      callbacks.onError?.call(asset.localId!, error.toString());
    } finally {
      if (Platform.isIOS) {
        try {
          await file?.delete();
          await livePhotoFile?.delete();
        } catch (error, stackTrace) {
          _logger.severe(() => "ERROR deleting file: $error", stackTrace);
        }
      }
    }
  }

  Future<bool> _canSend(String? scope, int? revision, {required LocalAsset asset}) async {
    if (scope == null) {
      return true;
    }
    if (!(_backupPolicyGuard?.isCurrentScope(scope) ?? true)) {
      return false;
    }
    if (revision == null) {
      return true;
    }
    final processed = await _backupPolicyRepository!.hasProcessed(scope, asset.id);
    final latest = await _assetService.getLocalAsset(asset.id);
    final policy = await _backupPolicyRepository.getPolicy(scope);
    return (_backupPolicyGuard?.isCurrentScope(scope) ?? true) &&
        policy.revision == revision &&
        !policy.isPaused &&
        !(policy.onlyNew && processed) &&
        latest != null &&
        latest.updatedAt == asset.updatedAt &&
        latest.checksum == asset.checksum;
  }

  Future<void> _handleUploadSuccess(
    LocalAsset asset,
    String remoteId,
    UploadCallbacks callbacks,
    String? historyScope,
    int? historyEpoch, {
    bool uploaded = true,
  }) async {
    if (historyScope != null) {
      await _backupPolicyRepository?.recordUploaded(
        historyScope,
        asset.localId!,
        checksum: asset.checksum,
        remoteId: remoteId,
        mediaStoreEpoch: historyEpoch,
        reason: uploaded ? BackupHistoryReason.uploaded : BackupHistoryReason.remoteMatched,
      );
    }
    callbacks.onSuccess?.call(asset.localId!, remoteId);
    if (historyScope != null &&
        (!(_backupPolicyGuard?.isCurrentScope(historyScope) ?? true) ||
            (await _backupPolicyRepository?.getPolicy(historyScope))?.onlyNew == true)) {
      return;
    }
    try {
      await _assetService.stackEditedUpload(asset.localId!, remoteId, asset.checksum);
    } catch (error) {
      _logger.warning("Failed to stack the upload of ${asset.localId}: $error");
    }
  }

  Future<UploadResult> _uploadSingleFile(
    File file, {
    required String deviceAssetId,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
  }) async {
    try {
      // ignore: avoid_slow_async_io
      final stats = await file.stat();
      final fileCreatedAt = stats.changed;
      final fileModifiedAt = stats.modified;
      final filename = p.basename(file.path);

      final fields = {
        // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
        'deviceAssetId': deviceAssetId,
        'deviceId': Store.get(StoreKey.deviceId),
        'fileCreatedAt': fileCreatedAt.toUtc().toIso8601String(),
        'fileModifiedAt': fileModifiedAt.toUtc().toIso8601String(),
        'isFavorite': 'false',
        'duration': '0',
      };

      return await _uploadRepository.uploadFile(
        file: file,
        originalFileName: filename,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress,
        logContext: 'shareIntent[$deviceAssetId]',
      );
    } catch (e) {
      return UploadResult.error(errorMessage: e.toString());
    }
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    final backup = SettingsRepository.instance.appConfig.backup;
    if (asset.isVideo && backup.useCellularForVideos) {
      return false;
    }
    if (!asset.isVideo && backup.useCellularForPhotos) {
      return false;
    }
    return true;
  }
}
