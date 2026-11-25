# 阶段 C：五大 Tab 页面 / 子页面 / 菜单 / 布局 / 交互全面审计

- 分支：`c-interface`（本地新建，基线 `b58df1f` = 本地 main，含 729747f 及 a-data-safety）
- 工作树：`/var/minis/shared/cctvhost/wt-c-interface`
- 工程：`cctv-ios-host`（Objective-C，非 Swift；本机 iSH/Alpine 无 Apple SDK，不编译，以源码契约测试 + 静态核对保证）
- 范围：Root/央视、频道、影视、资源、设置五个一级 Tab 及其全部二级页面、菜单、悬浮控件、模态窗
- CI #617 状态：见第 8 节
- 代码改动：仅新增独立小模块 `HostEmptyStateView`（统一空态 helper）+ 契约测试，未触碰 Agent B 拥有的 `SettingsViewController` / `ConfigCenterViewController`；不 push、不动 main

## 0. 导航架构总览

App 采用**单一容器 + 自绘底部 Dock** 的导航模型，而非系统 `UITabBarController`：

- `RootViewController`（1600 行 + 6 个分类扩展）是五个 Tab 的唯一宿主。底部 `HostTabBarController`（一个 `UIStackView`，等分 5 个 `UIButtonConfiguration` 图标+标题胶囊）通过 `onSelect` 回调 `selectBottomTab:`。
- 五个 Tab（`RootViewController.m:1052`）：

  | 索引 | 标题 | a11y 标识 | 图标 | 页面归属 |
  | --- | --- | --- | --- | --- |
  | 0 | 央视 | `tab.live` / 央视直播 | `tv.fill` | RootVC 内直播网格 |
  | 1 | 频道 | `tab.channels` / 订阅频道 | `play.rectangle.on.rectangle` | RootVC 内订阅网格 |
  | 2 | 影视 | `tab.vod` / 影视库 | `house.fill` | `MediaBrowserViewController`（子 VC） |
  | 3 | 资源 | `tab.resources` / 资源管理 | `square.stack.3d.up.fill` | `ConfigCenterViewController`（子 VC） |
  | 4 | 设置 | `tab.settings` / 设置 | `gearshape.fill` | `SettingsViewController`（子 VC） |

- `tabPages[@N]` 字典按需懒创建并缓存 2/3/4 三个子 VC；0/1 的内容直接由 RootVC 的 `channelGrid`/`table` 渲染。`showTabPage:title:` 会 `[self addChildViewController:]` 并把子 VC 的 `view` 设为 `self.view` 大小，同时隐藏 `navigationItem` 标题/搜索/左右按钮（custom 主导航模型）。
- 切换离开 0/1 进入 ≥2 会 `suspendLivePlaybackForReason:@"left_live_interface"`（停止直播播放器，生成 +1）；回到 0/1 恢复上次 `catalogState`（含 query/group/scroll offset）。
- 最后选中 Tab 持久化 `cctv.lastBottomTab.v1`，冷启动 `selectBottomTab:` 复原（`initialTabRestorePending`，且 `ui_session_tab_restored` 事件标注自动恢复不触发内容加载）。

## 1. 页面 / 菜单 / 状态矩阵

记号：✅ 有 / ⚠️ 部分或风险 / ❌ 缺失。返回=系统返回手势/按钮或自定义关闭。

### Tab 0 — 央视直播（RootVC）

