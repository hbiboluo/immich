import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/local/album.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_policy.repository.dart';
import 'package:immich_mobile/utils/option.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late BackupPolicyRepository sut;
  late BackupRepository backup;
  late String userId;
  late String scope;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = ctx.db.backupPolicyRepository;
    backup = ctx.db.backupRepository;
    userId = (await ctx.newUser()).id;
    scope = backupScope('https://photos.example.com/api', userId);
  });

  tearDown(() async => ctx.dispose());

  Future<void> initialize({String version = 'media-v1'}) async {
    await sut.beginInitialization(scope);
    await sut.completeInitialization(scope, version);
  }

  Future<String> selectedAsset({String? id, String? checksum}) async {
    final album = await ctx.newLocalAlbum(backupSelection: BackupSelection.selected);
    final asset = await ctx.newLocalAsset(id: id, checksum: checksum);
    await ctx.newLocalAlbumAsset(albumId: album.id, assetId: asset.id);
    return asset.id;
  }

  test('uses a normalized server and account scope', () {
    expect(backupScope('HTTPS://Photos.Example.com:443/api/', userId), scope);
    expect(backupScope('https://other.example.com/api', userId), isNot(scope));
    expect(backupScope('https://photos.example.com/api', 'other-user'), isNot(scope));
  });

  test('keeps legacy behavior until explicitly initialized', () async {
    final id = await selectedAsset();
    expect((await sut.getPolicy(scope)).status, BackupPolicyStatus.legacy);
    expect((await backup.getCandidates(userId, scope: scope)).single.id, id);
  });

  test('persists an initializing state that blocks all automatic candidates', () async {
    await selectedAsset();
    await sut.beginInitialization(scope);
    final policy = await sut.getPolicy(scope);
    expect(policy.onlyNew, isTrue);
    expect(policy.isPaused, isTrue);
    expect(policy.revision, 1);
    expect(await backup.getCandidates(userId, scope: scope), isEmpty);
    expect((await backup.getAllCounts(userId, scope: scope)).remainder, 1);
  });

  test('baselines all visible files including unselected albums and unhashed files', () async {
    final selected = await selectedAsset();
    final unselectedAlbum = await ctx.newLocalAlbum(backupSelection: BackupSelection.none);
    final unselected = await ctx.newLocalAsset(checksumOption: const Option.none());
    await ctx.newLocalAlbumAsset(albumId: unselectedAlbum.id, assetId: unselected.id);
    await initialize();

    expect(await sut.hasProcessed(scope, selected), isTrue);
    expect(await sut.hasProcessed(scope, unselected.id), isTrue);
    expect(await backup.getCandidates(userId, scope: scope), isEmpty);
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 1, uploaded: 0, matched: 0));
    await (ctx.db.update(ctx.db.localAlbumEntity)..where((a) => a.id.equals(unselectedAlbum.id))).write(
      const LocalAlbumEntityCompanion(backupSelection: Value(BackupSelection.selected)),
    );
    expect(await backup.getCandidates(userId, scope: scope, onlyHashed: false), isEmpty);
    expect((await backup.getAllCounts(userId, scope: scope)).processing, 0);
    expect((await sut.getHistoryCounts(scope, userId)).ignored, 2);
  });

  test('only uploads new identities and keeps original edits processed', () async {
    final oldId = await selectedAsset(checksum: 'before-edit');
    await initialize();
    await (ctx.db.update(
      ctx.db.localAssetEntity,
    )..where((a) => a.id.equals(oldId))).write(const LocalAssetEntityCompanion(checksum: Value('after-edit')));
    final newId = await selectedAsset(checksum: 'new-content');
    expect((await backup.getCandidates(userId, scope: scope)).map((a) => a.id), [newId]);
    expect(await backup.getAllCounts(userId, scope: scope), (total: 2, remainder: 1, processing: 0));
  });

  test('an unuploaded baseline checksum does not suppress a new file identity', () async {
    await selectedAsset(checksum: 'same-content');
    await initialize();
    final newId = await selectedAsset(checksum: 'same-content');
    expect((await backup.getCandidates(userId, scope: scope)).single.id, newId);
  });

  test('uploaded history survives remote and local cache deletion', () async {
    await initialize();
    final id = await selectedAsset(checksum: 'uploaded-content');
    final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'uploaded-content');
    await sut.recordUploaded(scope, id, checksum: 'uploaded-content', remoteId: remote.id);
    await ctx.db.remoteAssetEntity.deleteWhere((r) => r.id.equals(remote.id));
    expect(await backup.getCandidates(userId, scope: scope), isEmpty);
    await ctx.db.localAssetEntity.deleteWhere((l) => l.id.equals(id));
    expect(await sut.hasProcessed(scope, id), isTrue);
  });

  test('remote matches become durable history before candidates are returned', () async {
    await initialize();
    final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'remote-match');
    final id = await selectedAsset(checksum: 'remote-match');
    expect(await backup.getCandidates(userId, scope: scope), isEmpty);
    expect(await sut.hasProcessed(scope, id), isTrue);
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 0, uploaded: 0, matched: 1));
    await ctx.db.remoteAssetEntity.deleteWhere((r) => r.id.equals(remote.id));
    expect((await backup.getAllCounts(userId, scope: scope)).remainder, 0);
    expect(await backup.getCandidates(userId, scope: scope), isEmpty);
  });

  test('does not match a file owned by another server user', () async {
    await initialize();
    final other = await ctx.newUser();
    await ctx.newRemoteAsset(ownerId: other.id, checksum: 'other-user-content');
    final id = await selectedAsset(checksum: 'other-user-content');
    expect((await backup.getCandidates(userId, scope: scope)).single.id, id);
    expect(await sut.hasProcessed(scope, id), isFalse);
  });

  test('success replaces ignored status and duplicate success is idempotent', () async {
    final id = await selectedAsset();
    await initialize();
    final before = await sut.getPolicy(scope);
    await sut.recordUploaded(scope, id, remoteId: 'remote-1');
    await sut.recordUploaded(scope, id, remoteId: 'remote-1');
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 0, uploaded: 1, matched: 0));
    expect((await sut.getPolicy(scope)).revision, before.revision);
  });

  test('history does not affect another account or server scope', () async {
    final id = await selectedAsset();
    await initialize();
    final otherScope = backupScope('https://other.example.com/api', userId);
    expect(await sut.hasProcessed(otherScope, id), isFalse);
    expect((await backup.getCandidates(userId, scope: otherScope)).single.id, id);
  });

  test('counts preparation only for unprocessed files', () async {
    final old = await ctx.newLocalAsset(checksumOption: const Option.none());
    final album = await ctx.newLocalAlbum(backupSelection: BackupSelection.selected);
    await ctx.newLocalAlbumAsset(albumId: album.id, assetId: old.id);
    await initialize();
    final fresh = await ctx.newLocalAsset(checksumOption: const Option.none());
    await ctx.newLocalAlbumAsset(albumId: album.id, assetId: fresh.id);
    expect(await backup.getAllCounts(userId, scope: scope), (total: 2, remainder: 1, processing: 1));
    expect(await backup.getCandidates(userId, scope: scope), isEmpty);
    expect((await backup.getCandidates(userId, scope: scope, onlyHashed: false)).single.id, fresh.id);
  });

  test('excluded albums do not contribute to candidates or history counts', () async {
    final selected = await selectedAsset();
    final excludedAlbum = await ctx.newLocalAlbum(backupSelection: BackupSelection.excluded);
    await ctx.newLocalAlbumAsset(albumId: excludedAlbum.id, assetId: selected);
    await initialize();
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 0, uploaded: 0, matched: 0));
    expect(await backup.getAllCounts(userId, scope: scope), (total: 0, remainder: 0, processing: 0));
  });

  test('keyset pages do not skip assets when completed records leave the queue', () async {
    await initialize();
    for (final id in ['001', '002', '003', '004', '005']) {
      await selectedAsset(id: id);
    }
    final first = await backup.getCandidates(userId, scope: scope, limit: 2);
    expect(first.map((a) => a.id), ['001', '002']);
    for (final asset in first) {
      await sut.recordUploaded(scope, asset.id);
    }
    final second = await backup.getCandidates(userId, scope: scope, limit: 2, afterId: first.last.id);
    expect(second.map((a) => a.id), ['003', '004']);
    final third = await backup.getCandidates(userId, scope: scope, limit: 2, afterId: second.last.id);
    expect(third.map((a) => a.id), ['005']);
  });

  test('pause and mode changes invalidate old policy revisions and preserve history', () async {
    final id = await selectedAsset();
    await initialize();
    expect((await sut.getPolicy(scope)).revision, 2);
    await sut.pause(scope);
    expect((await sut.getPolicy(scope)).status, BackupPolicyStatus.paused);
    expect((await sut.getPolicy(scope)).revision, 3);
    expect(await backup.getCandidates(userId, scope: scope), isEmpty);
    await sut.useLegacy(scope);
    expect((await sut.getPolicy(scope)).revision, 4);
    expect((await backup.getCandidates(userId, scope: scope)).single.id, id);
    expect(await sut.hasProcessed(scope, id), isTrue);
  });

  test('cannot activate a baseline that was explicitly cancelled', () async {
    await sut.beginInitialization(scope);
    await sut.useLegacy(scope);
    await expectLater(sut.completeInitialization(scope, 'media-v1'), throwsStateError);
    expect((await sut.getPolicy(scope)).status, BackupPolicyStatus.legacy);
  });

  test('resuming the saved mode keeps files added while it was disabled pending', () async {
    await selectedAsset();
    await initialize();
    await sut.useLegacy(scope);
    final fresh = await selectedAsset();
    await sut.beginInitialization(scope);
    await sut.resume(scope, 'media-v1');
    expect((await sut.getPolicy(scope)).status, BackupPolicyStatus.active);
    expect((await sut.getPolicy(scope)).revision, 5);
    expect((await backup.getCandidates(userId, scope: scope)).single.id, fresh);
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 1, uploaded: 0, matched: 0));
  });

  test('resuming cannot silently reuse a baseline from a rebuilt media library', () async {
    await initialize();
    await sut.useLegacy(scope);
    await sut.beginInitialization(scope);
    await expectLater(sut.resume(scope, 'media-v2'), throwsStateError);
    expect((await sut.getPolicy(scope)).status, BackupPolicyStatus.initializing);
  });

  test('a stale media identity check cannot pause a newer user-selected mode', () async {
    await initialize();
    final revision = (await sut.getPolicy(scope)).revision;
    await sut.useLegacy(scope);
    await sut.pause(scope, expectedRevision: revision);
    expect((await sut.getPolicy(scope)).status, BackupPolicyStatus.legacy);
    expect((await sut.getPolicy(scope)).revision, revision + 1);
  });

  test('confirmed remote matches do not misreport a local upload or downgrade actual success', () async {
    await initialize();
    final id = await selectedAsset();
    await sut.recordUploaded(scope, id, reason: BackupHistoryReason.remoteMatched);
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 0, uploaded: 0, matched: 1));
    await sut.recordUploaded(scope, id);
    await sut.recordUploaded(scope, id, reason: BackupHistoryReason.remoteMatched);
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 0, uploaded: 1, matched: 0));
  });

  test('failed baseline transaction leaves initialization paused and no partial history', () async {
    await selectedAsset();
    await sut.beginInitialization(scope);
    await ctx.db.customStatement('''
      CREATE TEMP TRIGGER reject_baseline BEFORE INSERT ON backup_history_entity
      BEGIN SELECT RAISE(ABORT, 'baseline unavailable'); END
    ''');
    await expectLater(sut.completeInitialization(scope, 'media-v1'), throwsA(isA<Exception>()));
    expect((await sut.getPolicy(scope)).status, BackupPolicyStatus.initializing);
    final rows = await ctx.db.customSelect('SELECT COUNT(*) AS count FROM backup_history_entity').getSingle();
    expect(rows.read<int>('count'), 0);
  });

  test('a media store rebuild starts a new epoch without deleting old history', () async {
    final oldId = await selectedAsset();
    await initialize();
    await sut.recordUploaded(scope, oldId);
    await sut.pause(scope);
    await initialize(version: 'media-v2');
    await sut.recordUploaded(scope, oldId, mediaStoreEpoch: 0);
    expect((await sut.getPolicy(scope)).mediaStoreEpoch, 1);
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 1, uploaded: 0, matched: 0));
    final rows = await ctx.db.customSelect('SELECT COUNT(*) AS count FROM backup_history_entity').getSingle();
    expect(rows.read<int>('count'), 2);
  });

  test('diagnostic database reset keeps history and pauses new-only policies', () async {
    final id = await selectedAsset();
    await initialize();
    await sut.recordUploaded(scope, id);
    await ctx.db.reset();
    final policy = await sut.getPolicy(scope);
    expect(policy.status, BackupPolicyStatus.paused);
    expect(policy.revision, 3);
    expect(await sut.hasProcessed(scope, id), isTrue);
  });

  test('baselines fifty thousand media records with a single database operation', () async {
    final album = await ctx.newLocalAlbum(backupSelection: BackupSelection.selected);
    await ctx.db.customStatement('''
      WITH RECURSIVE media(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM media WHERE n < 50000)
      INSERT INTO local_asset_entity (id, name, type)
      SELECT printf('%06d', n), 'photo.jpg', 1 FROM media
    ''');
    await ctx.db.customStatement(
      'INSERT INTO local_album_asset_entity (asset_id, album_id) SELECT id, ? FROM local_asset_entity',
      [album.id],
    );
    await initialize();
    expect(await backup.getAllCounts(userId, scope: scope), (total: 50000, remainder: 0, processing: 0));
    expect(await sut.getHistoryCounts(scope, userId), (ignored: 50000, uploaded: 0, matched: 0));
    final fresh = await selectedAsset();
    expect((await backup.getCandidates(userId, scope: scope, limit: 25)).single.id, fresh);
  });
}
