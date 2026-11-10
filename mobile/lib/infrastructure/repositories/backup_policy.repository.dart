import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/backup/policy.drift.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_policy.repository.drift.dart';

const selectedBackupAssetSql = '''
  EXISTS (
    SELECT 1 FROM local_album_asset_entity laa
    INNER JOIN local_album_entity la ON laa.album_id = la.id
    WHERE laa.asset_id = lae.id AND la.backup_selection = 0
  )
  AND NOT EXISTS (
    SELECT 1 FROM local_album_asset_entity laa
    INNER JOIN local_album_entity la ON laa.album_id = la.id
    WHERE laa.asset_id = lae.id AND la.backup_selection = 2
  )
''';

@DriftAccessor()
class BackupPolicyRepository extends DatabaseAccessor<Drift> with $BackupPolicyRepositoryMixin {
  BackupPolicyRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  BackupPolicy _toPolicy(BackupPolicyEntityData? row, String scope) => BackupPolicy(
    scope: scope,
    status: row?.status ?? BackupPolicyStatus.legacy,
    mediaStoreVersion: row?.mediaStoreVersion,
    revision: row?.revision ?? 0,
    mediaStoreEpoch: row?.mediaStoreEpoch ?? 0,
  );

  SimpleSelectStatement<$BackupPolicyEntityTable, BackupPolicyEntityData> _policyQuery(String scope) =>
      _db.backupPolicyEntity.select()..where((row) => row.scope.equals(scope));

  Future<BackupPolicy> getPolicy(String scope) async => _toPolicy(await _policyQuery(scope).getSingleOrNull(), scope);

  Stream<BackupPolicy> watchPolicy(String scope) =>
      _policyQuery(scope).watchSingleOrNull().map((row) => _toPolicy(row, scope));

  Future<void> _setStatus(String scope, BackupPolicyStatus status) async {
    await _db.customInsert(
      '''
      INSERT INTO backup_policy_entity (scope, status, revision)
      VALUES (?1, ?2, 1)
      ON CONFLICT (scope) DO UPDATE SET status = excluded.status, revision = revision + 1
      ''',
      variables: [Variable.withString(scope), Variable.withInt(status.index)],
      updates: {_db.backupPolicyEntity},
    );
  }

  Future<void> beginInitialization(String scope) => _setStatus(scope, BackupPolicyStatus.initializing);

  Future<void> pause(String scope, {int? expectedRevision}) async {
    if (expectedRevision == null) {
      return _setStatus(scope, BackupPolicyStatus.paused);
    }
    await _db.customUpdate(
      '''
      UPDATE backup_policy_entity SET status = ?1, revision = revision + 1
      WHERE scope = ?2 AND revision = ?3
      ''',
      variables: [
        Variable.withInt(BackupPolicyStatus.paused.index),
        Variable.withString(scope),
        Variable.withInt(expectedRevision),
      ],
      updates: {_db.backupPolicyEntity},
    );
  }

  Future<void> useLegacy(String scope) => _setStatus(scope, BackupPolicyStatus.legacy);

  Future<void> resume(String scope, String mediaStoreVersion) {
    return _db.transaction(() async {
      final policy = await getPolicy(scope);
      if (policy.status != BackupPolicyStatus.initializing ||
          policy.mediaStoreVersion == null ||
          policy.mediaStoreVersion != mediaStoreVersion) {
        throw StateError('The saved backup baseline does not match the current media library');
      }
      await (_db.backupPolicyEntity.update()..where((row) => row.scope.equals(scope))).write(
        BackupPolicyEntityCompanion(
          status: const Value(BackupPolicyStatus.active),
          revision: Value(policy.revision + 1),
        ),
      );
    });
  }

