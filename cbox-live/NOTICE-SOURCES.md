# 新增来源代码与资料

上游：akiralereal/iptv — https://github.com/akiralereal/iptv

版本：提交 e475b2f6d24029f844ada2b362d703c8b88c2e9b（2026-10-20）。

上游许可证：GNU General Public License, version 3（GPL-3.0）。许可全文随交付包提供，并压缩内嵌于 Python 文件，可用 `--licenses` 输出。

涉及文件：

- `extractors/yangshipin/ckey.js`：完整代码压缩内嵌，运行时仅调整 ES module 导出并添加调用入口，使用 Node 内置 crypto，未修改其签名算法。
- `extractors/yangshipin/api.js`：参考请求参数、返回字段、主备地址规则，实现 Python HTTP 集成。
- `extractors/yangshipin/channels.js`：63 个公开请求目录、官方台标及分频道清晰度数据。
- `extractors/yangshipin/epg.js`：参考官方节目单 protobuf 字段，新增有边界校验的 Python 读取器。
- `extractors/ningxia/api.js`、`epg.js`：官方固定目录与官方节目单资料。
- `extractors/heilongjiang/api.js`：官方固定目录、台标及 4430 端口资料。
- `utils/cntvEpg.js`：v1.3 起参考备用官方节目单接口。

本次修改：新增 Python SourceClient、来源独立缓存和代理令牌、多来源 M3U/XMLTV 汇总、官方节目单故障切换及验证记录。完整新增适配源码随 Python 文件提供；内嵌 JS 的源文本也能由该文件中的 gzip/base85 常量直接还原。

本许可记录针对新增适配及上游参考材料。现有官方播放器内核等第三方材料保留其原有权利，频道及节目内容权利属于相应权利人。


v1.5 修改：将原 cKey 算法移植为 Python 标准库实现，保留原 JS 参考源码与许可；新增 AptvCatalog 同台来源对应、优先选择及失败退避、统一 XMLTV ID、节目单 ETag/304、错误媒体识别。签名无需 Node；原网页 CDRM 内核仍为可选 Node 功能。


v1.5.1：修复非主线程托管环境的 signal 注册异常；改进缓存降级、缓存初始化复用、日志输出及退出资源清理。来源算法和目录未变。


v1.5.2：APTV 内置 Python 无 Node 时的默认/旧频道入口兼容、HTTP 读循环及结束阶段的正常断连处理、缺少 CDRM 内核时的提前拒绝和能力提示限频；来源目录和签名算法未改。


v1.5.3：参考上游央视频取流器关于重复 CDN 请求及直播分片地址稳定性的处理思路，新增 Python 分片并发合并、Range 与完整分片共享、短暂失败缓存、清单两秒共享及按频道隔离的普通 TS 地址稳定处理；新增上下文诊断和能力筛选。仅使用官方清单实际提供的媒体地址，不修改签名算法。


v1.5.4：参考同一上游版本的 extractors/yangshipin/index.js、api.js、resolver.js 关于清单 relay、播放器直连分片、取票预算、403 冷却及 APTV 清单超时恢复的处理思路，以 Python 标准库实现。仅采用公开流官方返回的媒体地址；保留可选旧代理模式。预算、缓存与恢复策略为本项目适配，不是对上游所有功能的完整移植；未加入浏览器会员流或原 App UDRM。


v1.5.5-preview（独立研究版）：继续参照同一上游版本 extractors/yangshipin/resolver.js 与 playlist-history.js，以 Python 实现直连分片重叠 URL/时长稳定、基于官方留存范围的已观察连续历史、慢节点短暂回退容忍、观看期间共享刷新与缓存节目单辅助版权冷却。本项目未移植猜测缺片 URL/时长的补洞、浏览器会员桥接和 libVLC 垫片；复杂 HLS 不作历史合并。


v1.5.6：合入 v1.5.5-preview 的直播窗口与共享刷新；继续参考 extractors/yangshipin/resolver.js 的旧票据失效续票、官方候选入口优先顺序及全 403 识别，新增 Python 有界重试和安全代理拒绝诊断。增加真实 HLS 客户端连续解码验证，保留原逐片测试的失败记录与验证范围说明。