| 元素 | 导航入口 | 返回 | 加载态 | 空态 | 错误态 | a11y | 大字号/iPad |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 频道网格/列表 | 底部 Dock tab0 | n/a（根） | `spinner` 居中 + `status` 标签 | 暂无（依赖源） | `status` 内联文本 + `showServiceError` alert | ⚠️ 见下 | ⚠️ 见下 |
| 悬浮胶囊（玻璃）`catalogFloatingControls` | 视图内 | n/a | n/a | n/a | n/a | ✅ layout/airplay/more 均有 label、identifier | ✅ |
| 布局切换 `catalogLayoutButton` | 胶囊内 | n/a | n/a | n/a | n/a | ✅ label 随 gridMode 切换 | ✅ |
| More 菜单 `catalogMoreButton` | 胶囊内 | 菜单外点 | n/a | n/a | n/a | ✅ `showsMenuAsPrimaryAction` | ✅ |
| 频道行 context menu | 长按行 | 菜单外点 | n/a | n/a | n/a | ✅ | ✅ |
| 节目单 `EPGViewController`（push） | 频道菜单/`epgBtn` | 系统返回 | ✅ `spinner`+`emptyLabel` "下拉可重新加载" | ✅ "暂无节目单" | ✅ "刷新失败，显示上次节目单" | ⚠️ emptyLabel 无 a11yIdentifier | ✅ `adjustsFontForContentSizeCategory` |
| 回看/线路面板 `routesPanel`/`playbackPanel` | 频道菜单 | 系统返回 | ✅ | ✅ "暂无可显示内容" | ✅ | ✅ | ✅ |

### Tab 1 — 订阅频道（RootVC）

与 Tab 0 共用同一套网格/悬浮控件/节目单入口，区别仅 `subscriptionCatalog=YES`、来源为 `subscriptionURLs`。首次进入且无 `channelID` 且用户主动选中时触发 `refreshSubscriptionsWhenIdle`。

- 空态：无订阅时列表为空，**无显式空态提示** ❌（仅靠空网格）。中等风险：新用户进入看到空白。建议复用 `HostEmptyStateView` 补「还没有订阅，去资源页导入」。
- 错误态：订阅拉取失败 → 内联 `status` 文本 + alert。

### Tab 2 — 影视库（MediaBrowserViewController，2609 行）

| 元素 | 导航入口 | 返回 | 加载态 | 空态 | 错误态 | a11y | 大字号/iPad |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 首页分类/卡墙 | tab2 | n/a（嵌套） | ✅ `homeStatusIndicator`+`status`+`spinner` | ✅ 多种：无源→"开始浏览影视"；无推荐→"当前站点暂无推荐"；纯空→"暂无精选内容" | ✅ `showMessage:loading:` 内联 + 重试动作 | ✅ 52 处 a11y | ✅ 22 处动态字体 |
| 全局搜索 `MediaGlobalSearchViewController`（push） | 首页搜索按钮 | 系统返回 | ✅ `progressLabel` 进度 | ✅ 无源→"尚未导入影视资源"；无结果→文本 | ✅ 每来源失败可重试 | ⚠️ empty 无 identifier | ✅ 7 处动态字体 |
| 影片详情（内联 `MediaDetailViewController`） | 点卡片 | 自定义返回 | ✅ `spinner` | ✅ 海报占位/简介"暂无简介"/分集"此线路没有可选分集" | ✅ "影片详情加载失败" | ✅ | ✅ |
| 选集 `MediaEpisodeSelectionViewController` | 详情内 | 自定义关闭 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 内联播放 `MediaPlaybackViewController`（embed） | 详情播放 | 返回详情 | ✅ `spinner`+`status` | n/a | ✅ "解析失败" | ✅ 55 处 a11y | ✅ |
| 收藏列表（嵌套 section） | 首页收藏分类 | n/a | n/a | ⚠️ 手写 `UILabel` "还没有收藏影视" | n/a | ❌ empty 无 a11y 标签 | ❌ empty 未 `adjustsFontForContentSizeCategory` |
| 观看记录（嵌套 section） | 首页历史分类 | n/a | n/a | ⚠️ 手写 `UILabel` "还没有观看记录" | n/a | ❌ empty 无 a11y 标签 | ❌ empty 未 `adjustsFontForContentSizeCategory` |
| 源配置 `MediaWebViewController`（sheet） | 详情更多 | sheet 抓手 | n/a | n/a | n/a | ✅ `modalInPresentation` | ✅ |

### Tab 3 — 资源管理（ConfigCenterViewController，1925 行）⚠️ Agent B 拥有，本阶段仅审计不改

