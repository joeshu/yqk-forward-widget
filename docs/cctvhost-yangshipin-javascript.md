# CCTVHost 0.17.7：在 App 执行央视频原版 JavaScript

服务页新增“央视频 JS”，默认端口 18770。启用后自动添加 `http://127.0.0.1:18770/all.m3u` 到订阅，在“频道”页用 AVPlayer 播放。`/m3u`、`/all.m3u8` 同样可用；`/health` 返回引擎和频道数，`/epg.xml` 返回已观看频道的官方节目单缓存。首次播放后按需获取节目单，不在启动时扫描全部频道。

这不是把提取器改写成 Python。App 链接系统 JavaScriptCore，直接执行从 joeshu/iptv 提取器打包的 JavaScript。`index.js`、`api.js`、`ckey.js`、`channels.js`、`epg.js`、`resolver.js`、`playlist-history.js` 和 `libvlc-view.js` 保留原文件内容；来源固定为 `b121ed0291ae6751329f7a1b1b300605eaebc8f0`。`JSPlugins/yangshipin/SOURCE.json` 记录每个文件的 SHA256，构建时校验。原 JS 源码、GPL-3.0 许可与依赖声明也随 IPA 提供。

Python 文件 `Plugins/yangshipin-js.py` 仅提供 HTTP 入口和 XMLTV 输出，通过原生函数把请求传给 JS。频道取流、cKey、清单选线/刷新、URL 固定、限频/冷却和清单历史逻辑都在原 JS 中执行。该适配器单独放到旧版 CCTVHost 或普通 Python 中不会获得 JS 能力；须安装包含原生桥接的新 IPA。

## 当前能力

| 能力 | 支持情况 |
| --- | --- |
| 63 个公开频道、原版 JS 频道表和官方台标 | 支持；接口是否开放仍取决于平台、地区和节目版权 |
| 原版 cKey 和公开直播 API | 支持；不改写算法为 Python |
| `Buffer`、URL、URLSearchParams、Promise、AbortController | 已提供对应实现 |
| `node:crypto` 的 randomBytes/randomUUID | 原生安全随机数桥接 |
| fetch、setTimeout/clearTimeout、基本 interval | 原生 NSURLSession/定时队列桥接 |
| 官方 EPG | 按播放频道获取，最多一路后台 EPG 请求 |
| 普通 TS 分片播放 | JS 下发清单，播放器直连官方 CDN，不用 Python 全量代理 TS |
| 依赖 Chromium 的会员登录/会员浏览器分支 | 不支持；运行时明确报告不可用，不假装能登录或解锁 |
| 任意 Node.js 包、fs/child_process、npm 服务直接原样运行 | 不支持；这是为本提取器补齐 API 的 JavaScriptCore 环境，不是完整 Node.js |
| 从服务编辑器任意导入多文件 JS 工程 | 尚未提供通用工程导入；本次提供已集成的原版央视频 JS 插件 |

入口层只提供公开频道，不把 10 个需要浏览器登录的频道放进可播放订阅。上游 index.js 的浏览器 runtime 导入由显式能力适配器替换；该适配器不实现 Chromium，会返回不支持。其它公开取流模块保持原样。

## 生命周期与资源

JavaScript 由单独串行队列管理，网络等待不占界面线程，Python 调用时释放 GIL。网络只允许 HTTPS 的 CCTV/央视频域，最多 8 个并发响应，每份最大 1 MB；最多 128 个活动定时器、16 个待完成桥接调用。HTTP 入口最多 12 个处理线程，HEAD 不触发上游取票。停止服务会清理原版解析器定时任务、取消网络、释放上下文并唤醒待完成调用。会话标识避免旧请求重新启动已停止的上下文，或停止后来启动的新服务。

用“查看代码”可查看/导出打包后的 JavaScript；对应原始模块和构建脚本在 `cctv-ios-host/JSPlugins`。这次没有改变用户原有 Python 服务的执行方式，也没有把它们迁移到 JS。

## 验证边界

Node VM 测试移除 Node 全局对象后执行打包 JS，验证原版 cKey 与 Node 原版生成结果逐字节一致、63 个公开频道、URL/Buffer/fetch 桥接、主/媒体清单、清单推进、停止定时器和拒绝浏览器频道。

macOS 测试使用真实 JavaScriptCore 和原生安全随机数/NSURLSession，网络由 URLProtocol 提供固定响应；验证实际 JS 执行、HTTPS 异步结果、停止中断未完成请求及新旧会话隔离。它不是 SDK 替身的 UI 测试。

另外用原版 JS 签名请求真实 CCTV13 公开接口，返回 iretcode=0，并取到有效 HLS 清单。没有预取 TS 分片，未把这一步称为真机音画验证。接口可用性、地区限制、频道版权及会员能力不因桥接改变。
