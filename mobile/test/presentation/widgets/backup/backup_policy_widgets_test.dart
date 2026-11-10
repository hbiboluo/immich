import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/presentation/widgets/backup/backup_policy_settings.widget.dart';
import 'package:immich_mobile/presentation/widgets/backup/backup_policy_summary.widget.dart';
import 'package:immich_mobile/providers/backup/backup_policy.provider.dart';

import '../../../medium/repository_context.dart';
import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  testWidgets('separates ignored files from successful uploads', (tester) async {
    await tester.pumpTestWidget(context, const BackupHistorySummary(ignored: 8421, uploaded: 328, matched: 7));

    expect(find.text('No longer queued for automatic upload'), findsOneWidget);
    expect(find.text('Existing files ignored'), findsOneWidget);
    expect(find.text('Uploaded from this device'), findsOneWidget);
    expect(find.text('Previously matched on the server'), findsOneWidget);
    expect(find.text('8756'), findsOneWidget);
    expect(find.text('8421'), findsOneWidget);
    expect(find.text('328'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.textContaining('does not guarantee a current copy'), findsOneWidget);
  });

  testWidgets('requires confirmation before ignoring existing files', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final repositories = MediumRepositoryContext();
    addTearDown(repositories.dispose);
    var scans = 0;
    final controller = BackupPolicyController(
      repository: repositories.db.backupPolicyRepository,
      getScope: () => 'server:user',
      stopBackups: () async {},
      scan: () async {
        scans++;
      },
      getMediaStoreVersion: () async => 'media-store-1',
      onChanged: () async {},
      resume: () async {},
    );
    await tester.pumpTestWidget(
      context,
      const SingleChildScrollView(child: BackupPolicySettings()),
      overrides: [
        backupScopeProvider.overrideWithValue('server:user'),
        backupPolicyProvider.overrideWith((ref) => Stream.value(const BackupPolicy(scope: 'server:user'))),
        backupPolicyControllerProvider.overrideWithValue(controller),
      ],
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('Ignore existing files?'), findsOneWidget);
    expect(find.textContaining('including unselected albums'), findsOneWidget);
    expect(scans, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(scans, 0);
    expect((await repositories.db.backupPolicyRepository.getPolicy('server:user')).status, BackupPolicyStatus.legacy);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a paused policy offers an explicit baseline rebuild', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpTestWidget(
      context,
      const SingleChildScrollView(child: BackupPolicySettings()),
      overrides: [
        backupScopeProvider.overrideWithValue('server:user'),
        backupPolicyProvider.overrideWith(
          (ref) => Stream.value(const BackupPolicy(scope: 'server:user', status: BackupPolicyStatus.paused)),
        ),
      ],
    );

    expect(find.text('Automatic uploads paused'), findsOneWidget);
    expect(find.text('Ignore all current files'), findsOneWidget);
    expect(find.textContaining('Existing files will not be uploaded'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the Android-only setting is absent on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await tester.pumpTestWidget(context, const BackupPolicySettings());

    expect(find.text('Only new files'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
