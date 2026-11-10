import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/providers/backup/backup_policy.provider.dart';

import '../../medium/repository_context.dart';

void main() {
  late MediumRepositoryContext context;
  late BackupPolicyController controller;
  late String? scope;
  late List<String> calls;
  late int scans;
  late String version;
  Future<void> Function()? scan;

  setUp(() {
    context = MediumRepositoryContext();
    scope = 'server:user';
    calls = [];
    scans = 0;
    version = 'media-store-1';
    scan = null;
    controller = BackupPolicyController(
      repository: context.db.backupPolicyRepository,
      getScope: () => scope,
      stopBackups: () async {
        calls.add('stop');
        final policy = await context.db.backupPolicyRepository.getPolicy('server:user');
        expect(policy.status, BackupPolicyStatus.initializing);
      },
      scan: () async {
        scans++;
        calls.add('scan');
        await scan?.call();
      },
      getMediaStoreVersion: () async => version,
      onChanged: () async => calls.add('refresh'),
      resume: () async => calls.add('resume'),
    );
  });

  tearDown(() => context.dispose());

  test('persists a paused initialization before stopping or scanning', () async {
    await controller.enableOnlyNew();

    final policy = await context.db.backupPolicyRepository.getPolicy('server:user');
    expect(policy.status, BackupPolicyStatus.active);
    expect(policy.mediaStoreVersion, version);
    expect(calls, ['stop', 'scan', 'refresh', 'resume']);
    expect(controller.busy, isFalse);
  });

  test('keeps automatic uploads paused when the scan fails', () async {
    scan = () async => throw StateError('scan failed');

    await expectLater(controller.enableOnlyNew(), throwsStateError);

    final policy = await context.db.backupPolicyRepository.getPolicy('server:user');
    expect(policy.status, BackupPolicyStatus.paused);
    expect(calls, ['stop', 'scan', 'refresh']);
    expect(controller.busy, isFalse);
  });

  test('does not activate a baseline spanning two media-store versions', () async {
    scan = () async {
      version = 'media-store-2';
    };

    await expectLater(controller.enableOnlyNew(), throwsStateError);

    final policy = await context.db.backupPolicyRepository.getPolicy('server:user');
    expect(policy.status, BackupPolicyStatus.paused);
    expect(calls, isNot(contains('resume')));
  });

  test('does not activate the old account after an account switch', () async {
    scan = () async {
      scope = 'other-server:user';
    };

    await expectLater(controller.enableOnlyNew(), throwsStateError);

    final policy = await context.db.backupPolicyRepository.getPolicy('server:user');
    expect(policy.status, BackupPolicyStatus.paused);
    expect(calls, isNot(contains('resume')));
  });

  test('resuming an active policy keeps the existing baseline', () async {
    await controller.enableOnlyNew();
    calls.clear();
    scans = 0;
    final revision = (await context.db.backupPolicyRepository.getPolicy('server:user')).revision;

    await controller.enableOnlyNew();

    final policy = await context.db.backupPolicyRepository.getPolicy('server:user');
    expect(policy.revision, revision);
    expect(scans, 0);
    expect(calls, ['refresh', 'resume']);
  });

  test('re-enabling preserves history and leaves files added while disabled pending', () async {
    final existing = await context.newLocalAsset();
    await controller.enableOnlyNew();
    await controller.useLegacy();
    final fresh = await context.newLocalAsset();
    calls.clear();
    scans = 0;

    await controller.enableOnlyNew();

    final policy = await context.db.backupPolicyRepository.getPolicy('server:user');
    expect(policy.status, BackupPolicyStatus.active);
    expect(await context.db.backupPolicyRepository.hasProcessed('server:user', existing.id), isTrue);
    expect(await context.db.backupPolicyRepository.hasProcessed('server:user', fresh.id), isFalse);
    expect(scans, 1);
    expect(calls, ['stop', 'scan', 'refresh', 'resume']);
  });

  test('re-enabling after a media-library rebuild requires an explicit reset', () async {
    await controller.enableOnlyNew();
    await controller.useLegacy();
    final fresh = await context.newLocalAsset();
    version = 'media-store-2';
    calls.clear();
    scans = 0;

    await expectLater(controller.enableOnlyNew(), throwsStateError);

    expect((await context.db.backupPolicyRepository.getPolicy('server:user')).status, BackupPolicyStatus.paused);
    expect(await context.db.backupPolicyRepository.hasProcessed('server:user', fresh.id), isFalse);
    expect(scans, 0);
    expect(calls, ['stop', 'refresh']);
  });

  test('a paused policy needs an explicit baseline rebuild', () async {
    await context.db.backupPolicyRepository.beginInitialization('server:user');
    await context.db.backupPolicyRepository.pause('server:user');

    await expectLater(controller.enableOnlyNew(), throwsStateError);
    expect(scans, 0);

    await controller.enableOnlyNew(resetBaseline: true);
    expect(scans, 1);
    expect((await context.db.backupPolicyRepository.getPolicy('server:user')).status, BackupPolicyStatus.active);
  });

  test('switching to existing behavior stops uploads before changing policy', () async {
    await controller.enableOnlyNew();
    calls.clear();

    await controller.useLegacy();

    expect((await context.db.backupPolicyRepository.getPolicy('server:user')).status, BackupPolicyStatus.legacy);
    expect(calls, ['stop', 'refresh', 'resume']);
  });
}
