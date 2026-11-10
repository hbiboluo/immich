// dart format width=80
// ignore_for_file: unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:immich_mobile/utils/migration.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() async {
    verifier = SchemaVerifier(GeneratedHelper());
    await initializeDateFormatting();
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = Drift(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  group('v35 group_date backfill', () {
    Future<List<Bucket>> loadBuckets(Drift db) => TimelineRepository(
      db,
    ).main(const ['user-1'], GroupAssetsBy.day).bucketSource().first;

    test(
      'a created_at clamped by the datetime heal is grouped by the healed date',
      () async {
        final schema = await verifier.schemaAt(33);
        schema.rawDatabase.execute('''
          INSERT INTO local_album_entity (id, name, backup_selection) VALUES ('album-1', 'Camera', 0);
          INSERT INTO local_asset_entity (id, name, type, created_at, updated_at) VALUES ('garbage', 'g.jpg', 1, '+057780-01-01T00:00:00.000Z', '+057780-01-01T00:00:00.000Z'), ('good', 'ok.jpg', 1, '2026-07-24T10:00:00.000Z', '2026-07-24T10:00:00.000Z');
          INSERT INTO local_album_asset_entity (asset_id, album_id) VALUES ('garbage', 'album-1'), ('good', 'album-1');
        ''');

        final db = Drift(schema.newConnection());
        await verifier.migrateAndValidate(db, 35);
        await backfillAssetGroupDates(db);

        final result = await loadBuckets(db);
        expect(result.map((b) => (b as TimeBucket).date.year), [9999, 2026]);
        await db.close();
      },
    );

    test(
      'a created_at heal before the backfill lands in the header day',
      () async {
        final schema = await verifier.schemaAt(33);
        schema.rawDatabase.execute('''
          INSERT INTO local_album_entity (id, name, backup_selection) VALUES ('album-1', 'Camera', 0);
          INSERT INTO local_asset_entity (id, name, type, created_at, updated_at) VALUES ('healed', 'h.jpg', 1, '2027-01-01T00:00:00.000Z', '2026-07-20T10:00:00.000Z');
          INSERT INTO local_album_asset_entity (asset_id, album_id) VALUES ('healed', 'album-1');
        ''');

        final db = Drift(schema.newConnection());
        await verifier.migrateAndValidate(db, 35);

        await db.customStatement(
          "UPDATE local_asset_entity SET created_at = updated_at WHERE julianday(created_at) > julianday(updated_at)",
        );
        await backfillAssetGroupDates(db);

        expect(
          (await loadBuckets(db)).single,
          TimeBucket(date: DateTime(2026, 7, 20), assetCount: 1),
        );
        await db.close();
      },
    );
  });

  test(
    'v36 preserves local files and defaults existing installations to legacy backup',
    () async {
      final schema = await verifier.schemaAt(35);
      schema.rawDatabase.execute('''
      INSERT INTO local_album_entity (id, name, backup_selection) VALUES ('camera', 'Camera', 0);
      INSERT INTO local_asset_entity (id, name, type, checksum) VALUES ('existing', 'existing.jpg', 1, 'content');
      INSERT INTO local_album_asset_entity (asset_id, album_id) VALUES ('existing', 'camera');
    ''');
      final db = Drift(schema.newConnection());
      await verifier.migrateAndValidate(db, 36);
      final policy = await db.backupPolicyRepository.getPolicy('server-user');
      expect(policy.status, BackupPolicyStatus.legacy);
      expect(
        (await db.backupRepository.getCandidates(
          'user-1',
          scope: 'server-user',
        )).single.id,
        'existing',
      );
      final history = await db
          .customSelect('SELECT COUNT(*) AS count FROM backup_history_entity')
          .getSingle();
      expect(history.read<int>('count'), 0);
      final foreignKeys = await db
          .customSelect('PRAGMA foreign_key_list(backup_history_entity)')
          .get();
      expect(foreignKeys, isEmpty);
      await db.close();
    },
  );
}
