import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:mocktail/mocktail.dart';

import '../service.mocks.dart';

void main() {
  late MockServerInfoService service;
  late ProviderContainer container;

  setUp(() {
    service = MockServerInfoService();
    container = ProviderContainer(overrides: [serverInfoServiceProvider.overrideWithValue(service)]);
  });

  tearDown(() => container.dispose());

  for (final major in [2, 3, 99]) {
    test('server version $major stays available without an official update warning', () async {
      final version = ServerVersion(major: major, minor: 0, patch: 0, supportsPasskeys: true);
      when(service.getServerVersion).thenAnswer((_) async => version);

      await container.read(serverInfoProvider.notifier).getServerVersion();

      final state = container.read(serverInfoProvider);
      expect(state.serverVersion, version);
      expect(state.serverVersion.supportsPasskeys, isTrue);
      expect(state.latestVersion, isNull);
      expect(container.read(versionWarningPresentProvider(null)), isFalse);
    });
  }

  test('missing server version preserves known capabilities without an update warning', () async {
    const version = ServerVersion(major: 3, minor: 4, patch: 0, supportsPasskeys: true);
    when(service.getServerVersion).thenAnswer((_) async => version);
    final notifier = container.read(serverInfoProvider.notifier);
    await notifier.getServerVersion();
    when(service.getServerVersion).thenAnswer((_) async => null);

    await notifier.getServerVersion();

    expect(container.read(serverInfoProvider).serverVersion, version);
    expect(container.read(versionWarningPresentProvider(null)), isFalse);
  });

  test('server version failure does not trigger an official update warning', () async {
    when(service.getServerVersion).thenThrow(Exception('offline'));

    await container.read(serverInfoProvider.notifier).getServerVersion();

    expect(container.read(versionWarningPresentProvider(null)), isFalse);
  });

  test('server features and configuration still refresh', () async {
    const version = ServerVersion(major: 3, minor: 4, patch: 0);
    when(service.getServerVersion).thenAnswer((_) async => version);
    when(service.getServerFeatures).thenAnswer((_) async => null);
    when(service.getServerConfig).thenAnswer((_) async => null);

    final info = await container.read(serverInfoProvider.notifier).getServerInfo();

    expect(info.serverVersion, version);
    verify(service.getServerFeatures).called(1);
    verify(service.getServerConfig).called(1);
  });
}
