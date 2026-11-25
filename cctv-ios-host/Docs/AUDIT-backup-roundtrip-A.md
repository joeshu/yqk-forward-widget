# A 阶段备份恢复闭环审计报告

**仓库**：`/var/minis/shared/cctvhost/wt-a-backup-roundtrip` · **分支**：`a-backup-roundtrip` · **基线**：`559c421`
**审计范围**：`HostBackup` 导出(snapshot) → 导入(validatedBackup/restore) → `HostLibraryStore` SQLite/NSUserDefaults fallback roundtrip
**提交**：`c39e169 fix(backup): A阶段 导出→导入→SQLite/defaults roundtrip 去重与防静默丢失`
**约束遵守**：仅本地定向 3 个测试文件；未跑全量；未碰 CI/网络；未 push。

---

## 1. 数据流概览

### 导出 `+snapshot`
| 字段 | 来源 |
|---|---|
| preferences(bool/num/str/array) | NSUserDefaults（仅 objectForKey 非 nil 才采） |
| subscriptions / profileOrder / disabledSubscriptions / epgMappings | NSUserDefaults |
| favorites | `[HostLibraryStore.shared allFavorites]`（SQLite 或回退 defaults） |
| recents | `[HostLibraryStore.shared recents]`（SQLite `ORDER BY position ASC` 或回退 defaults） |
| vodFavorites | `[HostLibraryStore.shared mediaFavorites]`（SQLite 或回退 defaults） |
| watchHistory | `[HostLibraryStore.shared mediaWatchHistory]`（updatedAt NSDate→double） |
| profiles | `[ProfileStore metadata:]`（含磁盘 offload） |
| catalogs | NSUserDefaults `tvboxCatalogs`（剥离 `_sourceConfigData`） |
| resourceDependencies | 不可序列化 catalog id + 非内置 pythonService id（仅信息性） |
| skipPoints / epgReminders | NSUserDefaults |

### 导入 `+restore:error:`
1. `ProfileStore replaceBackupMetadata`（REPLACE profileMetadata + 磁盘 offload）
2. subscriptions→defaults；favorites→defaults + `replaceFavorites`(async)
3. profileOrder/disabledSubscriptions/epgMappings→defaults
4. catalogs→**MERGE** 进 defaults（已有 id 保留，新增 id 追加，≤64）
5. recents→defaults + `replaceRecents`(async)
6. vodFavorites→`replaceMediaFavorites`(async) + defaults
7. watchHistory→timestamp→NSDate rows→`replaceMediaWatchHistory`(async) + defaults(timestamp 形)
8. skipPoints/epgReminders→defaults
9. preferences：先 remove 所有已知键，再按存在性 set
10. `markRestorePendingIfFallback`（performSync，排空此前所有 async 写入）

### SQLite/defaults fallback 机制（`prepareLocked`）
- SQLite 可用 → 读写 SQLite；async `replaceXxx` 仅 fallback 分支才镜像到 defaults。
- SQLite 不可用 → `openAttempted=YES`，后续 `prepareLocked` 直返 NO；写入落 defaults；`markRestorePendingIfFallback` 置 `restorePending=YES`。
- 下次 SQLite 恢复 → `prepareLocked`：`restorePending` 走 `replaceFromDefaultsLocked`（REPLACE 语义，全量从 defaults 重建 SQLite）；否则走 `reconcileFallbackDataLocked`（MERGE 并集语义）。
- `markRestorePendingIfFallback` 用 `dispatch_sync`，保证 restore 返回前此前所有 async `replaceXxx` 已排空执行 → 无 crash 窗口丢失。

---

## 2. 确定性缺陷与修复

### 缺陷 A1（重复 / 两层分叉）— 已修复
**位置**：`HostLibraryStore.m` `replaceFavorites:` / `replaceRecents:` 的回退分支。
**现象**：SQLite 不可用时，两个方法向 NSUserDefaults 写入**原始未归一化** `snapshot`，而 SQLite 分支写 `HostLibraryNormalizedFavorites/Recents(snapshot)`（去重、过滤空串/无 id/不可序列化项）。备份含重复收藏或无 id/重复 id 的 recents 时：
- defaults 回退镜像残留重复/无效条目，SQLite 层（若后续恢复并 reconcile）已去重 → 两层分叉；
- fallback 期间 `allFavorites`/`recents` 读 defaults → **返回重复条目**（重复缺陷）。
- `replaceMediaWatchHistory` 已用 `boundedHistory()`（去重+裁剪），`replaceMediaFavorites` 因 dict 键唯一无重复风险——唯独 favorites/recents 未对齐。

**修复**：将 `normalized` 上提至两层共用，回退分支亦写入 `normalized`，确保回退镜像与 SQLite 一致。改动各 1 处（2 个方法），无新 API。

### 缺陷 A2（静默数据丢失 / 两层分叉）— 已修复
**位置**：`HostBackup.m` `+validatedBackup:`
**现象**：导入校验仅要求 `recents`/`watchHistory` 条目为 `NSDictionary`，但持久层会静默丢弃缺主的条目：
- `writeRecentsLocked` 经 `HostLibraryRecentKey` 要求非空 `entry[@"id"]`，缺 id 的条目被跳过；
- `writeMediaHistoryLocked` 与 `replaceMediaWatchHistory` 的 `boundedHistory()` 要求非空 `entry[@"key"]`，缺 key 的条目被跳过。
导入时 restore 仍把**原始**数组直写 defaults（两层一致性写），于是缺 id/key 的条目：defaults 层保留、SQLite 层丢失 → **两层分叉**；下次 `+snapshot` 从 SQLite 读取时**丢数据**（确定性丢失）。