| 元素 | 导航入口 | 返回 | 加载态 | 空态 | 错误态 | a11y | 大字号/iPad |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 资源列表 | tab3 | n/a | ✅ | ✅ `emptyContainerView`(图标+文字+动作按钮) 多文案 | ✅ alert | ✅ 38 处 | ✅ 11 处动态字体 |
| 悬浮 + / 更多 `compactAdd`/`compactMore` | 顶部 compactHeader | n/a | n/a | n/a | n/a | ✅ | ✅ |
| 脚本与服务 `ServicesViewController`（push） | 浮动按钮/资源悬浮菜单 | 系统返回 | ✅ 启停进度 | ⚠️ 无独立空态 | ✅ 多 alert "服务操作失败/超时" | ⚠️ 仅 5 处 a11y | ✅ 5 处动态字体 |
| 服务编辑 `ServiceEditorViewController`（push） | 服务行 | 系统返回 | n/a | n/a | ✅ | ⚠️ | ✅ |
| 资源导入 `ResourceImportWorkflowViewController`（full-screen modal） | 添加资源 | 自定义取消 | ✅ `progress` alert | n/a | ✅ "资源导入失败" | ⚠️ | ✅ |
| 资源详情/能力 `PluginResourceDetailViewController`（push） | 资源行 | 系统返回 | ✅ | ✅ | ✅ | ⚠️ | ✅ |
| 运行历史 `PluginRunHistoryViewController`（push） | 资源详情 | 系统返回 | ✅ | ✅ "暂无运行记录" | n/a | ⚠️ | ✅ |
| 日志中心 `LogCenterViewController`（push） | 运行历史/资源详情 | 系统返回 | ✅ | ✅ `emptyLabel` "暂无日志" | ✅ | ⚠️ empty 无 identifier | ✅ |
| 本地媒体 `LocalMediaViewController`（push，设置入口） | 设置→本地媒体 | 系统返回 | ✅ | ✅ `emptyLabel` "暂无本地媒体文件" | ✅ | ⚠️ empty 无 identifier | ✅ |
| 合集浏览 `TVBoxCatalogViewController`（push） | 资源页 | 系统返回 | ✅ | ⚠️ 手写 `UILabel`（多文案） | ✅ | ❌ 仅 2 处 a11y，empty 无 | ❌ empty 未动态字体 |

### Tab 4 — 设置（SettingsViewController，2376 行）⚠️ Agent B 拥有，本阶段仅审计不改

| 元素 | 导航入口 | 返回 | 加载态 | 空态 | 错误态 | a11y | 大字号/iPad |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 设置分组列表 | tab4 | n/a | ✅（检查更新 spinner pill） | n/a（总有项） | ✅ "检查更新失败" alert | ✅ 33 处 | ✅ 8 处动态字体 |
| 播放信息 `PlaybackInfoViewController`（sheet medium/large） | 播放中 | sheet 抓手 | `spinner` | ✅ `emptyLabel` | ✅ | ✅ | ✅ 7 处 |
| 运行诊断 `RuntimeDiagnosticsViewController`（push/sheet） | 设置 | 系统返回 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 各清除/恢复确认 | 行点击 | alert 取消 | n/a | n/a | ✅ "缓存清理失败" | ✅ | ✅ |
| 导出备份（share） | 行 | share 完成返回 | ✅ "正在准备备份…" prompt | n/a | ✅ | ✅ | ✅ |

### 跨页悬浮控件

- `liveMiniPlayerBar`：0/1 页直播迷你播放条，>2 页隐藏。✅ a11y。
- `bottomBarBackdrop` + `bottomDockGlass`：底部 Dock 毛玻璃背景 + 渐隐，宽度 clamp 540pt ✅（iPad 居中不拉满）。
- `resourceActionsButton`：资源页悬浮操作球（脚本与服务/添加资源/刷新资源/刷新当前媒体内容），默认 `hidden=YES`，仅 tab3 显示 `openServicesPage`。

## 2. 导航入口与返回一致性