  Future<void> completeInitialization(String scope, String mediaStoreVersion) {
    return _db.transaction(() async {
      final policy = await getPolicy(scope);
      if (policy.status != BackupPolicyStatus.initializing) {
        throw StateError('Backup baseline initialization is no longer active');
      }
      final changed = policy.mediaStoreVersion != null && policy.mediaStoreVersion != mediaStoreVersion;
      final epoch = policy.mediaStoreEpoch + (changed ? 1 : 0);
      await _db.customInsert(
        '''
        INSERT OR IGNORE INTO backup_history_entity
          (scope, media_store_epoch, local_asset_id, reason, processed_at, checksum)
        SELECT ?1, ?2, id, ?3, ?4, checksum FROM local_asset_entity
        ''',
        variables: [
          Variable.withString(scope),
          Variable.withInt(epoch),
          Variable.withInt(BackupHistoryReason.baseline.index),
          Variable.withInt(DateTime.now().millisecondsSinceEpoch),
        ],
        updates: {_db.backupHistoryEntity},
      );
      await (_db.backupPolicyEntity.update()..where((row) => row.scope.equals(scope))).write(
        BackupPolicyEntityCompanion(
          status: const Value(BackupPolicyStatus.active),
          mediaStoreVersion: Value(mediaStoreVersion),
          mediaStoreEpoch: Value(epoch),
          revision: Value(policy.revision + 1),
        ),
      );
    });
  }

  Future<bool> hasProcessed(String scope, String localAssetId) async {
    final row = await _db
        .customSelect(
          '''
      SELECT 1 FROM backup_history_entity h
      WHERE h.scope = ?1 AND h.local_asset_id = ?2
        AND h.media_store_epoch = COALESCE(
          (SELECT media_store_epoch FROM backup_policy_entity WHERE scope = ?1), 0
        )
      LIMIT 1
      ''',
          variables: [Variable.withString(scope), Variable.withString(localAssetId)],
          readsFrom: {_db.backupHistoryEntity, _db.backupPolicyEntity},
        )
        .getSingleOrNull();
    return row != null;
  }

  Future<void> recordUploaded(
    String scope,
    String localAssetId, {
    String? checksum,
    String? remoteId,
    BackupHistoryReason reason = BackupHistoryReason.uploaded,
    int? mediaStoreEpoch,
  }) async {
    await _db.customInsert(
      '''
      INSERT INTO backup_history_entity
        (scope, media_store_epoch, local_asset_id, reason, processed_at, checksum, remote_asset_id)
      VALUES (?1, COALESCE(?7, (SELECT media_store_epoch FROM backup_policy_entity WHERE scope = ?1), 0),
        ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT (scope, media_store_epoch, local_asset_id) DO UPDATE SET
        reason = CASE WHEN backup_history_entity.reason = 1 THEN 1 ELSE excluded.reason END,
        processed_at = excluded.processed_at,
        checksum = COALESCE(excluded.checksum, backup_history_entity.checksum),
        remote_asset_id = COALESCE(excluded.remote_asset_id, backup_history_entity.remote_asset_id)
      ''',
      variables: [
        Variable.withString(scope),
        Variable.withString(localAssetId),
        Variable.withInt(reason.index),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
        Variable<String>(checksum),
        Variable<String>(remoteId),
        Variable<int>(mediaStoreEpoch),
      ],
      updates: {_db.backupHistoryEntity},
    );
  }

  Selectable<({int ignored, int uploaded, int matched})> _historyCounts(String scope, String _) {
    return _db
        .customSelect(
          '''
      SELECT
        COUNT(*) FILTER (WHERE h.reason = 0) AS ignored,
        COUNT(*) FILTER (WHERE h.reason = 1) AS uploaded,
        COUNT(*) FILTER (WHERE h.reason = 2) AS matched
      FROM backup_history_entity h
      INNER JOIN local_asset_entity lae ON h.local_asset_id = lae.id
      WHERE h.scope = ?1
        AND h.media_store_epoch = COALESCE(
          (SELECT media_store_epoch FROM backup_policy_entity WHERE scope = ?1), 0
        )
        AND $selectedBackupAssetSql
      ''',
          variables: [Variable.withString(scope)],
          readsFrom: {
            _db.backupPolicyEntity,
            _db.backupHistoryEntity,
            _db.localAssetEntity,
            _db.localAlbumEntity,
            _db.localAlbumAssetEntity,
          },
        )
        .map(
          (row) => (
            ignored: row.read<int>('ignored'),
            uploaded: row.read<int>('uploaded'),
            matched: row.read<int>('matched'),
          ),
        );
  }

  Future<({int ignored, int uploaded, int matched})> getHistoryCounts(String scope, String userId) =>
      _historyCounts(scope, userId).getSingle();

  Stream<({int ignored, int uploaded, int matched})> watchHistoryCounts(String scope, String userId) =>
      _historyCounts(scope, userId).watchSingle();
}
