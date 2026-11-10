import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/backup_policy_guard.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_policy.provider.dart';
import 'package:immich_mobile/providers/backup/backup_policy_guard.provider.dart';
import 'package:immich_mobile/providers/infrastructure/cancel.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../medium/repository_context.dart';
import '../../repository.mocks.dart';
import '../../service.mocks.dart';
import '../../unit/factories/user_factory.dart';

void main() {
  late MediumRepositoryContext storeContext;
  late MediumRepositoryContext context;
  late MockNativeSyncApi native;
  late MockForegroundUploadService foreground;
  late MockBackgroundUploadService background;
  late MockBackgroundWorkerLockService lock;
  late MockBackgroundSyncManager sync;
  late MockUserService users;
  late ProviderContainer worker;
  late List<Override> localOverrides;
  late String scope;
  late int runs;
  Object? workerError;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    storeContext = MediumRepositoryContext();
    await StoreService.init(storeRepository: StoreRepository(storeContext.db), listenUpdates: false);
  });

  tearDownAll(() async {
    await StoreService.I.dispose();
    await storeContext.dispose();
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    context = MediumRepositoryContext();
    native = MockNativeSyncApi();
    foreground = MockForegroundUploadService();
    background = MockBackgroundUploadService();
    lock = MockBackgroundWorkerLockService();
    sync = MockBackgroundSyncManager();
    users = MockUserService();
    runs = 0;
    workerError = null;
    final user = UserFactory.createDto(id: 'user-1');
    const serverUrl = 'https://photos.example.com';
    scope = backupScope(serverUrl, user.id);
    await StoreService.I.put(StoreKey.currentUser, user);
    await StoreService.I.put(StoreKey.serverUrl, serverUrl);
    when(users.tryGetMyUser).thenReturn(user);
    when(users.watchMyUser).thenAnswer((_) => const Stream.empty());
    when(foreground.cancelAndWait).thenAnswer((_) async {});
    when(() => foreground.getBackupCounts(any())).thenAnswer((_) async => (total: 1, remainder: 0, processing: 0));
    when(lock.lock).thenAnswer((_) async {});
    when(sync.cancelResumeSyncs).thenAnswer((_) async {});
    when(native.getMediaStoreVersion).thenAnswer((_) async => 'media-1');
    when(
      native.getAlbums,
    ).thenAnswer((_) async => [PlatformAlbum(id: 'camera', name: 'Camera', isCloud: false, assetCount: 1)]);
    when(() => native.getAssetsForAlbum('camera')).thenAnswer(
      (_) async => [
        PlatformAsset(
          id: 'native-photo',
          name: 'photo.jpg',
          type: AssetType.image.index,
          durationMs: 0,
          orientation: 0,
          isFavorite: false,
          playbackStyle: PlatformAssetPlaybackStyle.image,
        ),
      ],
    );
    when(native.checkpointSync).thenAnswer((_) async {});
    when(native.clearSyncCheckpoint).thenAnswer((_) async {});
    localOverrides = [
      driftProvider.overrideWithValue(context.db),
      nativeSyncApiProvider.overrideWithValue(native),
      assetMediaRepositoryProvider.overrideWithValue(MockAssetMediaRepository()),
      permissionRepositoryProvider.overrideWithValue(MockPermissionRepository()),
      backupPolicyGuardProvider.overrideWithValue(
        BackupPolicyGuard(
          getScope: () => scope,
          getUserId: () => user.id,
          getPolicy: context.db.backupPolicyRepository.getPolicy,
          getMediaStoreVersion: native.getMediaStoreVersion,
          pause: context.db.backupPolicyRepository.pause,
        ),
      ),
    ];
    worker = ProviderContainer(
      overrides: [...localOverrides, cancellationProvider.overrideWithValue(Completer<void>())],
    );
  });

  tearDown(() async {
    worker.dispose();
    await context.dispose();
    await StoreService.I.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  ProviderContainer rootContainer({BackupBaselineRunner? runner}) {
    final container = ProviderContainer(
      overrides: [
        ...localOverrides,
        foregroundUploadServiceProvider.overrideWithValue(foreground),
        backgroundUploadServiceProvider.overrideWithValue(background),
        backgroundWorkerLockServiceProvider.overrideWithValue(lock),
        backgroundSyncProvider.overrideWithValue(sync),
        currentUserProvider.overrideWith((ref) => CurrentUserProvider(users)),
        appConfigProvider.overrideWithValue(defaultConfig),
        backupBaselineRunnerProvider.overrideWithValue(
          runner ??
              (computation) async {
                runs++;
                try {
                  return await computation(worker);
                } catch (error) {
                  workerError = error;
                  return null;
                }
              },
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the production controller scans through a worker without root cancellation wiring', () async {
    final container = rootContainer();
    expect(() => container.read(cancellationProvider), throwsUnimplementedError);
    expect(() => container.read(localSyncServiceProvider), throwsUnimplementedError);

    await container.read(backupPolicyControllerProvider).enableOnlyNew();

    expect(runs, 1);
    expect(workerError, isNull);
    expect((await context.db.backupPolicyRepository.getPolicy(scope)).status, BackupPolicyStatus.active);
    expect(await context.db.backupPolicyRepository.hasProcessed(scope, 'native-photo'), isTrue);
    verify(() => native.getAssetsForAlbum('camera')).called(1);
    verify(native.checkpointSync).called(1);
  });

  test('a swallowed worker scan failure cannot activate a baseline', () async {
    when(native.getAlbums).thenThrow(StateError('Media enumeration failed'));
    final container = rootContainer();

    await expectLater(container.read(backupPolicyControllerProvider).enableOnlyNew(), throwsStateError);

    expect(runs, 1);
    expect(workerError, isA<StateError>());
    expect((await context.db.backupPolicyRepository.getPolicy(scope)).status, BackupPolicyStatus.paused);
    expect(await context.db.backupPolicyRepository.hasProcessed(scope, 'native-photo'), isFalse);
    verify(native.checkpointSync).called(1);
    verify(native.clearSyncCheckpoint).called(1);
  });

  test('a worker result other than true keeps the production controller paused', () async {
    final container = rootContainer(runner: (_) async => false);

    await expectLater(container.read(backupPolicyControllerProvider).enableOnlyNew(), throwsStateError);

    expect((await context.db.backupPolicyRepository.getPolicy(scope)).status, BackupPolicyStatus.paused);
    verifyNever(native.getAlbums);
  });
}
