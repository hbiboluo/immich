import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/domain/services/backup_policy_guard.service.dart';

void main() {
  late String? scope;
  late BackupPolicy policy;
  late String version;
  late BackupPolicyGuard sut;
  late int pauses;

  setUp(() {
    scope = 'account';
    version = 'v1';
    pauses = 0;
    policy = const BackupPolicy(
      scope: 'account',
      status: BackupPolicyStatus.active,
      mediaStoreVersion: 'v1',
      revision: 2,
    );
    sut = BackupPolicyGuard(
      getScope: () => scope,
      getUserId: () => 'user',
      getPolicy: (_) async => policy,
      getMediaStoreVersion: () async => version,
      pause: (_, {expectedRevision}) async {
        expect(expectedRevision, policy.revision);
        pauses++;
        policy = const BackupPolicy(scope: 'account', status: BackupPolicyStatus.paused, revision: 3);
      },
    );
  });

  test('validates stable media identity without pausing', () async {
    expect((await sut.current(validateMediaStore: true))?.status, BackupPolicyStatus.active);
    expect(pauses, 0);
    expect(await sut.allowsMediaManagement(), isFalse);
  });

  test('persists pause before returning a changed media identity', () async {
    version = 'v2';
    expect((await sut.current(validateMediaStore: true))?.status, BackupPolicyStatus.paused);
    expect(pauses, 1);
  });

  test('does not query media identity for legacy mode', () async {
    policy = const BackupPolicy(scope: 'account');
    sut = BackupPolicyGuard(
      getScope: () => scope,
      getUserId: () => 'user',
      getPolicy: (_) async => policy,
      getMediaStoreVersion: () async => throw StateError('must not read media'),
      pause: (_, {expectedRevision}) async => fail('must not pause'),
    );
    expect((await sut.current(validateMediaStore: true))?.status, BackupPolicyStatus.legacy);
    expect(await sut.allowsMediaManagement(), isTrue);
  });

  test('rejects a policy read completed after account switching', () async {
    final pending = Completer<BackupPolicy>();
    sut = BackupPolicyGuard(
      getScope: () => scope,
      getUserId: () => 'user',
      getPolicy: (_) => pending.future,
      getMediaStoreVersion: () async => version,
      pause: (_, {expectedRevision}) async {},
    );
    final result = sut.current();
    scope = 'other-account';
    pending.complete(policy);
    expect(await result, isNull);
  });

  test('leaves non-Android callers on the existing path', () async {
    scope = null;
    expect(await sut.current(validateMediaStore: true), isNull);
    expect(await sut.allowsMediaManagement(), isTrue);
  });

  test('missing media permission pauses automatic backup', () async {
    sut = BackupPolicyGuard(
      getScope: () => scope,
      getUserId: () => 'user',
      getPolicy: (_) async => policy,
      getMediaStoreVersion: () async => throw StateError('permission revoked'),
      pause: (_, {expectedRevision}) async {
        pauses++;
        policy = const BackupPolicy(scope: 'account', status: BackupPolicyStatus.paused);
      },
    );
    expect((await sut.current(validateMediaStore: true))?.isPaused, isTrue);
    expect(pauses, 1);
  });
}