**修复**：`+validatedBackup:` 要求 `recents` 条目带非空 `id`、`watchHistory` 条目带非空 `key`，把"静默丢弃"前移为"显式拒绝整个备份文件"（错误信息不变）。自产备份由 SQLite 主键/写入逻辑强制带 id/key，始终满足该约束，不会被误拒；仅拦截畸形/跨版本缺主键的导入，避免静默丢数据。

---

## 3. 顺序问题审计结论（未发现需修复项）

- `writeFavoritesLocked`/`writeRecentsLocked`/`writeMediaHistoryLocked` 按 array 顺序赋 `position` 0,1,2…；取值均 `ORDER BY position ASC` → roundtrip 顺序稳定（已用 Python sqlite3 实跑断言）。
- `appendRecent` 用 `MIN(position)-1` 前插 + `LIMIT 24` 裁剪；最近观看顺序与上限语义正确。
- `reconcileFallbackDataLocked` 对 recents/history 按 `watchedAt`/`updatedAt` 降序合并并裁剪，幂等。
- preferences 先 remove-all 再 set → 干净覆盖，无残留旧值导致顺序/状态错乱。
- `markRestorePendingIfFallback` 的 `dispatch_sync` 排空此前 async 写入 → restore 返回时写入已完成，无异步顺序竞态。

---

## 4. 已知残留（本次未改，附理由）

| # | 现象 | 严重度 | 不改理由 |
|---|---|---|---|
| R1 | restore 在 SQLite 可用模式下仍把**原始** favorites/recents 直写 defaults（不经归一化）。若备份含重复收藏/id，defaults 镜像残留重复，直至后续 fallback reconcile 清理。 | 低（自产备份无重复；仅在 SQLite 不可用且未 reconcile 时短暂可见重复） | 修需向 `HostLibraryStore` 暴露归一化函数或在 HostBackup 内联去重，扩大 API/面；与"最小修复"取舍后留待后续。A1 已堵住 store 自身回退分支的重复源。 |
| R2 | `validatedBackup:` 未对 `watchHistory`/`recents` 设数量上限。备份含 >100 watchHistory（`HostMediaWatchHistoryLimit`）时，`boundedHistory()`/`writeMediaHistoryLocked` 静默截断到 100，超过部分丢弃。 | 低（自产备份 ≤100；仅跨版本/导入大备份） | 截断由既定设计上限驱动；是否在导入侧显式拒绝大备份 vs 静默截断属产品决策，本次不擅自收紧，仅记录。 |
| R3 | catalogs 导入为 MERGE（已有 id 保留、不更新内容），备份中与本地同 id 的 catalog 内容被丢弃（本地旧版胜出）。 | 中（跨设备更新 catalog 失效） | 属有意"不覆盖用户本地合集"语义；改为覆盖是语义决策非 bug 修复，超 A 阶段最小修复范围，留待产品确认。 |
| R4 | `writeRecentsLocked` 不强制 `HostLibraryRecentsLimit(24)`，仅 `appendRecent` 裁剪。导入 >24 recents 时 SQLite 暂存 >24 直至下次 append。 | 低 | 截断会丢数据、不截断仅超存；与 R2 同属上限策略，不擅自改。 |

> R1/R2/R4 均为"自产备份不触发、仅畸形/跨版本导入触发"的边界；A1/A2 已修复的是**自产备份也可能触发或必然分叉**的核心确定性缺陷。

---

## 5. 测试

**新增**：`cctv-ios-host/Tests/test_a_backup_roundtrip.py`（3 组 7 用例）
- `BackupValidationContractTests`：recents 必带 `id`、watchHistory 必带 `key`、校验层不去重（归一化交由 store）。
- `StoreFallbackNormalizationTests`：`replaceFavorites`/`replaceRecents` 回退分支写 `normalized` 不写 `snapshot`（各 2 处 defaults 写入）；实跑归一化语义。
- `RoundtripOrderingTests`：favorites/recents 写入→读取顺序稳定（Python sqlite3 实跑 SQL 字面量）。

**定向运行（≤3 文件，全部通过）**：
```
$ python3 -m unittest Tests.test_a_backup_roundtrip Tests.test_library_store Tests.test_settings_contracts
Ran 44 tests in 1.391s
OK
```
- `test_library_store`：回归 store 契约/括号配对/fallback/调用点 — 全过（确认 A1 改动未破坏既有契约）。
- `test_settings_contracts`：回归 backup 覆盖偏好/restore 元数据 — 全过（确认 A2 校验收紧未误伤）。
- 未跑全量、未碰 CI/网络、未 push。

---

## 6. 改动清单

```
 cctv-ios-host/Sources/HostBackup.m             |   4 +-
 cctv-ios-host/Sources/HostLibraryStore.m       |  16 ++-
 cctv-ios-host/Tests/test_a_backup_roundtrip.py | 171 +++++++++++++++++++++++++
 3 files changed, 183 insertions(+), 8 deletions(-)
```
- `HostBackup.m`：`validatedBackup:` 2 处校验收紧（recents `id` / watchHistory `key`）。
- `HostLibraryStore.m`：`replaceFavorites:` / `replaceRecents:` 归一化上提、回退分支写 `normalized`。
- `Tests/test_a_backup_roundtrip.py`：新增闭环审计用例。

提交 `c39e169` 在 `a-backup-roundtrip` 分支本地，未 push。
