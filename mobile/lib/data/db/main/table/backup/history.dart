import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/util/defaults_mixin.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';

class BackupHistoryEntity extends Table with DriftDefaultsMixin {
  const BackupHistoryEntity();

  TextColumn get scope => text()();

  IntColumn get mediaStoreEpoch => integer().withDefault(const Constant(0))();

  TextColumn get localAssetId => text()();

  IntColumn get reason => intEnum<BackupHistoryReason>()();

  IntColumn get processedAt => integer()();

  TextColumn get checksum => text().nullable()();

  TextColumn get remoteAssetId => text().nullable()();

  @override
  Set<Column> get primaryKey => {scope, mediaStoreEpoch, localAssetId};
}
