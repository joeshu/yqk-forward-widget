# Phase-C 落实报告 · ResourceImportWorkflowViewController 导入防误关闭

- 分支：`c-import-dismiss` ｜ 基线：`842b82b`
- 范围：仅 `ResourceImportWorkflowViewController` 页面 + 最小契约测试
- 限制遵守：仅跑 1 个新定向测试文件 + 1 个既有回归文件；未跑全量/CI/网络/push

## 1. 审计结论（依据 `Docs/PHASE-C-UI-AUDIT.md` §6/§9）

审计文档已明确两点：

1. **§6 返回逻辑薄弱点**：`ResourceImportWorkflowViewController` 以 full-screen modal 呈现，取消/完成依赖自定义按钮；若中途发生外部 dismiss（手势）无 `isModalInPresentation` 保护——`MediaWebViewController` 用了该保护，建议对齐。
2. **§9 待办**：`ResourceImportWorkflowViewController` full-screen modal 加 `isModalInPresentation` 防误 dismiss，并做 iPad sheet 适配。
3. **§7 iPad 风险**：full-screen modal 在 iPad 无 size-class 适配（占满），评级**低风险**。

### 现状盘点（基线 842b82b）

| 维度 | 基线状态 | 评价 |
|---|---|---|
| 手势/外部 dismiss | `UIModalPresentationFullScreen`，无下拉关闭路径 | full-screen 下天然无手势 dismiss，但缺少 `isModalInPresentation` 兜底，sheet 分支（viewDidLoad 已防御性配置 detents/grabber）一旦被启用即暴露 |
| 进度恢复（resume） | 快照系统 `workflow-v1.plist` + blob，`restoreSnapshot:` 按 `busy` 分流 stage（保存/URL/本地中断可重试） | 完整，任务说“不能改变显式取消语义”——未改 |
| 显式取消（cancel） | `cancelWork`：`generation++`→`[fetcher cancel]`→`[downloader cancel]`→清状态→`busy=NO`→`stage=任务已取消…`→`updateView`；入口为 busy 态点按“取消当前任务”行 | 完整且语义正确，**未改动** |
| 收起（minimize） | `dismissViewControllerAnimated:`，仅收起面板；VC 由 RootViewController 强引用保留，后台任务继续、快照持续写入 | 非破坏性，无需变更 |
| dealloc | 取消在途 `fetcher/downloader`，不写 stage/busy | 正确，与 cancelWork 解耦 |
| iPad 演示 | 全屏占满 | 审计评级低风险 |

## 2. 落实的改动（有据、最小）

**仅 1 处源码改动，9 行，纯新增** —— `Sources/ResourceImportWorkflowViewController.m`

新增 `applyModalDismissProtection`，并在 `updateView` 内调用：

```objc
- (void)applyModalDismissProtection {
    BOOL modal=self.busy&&!self.finished;
    self.isModalInPresentation=modal;
    if(self.navigationController)self.navigationController.isModalInPresentation=modal;
}
```

- `busy && !finished` 时置 `isModalInPresentation=YES`，阻止手势/外部 dismiss；空闲或完成时置 `NO`，保证“保存并启用”完成后的自动收起（`shouldDismiss→minimize`）不受影响。
- 在 `updateView` 刷新，使 busy 翻转即时生效（所有 busy 转换路径均经 `updateView`）。
- full-screen 演示下为兜底保险；一旦以 sheet 呈现即阻止下拉关闭——直接落实审计 §6/§9 的对齐建议。
- **不触碰 `cancelWork`、`minimize`、`reset`、快照读写、save 完成自动收起逻辑**，显式取消语义完全不变。

### 为何未做 iPad sheet 适配

审计 §7 将 iPad 全屏占满评为**低风险**；将其改为 pageSheet 需改动演示方 `RootViewController+Subscriptions.m`（超出“只改该页面”约束），且引入 sheet 几何/键盘交互回归风险，在本环境无法用设备/构建验证。依据“不做无依据改动 + 必要时”原则**暂缓**，留待具备 iPad 构建验证条件时另开任务。本改动已为其铺路：`isModalInPresentation` 与 viewDidLoad 中既有的 sheet detents 防御配置已就位，后续仅需在演示方按 idiom 切换 `modalPresentationStyle`。

## 3. 测试

新增定向契约测试 **`Tests/test_resource_import_dismiss_protection_contracts.py`**（5 例，纯源码文本断言，无构建/网络）：

| 用例 | 断言要点 |
|---|---|
| `test_modal_in_presentation_guard_is_bound_to_busy` | `applyModalDismissProtection` 存在；`self/self.navigationController.isModalInPresentation` 与 `self.busy&&!self.finished` 绑定；在 `updateView` 内调用；空闲态不写死 `YES`（不阻断完成自动收起） |
| `test_explicit_cancel_semantics_unchanged` | `cancelWork` 顺序锁：`generation++` < `[fetcher cancel]` < `[downloader cancel]` < `busy=NO`；stage=“任务已取消”；末尾 `updateView` |
| `test_minimize_is_hide_not_cancel` | `minimize` 含 `dismissViewControllerAnimated:YES`；不得直接触发 `fetcher/downloader cancel`、`generation++`、`cancelWork`（收起≠取消） |
| `test_snapshot_busy_restore_semantics_preserved` | 三类中断 stage 提示仍在；`restoreSnapshot:` 实现体在；`busy` 行仍路由到 `cancelWork` |
| `test_dealloc_aborts_inflight_without_changing_cancel_semantics` | dealloc 取消在途网络任务但不写 `busy=NO`/stage |

结果：**5/5 通过**。

回归：`Tests/test_resource_interaction_contracts.py`（覆盖既有快照/cancel 契约）。该文件 138 例中 3 例（`test_release_waits_for_verified_build…`、`test_fullscreen_player_shows_observed_rate…`、`test_tvbox_playback_keeps_native_api_client…`）失败，**已 `git stash` 在基线 842b82b 复现为既有失败**（断言对象为 playback/release 源码，与本改动无关）；本改动未引入新失败。

## 4. 改动清单

- `cctv-ios-host/Sources/ResourceImportWorkflowViewController.m`（+9 行，新增 `applyModalDismissProtection` + `updateView` 调用）
- `cctv-ios-host/Tests/test_resource_import_dismiss_protection_contracts.py`（新增，5 例契约测试）

## 5. 一句话结论

落地了审计 §6/§9 指出的 `isModalInPresentation` 防误 dismiss 保护（与 busy 绑定、在 updateView 刷新），显式取消/进度恢复语义与快照系统均保持原状；iPad sheet 适配按低风险暂缓并说明依据。
