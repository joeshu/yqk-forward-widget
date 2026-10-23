# CCTV SDK 起播研究与 0.17.3 实现

依据用户上传的《央视网iOS播放器集成手册》BV3.23.17（2025-10-27），并核对当前 SDK 3.23.28 的导出接口与直播实现。

## 可确认结论

1. prepareToPlay 包含 VDN、一级 HLS、EPG、码率准备及缓冲。SetupPlayer 是 VDN 等完成、开始设置内核；FirstRenderDidStart 才是真实首帧，PrepareDone 不等于首帧。
2. reset/removePlayerCore 会释放内核。仅复用 CNPlayer 外壳，随后重新 playLIVE，并不能保证省掉 VDN。当前日志的宿主准备约 0.15 秒，而调度约 2.3–3.6 秒；减少宿主几毫秒不能解释全部差距。
3. 手册通用说明 retry 不重新请求 VDN，但当前直播 retry_needRefreshVDN 路由到 retryLive。retryLive 会 emptyRates、setVdnDataItem:nil，再 prepareToPlay。因此不能把通用 retry 说明当作当前直播免调度保证，本次不据此修改重试逻辑。
4. DefaultRate、SupporttedRates 等手册选项标明点播用途；没有依据将其当作直播快速起播参数。保留 SDK 选码率与 DRM/版权流程。
5. prepareRateItemToPlay_completionBlock: 是有文档和实际接口支持的元数据准备入口；不会由宿主调用 prepareToPlay/play，也不建立第二个视频渲染会话。

## 实现

首帧稳定 3 秒后，仅预解析列表中的下一个 CCTV 原生频道。最多持有一个 SDK 实例，自开始起 15 秒有效；关闭 autoplay，使用单独代理。没有命中、未完成、过期、失败、切到订阅或进入后台时 reset 释放。取消代次保护过期回调。

选台命中时直接转交该实例，仅更新代理与 autoplay，再 prepareToPlay；不重复 playLIVE，不在转交前 stop/reset，保留 SDK 的 CNPlayerItem/已解析信息。自动线路才使用预解析；手动 CDN 线路保持原流程。失败仍按既有有限重试回退正常起播。记录 preloadedVDN 阶段；不导出、拼接或绕过受保护 URL、license 与版权检查。

设置新增“预解析下一个 CCTV 频道”（默认开启）和“SDK 详细日志（诊断）”（默认关闭）。常态保留宿主阶段日志、关闭 SDK 内核/网络/统计详细日志，减少输出开销。

## 验证与实际限制

Foundation 执行测试覆盖元数据模式、一次转交、未完成/过期/错误频道、替换/取消后的旧回调及不支持的 SDK。模拟器验证已准备实例被正式播放接管、未二次配置且到达首帧；这些测试验证生命周期，不验证闭源 SDK 的真实网络耗时。

预解析主要帮助短时间内连续切到相邻频道；任意跳台或过期时仍正常调度。它不能缩短所有频道的冷启动，也不能承诺消除 SDK 媒体分片、DRM 与首帧解码等待。真实 SDK 是否复用已解析信息及提速幅度，需用命中 preloadedVDN 的真机日志验证。

0.17.3 同时包含 0.17.2 的内置 YSP Live 订阅刷新与首帧后停顿修正，见 PLUGIN-v0.17.2.md。
