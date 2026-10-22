# iOS运行层减重研究（2026-10-22）

后续进展：memcpy/memmove/memset现已在v0.3.6实现WASM回调下沉及兼容回退，见[实现与实测](WASM-BACKEND-v0.3.6.md)。以下保留最初研究的依据和限制；原生iOS SDK/TCTI路线仍未集成。

本次研究不修改v0.3.4生产脚本、不声称已获得官方iOS SDK，也不将其他项目宣传的速度当成本项目实测。关注如何移除或减少ARM64模拟成本，保留正常许可验证和高清媒体。

## 实测定位

对最终v0.3.4执行三组原媒体样本、正式SDK许可，插桩只记录调用数量与耗时，不记录JS表达式、许可载荷、密钥或媒体。三组输出摘要与历史一致，600帧音视频解码错误0。

媒体阶段150次JSC求值合计1.4069秒；150次输入传输0.0131秒、150次输出传输0.0069秒。相对于这三项合计，JSC求值约占98.6%。这里的求值包含JS适配、模拟器执行与结果转换，不等于已单独测出ARM模拟占98.6%；也不包含所有Python映射、网络和播放器开销。启动阶段求值另计约2.1683秒，不能和媒体处理混算。

整个会话累计宿主调用中memcpy 25,281次、malloc 5,616次、memset 5,021次、pthread_mutex_lock/unlock各1,775次；这些数量包含初始化与许可，不是600帧媒体独占。VM每次进入导入存根会停止模拟、返回JS处理，再恢复执行，因此可进一步研究把可证明语义等价的通用libc适配移入模拟器内部，减少边界往返。尚未分离各类调用耗时，不能仅按次数认定某函数就是最大瓶颈；不移除锁、跳过SDK处理或短路许可来求快。

数据见 [运行剖析](RUNTIME-RESEARCH-PROFILE.json)。环境Linux JavaScriptCoreGTK；未测iPhone总RSS、功耗或持续实时处理。

## 公开项目经验及适用条件

| 路线 | 公开依据 | 适用判断 |
| --- | --- | --- |
| 官方iOS SDK原生集成 | iOS原生播放器/SDK常规集成方式；本次未发现可验证的央视UDRM公开XCFramework及授权文档 | 优先级最高：可能同时移除Unicorn、WASM和Android ABI适配；需官方SDK、集成许可与APTV提供原生接口。SDK可能只输出受保护播放表面，未必允许输出明文TS，不预设可以做M3U代理 |
| 原生线程化解释器 | UTM SE使用TCTI；iSH使用函数/gadget链减少传统switch分派 | 已有实际项目依据，不依赖动态机器码生成；需预编译原生后端随宿主签名分发。现有WASM TCI不能靠Python参数变成原生TCTI；迁移Unicorn到相应后端仍需工程验证 |
| WASM预编译到原生C/AOT | WABT wasm2c将WASM转C并编译链接运行时 | 可研究移除JSC执行WASM这层，ARM模拟仍保留；需要编译、导入适配、正确性验证和宿主内置签名组件。不是下载C文件或dylib后即可在APTV执行 |
| 通用libc适配下沉到WASM | 本项目实际大量memcpy/memset/分配器导入往返 | 有望减少JS↔WASM分派；需要重建模拟器宿主后端并与原版逐调用/媒体差分验证。对malloc、锁、重叠memcpy、越界和错误语义不能随意替换，当前未实现 |
| 官方可直放HLS/系统DRM | Apple FairPlay Streaming文档；参考仓库公开频道直连CDN视图 | 先确认同一频道、同一授权、同一画质及官方允许的播放器路径。TS容器或HTTP200不代表视频ES可直接解码；当前UDRM不能改个标签就变FairPlay。央视频是独立来源，不能冒充原央视影音UDRM路径 |
| 其他JS引擎/多开模拟器 | 未获得同条件可复现提速证据 | 不列为优先方案；仍有ARM模拟，多实例复制状态会增加内存 |

UTM项目称SE使用线程化解释器，性能优于传统解释器但慢于JIT；iSH README中的3–5倍是其自身与简单switch解释器的比较，不适用于本项目。JavaScriptCore即使能为JS或WASM优化，也不等同于Unicorn已拥有直接生成iOS ARM机器码的后端。

## 系统约束需要说准确

“安卓.so不能直接加载到iOS”指现有二进制与ABI不兼容，不是说任何跨平台移植都不可能。ELF装载、Android libc/JNI、TLS、线程和系统调用语义都需要解决；同为ARM64不能自动消除这些差异。开发一个签名的原生兼容层属于宿主工程，不是ctypes换一个路径。

Apple App Review 2.5.2对下载执行改变应用功能的代码有规则和例外；本次不据此推断APTV具体具有什么权限，也不把macOS的allow-jit entitlement当成任意iOS应用都能使用的能力。APTV的实际原生插件、动态加载和JIT能力尚无可核验的接口文档。不能承诺下载未集成的framework即可使用。

FairPlay需要内容服务端与播放器完整配合；官方文档明确生产凭据需要审批。这是标准播放机制的参考，不是把当前UDRM转换成FairPlay的工具。App能正常播放仅证明App已有相应实现与授权，不证明第三方播放器拥有同等SDK接口。

## 可推进的实施顺序

1. 保留当前单文件作为正确性基线及回退，固定样本输出摘要、正式许可和高清选择条件。
2. 对模拟器导入分派按阶段计时，区分初始化、许可和媒体；先证明通用libc桥接的耗时占比，再决定是否值得自建WASM后端。
3. 与宿主集成时优先评估官方iOS SDK；若不可获得，才比较原生线程化解释器与WASM AOT。先用无媒体的算术/内存程序测试，再以相同授权和同批样本差分；不提前承诺倍数。
4. 接口验证清单见 [宿主集成要求](HOST-INTEGRATION-REQUIREMENTS.md)。没有宿主原生接口时，以上原生路线不能伪装成已经在单文件里实现。

## 公开来源

- UTM iOS安装说明：https://docs.getutm.app/installation/ios/
- UTM README：https://github.com/utmapp/UTM （UTM SE章节）
- TCTI设计：https://github.com/ktemkin/qemu/blob/with_tcti/tcg/aarch64-tcti/README.md
- iSH实现说明：https://github.com/ish-app/ish/blob/master/README.md
- wasm2c编译流程：https://github.com/WebAssembly/wabt/blob/main/wasm2c/README.md
- Apple审核规则2.5.2：https://developer.apple.com/app-store/review/guidelines/#software-requirements
- Apple FairPlay：https://developer.apple.com/streaming/fps/
- 参考仓库直连视图：https://github.com/akiralereal/iptv/blob/main/extractors/yangshipin/libvlc-view.js
- 当前Unicorn.js：https://github.com/AlexAltea/unicorn.js/tree/v2.1.4

上述链接本轮已读取。GitHub仓库关键词搜索未找到可核验的公开央视iOS UDRM SDK，搜索结果不等于证明其不存在；尚无SDK包、头文件、集成手册和APTV原生插件文档，官方iOS路线仍属待验证。