- **push 模式**（系统返回）：EPG、Services、ServiceEditor、PluginRunHistory、LogCenter、PluginResourceDetail、MediaGlobalSearch、RuntimeDiagnostics、LocalMedia、TVBoxCatalog、MediaPlayback。均走 `navigationController pushViewController:`，返回由导航栏 back button 承担。✅ 一致。
- **sheet 模态**（自定义关闭）：PlaybackInfo（page sheet medium/large + grabber）、MediaWeb（`modalInPresentation`）、ResourceImportWorkflow（full-screen + 自定义取消按钮 + `UIModalPresentationFullScreen`）、HostGlassActionSheet（glass + popover source）。✅ 一致。
- **alert 模态**：所有错误/确认/进度均 `UIAlertController`。返回靠 action。✅。
- ⚠️ **返回逻辑薄弱点**：`ResourceImportWorkflowViewController` 以 full-screen modal 呈现但取消/完成依赖自定义按钮，若中途外部 dismiss（如手势）无 `isModalInPresentation` 保护——`MediaWebViewController` 用了该保护，建议对齐。
- ⚠️ **Tab 0/1↔2 切换的播放暂停** 有序（`suspendLivePlaybackForReason` + 生成号 + 诊断事件），但 2→0/1 恢复的是 catalogState 而非播放器；直播需用户重新点频道。属设计行为，非缺陷。

## 3. 空态审计（核心发现）

全仓 119 处空态相关文案，**手写 `UILabel` 当 `tableView.backgroundView` 的站点至少 12 处**，约定不统一：

| 站点 | 文件 | 动态字体 | a11y label/identifier | 一致性 |
| --- | --- | --- | --- | --- |
| 影视收藏 | MediaBrowserViewController.m:1238 | ❌ | ❌ | 不一致 |
| 影视观看记录 | MediaBrowserViewController.m:1316 | ❌ | ❌ | 不一致 |
| 全局搜索无源 | MediaGlobalSearchViewController.m:265 | ✅ | ❌ 无 identifier | 部分 |
| 本地媒体 | LocalMediaViewController.m:161 | ✅ | ❌ 无 identifier | 部分 |
| 日志中心 | LogCenterViewController.m:110 | ✅ | ❌ 无 identifier | 部分 |
| 节目单 | EPGViewController.m:127 | ✅ | ❌ 无 identifier | 部分 |
| 合集浏览 | TVBoxCatalogViewController.m:95 | ✅ | ❌ 仅 2 处 a11y | 部分 |
| 选集搜索空 | MediaBrowserViewController.m:135 | ✅ | ✅ `media-picker-empty` | ✅ |
| ConfigCenter empty 容器 | ConfigCenterViewController.m:309 | ✅ | ✅ | ✅（Agent B） |
| PlaybackInfo | PlaybackInfoViewController.m:50 | ✅ | ⚠️ | 部分 |

**结论**：空态在「颜色/字号/a11y」三维度高度碎片化，是大字号与 VoiceOver 回归的高发区。本阶段已落地统一 helper（见第 6 节），后续各页可逐步迁移；因 ConfigCenter/Settings 归 Agent B，本轮不迁移其站点。

## 4. 加载态审计

- 主加载指示器统一 `UIActivityIndicatorViewStyleMedium` + `hidesWhenStopped`，居中 Auto Layout。✅。
- 影视首页/详情用 `status` 文本标签叠加 spinner，描述性强（"正在解析…"/"刷新失败 · 保留当前详情"）。✅。
- 长任务用 `UIAlertController` 进度弹窗（ZIP 导出、订阅验证、整包导入）。⚠️ 这些 alert 阻塞但无超时；`tvboxCatalogExportProgressAlert` 取消靠 action，若网络挂起会长时间停留——已有取消按钮，可接受。
- ⚠️ `ServicesViewController` 启停有超时 alert（"服务启停响应超时"），✅；但 `ServiceEditorViewController` 保存无独立加载态（同步写），低风险。

## 5. 错误态审计

- 统一入口 `showServiceError:`（RootVC+Services.m:613）→ `UIAlertController` 标题"服务"，默认文案"服务操作失败，请查看日志。"。✅ 一致。
- 影视层用 `showMessage:loading:` 内联到 `status` 标签（更贴详情页上下文，不弹窗）。✅。
- 网络/解析失败均带 `error.localizedDescription`，并有 `RuntimeDiagnostics` 事件记录（`episode_resolve_failed` 等）。✅。
- ❌ **无全局重试队列**：影视首页失败有"重试"动作；EPG 失败保留旧数据并提示；但订阅刷新失败仅 alert，无内联重试入口（需手动下拉）。低风险但可改进。

