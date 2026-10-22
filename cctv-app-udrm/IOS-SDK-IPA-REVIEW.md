# 央视影音 iOS SDK 样本与正式接口核对

2026-10-22。对用户提供的 7.9.31 IPA 做了只读包结构、Mach-O 加载命令/导出及选定 Objective-C 前端接口元数据检查。没有执行或加载其中的二进制，没有分析 DRM 方法实现、密钥或许可数据。本报告发布元数据，不另行分发 SDK 二进制。该修改后样本的原始供应方分发与签名真实性未独立认证。

## 本轮解决到哪一步

已从样本定位到独立的 iOS 真机 ARM64 播放 SDK 候选 **CNPlayerSDK.framework**，并确认实际依赖关系和前端原生播放器接口。随后核实用户附件与包内**央视网iOS播放器集成手册BV3.23.17逐字节一致**：基础工程接入、VOD、视图、生命周期、回调和错误表已取得。上一轮漏查中文Markdown文档，对“未取得正式手册”的表述现予更正。完整头文件、LIVE/UDRM配置与服务授权合同、APTV宿主接入仍未取得。详见 [手册复核及实施策略](IOS-SDK-MANUAL-REVIEW.md)。本轮没有完成原生播放或性能验证。

这比此前只按 Android `kooplayer` 名称寻找 iOS 库更具体。旧手机探针 v0.1.0 未匹配 CNPlayerSDK/CicadaPlayerSDK，也未查询已注册 Objective-C 类，故旧结果不能完整排除这些 SDK。`ctx` 缺失只描述那次入口调用，不能证明 APTV 不存在其他模块或全局接口。

## 二进制证据

样本 74,093,434 字节，SHA-256：`e7b153ab80a17a646d7011ebedc17b786835ab27feba4959af07bcc7ec8c9315`，Git blob SHA-1 与仓库元数据一致。Info.plist 声明：`cn.vuclip.mobiletv`、央视影音、7.9.31/build 1、最低 iOS 15。包内共24个 framework，没有发现 `.h`、`.modulemap`、`.swiftinterface` 或 `.a` 接口/静态库文件，但CNPlayerSDK目录确有19,218字节的集成手册，SHA-256为`908d2581305dcfe5663cc3754c697345682f15efbaf1a6bda075d3a39407e797`。

| 样本组件 | Mach-O / 平台 | 二进制大小 | 加载命令中的非系统依赖 |
|---|---|---:|---|
| CNPlayerSDK | arm64 / MH_DYLIB / iPhoneOS，最低 iOS 10 | 14,968,320 B | CicadaPlayerSDK、xnet |
| CicadaPlayerSDK | arm64 / MH_DYLIB / iPhoneOS，最低 iOS 11 | 6,917,760 B | alivcffmpeg |
| alivcffmpeg | arm64 / MH_DYLIB / iOS，最低 iOS 9 | 12,190,144 B | 未见其他包内 framework 依赖 |
| xnet | arm64 / MH_DYLIB / iOS，最低 iOS 9 | 3,004,224 B | 未见其他包内 framework 依赖 |
| Tquic | arm64 / MH_DYLIB / iOS，最低 iOS 10 | 2,728,048 B | 未见其他包内 framework 依赖 |

主 App 的加载命令直接引用 CNPlayerSDK、CicadaPlayerSDK、alivcffmpeg、xnet、Tquic；CNPlayerSDK 再依赖 CicadaPlayerSDK 和 xnet。Tquic 是主 App 的另一个直接依赖，本次未证明它是 CNPlayerSDK 的独立必要依赖。CNPlayerSDK 的 bundle 元数据声明 `com.cctv.ysyy.CNPlayerSDK`；Cicada 声明 `com.alibaba.CicadaPlayerSDK`。CNPlayerSDK 和 Cicada 的平台声明均为 `iphoneos`/`iPhoneOS`，并由独立 `file` 工具复核为 arm64 动态共享库。

## 接口证据的边界

在 CNPlayerSDK 导出及 Objective-C 前端元数据中观察到：

- `CNPlayer`、`CNPlayerConfig`、`CNPlayerStartOptions`、`CNPlayerPlayOptions` 等类；主 App 确实导入 CNPlayer/CNPlayerConfig 等符号。
- CNPlayer 的 `view` 为只读 `UIView`；`delegate` 标为弱引用的 `CNPlayerCallbackProtocol`。名为 `dataSource` 的属性标为 `CNPlayerRecordsDataSource`，不能因名称就认定它是媒体输出接口。
- 直播前端方法包括 `initWithLIVEChannelID:delegate:configOptions:`、`initWithLIVEUrl:delegate:configOptions:`、`prepareToPlay`、`play`、`pause`、`stop`，以及 SDK 启动/版本入口。
- 初始化方法的运行时编码只把参数标为通用对象，不能据此确定配置键、具体类型、所有权、回调契约、主线程要求或服务授权流程。

