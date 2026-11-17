import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/models/server_info/server_config.model.dart';
import 'package:immich_mobile/models/server_info/server_disk_info.model.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';
import 'package:immich_mobile/models/server_info/server_version.model.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:logging/logging.dart';

class ServerInfoNotifier extends StateNotifier<ServerInfo> {
  ServerInfoNotifier(this._serverInfoService)
    : super(
        const ServerInfo(
          serverVersion: ServerVersion(major: 0, minor: 0, patch: 0),
          serverFeatures: ServerFeatures(map: true, trash: true, oauthEnabled: false, passwordLogin: true),
          serverConfig: ServerConfig(
            trashDays: 30,
            oauthButtonText: '',
            externalDomain: '',
            mapLightStyleUrl: 'https://tiles.immich.cloud/v1/style/light.json',
            mapDarkStyleUrl: 'https://tiles.immich.cloud/v1/style/dark.json',
          ),
          serverDiskInfo: ServerDiskInfo(diskAvailable: "0", diskSize: "0", diskUse: "0", diskUsagePercentage: 0),
          versionStatus: VersionStatus.upToDate,
        ),
      );

  final ServerInfoService _serverInfoService;
  final _log = Logger("ServerInfoNotifier");

  Future<ServerInfo> getServerInfo() async {
    await getServerVersion();
    await getServerFeatures();
    await getServerConfig();
    return state;
  }

  Future<void> getServerVersion() async {
    try {
      final serverVersion = await _serverInfoService.getServerVersion();

      if (serverVersion != null) {
        state = state.copyWith(serverVersion: serverVersion);
      }
    } catch (e, stackTrace) {
      _log.severe("Failed to get server version", e, stackTrace);
    }
  }

  Future<void> getServerFeatures() async {
    final serverFeatures = await _serverInfoService.getServerFeatures();
    if (serverFeatures == null) {
      return;
    }
    state = state.copyWith(serverFeatures: serverFeatures);
  }

  Future<void> getServerConfig() async {
    final serverConfig = await _serverInfoService.getServerConfig();
    if (serverConfig == null) {
      return;
    }
    state = state.copyWith(serverConfig: serverConfig);
  }
}

final serverInfoProvider = StateNotifierProvider<ServerInfoNotifier, ServerInfo>((ref) {
  return ServerInfoNotifier(ref.read(serverInfoServiceProvider));
});

final versionWarningPresentProvider = Provider.family<bool, UserDto?>((ref, user) {
  final serverInfo = ref.watch(serverInfoProvider);
  return switch (serverInfo.versionStatus) {
    VersionStatus.clientOutOfDate || VersionStatus.error => true,
    VersionStatus.serverOutOfDate => serverInfo.latestVersion != null && (user?.isAdmin ?? false),
    VersionStatus.upToDate => false,
  };
});