## 6. 无障碍（a11y）专项

- 五个 Tab 按钮均齐备 `accessibilityLabel/Hint/Traits/Value`（选中态 `Selected`+`@"已选中"`），唯一缺口是 Tab 1/3/4 初始 `accessibilityTraits` 未带 `Selected`（仅 tab0 设了）——但因 `selectBottomTab:` 会 `updateBottomBarSelection` 重设 traits，实际选中后会修正，属轻微。
- 底部 Dock 按钮标题在大字号下用 `UIFontMetrics(Caption2) scaledFont`，且 `b.titleLabel.hidden=UIContentSizeCategoryIsAccessibilityCategory(...)`（accessibility 档隐藏文字只留图标）✅，并在 `fontSizeOverrideTraitCollection` 推送自定义字号覆盖子 VC ✅。
- 缺口集中在二级页空态标签（见第 3 节）与 `ServicesViewController`（仅 5 处 a11y，服务行/启停按钮 label 偏少）。
- 影片详情/播放控制 a11y 在阶段 3 已补强（见 `report-p3-accessibility.md`），本轮未改。

## 7. iPad / 大字号风险

- **iPad 宽屏**：底部 Dock 宽度 clamp `min(w-20, 540)` 居中 ✅。影视卡墙/网格按宽度算列数 ✅。但**二级 push 页多为单列 table，iPad 横屏大量留白**——未做 `regular` size-class 多栏/分栏。中风险（体验，非功能）。`compactHeader` 仅在 compact 显示，regular 下靠导航栏，已处理。
- **大字号**：RootVC `fontSizeOverrideTraitCollection` 把用户字号档推给所有子 VC ✅；`b.titleLabel` 在 accessibility 档隐藏 ✅。但 12 处手写空态 label 中 4 处未开 `adjustsFontForContentSizeCategory`（收藏/历史/合集等），大字号下文字不缩放。本次 helper 已解决，待迁移。
- **popover**：所有 `UIActivityViewController`/sheet 均设了 `popoverPresentationController.sourceView/sourceRect` 或 `barButtonItem` ✅（iPad 不崩）。Share 路径 `shareDiagnosticLogAtURL:` 优先 `barButtonItem`，无则中心点 fallback ✅。
- ⚠️ `ResourceImportWorkflowViewController` full-screen modal 在 iPad 无 size-class 适配（占满），低风险。

## 8. CI #617 后续状态

- CI #617 的修复在分支 `a-smoke-fix`，提交 `7a99992 fix(smoke): assert media favorites via HostLibraryStore not legacy defaults (CI #617)`——把烟测断言由旧 `NSUserDefaults cctv.mediaFavorites.v1` 改读 `HostLibraryStore.shared.mediaFavorites`，对齐迁移后的 SQLite 存储。
- 该提交**仅存在于 `a-smoke-fix`，未合入本地 main（b58df1f），也未 push 到 origin/main（dfef066）**。`git branch --contains 7a99992` 只列 `a-smoke-fix`。
- 本分支 `c-interface` 从本地 main `b58df1f`（729747f 的后继，已含 a-playback-route/a-data-safety）切出，与 a-smoke-fix 并行，**未覆盖、未触碰 a-smoke-fix 分支**。若 a-smoke-fix 后续合入 main，与本分支无路径冲突（本分支仅新增 `HostEmptyStateView.*` 与 `Tests/test_host_empty_state_view.py`，不改烟测）。
- 无法直接抓取 CI 运行详情：本机 `GH_TOKEN` 无效，`gh auth status` 失败；origin 为 `blob:none` 稀疏，无 `.github/workflows`。结论基于本地 git 历史推断，建议人工在 GitHub Checks 确认 CI #617 是否绿。

## 9. 代码改动（低风险独立模块）

仅新增 `HostEmptyStateView`（统一空态 helper），**未编辑任何现有 Sources 文件**，因此与 Agent B 的 SettingsViewController/ConfigCenterViewController 零冲突。

### 新增文件

