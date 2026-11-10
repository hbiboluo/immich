import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late LocalAlbumRepository sut;

  setUp(() {
    ctx = MediumRepositoryContext();
    sut = LocalAlbumRepository(ctx.db);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await ctx.dispose();
  });

  group('replaceSnapshot', () {
    test('android: moving to the first scanned album keeps the asset and removes the old link', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final previous = LocalAlbum(id: 'old', name: 'Old', updatedAt: DateTime(2024));
      final destination = LocalAlbum(id: 'new', name: 'New', updatedAt: DateTime(2024));
      final asset = _localAsset('moved');
      await sut.upsert(previous, toUpsert: [asset]);

      await sut.replaceSnapshot(
        [destination, previous],
        {
          destination.id: [asset],
          previous.id: [],
        },
      );

      expect(await sut.getAssetIds(destination.id), [asset.id]);
      expect(await sut.getAssetIds(previous.id), isEmpty);
      expect(await LocalAssetRepository(ctx.db).getById(asset.id), isNotNull);
    });

    test('android: moving from a missing album survives the final album cleanup', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final previous = LocalAlbum(id: 'old', name: 'Old', updatedAt: DateTime(2024));
      final destination = LocalAlbum(id: 'new', name: 'New', updatedAt: DateTime(2024));
      final asset = _localAsset('moved');
      await sut.upsert(previous, toUpsert: [asset]);

      await sut.replaceSnapshot(
        [destination],
        {
          destination.id: [asset],
        },
      );

      expect(await sut.getAssetIds(destination.id), [asset.id]);
      expect((await sut.getAll()).map((album) => album.id), [destination.id]);
      expect(await LocalAssetRepository(ctx.db).getById(asset.id), isNotNull);
    });

    test('keeps the supplied backup selection and linked remote album while updating metadata', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final user = await ctx.newUser();
      final remote = await ctx.newRemoteAlbum(ownerId: user.id);
      await ctx.newLocalAlbum(
        id: 'camera',
        name: 'Old camera',
        backupSelection: BackupSelection.selected,
        linkedRemoteAlbumId: remote.id,
      );
      final previous = (await sut.getAll()).single;
      final snapshot = previous.copyWith(name: 'Renamed camera', updatedAt: DateTime(2026));

      await sut.replaceSnapshot([snapshot], {snapshot.id: []});

      final current = (await sut.getAll()).single;
      expect(current.name, 'Renamed camera');
      expect(current.updatedAt, DateTime(2026));
      expect(current.backupSelection, BackupSelection.selected);
      expect(current.linkedRemoteAlbumId, remote.id);
    });

    test('deletes missing assets and unselected albums while retaining saved album selections', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final selection in BackupSelection.values) {
        final album = LocalAlbum(
          id: selection.name,
          name: selection.name,
          updatedAt: DateTime(2024),
          backupSelection: selection,
        );
        await sut.upsert(album, toUpsert: [_localAsset(selection.name)]);
      }

      await sut.replaceSnapshot([], {});

      final remaining = await sut.getAll();
      expect(
        remaining.map((album) => album.backupSelection),
        unorderedEquals([BackupSelection.selected, BackupSelection.excluded]),
      );
      expect(remaining.every((album) => album.assetCount == 0), isTrue);
      expect(await ctx.db.managers.localAssetEntity.count(), 0);
      expect(await ctx.db.managers.localAlbumAssetEntity.count(), 0);
    });

    test('rejects an incomplete snapshot before changing any existing media', () async {
      final album = LocalAlbum(id: 'camera', name: 'Camera', updatedAt: DateTime(2024));
      await sut.upsert(album, toUpsert: [_localAsset('old')]);

      expect(() => sut.replaceSnapshot([album], {}), throwsArgumentError);

      expect(await sut.getAssetIds(album.id), ['old']);
    });

    test('a failed asset replacement rolls album metadata and deleted media back together', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final album = LocalAlbum(id: 'camera', name: 'Camera', updatedAt: DateTime(2024));
      await sut.upsert(album, toUpsert: [_localAsset('old')]);
      await ctx.db.customStatement('''
        CREATE TEMP TRIGGER reject_snapshot BEFORE INSERT ON local_asset_entity
        BEGIN SELECT RAISE(ABORT, 'snapshot unavailable'); END
      ''');

      await expectLater(
        sut.replaceSnapshot(
          [album.copyWith(name: 'Renamed')],
          {
            album.id: [_localAsset('new')],
          },
        ),
        throwsA(isA<Exception>()),
      );

      expect((await sut.getAll()).single.name, 'Camera');
      expect(await sut.getAssetIds(album.id), ['old']);
      expect(await LocalAssetRepository(ctx.db).getById('new'), isNull);
    });
  });

  group('upsert', () {
    final album = LocalAlbum(id: 'album', name: 'Camera', updatedAt: DateTime(2024));

    Future<({String? checksum, String? previousChecksum})> row(String id) async {
      final data = await ctx.db.managers.localAssetEntity.filter((row) => row.id.equals(id)).getSingle();
      return (checksum: data.checksum, previousChecksum: data.previousChecksum);
    }

    for (final (platform, scenario, before, edited, after) in [
      (
        TargetPlatform.android,
        'updatedAt changed clears the checksum and remembers it',
        (checksum: 'a', previousChecksum: null),
        _localAsset('edited', updatedAt: DateTime(2025)),
        (checksum: null, previousChecksum: 'a'),
      ),
      (
        TargetPlatform.android,
        'adjustmentTime changed keeps the checksum',
        (checksum: 'a', previousChecksum: null),
        _localAsset('edited', adjustmentTime: DateTime(2025)),
        (checksum: 'a', previousChecksum: null),
      ),
      (
        TargetPlatform.android,
        'updatedAt changed again before the upload keeps the uploaded checksum',
        (checksum: 'b', previousChecksum: 'a'),
        _localAsset('edited', updatedAt: DateTime(2025)),
        (checksum: null, previousChecksum: 'a'),
      ),
      (
        TargetPlatform.iOS,
        'adjustmentTime changed clears the checksum and remembers it',
        (checksum: 'a', previousChecksum: null),
        _localAsset('edited', adjustmentTime: DateTime(2025)),
        (checksum: null, previousChecksum: 'a'),
      ),
      (
        TargetPlatform.iOS,
        'updatedAt changed keeps the checksum',
        (checksum: 'a', previousChecksum: null),
        _localAsset('edited', updatedAt: DateTime(2025)),
        (checksum: 'a', previousChecksum: null),
      ),
      (
        TargetPlatform.iOS,
        'adjustmentTime changed again before the upload keeps the uploaded checksum',
        (checksum: 'b', previousChecksum: 'a'),
        _localAsset('edited', adjustmentTime: DateTime(2025)),
        (checksum: null, previousChecksum: 'a'),
      ),
    ]) {
      test('${platform.name}: $scenario', () async {
        debugDefaultTargetPlatformOverride = platform;
        await ctx.newLocalAsset(
          id: 'edited',
          checksum: before.checksum,
          previousChecksum: before.previousChecksum,
          updatedAt: DateTime(2024),
          adjustmentTime: DateTime(2024),
        );

        await sut.upsert(album, toUpsert: [edited]);

        expect(await row('edited'), after);
      });
    }

    test('android: previous follows the uploads across two edits', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final assets = LocalAssetRepository(ctx.db);
      await ctx.newLocalAsset(id: 'edited', checksum: 'a', updatedAt: DateTime(2024), adjustmentTime: DateTime(2024));

      await assets.updatePreviousChecksum('edited', 'a');
      await sut.upsert(album, toUpsert: [_localAsset('edited', updatedAt: DateTime(2025))]);
      expect(await row('edited'), (checksum: null, previousChecksum: 'a'));

      await assets.updateHashes({'edited': 'b'});
      await assets.updatePreviousChecksum('edited', 'b');
      await sut.upsert(album, toUpsert: [_localAsset('edited', updatedAt: DateTime(2026))]);
      expect(await row('edited'), (checksum: null, previousChecksum: 'b'));
    });
  });
}

LocalAsset _localAsset(String id, {DateTime? updatedAt, DateTime? adjustmentTime}) => LocalAsset(
  id: id,
  name: '$id.jpg',
  type: AssetType.image,
  createdAt: DateTime(2024),
  updatedAt: updatedAt ?? DateTime(2024),
  adjustmentTime: adjustmentTime ?? DateTime(2024),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);