这为“由宿主嵌入原生播放器视图”的路线提供了正面证据。在本次选定前端类中，**没有证明可输出编码 TS/PES、供现有 Python HLS 服务处理的正式接口**；也不能据这次有限检查断言整个 SDK 都没有此能力。完整选定名称/类型观察见 [IOS-SDK-INTERFACE-OBSERVATIONS.json](IOS-SDK-INTERFACE-OBSERVATIONS.json)。它是运行时元数据观察，**不是官方头文件或稳定 ABI 合同**，不包含方法实现。

## 已取得的集成文档与公开接口

随包CNPlayer手册明确三库、arm64、工程链接/签名、启动、VOD、视图和回调等基础接口；手册最低iOS9与本样本组件10/11及App15不同，且样本另外依赖xnet，不能把这份旧基础清单作为本样本的完整依赖/兼容合同。LIVE构造、用户另列的CICADA_UDRM配置注入/许可检查方法并未在此手册中完整定义。

Alibaba 的 [CicadaPlayer iOS 使用指导](https://github.com/alibaba/CicadaPlayer/blob/master/platform/Apple/README.md)与 [CicadaPlayer.h](https://github.com/alibaba/CicadaPlayer/blob/master/platform/Apple/source/CicadaPlayer.h)公开 `CicadaPlayer`、`CicadaUrlSource`、视图/事件回调及 `prepare/start/stop/destroy` 生命周期；[iOS构建说明](https://github.com/alibaba/CicadaPlayer/blob/master/doc/compile_ios.md)提供原生宿主的构建路线。

这些资料证明通用 iOS 播放器内核有正式公开 API，未证明公开 CicadaPlayer 可以单独播放本次央视 UDRM，也未核验样本定制二进制与当前公开源码的版本/ABI对应。阿里云[加密播放指导](https://help.aliyun.com/zh/vod/developer-reference/play-an-encrypted-video)的 iOS 三方 DRM 说明针对 HLS/FairPlay，不能代替央视专用封装的正式集成说明。Cicada 的开源许可也不覆盖 CNPlayerSDK 或央视的私有服务授权。

公开检索仍未取得供应方的完整SDK头文件和公共下载，但随包基础手册已经核验取得。需要补齐的是匹配版本的头文件/协议/枚举、LIVE/UDRM配置与服务授权样例；从二进制单独观察到的名称仍不能自动补全这些合同。

## 可交付给宿主与 SDK 提供方的接入要求

1. **央视 SDK 方**：在已取得基础手册的基础上，补齐当前直播服务兼容的分发SDK、CNPlayer/配置/回调协议头文件、LIVE/UDRM授权样例、资源/依赖版本、线程及释放约定。版本查询和包内 Info.plist 的 `1.0` 不能代替实际 SDK 版本合同。
2. **明确输出类型**：若正式接口提供的是 CNPlayer 原生视图，由 APTV 原生页面嵌入其 UIView并接入控制、音频会话与前后台。若要维持 `Python → 本地M3U/HLS` 架构，则必须由提供方确认编码媒体输入/输出接口；目前不能把 CNPlayer 当作已有的 `transform(ts)` 函数。
3. **APTV 宿主方**：确认 9.9.9（548）是否有可支持的原生模块/插件合同；由宿主工程链接、嵌入、签名 SDK及传递依赖，并暴露有明确线程、取消和对象生命周期的桥接。Apple [TN2435](https://developer.apple.com/library/archive/technotes/tn2435/_index.html)和[代码签名说明](https://support.apple.com/guide/security/sec7c917bf14/web)给出约束。正确集成的 framework 可设计加载/调用方式，不能一概说 iOS 不支持 dlopen；另一个 App 的库文件也不证明 APTV 脚本已具备安装/加载能力。
4. **验证顺序**：先在受支持原生宿主查询版本/能力，再按正式接口授权播放单频道，随后接入 APTV。最后用同设备、同频道和同画质比较首帧、持续吞吐、CPU/RSS及后台恢复。原生路径目标是去掉 Android ARM 模拟层；包体大小、峰值内存和提速比例仍须分别测量。

本轮没有发送第三方消息，没有修改 v0.3.7 播放引擎或降低清晰度。

## 修正后的只读手机探针

[cctv-ios-native-probe-v0.1.1.py](https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/cctv-app-udrm/diagnostics/cctv-ios-native-probe-v0.1.1.py)新增 CNPlayerSDK/CicadaPlayerSDK/配套库名称匹配，以及通过系统 `objc_lookUpClass` 只读查询已注册 CNPlayer/CicadaPlayer 类。它不向这些类发送方法消息，也不加载 IPA 中的任何库。查询结果只说明当前进程可见的候选，不能证明官方兼容或正式插件接口。

在 APTV 中停止旧检测服务并加载新版，启动日志或 `http://127.0.0.1:18771/status` 输出报告。保留原播放服务；此脚本不提供节目订阅。探针相关12项本地检查通过（含新版本5项），平台调用使用合成 iOS 对象；旧版另有真实本地 HTTP 检查。**新版尚未在用户 iPhone 执行**。所有者线程、许可、原生 SDK播放及性能均未因此得到验证。

可复核摘要：[IOS-SDK-IPA-METADATA.json](IOS-SDK-IPA-METADATA.json)。
