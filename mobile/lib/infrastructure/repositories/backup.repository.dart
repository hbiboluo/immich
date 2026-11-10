import 'dart:async';

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/album_asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_policy.repository.dart';

@DriftAccessor()
class BackupRepository extends DatabaseAccessor<Drift> with $BackupRepositoryMixin {
  BackupRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  JoinedSelectStatement<$LocalAlbumAssetEntityTable, LocalAlbumAssetEntityData> _getExcludedSubquery() {
    return _db.localAlbumAssetEntity.selectOnly()
      ..addColumns([_db.localAlbumAssetEntity.assetId])
      ..join([
        innerJoin(
          _db.localAlbumEntity,
          _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id),
          useColumns: false,
        ),
      ])
      ..where(_db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.excluded));
  }

  /// Returns all backup-related counts in a single query.
  ///
  /// - total:     number of distinct assets in selected albums, excluding those that are also in excluded albums
  /// - backup:    number of those assets that already exist on the server for [userId]
  /// - remainder: number of those assets that do not yet exist on the server for [userId]
  ///              (includes processing)
  /// - processing: number of those assets that are still preparing/have a null checksum
  Future<({int total, int remainder, int processing})> getAllCounts(String userId, {String? scope}) {
    return _db.transaction(() async {
      final policy = scope == null ? null : await _db.backupPolicyRepository.getPolicy(scope);
      if (policy != null && policy.onlyNew) {
        if (!policy.isPaused) {
          await _reconcileRemoteMatches(scope!, userId, policy);
        }
        return _getNewOnlyCounts(scope!, policy);
      }
      return _getLegacyCounts(userId);
    });
  }

  Future<({int total, int remainder, int processing})> _getLegacyCounts(String userId) async {
    const sql = '''
        SELECT
        COUNT(*) AS total_count,
        COUNT(*) FILTER (WHERE lae.checksum IS NULL) AS processing_count,
        COUNT(*) FILTER (WHERE rae.id IS NULL) AS remainder_count
        FROM local_asset_entity lae
        LEFT JOIN main.remote_asset_entity rae
            ON lae.checksum = rae.checksum AND rae.owner_id = ?1
        WHERE EXISTS (
            SELECT 1
            FROM local_album_asset_entity laa
            INNER JOIN main.local_album_entity la on laa.album_id = la.id
            WHERE laa.asset_id = lae.id
                AND la.backup_selection = ?2
        )
        AND NOT EXISTS (
            SELECT 1
            FROM local_album_asset_entity laa
            INNER JOIN main.local_album_entity la on laa.album_id = la.id
            WHERE laa.asset_id = lae.id
                AND la.backup_selection = ?3
        );
      ''';

    final row = await _db
        .customSelect(
          sql,
          variables: [
            Variable.withString(userId),
            Variable.withInt(BackupSelection.selected.index),
            Variable.withInt(BackupSelection.excluded.index),
          ],
          readsFrom: {_db.localAlbumAssetEntity, _db.localAlbumEntity, _db.localAssetEntity, _db.remoteAssetEntity},
        )
        .getSingle();

    final data = row.data;
    return (
      total: (data['total_count'] as int?) ?? 0,
      remainder: (data['remainder_count'] as int?) ?? 0,
      processing: (data['processing_count'] as int?) ?? 0,
    );
  }

  Future<({int total, int remainder, int processing})> _getNewOnlyCounts(String scope, BackupPolicy policy) async {
    const unprocessed = '''
      NOT EXISTS (
        SELECT 1 FROM backup_history_entity h
        WHERE h.scope = ?1 AND h.media_store_epoch = ?2 AND h.local_asset_id = lae.id
      )
    ''';
    final row = await _db
        .customSelect(
          '''
      SELECT COUNT(*) AS total_count,
        COUNT(*) FILTER (WHERE $unprocessed) AS remainder_count,
        COUNT(*) FILTER (WHERE lae.checksum IS NULL AND $unprocessed) AS processing_count
      FROM local_asset_entity lae
      WHERE $selectedBackupAssetSql
      ''',
          variables: [Variable.withString(scope), Variable.withInt(policy.mediaStoreEpoch)],
          readsFrom: {_db.backupHistoryEntity, _db.localAssetEntity, _db.localAlbumAssetEntity, _db.localAlbumEntity},
        )
        .getSingle();
    return (
      total: row.read<int>('total_count'),
      remainder: row.read<int>('remainder_count'),
      processing: row.read<int>('processing_count'),
    );
  }

  Future<void> reconcileRemoteMatches(String scope, String userId) {
    return _db.transaction(() async {
      final policy = await _db.backupPolicyRepository.getPolicy(scope);
      if (policy.status == BackupPolicyStatus.active) {
        await _reconcileRemoteMatches(scope, userId, policy);
      }
    });
  }

  Future<void> _reconcileRemoteMatches(String scope, String userId, BackupPolicy policy) async {
    await _db.customInsert(
      '''
      INSERT OR IGNORE INTO backup_history_entity
        (scope, media_store_epoch, local_asset_id, reason, processed_at, checksum, remote_asset_id)
      SELECT ?1, ?2, lae.id, ?3, ?4, lae.checksum,
        (SELECT id FROM remote_asset_entity rae WHERE rae.owner_id = ?5 AND rae.checksum = lae.checksum LIMIT 1)
      FROM local_asset_entity lae
      WHERE $selectedBackupAssetSql
        AND NOT EXISTS (
          SELECT 1 FROM backup_history_entity h
          WHERE h.scope = ?1 AND h.media_store_epoch = ?2 AND h.local_asset_id = lae.id
        )
        AND EXISTS (
          SELECT 1 FROM remote_asset_entity rae WHERE rae.owner_id = ?5 AND rae.checksum = lae.checksum
        )
      ''',
      variables: [
        Variable.withString(scope),
        Variable.withInt(policy.mediaStoreEpoch),
        Variable.withInt(BackupHistoryReason.remoteMatched.index),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
        Variable.withString(userId),
      ],
      updates: {_db.backupHistoryEntity},
    );
  }

  Future<List<LocalAsset>> getCandidates(
    String userId, {
    bool onlyHashed = true,
    String? scope,
    int? limit,
    String? afterId,
  }) {
    return _db.transaction(() async {
      final policy = scope == null ? null : await _db.backupPolicyRepository.getPolicy(scope);
      if (policy?.isPaused == true) {
        return [];
      }
      if (policy != null && policy.onlyNew) {
        await _reconcileRemoteMatches(scope!, userId, policy);
      }
      return _getCandidates(
        userId,
        onlyHashed: onlyHashed,
        scope: scope,
        policy: policy,
        limit: limit,
        afterId: afterId,
      );
    });
  }

  Future<List<LocalAsset>> _getCandidates(
    String userId, {
    required bool onlyHashed,
    String? scope,
    BackupPolicy? policy,
    int? limit,
    String? afterId,
  }) async {
    final selectedAlbumIds = _db.localAlbumEntity.selectOnly(distinct: true)
      ..addColumns([_db.localAlbumEntity.id])
      ..where(_db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.selected));

    final query = _db.localAssetEntity.select()
      ..where(
        (lae) =>
            existsQuery(
              _db.localAlbumAssetEntity.selectOnly()
                ..addColumns([_db.localAlbumAssetEntity.assetId])
                ..where(
                  _db.localAlbumAssetEntity.albumId.isInQuery(selectedAlbumIds) &
                      _db.localAlbumAssetEntity.assetId.equalsExp(lae.id),
                ),
            ) &
            (policy?.onlyNew == true
                ? notExistsQuery(
                    _db.backupHistoryEntity.selectOnly()
                      ..addColumns([_db.backupHistoryEntity.localAssetId])
                      ..where(
                        _db.backupHistoryEntity.scope.equals(scope!) &
                            _db.backupHistoryEntity.mediaStoreEpoch.equals(policy!.mediaStoreEpoch) &
                            _db.backupHistoryEntity.localAssetId.equalsExp(lae.id),
                      ),
                  )
                : notExistsQuery(
                    _db.remoteAssetEntity.selectOnly()
                      ..addColumns([_db.remoteAssetEntity.checksum])
                      ..where(
                        _db.remoteAssetEntity.checksum.equalsExp(lae.checksum) &
                            _db.remoteAssetEntity.ownerId.equals(userId),
                      ),
                  )) &
            lae.id.isNotInQuery(_getExcludedSubquery()),
      )
      ..orderBy([
        (localAsset) => limit == null ? OrderingTerm.desc(localAsset.createdAt) : OrderingTerm.asc(localAsset.id),
      ]);

    if (onlyHashed) {
      query.where((lae) => lae.checksum.isNotNull());
    }

    if (afterId != null) {
      query.where((lae) => lae.id.isBiggerThanValue(afterId));
    }
    if (limit != null) {
      query.limit(limit);
    }

    return query.map((localAsset) => localAsset.toDto()).get();
  }
}