| 文件 | 作用 |
| --- | --- |
| `Sources/HostEmptyStateView.h/.m` | 统一空态视图：SF Symbol 图标 + title + subtitle + 可选动作按钮；全文字 `preferredFontForTextStyle`+`adjustsFontForContentSizeCategory`；`HostTheme` 动态颜色；`traitCollectionDidChange` 自动重刷；作为单个 VoiceOver 元素合并朗读 title/subtitle，有按钮时切 `Button` trait；居中 + 水平内边距（iPad 不拉满）。另提供 `+placeholderLabelWithText:` 工厂直接替换既有 `UILabel` 背景模式。含私有方法类扩展前向声明（满足 round17 选择器审计）。 |
| `Tests/test_host_empty_state_view.py` | 10 个源码契约测试：API 表面、主题色、动态字体、trait 变化、VoiceOver 合并/traits 切换/子元素排除、占位标签 a11y、布局居中与内边距、工厂不强制 frame。 |

### 未迁移既有站点（刻意）

本轮仅交付 helper + 测试，**不在 c-interface 分支迁移第 3 节的 12 处空态调用点**，原因：(1) 多数在 MediaBrowser/EPG/LogCenter/LocalMedia/TVBoxCatalog，迁移虽小但属行为改动，需逐页视觉验证，留作后续小步 PR；(2) ConfigCenter/Settings 归 Agent B，不越界。helper 已就绪，迁移是机械替换 `UILabel *empty=[UILabel new]…` → `[HostEmptyStateView emptyStateViewWithTitle:… symbol:…]` 或 `+placeholderLabelWithText:`，零风险。

## 10. 未完成项分级

### P1（建议尽快，中风险）
- 迁移第 3 节 12 处空态到 `HostEmptyStateView`（尤其收藏/历史/合集 3 处既无动态字体又无 a11y）。
- Tab 1 无订阅时补空态提示「还没有订阅，去资源页导入」。
- `ServicesViewController` 服务行/启停按钮补 `accessibilityLabel`（当前仅 5 处）。

### P2（体验优化，低风险）
- iPad `regular` size-class 二级页多栏/分栏（EPG/LogCenter/Services/TVBoxCatalog 单列留白）。
- `ResourceImportWorkflowViewController` full-screen modal 加 `isModalInPresentation` 防误 dismiss，并做 iPad sheet 适配。
- 订阅刷新失败补内联重试入口（当前仅 alert）。

### P3（防御性，低优先）
- 各二级页空态补 `accessibilityIdentifier`（`media-favorites-empty` 等）便于 UI 自动化定位。
- `PlaybackInfoViewController.emptyLabel` 补 a11y。
- 长进度 alert（ZIP 导出/订阅验证）考虑超时上限。

## 11. 验收建议

1. **测试基线**：本机 `python3 -m unittest discover -s Tests -p 'test_*.py'` → 1421 tests / 5 failures / 13 errors / 68 skipped。较基线（1411/5/13/68）新增 10 测试全过、failures/errors 数与名单一致（未新增确定性失败）。注意：`test_round17…test_zero_undeclared_forward…` 与 `test_media_proxy_streaming…test_real_python_main…` 在 iSH 因内存压力偶发 MemoryError/OOM，属环境抖动，非本分支引入（加私有方法前向声明后断言扫描零违规，已验证）。
2. **构建验证**：iOS 工程本机不可编译；helper 仅用 UIKit + HostTheme 公共 API，私有方法已声明，应可直接编入。建议在 Xcode/CI 验证 `HostEmptyStateView.m` 编译与一个迁移样例（如 LogCenter 空态）的视觉。
3. **回归点**：迁移空态后重点验 (a) 深浅主题切换颜色、(b) 大字号（AX5）文字不截断、(c) VoiceOver 朗读为合并单句、(d) iPad 横屏居中不拉满。
4. **CI**：合入前在 GitHub 确认 CI #617（a-smoke-fix）状态与本分支构建绿。

## 12. 提交信息

- 分支 `c-interface`，单提交：`feat(ui): add HostEmptyStateView unified empty-state helper + contract tests (Phase C UI audit)`
- 未 push、未动 main、未动其他工作树。
