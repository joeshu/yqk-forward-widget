# CCTVHost 0.15.1 切台优化

- 原生 SDK 切台从 `stop → reset → playLIVE → prepareToPlay` 改为
  `reset → playLIVE → prepareToPlay`。SDK 手册明确 reset 会释放播放内核，
  不再先执行一次 stop。仍复用 CNPlayer 外层实例，不跨频道复用受保护的播放地址。
- 记录实例是否使用过，首次使用预热实例不再 reset；重试及从订阅切回 SDK 时仍重置旧内核。
- 清理播放器前先断开回调，避免同步的停止/重置事件修改新频道状态。
- 切台取消旧节目单任务和定时器，新节目单在 SDK 首帧后加载，减少起播时的并发网络请求。
- 订阅 AVPlayer 的前向缓冲目标设为 1 秒，关闭起播时额外的防卡顿等待。
  弱网下可能更早出现缓冲；该设置只影响订阅，不改变官方 SDK 的缓冲策略。
- 清理订阅失败通知，给旧条目的状态回调和 12 秒超时增加当前播放校验。
- SDK 首帧日志记录从选台起算的耗时，使用单调时钟，便于真机前后对比。

## 验证

本地执行 `python3 -m unittest discover -s cctv-ios-host/Tests -p 'test_*.py' -v`。
这些测试包含源码约束和打包/引导逻辑检查，不代表真机播放验证。

优化分支 `codex/cctv-fast-switch` 的 push 会触发现有 macOS 构建工作流，
执行 Objective-C 语法检查、编译及 IPA 结构校验，上传 unsigned IPA；
该分支不触发 Release 发布。

真机对照建议：相同设备/网络，用 0.15.0 和 0.15.1 各完成
CCTV1 → CCTV13 → CCTV5 → CCTV1 十轮，比较“首帧渲染 X.XXs”的中位数与慢端耗时；
另外测试 SDK/订阅互切、连续快速切台、指定 CDN、弱网及断流重连。
尚无真机测量结果，不承诺具体秒数或提速百分比。
