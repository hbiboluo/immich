# Android 仅新文件备份实现计划

> 智能体执行说明：本次已获用户明确授权，采用当前会话分工开发、统一集成，并在本地英文提交后进行整体审查。

**目标：** 用户开启仅新文件模式时忽略当前可见媒体，此后只自动上传未处理的新媒体；上传后的设备原片和云端托管文件独立。

**架构：** 在现有 Drift 数据库新增独立策略与处理历史表。Android 前后台继续共用上传仓储，依据持久历史过滤候选；现有差集模式保持默认。媒体库身份变更与初始化失败进入持久暂停状态。

**技术栈：** Flutter、Riverpod、Drift/SQLite、Pigeon、Android MediaStore。

**设计依据：** 用户已批准本次会话交付的「Immich Android 仅新文件上传：代码评估与修改建议」，并确认 SQLite 每个媒体保存小记录的方案。

## 全局约束

- 功能仅在 Android 10 及以上开启，要求完整照片和视频权限；服务器和 Web 不修改。
- 不复制照片内容；不把已忽略文件宣称为已上传或允许安全清理。
- 历史按稳定服务器地址与账号隔离，网络 endpoint 切换不改变范围。
- 首版按媒体身份识别已处理，不用 baseline checksum 阻止新副本上传。
- 初始化以完整成功快照为边界；扫描中断后保持暂停，不回退旧模式。
- 新代码进入 domain/data/presentation；生成文件仅由工具产生；源文案仅修改 i18n/en.json。
- 仅作本地英文 commit，不推送；用户要求完成后 review。

## 审查重点

- 云端永久删除、回收和恢复均不自动操作设备原片，也不触发旧文件补传。
- 基线扫描失败或进程被杀后，前后台都不能继续上传旧候选。
- 新文件已在云端时，先保存 remoteMatched 历史，避免以后云删重传。
- 媒体库重建和部分权限范围变化不能静默串用旧 ID。
- 混合素材删除、仅设备文件删除和释放空间保持明确的作用范围。

## 任务一：持久策略与历史

文件：新增 `domain/models/backup_policy.model.dart`、策略和历史 Drift 表、`infrastructure/repositories/backup_policy.repository.dart`；修改 `data/db/main/database.dart`、`infrastructure/repositories/backup.repository.dart`；扩展仓储及迁移测试。

接口：`BackupPolicyStatus {legacy, initializing, active, paused}`；策略包含 scope、status、mediaStoreVersion、revision；历史原因 `baseline/uploaded/remoteMatched`。仓储提供 get/watchPolicy、begin/completeInitialization、pause/useLegacy、hasProcessed、recordUploaded、get/watchHistoryCounts。现有候选和统计增加可选 scope；批次候选使用 limit+afterId。

- [x] 添加基线、云删后不补传、同 ID 编辑、remoteMatched、范围隔离、暂停、相册排除和分页测试。
- [x] 添加新增行为的回归用例并实现历史、策略及 schema 36 迁移。
- [x] 事务化保存全可见媒体基线；失败状态持久化；重置数据库后旧策略至少恢复为暂停。
- [x] 用统一未处理条件计算候选和计数，生成前持久记录远端匹配。
- [x] 运行仓储及迁移测试。

## 任务二：上传及设备快照

文件：`services/foreground_upload.service.dart`、`providers/backup/backup.provider.dart`、`domain/services/local_sync.service.dart`、`domain/services/hash.service.dart`、`infrastructure/repositories/local_asset.repository.dart`、`pigeon/native_sync_api.dart`、Android Sync 实现及 iOS API 占位实现。

接口：上传服务增加 `cancelAndWait()`；本地扫描增加 `throwOnError` 和 `skipMediaManagement` 可选参数；NativeSyncApi 增加 `getMediaStoreVersion(): String`，Android 返回实际 version/volume 身份。

- [x] 添加成功历史落库、失败不完成、取消等待和当前策略变更的测试。
- [x] 分批读取候选；每次发送前复核范围、策略版本、处理历史和素材元数据。
- [x] 成功后先保存历史再通知 UI；手动上传仍可覆盖忽略状态。
- [x] 基线扫描明确传播错误；原生媒体版本前后不一致时不完成初始化。
- [x] 哈希回写增加预期更新时间校验，避免旧哈希写进已改变的素材。
- [x] 生成 Pigeon 并运行上传和同步相关测试。

## 任务三：模式设置与备份统计

文件：新增 `providers/backup/backup_policy.provider.dart` 与 `presentation/widgets/backup/` 组件，修改现有备份设置和页面接线、`i18n/en.json`，添加相关测试。

接口：暴露 backupScopeProvider、backupPolicyProvider、backupHistoryCountsProvider、backupPolicyControllerProvider；controller 提供 enableOnlyNew 和 useLegacy。

- [x] 实现先持久暂停、等待任务退出、完整扫描、事务建立基线再恢复调度。
- [x] 提供 Android 模式选择、快照忽略确认、持久暂停恢复提示。
- [x] 新模式将已处理数与实际上传、忽略、远端匹配分项展示；候选列表使用同一策略。
- [x] 新模式停止相册持续补齐，保留显式手动上传。
- [x] 运行 widget/provider 验证并生成源文案。

## 任务四：两端文件操作独立

文件：`domain/services/sync_stream.service.dart`、`domain/services/local_sync.service.dart`、`domain/services/sync_linked_album.service.dart`、相关调用入口、`presentation/actions/delete.action.dart`。

- [x] 添加管理本地媒体启用时，新模式禁止自动跨端删除和恢复的测试。
- [x] 两个同步入口均读取持久策略；继续更新远端索引，禁止自动改设备文件。
- [x] 云端软删除和永久删除不调用设备清理；云端撤销仅恢复云端。
- [x] 保留单独设备删除，混合选择明确目标；释放空间继续依据真实云端副本。
- [x] 运行相关服务与动作测试。

## 任务五：集成、验证、本地提交与审查

- [x] 通过 mise 生成 Drift/Pigeon/翻译等必要产物，执行针对性测试与静态分析。
- [x] 尝试移动端完整测试，记录任何已有或环境性失败；不将未执行项写为通过。
- [x] 用 SQLite 5 万条历史验证存储规模和索引查询，并记录方法与结果。
- [ ] 检查 diff、迁移、生成物及无关改动，使用英文 commit 留在本地。
- [ ] 对已提交版本进行独立 review，修复发现的问题并补充英文提交。
- [ ] 交付中文验证与审查记录，明确真机验证范围和剩余限制。

## 实施验证记录

- 已生成 Drift v36、Pigeon、Dart 代码和移动端文案；生成过程未修改依赖锁文件。
- 仓储与迁移 717 项通过；新增完整快照相册回归与策略 37 项通过；上传及同步服务最新一轮 61 项通过；界面/controller/删除动作分别完成定向验证。
- 完整移动端测试：1753 项通过，1 项按原测试配置跳过；全项目 `dart analyze --fatal-infos` 无问题。
- 5 万条生产 Drift schema 的文件 SQLite 验证：处理历史增加 6.98 MiB，基线 120ms、统计 181ms、候选 127ms；为 Linux 主机结果。
- 新模式首次建立基线使用完整快照事务，避免相册扫描顺序把已移动的媒体从索引删除。
- 本机没有 Android SDK，未构建 APK，也未做 Android 真机验证；DCM 未安装，未运行其检查。
