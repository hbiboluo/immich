import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/backup_policy_guard.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../api.mocks.dart';
import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';
import '../service.mocks.dart';

void main() {
  late ForegroundUploadService sut;
  late MockUploadRepository mockUploadRepository;
  late MockStorageRepository mockStorageRepository;
  late MockBackupRepository mockBackupRepository;
  late MockConnectivityApi mockConnectivityApi;
  late MockAssetMediaRepository mockAssetMediaRepository;
  late MockAssetService mockAssetService;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => 'test',
    );
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await SettingsRepository.ensureInitialized(db);

    await Store.put(StoreKey.serverEndpoint, 'http://demo.immich.app');
    await Store.put(StoreKey.deviceId, 'device-id');

    registerFallbackValue(File('file'));
    registerFallbackValue(LocalAssetStub.image1);
    registerFallbackValue(<String, String>{});
  });

  setUp(() {
    mockUploadRepository = MockUploadRepository();
    mockStorageRepository = MockStorageRepository();
    mockBackupRepository = MockBackupRepository();
    mockConnectivityApi = MockConnectivityApi();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockAssetService = MockAssetService();
    when(() => mockAssetService.getLocalAsset(any())).thenAnswer((_) async => null);
    when(() => mockAssetService.stackEditedUpload(any(), any(), any())).thenAnswer((_) async {});

    sut = ForegroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockBackupRepository,
      mockConnectivityApi,
      mockAssetMediaRepository,
      mockAssetService,
    );
  });

  List<Map<String, String>> captureFields() {
    final captured = <Map<String, String>>[];
    when(
      () => mockUploadRepository.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
      ),
    ).thenAnswer((invocation) async {
      final fields = invocation.namedArguments[#fields] as Map<String, String>;
      captured.add(Map.of(fields));
      return UploadResult.success(remoteAssetId: 'remote-${captured.length}');
    });
    return captured;
  }

  List<String> captureOriginalFileNames() {
    final captured = <String>[];
    when(
      () => mockUploadRepository.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
      ),
    ).thenAnswer((invocation) async {
      captured.add(invocation.namedArguments[#originalFileName] as String);
      return UploadResult.success(remoteAssetId: 'remote-${captured.length}');
    });
    return captured;
  }

  group('uploadSingleAsset', () {
    test('should upload the motion part hidden and keep the still image visible', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/still.heic');
      final videoFile = File('/path/to/motion.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => videoFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'live.heic');

      final captured = captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(captured, hasLength(2));
      expect(captured[0]['visibility'], equals('hidden'));
      expect(captured[0].containsKey('livePhotoVideoId'), isFalse);
      expect(captured[1].containsKey('visibility'), isFalse);
      expect(captured[1]['livePhotoVideoId'], equals('remote-1'));
    });

    test('should not set visibility for a regular photo', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/photo.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');

      final captured = captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(captured, hasLength(1));
      expect(captured[0].containsKey('visibility'), isFalse);
    });

    test('corrects the extension when iOS returns a rendered file for a .dng asset', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/IMG_6499.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'IMG_6499.dng');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['IMG_6499.jpg']));
    });

    test('keeps the .dng extension for a genuine RAW original', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/IMG_5210.dng');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'IMG_5210.dng');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['IMG_5210.dng']));
    });

    test('borrows the extension from the asset name for an extensionless name (DJI/Fusion)', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/DJI_0001');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'DJI_0001');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['DJI_0001.jpg']));
    });

    test('stacks a plain photo after its upload', () async {
      final asset = LocalAssetStub.image1.copyWith(checksum: 'sha');
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/photo.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');
      captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      verify(() => mockAssetService.getLocalAsset(asset.id)).called(1);
      verify(() => mockAssetService.stackEditedUpload(asset.localId!, 'remote-1', 'sha')).called(1);
      verifyNoMoreInteractions(mockAssetService);
    });

    test('stacks the still of a live photo, not its video', () async {
      final asset = LocalAssetStub.image1.copyWith(checksum: 'sha');
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/still.heic');
      final videoFile = File('/path/to/motion.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => videoFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'live.heic');
      captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      verify(() => mockAssetService.getLocalAsset(asset.id)).called(1);
      verify(() => mockAssetService.stackEditedUpload(asset.localId!, 'remote-2', 'sha')).called(1);
      verifyNoMoreInteractions(mockAssetService);
    });

    test('does not upload a photo the server already has', () async {
      final asset = LocalAssetStub.image1.copyWith(checksum: 'sha');
      final succeeded = <String>[];
      when(() => mockAssetService.getLocalAsset(asset.id)).thenAnswer((_) async => asset.copyWith(remoteId: 'remote'));

      await sut.uploadSingleAsset(
        asset,
        null,
        callbacks: UploadCallbacks(onSuccess: (_, remoteId) => succeeded.add(remoteId)),
      );

      expect(succeeded, equals(['remote']));
      verify(() => mockAssetService.stackEditedUpload(asset.localId!, 'remote', 'sha')).called(1);
      verifyZeroInteractions(mockStorageRepository);
      verifyZeroInteractions(mockUploadRepository);
    });
  });
  group('upload-once policy', () {
    late String scope;
    late String? currentScope;
    var sequence = 0;
    final asset = LocalAssetStub.image1;

    setUp(() async {
      scope = 'upload-test-${sequence++}';
      currentScope = scope;
      await db.backupPolicyRepository.beginInitialization(scope);
      await db.backupPolicyRepository.completeInitialization(scope, 'v1');
      final guard = BackupPolicyGuard(
        getScope: () => currentScope,
        getUserId: () => 'user',
        getPolicy: db.backupPolicyRepository.getPolicy,
        getMediaStoreVersion: () async => 'v1',
        pause: db.backupPolicyRepository.pause,
      );
      sut = ForegroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockBackupRepository,
        mockConnectivityApi,
        mockAssetMediaRepository,
        mockAssetService,
        backupPolicyRepository: db.backupPolicyRepository,
        backupPolicyGuard: guard,
      );
      final entity = MockAssetEntity();
      when(() => entity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(any())).thenAnswer((_) async => entity);
      when(() => mockStorageRepository.isAssetAvailableLocally(any())).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(any())).thenAnswer((_) async => File('/photo.jpg'));
      when(() => mockStorageRepository.clearCache()).thenAnswer((_) async {});
      when(() => mockAssetMediaRepository.getOriginalFilename(any())).thenAnswer((_) async => 'photo.jpg');
      when(() => mockConnectivityApi.getCapabilities()).thenAnswer((_) async => [NetworkCapability.unmetered]);
    });

    void respond(Future<UploadResult> Function(Invocation) response) {
      when(
        () => mockUploadRepository.uploadFile(
          file: any(named: 'file'),
          originalFileName: any(named: 'originalFileName'),
          fields: any(named: 'fields'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: any(named: 'logContext'),
        ),
      ).thenAnswer(response);
    }

    test('manual success records durable history and does not stack edited originals', () async {
      captureFields();
      var succeeded = false;
      await sut.uploadSingleAsset(asset, null, callbacks: UploadCallbacks(onSuccess: (_, _) => succeeded = true));
      expect(succeeded, isTrue);
      expect(await db.backupPolicyRepository.hasProcessed(scope, asset.id), isTrue);
      verifyNever(() => mockAssetService.stackEditedUpload(any(), any(), any()));
    });

    test('failed and cancelled uploads leave the file pending', () async {
      for (final result in [UploadResult.error(errorMessage: 'network'), UploadResult.cancelled()]) {
        respond((_) async => result);
        await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());
        expect(await db.backupPolicyRepository.hasProcessed(scope, asset.id), isFalse);
      }
    });

    test('already matched server assets record a match without another request', () async {
      when(() => mockAssetService.getLocalAsset(asset.id)).thenAnswer((_) async => asset.copyWith(remoteId: 'remote'));
      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());
      expect(await db.backupPolicyRepository.hasProcessed(scope, asset.id), isTrue);
      final row = await db
          .customSelect('SELECT reason FROM backup_history_entity WHERE scope = ?', variables: [Variable(scope)])
          .getSingle();
      expect(row.read<int>('reason'), BackupHistoryReason.remoteMatched.index);
      verifyZeroInteractions(mockUploadRepository);
    });

    test('a policy change while loading a file prevents the request', () async {
      when(() => mockStorageRepository.getFileForAsset(any())).thenAnswer((_) async {
        await db.backupPolicyRepository.pause(scope);
        return File('/photo.jpg');
      });
      final revision = (await db.backupPolicyRepository.getPolicy(scope)).revision;
      final requests = captureFields();
      await sut.uploadSingleAsset(
        asset,
        null,
        callbacks: const UploadCallbacks(),
        historyScope: scope,
        historyRevision: revision,
      );
      expect(requests, isEmpty);
      expect(await db.backupPolicyRepository.hasProcessed(scope, asset.id), isFalse);
    });

    test('editing a file during loading invalidates the automatic upload snapshot', () async {
      when(() => mockAssetService.getLocalAsset(asset.id)).thenAnswer((_) async => asset);
      when(() => mockStorageRepository.getFileForAsset(any())).thenAnswer((_) async {
        when(
          () => mockAssetService.getLocalAsset(asset.id),
        ).thenAnswer((_) async => asset.copyWith(updatedAt: asset.updatedAt.add(const Duration(seconds: 1))));
        return File('/photo.jpg');
      });
      final revision = (await db.backupPolicyRepository.getPolicy(scope)).revision;
      final requests = captureFields();
      await sut.uploadSingleAsset(
        asset,
        null,
        callbacks: const UploadCallbacks(),
        historyScope: scope,
        historyRevision: revision,
      );
      expect(requests, isEmpty);
      expect(await db.backupPolicyRepository.hasProcessed(scope, asset.id), isFalse);
    });

    test('changing account while loading a file prevents the request', () async {
      when(() => mockStorageRepository.getFileForAsset(any())).thenAnswer((_) async {
        currentScope = 'different-account';
        return File('/photo.jpg');
      });
      final requests = captureFields();
      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());
      expect(requests, isEmpty);
      expect(await db.backupPolicyRepository.hasProcessed(scope, asset.id), isFalse);
    });

    test('a failed live photo motion upload does not complete the still asset', () async {
      final entity = MockAssetEntity();
      when(() => entity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(any())).thenAnswer((_) async => entity);
      when(() => mockStorageRepository.getMotionFileForAsset(any())).thenAnswer((_) async => File('/motion.mov'));
      var requests = 0;
      respond((_) async {
        requests++;
        return UploadResult.error(errorMessage: 'motion failed');
      });
      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());
      expect(requests, 1);
      expect(await db.backupPolicyRepository.hasProcessed(scope, asset.id), isFalse);
    });

    test('cancelAndWait waits for an in-flight request to settle', () async {
      final entered = Completer<void>();
      final released = Completer<UploadResult>();
      when(
        () => mockBackupRepository.getCandidates('user', scope: scope, limit: 200, afterId: null),
      ).thenAnswer((_) async => [asset]);
      when(() => mockAssetService.getLocalAsset(asset.id)).thenAnswer((_) async => asset);
      respond((_) {
        entered.complete();
        return released.future;
      });
      final upload = sut.uploadCandidates('user', Completer<void>());
      await entered.future;
      var stopped = false;
      final stop = sut.cancelAndWait().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      released.complete(UploadResult.cancelled());
      await Future.wait([upload, stop]);
      expect(stopped, isTrue);
      expect(await db.backupPolicyRepository.hasProcessed(scope, asset.id), isFalse);
    });

    test('walks keyset batches after successful files leave the queue', () async {
      final assets = List.generate(201, (i) => asset.copyWith(id: i.toString().padLeft(4, '0')));
      when(
        () => mockBackupRepository.getCandidates(
          'user',
          scope: scope,
          limit: 200,
          afterId: any(named: 'afterId'),
        ),
      ).thenAnswer((invocation) async {
        final after = invocation.namedArguments[#afterId] as String?;
        return assets.where((a) => after == null || a.id.compareTo(after) > 0).take(200).toList();
      });
      when(
        () => mockAssetService.getLocalAsset(any()),
      ).thenAnswer((invocation) async => assets.firstWhere((a) => a.id == invocation.positionalArguments.first));
      final requests = captureFields();
      await sut.uploadCandidates('user', Completer<void>());
      expect(requests, hasLength(201));
      expect(await db.backupPolicyRepository.hasProcessed(scope, assets.last.id), isTrue);
    });
  });
}
