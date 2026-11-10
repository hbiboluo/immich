import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/backup/backup_policy.provider.dart';

class BackupPolicyStatusBanner extends ConsumerWidget {
  const BackupPolicyStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(backupPolicyProvider)
        .when(
          loading: () => const SizedBox.shrink(),
          error: (error, stack) =>
              ListTile(leading: const Icon(Icons.error_outline), title: Text(context.t.backup_upload_mode_error)),
          data: (policy) {
            if (!policy.onlyNew) {
              return const SizedBox.shrink();
            }
            return Card(
              child: ListTile(
                leading: Icon(policy.isPaused ? Icons.pause_circle_outline : Icons.fiber_new_outlined),
                title: Text(
                  policy.isPaused ? context.t.backup_upload_mode_paused : context.t.backup_upload_mode_only_new,
                ),
                subtitle: Text(
                  policy.status == BackupPolicyStatus.initializing
                      ? context.t.backup_upload_mode_initializing
                      : policy.isPaused
                      ? context.t.backup_upload_mode_paused_description
                      : context.t.backup_upload_mode_only_new_description,
                ),
              ),
            );
          },
        );
  }
}

class BackupPolicyHistoryCard extends ConsumerWidget {
  const BackupPolicyHistoryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(backupHistoryCountsProvider)
        .when(
          loading: () => const Card(
            child: Padding(padding: EdgeInsets.all(20), child: LinearProgressIndicator()),
          ),
          error: (error, stack) => Card(child: ListTile(title: Text(context.t.backup_upload_mode_error))),
          data: (counts) =>
              BackupHistorySummary(ignored: counts.ignored, uploaded: counts.uploaded, matched: counts.matched),
        );
  }
}

class BackupHistorySummary extends StatelessWidget {
  final int ignored;
  final int uploaded;
  final int matched;

  const BackupHistorySummary({super.key, required this.ignored, required this.uploaded, required this.matched});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        side: BorderSide(color: context.colorScheme.outlineVariant),
      ),
      elevation: 0,
      child: Column(
        children: [
          ListTile(
            title: Text(context.t.backup_upload_mode_processed, style: context.textTheme.titleMedium),
            subtitle: Text(context.t.backup_upload_mode_processed_description),
            trailing: Text('${ignored + uploaded + matched}', style: context.textTheme.titleLarge),
          ),
          const Divider(height: 0),
          _HistoryCount(title: context.t.backup_upload_mode_uploaded, count: uploaded),
          _HistoryCount(title: context.t.backup_upload_mode_ignored, count: ignored),
          _HistoryCount(title: context.t.backup_upload_mode_matched, count: matched),
        ],
      ),
    );
  }
}

class _HistoryCount extends StatelessWidget {
  final String title;
  final int count;

  const _HistoryCount({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    return ListTile(dense: true, title: Text(title), trailing: Text('$count'));
  }
}
