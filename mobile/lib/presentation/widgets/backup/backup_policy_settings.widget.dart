import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/backup_policy.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/backup/backup_policy.provider.dart';
import 'package:immich_ui/immich_ui.dart';

class BackupPolicySettings extends ConsumerStatefulWidget {
  const BackupPolicySettings({super.key});

  @override
  ConsumerState<BackupPolicySettings> createState() => _BackupPolicySettingsState();
}

class _BackupPolicySettingsState extends ConsumerState<BackupPolicySettings> {
  bool _busy = false;

  Future<void> _change({required bool onlyNew, bool resetBaseline = false}) async {
    final policy = ref.read(backupPolicyProvider).asData?.value;
    final restoreExisting = onlyNew && !resetBaseline && policy?.mediaStoreVersion != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          restoreExisting
              ? context.t.backup_upload_mode_resume_title
              : onlyNew
              ? context.t.backup_upload_mode_confirm_title
              : context.t.backup_upload_mode_legacy_confirm_title,
        ),
        content: Text(
          restoreExisting
              ? context.t.backup_upload_mode_resume_description
              : onlyNew
              ? context.t.backup_upload_mode_confirm_description
              : context.t.backup_upload_mode_legacy_confirm_description,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.t.confirm)),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final controller = ref.read(backupPolicyControllerProvider);
      if (onlyNew) {
        await controller.enableOnlyNew(resetBaseline: resetBaseline);
      } else {
        await controller.useLegacy();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t.backup_upload_mode_failed)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!CurrentPlatform.isAndroid) {
      return const SizedBox.shrink();
    }
    final policy = ref.watch(backupPolicyProvider);
    final scope = ref.watch(backupScopeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroupTitle(title: context.t.backup_upload_mode, icon: Icons.cloud_upload_outlined),
        policy.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator.adaptive()),
          ),
          error: (error, stack) => SettingListTile(title: context.t.backup_upload_mode_error),
          data: (policy) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile.adaptive(
                title: Text(context.t.backup_upload_mode_only_new),
                subtitle: Text(context.t.backup_upload_mode_only_new_description),
                value: policy.onlyNew,
                onChanged: _busy || scope == null
                    ? null
                    : (value) => _change(onlyNew: value, resetBaseline: policy.isPaused),
              ),
              if (_busy || policy.status == BackupPolicyStatus.initializing)
                ListTile(
                  leading: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  title: Text(context.t.backup_upload_mode_initializing),
                ),
              if (policy.isPaused && !_busy) ...[
                SettingListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: context.t.backup_upload_mode_paused,
                  subtitle: context.t.backup_upload_mode_paused_description,
                ),
              ],
              if ((policy.onlyNew || policy.mediaStoreVersion != null) && !_busy)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: OutlinedButton(
                    onPressed: () => _change(onlyNew: true, resetBaseline: true),
                    child: Text(context.t.backup_upload_mode_rebuild_baseline),
                  ),
                ),
              if (!policy.onlyNew)
                SettingListTile(
                  title: context.t.backup_upload_mode_existing,
                  subtitle: context.t.backup_upload_mode_existing_description,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
