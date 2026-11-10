import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/util/defaults_mixin.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';

class BackupPolicyEntity extends Table with DriftDefaultsMixin {
  const BackupPolicyEntity();

  TextColumn get scope => text()();

  IntColumn get status => intEnum<BackupPolicyStatus>().withDefault(const Constant(0))();

  TextColumn get mediaStoreVersion => text().nullable()();

  IntColumn get revision => integer().withDefault(const Constant(0))();

  IntColumn get mediaStoreEpoch => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {scope};
}
