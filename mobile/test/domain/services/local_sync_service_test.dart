import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/backup_policy_guard.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';
import '../../service.mocks.dart';

void main() {
  late LocalSyncService sut;
  late LocalAlbumRepository mockLocalAlbumRepository;
  late TrashedLocalAssetRepository mockTrashedLocalAssetRepository;
  late AssetMediaRepository mockAssetMediaRepository;
  late MockPermissionRepository mockPermissionRepository;
  late MockNativeSyncApi mockNativeSyncApi;
  late Drift db;
  var onlyNew = false;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(<LocalAlbum>[]);
    registerFallbackValue(<String, List<LocalAsset>>{});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await Store.clear();
    await db.close();
  });

  setUp(() async {
    onlyNew = false;
    mockLocalAlbumRepository = MockLocalAlbumRepository();
    mockTrashedLocalAssetRepository = MockTrashedLocalAssetRepository();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockPermissionRepository = MockPermissionRepository();
    mockNativeSyncApi = MockNativeSyncApi();

    when(() => mockNativeSyncApi.shouldFullSync()).thenAnswer((_) async => false);
    when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});
    when(() => mockNativeSyncApi.clearSyncCheckpoint()).thenAnswer((_) async {});
    when(() => mockNativeSyncApi.getMediaChanges()).thenAnswer(
      (_) async => SyncDelta(hasChanges: false, updates: const [], deletes: const [], assetAlbums: const {}),
    );
    when(() => mockNativeSyncApi.getTrashedAssets()).thenAnswer((_) async => {});
    when(() => mockTrashedLocalAssetRepository.processTrashSnapshot(any())).thenAnswer((_) async {});
    when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => []);
    when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer((_) async => {});
    when(() => mockTrashedLocalAssetRepository.applyRestoredAssets(any())).thenAnswer((_) async {});
    when(() => mockTrashedLocalAssetRepository.trashLocalAsset(any())).thenAnswer((_) async {});
    when(() => mockAssetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
      final ids = invocation.positionalArguments.first as List<String>;
      return ids;
    });

    sut = LocalSyncService(
      backupPolicyGuard: BackupPolicyGuard(
        getScope: () => 'scope',
        getUserId: () => 'user',
        getPolicy: (_) async => BackupPolicy(
          scope: 'scope',
          status: onlyNew ? BackupPolicyStatus.active : BackupPolicyStatus.legacy,
          mediaStoreVersion: 'v1',
        ),
        getMediaStoreVersion: () async => 'v1',
        pause: (_, {expectedRevision}) async {},
      ),
      localAlbumRepository: mockLocalAlbumRepository,
      trashedLocalAssetRepository: mockTrashedLocalAssetRepository,
      assetMediaRepository: mockAssetMediaRepository,
      permissionRepository: mockPermissionRepository,
      nativeSyncApi: mockNativeSyncApi,
    );

    await Store.put(StoreKey.manageLocalMediaAndroid, false);
    when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => false);
  });

  test('strict baseline scans read every album before committing a complete snapshot', () async {
    when(
      () => mockNativeSyncApi.getAlbums(),
    ).thenAnswer((_) async => [PlatformAlbum(id: 'album', name: 'Camera', isCloud: false, assetCount: 0)]);
    when(() => mockLocalAlbumRepository.getAll()).thenAnswer((_) async => []);
    when(() => mockNativeSyncApi.getAssetsForAlbum('album')).thenAnswer((_) async => []);
    when(() => mockLocalAlbumRepository.replaceSnapshot(any(), any())).thenAnswer((_) async {});
    when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});
    await sut.sync(full: true, throwOnError: true);
    verifyInOrder([
      () => mockNativeSyncApi.checkpointSync(),
      () => mockNativeSyncApi.getAssetsForAlbum('album'),
      () => mockLocalAlbumRepository.replaceSnapshot(any(), any()),
    ]);
  });

  test('strict baseline keeps photos created in an already scanned album after the checkpoint', () async {
    var generation = 10;
    var checkpoint = 0;
    when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async => checkpoint = generation);
    when(() => mockNativeSyncApi.getAlbums()).thenAnswer(
      (_) async => [
        PlatformAlbum(id: 'camera', name: 'Camera', isCloud: false, assetCount: 0),
        PlatformAlbum(id: 'screenshots', name: 'Screenshots', isCloud: false, assetCount: 0),
      ],
    );
    when(() => mockLocalAlbumRepository.getAll()).thenAnswer((_) async => []);
    when(() => mockNativeSyncApi.getAssetsForAlbum('camera')).thenAnswer((_) async => []);
    when(() => mockNativeSyncApi.getAssetsForAlbum('screenshots')).thenAnswer((_) async {
      generation++;
      return [];
    });
    when(() => mockLocalAlbumRepository.replaceSnapshot(any(), any())).thenAnswer((_) async {});
    await sut.sync(full: true, throwOnError: true);
    expect(checkpoint, 10);
    expect(generation, greaterThan(checkpoint));
    verify(() => mockNativeSyncApi.checkpointSync()).called(1);
  });

  test('strict baseline scans propagate album enumeration failures', () async {
    when(() => mockNativeSyncApi.getAlbums()).thenThrow(StateError('permission revoked'));
    await expectLater(sut.sync(full: true, throwOnError: true, skipMediaManagement: true), throwsStateError);
    verifyNever(() => mockLocalAlbumRepository.replaceSnapshot(any(), any()));
    verify(() => mockNativeSyncApi.clearSyncCheckpoint()).called(1);
  });

  test('strict baseline scans propagate failures inside an album', () async {
    when(
      () => mockNativeSyncApi.getAlbums(),
    ).thenAnswer((_) async => [PlatformAlbum(id: 'album', name: 'Camera', isCloud: false, assetCount: 1)]);
    when(() => mockLocalAlbumRepository.getAll()).thenAnswer((_) async => []);
    when(() => mockNativeSyncApi.getAssetsForAlbum('album')).thenThrow(StateError('scan interrupted'));
    await expectLater(sut.sync(full: true, throwOnError: true), throwsStateError);
    verifyNever(() => mockLocalAlbumRepository.replaceSnapshot(any(), any()));
    verify(() => mockNativeSyncApi.clearSyncCheckpoint()).called(1);
  });

  test('new-files mode blocks the public local trash synchronization entry', () async {
    onlyNew = true;
    await sut.processTrashedAssets({});
    verifyZeroInteractions(mockTrashedLocalAssetRepository);
    verifyZeroInteractions(mockAssetMediaRepository);
  });

  group('LocalSyncService - syncTrashedAssets gating', () {
    test('invokes syncTrashedAssets when Android flag enabled and permission granted', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => true);

      await sut.sync();

      verify(() => mockNativeSyncApi.getTrashedAssets()).called(1);
      verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(any())).called(1);
    });

    test('skips syncTrashedAssets when store flag disabled', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, false);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => true);

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });

    test('skips syncTrashedAssets when MANAGE_MEDIA permission absent', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => false);

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });

    test('skips syncTrashedAssets on non-Android platforms', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => true);

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });
  });

  group('LocalSyncService - syncTrashedAssets behavior', () {
    test('processes trashed snapshot, restores assets, and trashes local files', () async {
      final platformAsset = PlatformAsset(
        id: 'remote-id',
        name: 'remote.jpg',
        type: AssetType.image.index,
        durationMs: 0,
        orientation: 0,
        isFavorite: false,
        playbackStyle: PlatformAssetPlaybackStyle.image,
      );

      final assetsToRestore = [LocalAssetStub.image1];
      when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => assetsToRestore);
      final restoredIds = ['image1'];
      when(() => mockAssetMediaRepository.restoreAssetsFromTrash(any())).thenAnswer((invocation) async {
        final Iterable<LocalAsset> requested = invocation.positionalArguments.first as Iterable<LocalAsset>;
        expect(requested, orderedEquals(assetsToRestore));
        return restoredIds;
      });

      final localAssetToTrash = LocalAssetStub.image2.copyWith(id: 'local-trash', checksum: 'checksum-trash');
      when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer(
        (_) async => {
          'album-a': [localAssetToTrash],
        },
      );

      await sut.processTrashedAssets({
        'album-a': [platformAsset],
      });

      final trashedSnapshot =
          verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(captureAny())).captured.single
              as Iterable<TrashedAsset>;
      expect(trashedSnapshot.length, 1);
      final trashedEntry = trashedSnapshot.single;
      expect(trashedEntry.albumId, 'album-a');
      expect(trashedEntry.asset.id, platformAsset.id);
      expect(trashedEntry.asset.name, platformAsset.name);
      verify(() => mockTrashedLocalAssetRepository.getToTrash()).called(1);

      verify(() => mockAssetMediaRepository.restoreAssetsFromTrash(any())).called(1);
      verify(() => mockTrashedLocalAssetRepository.applyRestoredAssets(restoredIds)).called(1);

      final moveArgs = verify(() => mockAssetMediaRepository.deleteAll(captureAny())).captured.single as List<String>;
      expect(moveArgs, ['local-trash']);
      final trashArgs =
          verify(() => mockTrashedLocalAssetRepository.trashLocalAsset(captureAny())).captured.single
              as Map<String, List<LocalAsset>>;
      expect(trashArgs.keys, ['album-a']);
      expect(trashArgs['album-a'], [localAssetToTrash]);
    });

    test('records only local assets that were moved to device trash', () async {
      final movedAsset = LocalAssetStub.image1.copyWith(id: 'moved-local', checksum: 'checksum-moved');
      final skippedAsset = LocalAssetStub.image2.copyWith(id: 'skipped-local', checksum: 'checksum-skipped');
      when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer(
        (_) async => {
          'album-a': [movedAsset],
          'album-b': [skippedAsset],
        },
      );
      when(() => mockAssetMediaRepository.deleteAll(any())).thenAnswer((_) async => ['moved-local']);

      await sut.processTrashedAssets({});

      final trashArgs =
          verify(() => mockTrashedLocalAssetRepository.trashLocalAsset(captureAny())).captured.single
              as Map<String, List<LocalAsset>>;
      expect(trashArgs.keys, ['album-a']);
      expect(trashArgs['album-a'], [movedAsset]);
    });

    test('does not attempt restore when repository has no assets to restore', () async {
      when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => []);

      await sut.processTrashedAssets({});

      final trashedSnapshot =
          verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(captureAny())).captured.single
              as Iterable<TrashedAsset>;
      expect(trashedSnapshot, isEmpty);
      verifyNever(() => mockAssetMediaRepository.restoreAssetsFromTrash(any()));
      verifyNever(() => mockTrashedLocalAssetRepository.applyRestoredAssets(any()));
    });

    test('does not move local assets when repository finds nothing to trash', () async {
      when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer((_) async => {});

      await sut.processTrashedAssets({});

      verifyNever(() => mockAssetMediaRepository.deleteAll(any()));
      verifyNever(() => mockTrashedLocalAssetRepository.trashLocalAsset(any()));
    });
  });

  group('LocalSyncService - PlatformAsset conversion', () {
    test('toLocalAsset uses correct updatedAt timestamp', () {
      final platformAsset = PlatformAsset(
        id: 'test-id',
        name: 'test.jpg',
        type: AssetType.image.index,
        durationMs: 0,
        orientation: 0,
        isFavorite: false,
        createdAt: 1700000000,
        updatedAt: 1732000000,
        playbackStyle: PlatformAssetPlaybackStyle.image,
      );

      final localAsset = platformAsset.toLocalAsset();

      expect(localAsset.createdAt.millisecondsSinceEpoch ~/ 1000, 1700000000);
      expect(localAsset.updatedAt.millisecondsSinceEpoch ~/ 1000, 1732000000);
      expect(localAsset.updatedAt, isNot(localAsset.createdAt));
    });
  });
}
